-- =========================================================
-- Fix: Add SECURITY DEFINER to game functions
-- This allows the functions to bypass RLS policies
-- =========================================================

-- ff_create_room
CREATE OR REPLACE FUNCTION public.ff_create_room(
  p_room_code text,
  p_settings jsonb,
  p_host_user_id uuid,
  p_host_name text
)
RETURNS TABLE(id uuid, room_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_code text;
  mp int;
  jmode text;
  sh text;
  g_id uuid;
BEGIN
  mp := greatest(2, least(12, coalesce((p_settings->>'maxPlayers')::int, 2)));
  jmode := coalesce(p_settings->>'joinMode','code');
  sh := p_settings->>'settingsHash';
  if sh is null then sh := md5(p_settings::text); end if;

  v_room_code := upper(trim(coalesce(p_room_code,'')));
  if v_room_code = '' then
    loop
      v_room_code := public.ff_gen_room_code();
      exit when not exists (select 1 from public.games gg where gg.room_code = v_room_code);
    end loop;
  end if;

  INSERT INTO public.games(room_code, status, settings, pick_number, max_players, join_mode, settings_hash)
  VALUES (v_room_code, 'lobby', p_settings, 1, mp, jmode, sh)
  RETURNING public.games.id INTO g_id;

  INSERT INTO public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
  VALUES (g_id, p_host_user_id, p_host_name, 1, true, true, now());

  RETURN QUERY SELECT g_id, v_room_code;
END $$;

-- ff_join_room
CREATE OR REPLACE FUNCTION public.ff_join_room(
  p_room_code text,
  p_user_id uuid,
  p_name text
)
RETURNS TABLE(game_id uuid, seat int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  ns int;
BEGIN
  SELECT * INTO g FROM public.games
  WHERE room_code = upper(trim(p_room_code)) AND status = 'lobby'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room not found or not in lobby';
  END IF;

  IF EXISTS (SELECT 1 FROM public.game_players gp WHERE gp.game_id = g.id AND gp.user_id = p_user_id) THEN
    UPDATE public.game_players gp SET display_name = p_name, is_active = true, last_seen = now()
    WHERE gp.game_id = g.id AND gp.user_id = p_user_id
    RETURNING gp.seat INTO ns;
    RETURN QUERY SELECT g.id, ns;
    RETURN;
  END IF;

  SELECT coalesce(max(gp.seat), 0) + 1 INTO ns FROM public.game_players gp WHERE gp.game_id = g.id;

  IF ns > g.max_players THEN
    RAISE EXCEPTION 'Room is full';
  END IF;

  INSERT INTO public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
  VALUES (g.id, p_user_id, p_name, ns, false, true, now());

  RETURN QUERY SELECT g.id, ns;
END $$;

-- ff_make_pick
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
  IF g.status <> 'drafting' THEN
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

  -- Advance to next drafter (snake draft logic handled in ff_advance_draft)
  PERFORM public.ff_advance_draft(p_game_id);

  SELECT current_drafter INTO v_pick FROM public.games WHERE id = p_game_id;

  RETURN QUERY
  SELECT true,
         (SELECT pick_number FROM public.games WHERE id = p_game_id),
         (SELECT user_id FROM public.game_players WHERE game_id = p_game_id AND draft_position = v_pick);
END $$;

-- ff_start_draft
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
  SET status = 'drafting',
      current_drafter = 1,
      pick_number = 1,
      current_direction = 1,
      draft_started_at = now(),
      turn_started_at = now()
  WHERE id = p_game_id;
END $$;

-- ff_advance_draft
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

-- ff_auto_pick_if_needed
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
BEGIN
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;

  IF g.status <> 'drafting' THEN
    RETURN QUERY SELECT false, null::text;
    RETURN;
  END IF;

  IF g.turn_started_at + (p_timeout_seconds || ' seconds')::interval > now() THEN
    RETURN QUERY SELECT false, null::text;
    RETURN;
  END IF;

  SELECT * INTO drafter FROM public.game_players
  WHERE game_id = p_game_id AND draft_position = g.current_drafter;

  -- Determine slots still needed based on settings
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

  -- Add FLEX slots
  FOR i IN 1..coalesce((g.settings->>'flexSlots')::int, 1) LOOP
    IF (SELECT count(*) FROM public.game_picks WHERE game_id = p_game_id AND user_id = drafter.user_id AND slot = 'FLEX') < i THEN
      slots_needed := array_append(slots_needed, 'FLEX');
    END IF;
  END LOOP;

  -- Find best available player for needed slots
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
