-- =========================================================
-- Fix: Performance warnings from Supabase advisor
--
-- 1. RLS policies: wrap auth.uid() in (select ...) to prevent
--    re-evaluation for each row
-- 2. Remove duplicate SELECT policies on player_week_stats
-- 3. Remove duplicate indexes
-- =========================================================

-- =========================================================
-- 1) Fix RLS policies - use (select auth.uid()) pattern
-- =========================================================

-- Fix participant_update_games
DROP POLICY IF EXISTS "participant_update_games" ON public.games;
CREATE POLICY "participant_update_games" ON public.games
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM public.game_players gp
      WHERE gp.game_id = id AND gp.user_id = (SELECT auth.uid())
    )
  );

-- Fix self_update_game_players
DROP POLICY IF EXISTS "self_update_game_players" ON public.game_players;
CREATE POLICY "self_update_game_players" ON public.game_players
  FOR UPDATE USING (user_id = (SELECT auth.uid()));

-- Fix participant_read_picks
DROP POLICY IF EXISTS "participant_read_picks" ON public.game_picks;
CREATE POLICY "participant_read_picks" ON public.game_picks
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.game_players gp
      WHERE gp.game_id = game_id AND gp.user_id = (SELECT auth.uid())
    )
  );

-- Fix self_insert_profile
DROP POLICY IF EXISTS "self_insert_profile" ON public.user_profiles;
CREATE POLICY "self_insert_profile" ON public.user_profiles
  FOR INSERT WITH CHECK (id = (SELECT auth.uid()));

-- Fix self_update_profile
DROP POLICY IF EXISTS "self_update_profile" ON public.user_profiles;
CREATE POLICY "self_update_profile" ON public.user_profiles
  FOR UPDATE USING (id = (SELECT auth.uid()));

-- =========================================================
-- 2) Remove duplicate SELECT policies on player_week_stats
-- Keep anon_read_player_stats, remove pws_read_all
-- =========================================================

DROP POLICY IF EXISTS "pws_read_all" ON public.player_week_stats;

-- =========================================================
-- 3) Remove duplicate indexes
-- =========================================================

-- game_picks: keep idx_game_picks_game, drop idx_game_picks_game_id
DROP INDEX IF EXISTS public.idx_game_picks_game_id;

-- player_week_stats: keep idx_player_week_stats_season_week_position, drop duplicates
DROP INDEX IF EXISTS public.idx_pws_lookup;
DROP INDEX IF EXISTS public.idx_pws_season_week_pos;

-- player_week_stats: keep idx_pws_name_search, drop duplicates
DROP INDEX IF EXISTS public.idx_pws_search;
DROP INDEX IF EXISTS public.idx_pws_season_week_name;

-- NOTE: Keeping player_week_stats_one_row and team_week_stats_one_row constraints
-- These UNIQUE constraints on (season, week, player_id) and (season, week, team)
-- are required for upsert operations in data import scripts.
-- The linter reports them as "identical" to pkey, but dropping them could break
-- upserts if the primary key is on a different column (like id).
--
-- If you want to remove these warnings, first verify that:
-- 1. The primary key IS on (season, week, player_id) / (season, week, team)
-- 2. Then you can safely drop the _one_row constraints
--
-- To verify, run:
--   SELECT conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--   WHERE conrelid = 'public.player_week_stats'::regclass;
