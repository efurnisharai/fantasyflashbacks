-- =========================================================
-- Remove overly permissive INSERT policies
--
-- These policies allowed direct client inserts with no restrictions.
-- Since all mutations go through SECURITY DEFINER functions
-- (ff_create_room, ff_join_room, ff_make_pick, etc.), these
-- policies are redundant and create unnecessary security warnings.
--
-- The functions bypass RLS anyway, so removing these policies
-- has no effect on normal app operation.
-- =========================================================

-- Remove permissive INSERT policies
DROP POLICY IF EXISTS "allow_insert_picks" ON public.game_picks;
DROP POLICY IF EXISTS "allow_insert_game_players" ON public.game_players;
DROP POLICY IF EXISTS "allow_insert_results" ON public.game_results;
DROP POLICY IF EXISTS "allow_insert_games" ON public.games;
DROP POLICY IF EXISTS "allow_matchmaking" ON public.matchmaking_queue;

-- Also clean up the old "service_*" policies that used WITH CHECK (false)
-- These were meant to block inserts but are now redundant
DROP POLICY IF EXISTS "service_insert_games" ON public.games;
DROP POLICY IF EXISTS "service_insert_game_players" ON public.game_players;
DROP POLICY IF EXISTS "service_insert_picks" ON public.game_picks;
DROP POLICY IF EXISTS "service_insert_results" ON public.game_results;
DROP POLICY IF EXISTS "service_only_matchmaking" ON public.matchmaking_queue;
