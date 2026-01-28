-- =========================================================
-- Fix: Allow anonymous users to create/join games
-- =========================================================

-- Drop existing insert policies
DROP POLICY IF EXISTS "auth_insert_games" ON public.games;
DROP POLICY IF EXISTS "auth_insert_game_players" ON public.game_players;
DROP POLICY IF EXISTS "auth_insert_picks" ON public.game_picks;
DROP POLICY IF EXISTS "auth_insert_results" ON public.game_results;
DROP POLICY IF EXISTS "auth_matchmaking" ON public.matchmaking_queue;

-- Allow anyone to insert (the functions handle all validation)
CREATE POLICY "allow_insert_games" ON public.games
  FOR INSERT WITH CHECK (true);

CREATE POLICY "allow_insert_game_players" ON public.game_players
  FOR INSERT WITH CHECK (true);

CREATE POLICY "allow_insert_picks" ON public.game_picks
  FOR INSERT WITH CHECK (true);

CREATE POLICY "allow_insert_results" ON public.game_results
  FOR INSERT WITH CHECK (true);

CREATE POLICY "allow_matchmaking" ON public.matchmaking_queue
  FOR ALL USING (true);
