-- Revert: restore direct write access
GRANT INSERT, UPDATE, DELETE ON public.games TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.game_players TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.game_picks TO anon, authenticated;
