-- =========================================================
-- Fix: Set security_invoker = true on views
--
-- By default, views run with the permissions of the view owner
-- (SECURITY DEFINER behavior). This bypasses RLS policies.
--
-- Setting security_invoker = true makes views respect the
-- permissions and RLS policies of the calling user.
-- =========================================================

-- Fix leaderboard_all_time view
ALTER VIEW public.leaderboard_all_time SET (security_invoker = true);

-- Fix leaderboard_wins view
ALTER VIEW public.leaderboard_wins SET (security_invoker = true);

-- Fix game_mode_high_scores view
ALTER VIEW public.game_mode_high_scores SET (security_invoker = true);
