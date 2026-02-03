-- =========================================================
-- Fix: Allow rematch from 'draft' status
-- The game status is only set to 'done' by the host (seat 1),
-- so non-host players would have games stuck in 'draft' status
-- when viewing the results screen.
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_request_rematch(
  p_game_id uuid,
  p_user_id uuid
)
RETURNS TABLE(
  new_game_id uuid,
  new_room_code text,
  rematch_ready boolean,
  players_ready int,
  players_total int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  ready_count int;
  total_active int;
  v_new_game_id uuid;
  v_new_room_code text;
  player_rec record;
  new_seat int;
  mp int;
  sh text;
BEGIN
  -- Get the original game with lock
  SELECT * INTO g FROM public.games WHERE id = p_game_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found';
  END IF;

  -- Verify game is in completed status (include 'draft' since status update is host-only)
  IF g.status NOT IN ('draft', 'scoring', 'done', 'results') THEN
    RAISE EXCEPTION 'Game not in completed status';
  END IF;

  -- Check if a rematch already exists for this game
  IF EXISTS (SELECT 1 FROM public.games WHERE rematch_of_game_id = p_game_id) THEN
    -- Return the existing rematch game
    SELECT gg.id, gg.room_code INTO v_new_game_id, v_new_room_code
    FROM public.games gg
    WHERE gg.rematch_of_game_id = p_game_id
    LIMIT 1;

    RETURN QUERY SELECT
      v_new_game_id,
      v_new_room_code,
      true,
      0,
      0;
    RETURN;
  END IF;

  -- Mark this player as requesting rematch
  UPDATE public.game_players
  SET rematch_requested = true
  WHERE game_id = p_game_id AND user_id = p_user_id;

  -- Count active players and ready players
  SELECT
    COUNT(*) FILTER (WHERE is_active = true),
    COUNT(*) FILTER (WHERE is_active = true AND rematch_requested = true)
  INTO total_active, ready_count
  FROM public.game_players
  WHERE game_id = p_game_id;

  -- If not all players ready, return current status
  IF ready_count < total_active OR total_active < 2 THEN
    RETURN QUERY SELECT
      NULL::uuid,
      NULL::text,
      false,
      ready_count,
      total_active;
    RETURN;
  END IF;

  -- All players ready! Create the new game

  -- Generate new room code
  LOOP
    v_new_room_code := public.ff_gen_room_code();
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.games gg WHERE gg.room_code = v_new_room_code);
  END LOOP;

  -- Get settings
  mp := g.max_players;
  sh := g.settings_hash;
  IF sh IS NULL THEN sh := md5(g.settings::text); END IF;

  -- Create new game with same settings
  INSERT INTO public.games(
    room_code,
    status,
    settings,
    pick_number,
    max_players,
    join_mode,
    settings_hash,
    rematch_of_game_id
  )
  VALUES (
    v_new_room_code,
    'lobby',
    g.settings,
    1,
    mp,
    'code',
    sh,
    p_game_id
  )
  RETURNING id INTO v_new_game_id;

  -- Add all active players to the new game (randomized seat order)
  new_seat := 0;
  FOR player_rec IN
    SELECT user_id, display_name
    FROM public.game_players
    WHERE game_id = p_game_id AND is_active = true
    ORDER BY RANDOM()
  LOOP
    new_seat := new_seat + 1;
    INSERT INTO public.game_players(
      game_id, user_id, display_name, seat, ready, is_active, last_seen
    )
    VALUES (
      v_new_game_id, player_rec.user_id, player_rec.display_name,
      new_seat, true, true, now()
    );
  END LOOP;

  RETURN QUERY SELECT
    v_new_game_id,
    v_new_room_code,
    true,
    ready_count,
    total_active;
END $$;
