-- =========================================================
-- Fix: Correct status values to match frontend expectations
-- Original uses 'draft', my fix incorrectly used 'drafting'
-- =========================================================

-- Fix the validation trigger to use correct status values
CREATE OR REPLACE FUNCTION public.validate_game_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Prevent invalid status transitions
  -- Valid: lobby -> draft -> scoring -> complete/done

  IF OLD.status IN ('complete', 'done') THEN
    RAISE EXCEPTION 'Cannot modify completed game';
  END IF;

  IF OLD.status = 'scoring' AND NEW.status NOT IN ('scoring', 'complete', 'done') THEN
    RAISE EXCEPTION 'Invalid status transition from scoring';
  END IF;

  IF OLD.status = 'draft' AND NEW.status NOT IN ('draft', 'scoring', 'complete', 'done') THEN
    RAISE EXCEPTION 'Invalid status transition from draft';
  END IF;

  IF OLD.status = 'lobby' AND NEW.status NOT IN ('lobby', 'draft') THEN
    RAISE EXCEPTION 'Invalid status transition from lobby';
  END IF;

  RETURN NEW;
END;
$$;

-- Fix ff_start_draft to use 'draft' not 'drafting'
CREATE OR REPLACE FUNCTION public.ff_start_draft(p_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  player_count int;
  i int;
  arr uuid[];
BEGIN
  SELECT count(*) INTO player_count FROM public.game_players WHERE game_id = p_game_id;

  IF player_count < 2 THEN
    RAISE EXCEPTION 'Need at least 2 players to start';
  END IF;

  SELECT array_agg(user_id ORDER BY random()) INTO arr
  FROM public.game_players WHERE game_id = p_game_id;

  FOR i IN 1..array_length(arr, 1) LOOP
    UPDATE public.game_players
    SET draft_position = i
    WHERE game_id = p_game_id AND user_id = arr[i];
  END LOOP;

  UPDATE public.games
  SET status = 'draft',
      current_drafter = 1,
      pick_number = 1,
      current_direction = 1,
      draft_started_at = now(),
      turn_started_at = now()
  WHERE id = p_game_id;
END $$;

-- Fix ff_advance_draft to use 'scoring'
CREATE OR REPLACE FUNCTION public.ff_advance_draft(p_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  total_players int;
  total_rounds int;
  next_drafter int;
  next_direction int;
  next_pick int;
BEGIN
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;
  SELECT count(*) INTO total_players FROM public.game_players WHERE game_id = p_game_id;

  total_rounds := coalesce((g.settings->>'totalRounds')::int, 15);
  next_pick := g.pick_number + 1;

  IF next_pick > total_players * total_rounds THEN
    UPDATE public.games SET status = 'scoring', turn_started_at = now() WHERE id = p_game_id;
    RETURN;
  END IF;

  next_drafter := g.current_drafter + g.current_direction;
  next_direction := g.current_direction;

  IF next_drafter > total_players THEN
    next_drafter := total_players;
    next_direction := -1;
  ELSIF next_drafter < 1 THEN
    next_drafter := 1;
    next_direction := 1;
  END IF;

  UPDATE public.games
  SET current_drafter = next_drafter,
      current_direction = next_direction,
      pick_number = next_pick,
      turn_started_at = now()
  WHERE id = p_game_id;
END $$;

-- Fix validation for game_results to accept 'complete' or 'done'
CREATE OR REPLACE FUNCTION public.validate_game_result()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game_rec RECORD;
  was_player BOOLEAN;
BEGIN
  SELECT * INTO game_rec FROM public.games WHERE id = NEW.game_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid game_id';
  END IF;

  -- Game must be in scoring or complete status
  IF game_rec.status NOT IN ('scoring', 'complete', 'done') THEN
    RAISE EXCEPTION 'Game is not in scoring phase';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.game_players
    WHERE game_id = NEW.game_id AND user_id = NEW.user_id
  ) INTO was_player;

  IF NOT was_player THEN
    RAISE EXCEPTION 'User was not a player in this game';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.game_results
    WHERE game_id = NEW.game_id AND user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Result already recorded for this user';
  END IF;

  RETURN NEW;
END;
$$;

-- Fix validation for game_picks to check 'draft' status
CREATE OR REPLACE FUNCTION public.validate_game_pick()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game_rec RECORD;
  drafter_rec RECORD;
BEGIN
  SELECT * INTO game_rec FROM public.games WHERE id = NEW.game_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid game_id';
  END IF;

  IF game_rec.status <> 'draft' THEN
    RAISE EXCEPTION 'Game is not in drafting phase';
  END IF;

  SELECT * INTO drafter_rec FROM public.game_players
  WHERE game_id = NEW.game_id AND draft_position = game_rec.current_drafter;

  IF drafter_rec.user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'Not your turn to pick';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.game_picks
    WHERE game_id = NEW.game_id AND player_id = NEW.player_id
  ) THEN
    RAISE EXCEPTION 'Player already drafted';
  END IF;

  IF NEW.pick_number <> game_rec.pick_number THEN
    RAISE EXCEPTION 'Invalid pick number';
  END IF;

  RETURN NEW;
END;
$$;

-- Fix ff_make_pick to check 'draft' status
CREATE OR REPLACE FUNCTION public.ff_make_pick(
  p_game_id uuid,
  p_user_id uuid,
  p_player_id text,
  p_slot text
)
RETURNS TABLE(success boolean, pick_number int, next_drafter_user_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  drafter record;
  v_pick int;
BEGIN
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;
  IF g.status <> 'draft' THEN
    RAISE EXCEPTION 'Game is not in drafting phase';
  END IF;

  SELECT * INTO drafter FROM public.game_players
  WHERE game_id = p_game_id AND draft_position = g.current_drafter;

  IF drafter.user_id <> p_user_id THEN
    RAISE EXCEPTION 'Not your turn to pick';
  END IF;

  IF EXISTS (SELECT 1 FROM public.game_picks WHERE game_id = p_game_id AND player_id = p_player_id) THEN
    RAISE EXCEPTION 'Player already drafted';
  END IF;

  v_pick := g.pick_number;

  INSERT INTO public.game_picks(game_id, user_id, player_id, slot, pick_number, round, picked_at)
  VALUES (p_game_id, p_user_id, p_player_id, p_slot, v_pick,
          ((v_pick - 1) / (SELECT count(*) FROM public.game_players WHERE game_id = p_game_id)) + 1,
          now());

  PERFORM public.ff_advance_draft(p_game_id);

  SELECT current_drafter INTO v_pick FROM public.games WHERE id = p_game_id;

  RETURN QUERY
  SELECT true,
         (SELECT pg.pick_number FROM public.games pg WHERE pg.id = p_game_id),
         (SELECT gp.user_id FROM public.game_players gp WHERE gp.game_id = p_game_id AND gp.draft_position = v_pick);
END $$;

-- Fix ff_auto_pick_if_needed to check 'draft' status
CREATE OR REPLACE FUNCTION public.ff_auto_pick_if_needed(p_game_id uuid, p_timeout_seconds int default 30)
RETURNS TABLE(did_auto_pick boolean, picked_player_id text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  drafter record;
  best_player text;
  best_slot text;
  slots_needed text[];
  s text;
  i int;
BEGIN
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;

  IF g.status <> 'draft' THEN
    RETURN QUERY SELECT false, null::text;
    RETURN;
  END IF;

  IF g.turn_started_at + (p_timeout_seconds || ' seconds')::interval > now() THEN
    RETURN QUERY SELECT false, null::text;
    RETURN;
  END IF;

  SELECT * INTO drafter FROM public.game_players
  WHERE game_id = p_game_id AND draft_position = g.current_drafter;

  slots_needed := ARRAY[]::text[];

  FOR i IN 1..coalesce((g.settings->>'qbSlots')::int, 1) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'QB') < i THEN
      slots_needed := array_append(slots_needed, 'QB');
    END IF;
  END LOOP;

  FOR i IN 1..coalesce((g.settings->>'rbSlots')::int, 2) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'RB') < i THEN
      slots_needed := array_append(slots_needed, 'RB');
    END IF;
  END LOOP;

  FOR i IN 1..coalesce((g.settings->>'wrSlots')::int, 2) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'WR') < i THEN
      slots_needed := array_append(slots_needed, 'WR');
    END IF;
  END LOOP;

  FOR i IN 1..coalesce((g.settings->>'teSlots')::int, 1) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'TE') < i THEN
      slots_needed := array_append(slots_needed, 'TE');
    END IF;
  END LOOP;

  FOR i IN 1..coalesce((g.settings->>'kSlots')::int, 1) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'K') < i THEN
      slots_needed := array_append(slots_needed, 'K');
    END IF;
  END LOOP;

  FOR i IN 1..coalesce((g.settings->>'dstSlots')::int, 1) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'DST') < i THEN
      slots_needed := array_append(slots_needed, 'DST');
    END IF;
  END LOOP;

  FOR i IN 1..coalesce((g.settings->>'flexSlots')::int, 1) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'FLEX') < i THEN
      slots_needed := array_append(slots_needed, 'FLEX');
    END IF;
  END LOOP;

  best_player := null;
  best_slot := null;

  FOREACH s IN ARRAY slots_needed LOOP
    IF s = 'FLEX' THEN
      SELECT player_id INTO best_player
      FROM public.player_week_stats
      WHERE season = (g.settings->>'season')::int
        AND week = (g.settings->>'week')::int
        AND position IN ('RB', 'WR', 'TE')
        AND player_id NOT IN (SELECT player_id FROM public.game_picks WHERE game_id = p_game_id)
      ORDER BY fantasy_points DESC
      LIMIT 1;
    ELSE
      SELECT player_id INTO best_player
      FROM public.player_week_stats
      WHERE season = (g.settings->>'season')::int
        AND week = (g.settings->>'week')::int
        AND position = s
        AND player_id NOT IN (SELECT player_id FROM public.game_picks WHERE game_id = p_game_id)
      ORDER BY fantasy_points DESC
      LIMIT 1;
    END IF;

    IF best_player IS NOT NULL THEN
      best_slot := s;
      EXIT;
    END IF;
  END LOOP;

  IF best_player IS NULL THEN
    PERFORM public.ff_advance_draft(p_game_id);
    RETURN QUERY SELECT true, null::text;
    RETURN;
  END IF;

  INSERT INTO public.game_picks(game_id, user_id, player_id, slot, pick_number, round, picked_at)
  VALUES (p_game_id, drafter.user_id, best_player, best_slot, g.pick_number,
          ((g.pick_number - 1) / (SELECT count(*) FROM public.game_players WHERE game_id = p_game_id)) + 1,
          now());

  PERFORM public.ff_advance_draft(p_game_id);

  RETURN QUERY SELECT true, best_player;
END $$;
