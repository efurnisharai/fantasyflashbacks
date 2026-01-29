-- Cleanup function to delete game_picks older than 1 day
-- This keeps the draft working but prevents long-term data bloat

CREATE OR REPLACE FUNCTION public.cleanup_old_game_picks()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM public.game_picks
  WHERE game_id IN (
    SELECT id FROM public.games
    WHERE created_at < NOW() - INTERVAL '1 day'
  );

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

-- Try to enable pg_cron and schedule cleanup
-- pg_cron must be enabled in Supabase Dashboard > Database > Extensions
DO $$
BEGIN
  -- Check if pg_cron is available
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Schedule cleanup to run daily at 4 AM UTC
    PERFORM cron.schedule(
      'cleanup-old-game-picks',
      '0 4 * * *',
      'SELECT public.cleanup_old_game_picks()'
    );
    RAISE NOTICE 'Scheduled daily cleanup job';
  ELSE
    RAISE NOTICE 'pg_cron not enabled - enable it in Supabase Dashboard > Database > Extensions, then run: SELECT cron.schedule(''cleanup-old-game-picks'', ''0 4 * * *'', ''SELECT public.cleanup_old_game_picks()'')';
  END IF;
END;
$$;
