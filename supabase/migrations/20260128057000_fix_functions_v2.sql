-- =========================================================
-- CRITICAL FIX: Drop and recreate functions with correct signatures
-- =========================================================

-- Drop broken triggers
DROP TRIGGER IF EXISTS validate_game_pick_trigger ON public.game_picks;
DROP TRIGGER IF EXISTS validate_game_result_trigger ON public.game_results;
DROP TRIGGER IF EXISTS validate_game_update_trigger ON public.games;

-- Drop ALL versions of these functions
DROP FUNCTION IF EXISTS public.ff_start_draft(uuid);
DROP FUNCTION IF EXISTS public.ff_start_draft(uuid, uuid, int, int, jsonb);
DROP FUNCTION IF EXISTS public.ff_make_pick(uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public.ff_make_pick(uuid, uuid, text, int, text);
DROP FUNCTION IF EXISTS public.ff_advance_draft(uuid);
DROP FUNCTION IF EXISTS public.ff_advance_draft_state(uuid);
DROP FUNCTION IF EXISTS public.ff_auto_pick_if_needed(uuid, int);
DROP FUNCTION IF EXISTS public.ff_create_room(text, jsonb, uuid, text);
DROP FUNCTION IF EXISTS public.ff_join_room(text, uuid, text);

-- =========================================================
-- ff_start_draft
-- =========================================================

CREATE FUNCTION public.ff_start_draft(
  p_game_id uuid,
  p_host_user_id uuid,
  p_season int,
  p_week int,
  p_settings jsonb
)
RETURNS TABLE(id uuid, status text, season int, week int, turn_user_id uuid, pick_number int, turn_deadline_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pick_time int;
  mp int;
  ord uuid[];
  requested_snake boolean;
  snake boolean;
  first_user uuid;
  nplayers int;
BEGIN
  pick_time := coalesce((p_settings->>'pickTime')::int, 30);
  mp := greatest(2, least(12, coalesce((p_settings->>'maxPlayers')::int, 2)));
  requested_snake := coalesce((p_settings->>'snakeDraft')::boolean, true);

  SELECT array_agg(gp.user_id ORDER BY random())
  INTO ord
  FROM public.game_players gp
  WHERE gp.game_id = p_game_id;

  IF ord IS NULL OR array_length(ord, 1) IS NULL THEN
    RAISE EXCEPTION 'no players in game';
  END IF;

  nplayers := array_length(ord, 1);
  snake := (requested_snake AND nplayers >= 3);

  first_user := ord[1];

  UPDATE public.games g
  SET status = 'draft',
      season = p_season,
      week = p_week,
      settings = p_settings,
      max_players = mp,
      snake_draft = snake,
      draft_order = ord,
      draft_pos = 1,
      draft_dir = 1,
      turn_user_id = first_user,
      pick_number = 1,
      turn_deadline_at = now() + make_interval(secs => pick_time)
  WHERE g.id = p_game_id;

  RETURN QUERY
    SELECT g.id, g.status, g.season, g.week, g.turn_user_id, g.pick_number, g.turn_deadline_at
    FROM public.games g
    WHERE g.id = p_game_id;
END $$;

-- =========================================================
-- ff_advance_draft_state
-- =========================================================

CREATE FUNCTION public.ff_advance_draft_state(p_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  nplayers int;
  total_rounds int;
  new_pos int;
  new_dir int;
  new_pick int;
  pick_time int;
BEGIN
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;

  nplayers := array_length(g.draft_order, 1);
  total_rounds := coalesce((g.settings->>'totalRounds')::int, 15);
  pick_time := coalesce((g.settings->>'pickTime')::int, 30);

  new_pick := g.pick_number + 1;

  IF new_pick > nplayers * total_rounds THEN
    UPDATE public.games
    SET status = 'scoring',
        turn_user_id = NULL,
        turn_deadline_at = NULL
    WHERE id = p_game_id;
    RETURN;
  END IF;

  new_pos := g.draft_pos;
  new_dir := g.draft_dir;

  IF g.snake_draft THEN
    new_pos := new_pos + new_dir;
    IF new_pos > nplayers THEN
      new_pos := nplayers;
      new_dir := -1;
    ELSIF new_pos < 1 THEN
      new_pos := 1;
      new_dir := 1;
    END IF;
  ELSE
    new_pos := ((g.pick_number) % nplayers) + 1;
  END IF;

  UPDATE public.games
  SET draft_pos = new_pos,
      draft_dir = new_dir,
      pick_number = new_pick,
      turn_user_id = g.draft_order[new_pos],
      turn_deadline_at = now() + make_interval(secs => pick_time)
  WHERE id = p_game_id;
END $$;

-- =========================================================
-- ff_make_pick
-- =========================================================

CREATE FUNCTION public.ff_make_pick(
  p_game_id uuid,
  p_user_id uuid,
  p_player_id text,
  p_slot_index int,
  p_slot_position text
)
RETURNS TABLE(success boolean, new_turn_user_id uuid, new_pick_number int, new_turn_deadline_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  pick_time int;
  r int;
BEGIN
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;

  IF g.status <> 'draft' THEN
    RAISE EXCEPTION 'Game not in draft status';
  END IF;

  IF g.turn_user_id <> p_user_id THEN
    RAISE EXCEPTION 'Not your turn';
  END IF;

  IF EXISTS (SELECT 1 FROM public.game_picks WHERE game_id = p_game_id AND player_id = p_player_id) THEN
    RAISE EXCEPTION 'Player already drafted';
  END IF;

  r := ((g.pick_number - 1) / array_length(g.draft_order, 1)) + 1;

  INSERT INTO public.game_picks(game_id, user_id, player_id, slot_index, slot_position, pick_number, round)
  VALUES (p_game_id, p_user_id, p_player_id, p_slot_index, p_slot_position, g.pick_number, r);

  PERFORM public.ff_advance_draft_state(p_game_id);

  RETURN QUERY
    SELECT true,
           gg.turn_user_id,
           gg.pick_number,
           gg.turn_deadline_at
    FROM public.games gg
    WHERE gg.id = p_game_id;
END $$;

-- =========================================================
-- ff_auto_pick_if_needed
-- =========================================================

CREATE FUNCTION public.ff_auto_pick_if_needed(p_game_id uuid, p_timeout_seconds int DEFAULT 30)
RETURNS TABLE(did_auto_pick boolean, picked_player_id text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  drafter_user uuid;
  best_player text;
  best_slot_idx int;
  best_slot_pos text;
  roster_def jsonb;
  i int;
  pos text;
  needed int;
  have int;
  found_slot boolean := false;
BEGIN
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;

  IF g.status <> 'draft' THEN
    RETURN QUERY SELECT false, null::text;
    RETURN;
  END IF;

  IF g.turn_deadline_at > now() THEN
    RETURN QUERY SELECT false, null::text;
    RETURN;
  END IF;

  drafter_user := g.turn_user_id;
  roster_def := g.settings->'roster';

  -- Find first unfilled slot
  FOR i IN 0..(jsonb_array_length(roster_def) - 1) LOOP
    pos := roster_def->i->>'position';
    needed := (roster_def->i->>'count')::int;

    SELECT count(*) INTO have
    FROM public.game_picks
    WHERE game_id = p_game_id
      AND user_id = drafter_user
      AND slot_position = pos;

    IF have < needed THEN
      best_slot_idx := i;
      best_slot_pos := pos;
      found_slot := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT found_slot THEN
    PERFORM public.ff_advance_draft_state(p_game_id);
    RETURN QUERY SELECT true, null::text;
    RETURN;
  END IF;

  -- Find best available player for position
  IF best_slot_pos = 'FLEX' THEN
    SELECT pws.player_id INTO best_player
    FROM public.player_week_stats pws
    WHERE pws.season = g.season
      AND pws.week = g.week
      AND pws.position IN ('RB', 'WR', 'TE')
      AND pws.player_id NOT IN (SELECT player_id FROM public.game_picks WHERE game_id = p_game_id)
    ORDER BY pws.fantasy_points DESC
    LIMIT 1;
  ELSE
    SELECT pws.player_id INTO best_player
    FROM public.player_week_stats pws
    WHERE pws.season = g.season
      AND pws.week = g.week
      AND pws.position = best_slot_pos
      AND pws.player_id NOT IN (SELECT player_id FROM public.game_picks WHERE game_id = p_game_id)
    ORDER BY pws.fantasy_points DESC
    LIMIT 1;
  END IF;

  IF best_player IS NULL THEN
    PERFORM public.ff_advance_draft_state(p_game_id);
    RETURN QUERY SELECT true, null::text;
    RETURN;
  END IF;

  INSERT INTO public.game_picks(game_id, user_id, player_id, slot_index, slot_position, pick_number, round)
  VALUES (
    p_game_id,
    drafter_user,
    best_player,
    best_slot_idx,
    best_slot_pos,
    g.pick_number,
    ((g.pick_number - 1) / array_length(g.draft_order, 1)) + 1
  );

  PERFORM public.ff_advance_draft_state(p_game_id);

  RETURN QUERY SELECT true, best_player;
END $$;

-- =========================================================
-- ff_create_room
-- =========================================================

CREATE FUNCTION public.ff_create_room(
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
  jmode := coalesce(p_settings->>'joinMode', 'code');
  sh := p_settings->>'settingsHash';
  IF sh IS NULL THEN sh := md5(p_settings::text); END IF;

  v_room_code := upper(trim(coalesce(p_room_code, '')));
  IF v_room_code = '' THEN
    LOOP
      v_room_code := public.ff_gen_room_code();
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.games gg WHERE gg.room_code = v_room_code);
    END LOOP;
  END IF;

  INSERT INTO public.games(room_code, status, settings, pick_number, max_players, join_mode, settings_hash)
  VALUES (v_room_code, 'lobby', p_settings, 1, mp, jmode, sh)
  RETURNING public.games.id INTO g_id;

  INSERT INTO public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
  VALUES (g_id, p_host_user_id, p_host_name, 1, true, true, now());

  RETURN QUERY SELECT g_id, v_room_code;
END $$;

-- =========================================================
-- ff_join_room
-- =========================================================

CREATE FUNCTION public.ff_join_room(
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
  mp int;
  taken int[];
  s int;
BEGIN
  SELECT * INTO g FROM public.games
  WHERE room_code = upper(trim(p_room_code)) AND status = 'lobby'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found or not accepting players';
  END IF;

  mp := g.max_players;

  -- Check if user already in game (rejoin)
  IF EXISTS (SELECT 1 FROM public.game_players gp WHERE gp.game_id = g.id AND gp.user_id = p_user_id) THEN
    UPDATE public.game_players gp
    SET display_name = p_name, is_active = true, last_seen = now()
    WHERE gp.game_id = g.id AND gp.user_id = p_user_id
    RETURNING gp.seat INTO s;
    RETURN QUERY SELECT g.id, s;
    RETURN;
  END IF;

  -- Get taken seats
  SELECT array_agg(gp.seat) INTO taken
  FROM public.game_players gp
  WHERE gp.game_id = g.id;

  -- Find first available seat
  FOR s IN 1..mp LOOP
    IF taken IS NULL OR NOT (s = ANY(taken)) THEN
      INSERT INTO public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
      VALUES (g.id, p_user_id, p_name, s, true, true, now());
      RETURN QUERY SELECT g.id, s;
      RETURN;
    END IF;
  END LOOP;

  RAISE EXCEPTION 'Room is full';
END $$;
