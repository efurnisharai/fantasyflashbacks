-- Fix: ff_make_pick and ff_auto_pick missing seat column

DROP FUNCTION IF EXISTS public.ff_make_pick(uuid, uuid, text, int, text);

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
  user_seat int;
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

  -- Get the user's seat
  SELECT seat INTO user_seat FROM public.game_players
  WHERE game_id = p_game_id AND user_id = p_user_id;

  r := ((g.pick_number - 1) / array_length(g.draft_order, 1)) + 1;

  INSERT INTO public.game_picks(game_id, user_id, seat, player_id, slot_index, slot_position, pick_number, round)
  VALUES (p_game_id, p_user_id, user_seat, p_player_id, p_slot_index, p_slot_position, g.pick_number, r);

  PERFORM public.ff_advance_draft_state(p_game_id);

  RETURN QUERY
    SELECT true,
           gg.turn_user_id,
           gg.pick_number,
           gg.turn_deadline_at
    FROM public.games gg
    WHERE gg.id = p_game_id;
END $$;

-- Also fix auto pick
DROP FUNCTION IF EXISTS public.ff_auto_pick_if_needed(uuid, int);

CREATE FUNCTION public.ff_auto_pick_if_needed(p_game_id uuid, p_timeout_seconds int DEFAULT 30)
RETURNS TABLE(did_auto_pick boolean, picked_player_id text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g record;
  drafter_user uuid;
  drafter_seat int;
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

  -- Get the drafter's seat
  SELECT seat INTO drafter_seat FROM public.game_players
  WHERE game_id = p_game_id AND user_id = drafter_user;

  roster_def := g.settings->'roster';

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

  INSERT INTO public.game_picks(game_id, user_id, seat, player_id, slot_index, slot_position, pick_number, round)
  VALUES (
    p_game_id,
    drafter_user,
    drafter_seat,
    best_player,
    best_slot_idx,
    best_slot_pos,
    g.pick_number,
    ((g.pick_number - 1) / array_length(g.draft_order, 1)) + 1
  );

  PERFORM public.ff_advance_draft_state(p_game_id);

  RETURN QUERY SELECT true, best_player;
END $$;
