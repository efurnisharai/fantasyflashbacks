-- Update cleanup function to also delete game_players older than 1 day

CREATE OR REPLACE FUNCTION public.cleanup_old_game_picks()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted_picks INTEGER;
  v_deleted_players INTEGER;
  v_old_game_ids UUID[];
BEGIN
  -- Get IDs of old games
  SELECT ARRAY_AGG(id) INTO v_old_game_ids
  FROM public.games
  WHERE created_at < NOW() - INTERVAL '1 day';

  IF v_old_game_ids IS NULL OR array_length(v_old_game_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- Delete old game_picks
  DELETE FROM public.game_picks
  WHERE game_id = ANY(v_old_game_ids);
  GET DIAGNOSTICS v_deleted_picks = ROW_COUNT;

  -- Delete old game_players
  DELETE FROM public.game_players
  WHERE game_id = ANY(v_old_game_ids);
  GET DIAGNOSTICS v_deleted_players = ROW_COUNT;

  RETURN v_deleted_picks + v_deleted_players;
END;
$$;
