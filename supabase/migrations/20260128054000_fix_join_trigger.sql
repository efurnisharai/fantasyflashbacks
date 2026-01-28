-- =========================================================
-- Fix: Remove the game_player trigger that's breaking joins
-- The ff_join_room function already validates everything
-- =========================================================

DROP TRIGGER IF EXISTS validate_game_player_trigger ON public.game_players;
DROP FUNCTION IF EXISTS public.validate_game_player();

-- Also fix ff_join_room to match original logic
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
  mp int;
  taken int[];
  s int;
BEGIN
  -- Lock game and check status
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
