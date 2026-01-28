-- =========================================================
-- Fix RLS policies that were blocking inserts
-- =========================================================

-- Drop the blocking policies
DROP POLICY IF EXISTS "service_insert_games" ON public.games;
DROP POLICY IF EXISTS "service_insert_game_players" ON public.game_players;
DROP POLICY IF EXISTS "service_insert_picks" ON public.game_picks;
DROP POLICY IF EXISTS "service_insert_results" ON public.game_results;
DROP POLICY IF EXISTS "service_only_matchmaking" ON public.matchmaking_queue;

-- Games: Allow authenticated users to insert (function will handle validation)
CREATE POLICY "auth_insert_games" ON public.games
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Game players: Allow authenticated users to insert
CREATE POLICY "auth_insert_game_players" ON public.game_players
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Game picks: Allow authenticated users to insert their own picks
CREATE POLICY "auth_insert_picks" ON public.game_picks
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Game results: Allow authenticated users to insert
CREATE POLICY "auth_insert_results" ON public.game_results
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Matchmaking: Allow authenticated users to interact
DROP POLICY IF EXISTS "service_only_matchmaking" ON public.matchmaking_queue;
CREATE POLICY "auth_matchmaking" ON public.matchmaking_queue
  FOR ALL USING (auth.uid() IS NOT NULL);
