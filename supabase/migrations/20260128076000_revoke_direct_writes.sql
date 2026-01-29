-- Simple security layer: revoke direct write access on game tables
-- All writes must go through SECURITY DEFINER functions (ff_create_room, ff_join_room, etc.)
-- This prevents direct manipulation while keeping RPC functions working

-- Revoke direct INSERT/UPDATE/DELETE on game tables
REVOKE INSERT, UPDATE, DELETE ON public.games FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.game_players FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.game_picks FROM anon, authenticated;

-- Keep SELECT for real-time subscriptions and reads
GRANT SELECT ON public.games TO anon, authenticated;
GRANT SELECT ON public.game_players TO anon, authenticated;
GRANT SELECT ON public.game_picks TO anon, authenticated;

-- Note: SECURITY DEFINER functions run as the function owner (postgres),
-- so they bypass these restrictions and can still write to tables.
