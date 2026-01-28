-- =========================================================
-- Restore unique constraints if they were dropped
--
-- These constraints are required for upsert operations:
--   on_conflict="season,week,player_id"
--   on_conflict="season,week,team"
-- =========================================================

-- Restore player_week_stats_one_row if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'player_week_stats_one_row'
      AND conrelid = 'public.player_week_stats'::regclass
  ) THEN
    ALTER TABLE public.player_week_stats
      ADD CONSTRAINT player_week_stats_one_row UNIQUE (season, week, player_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- Restore team_week_stats_one_row if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'team_week_stats_one_row'
      AND conrelid = 'public.team_week_stats'::regclass
  ) THEN
    ALTER TABLE public.team_week_stats
      ADD CONSTRAINT team_week_stats_one_row UNIQUE (season, week, team);
  END IF;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;
