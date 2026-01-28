-- =========================================================
-- Fix: Set search_path on functions missing it
--
-- Without search_path set, functions are vulnerable to
-- search path injection attacks where an attacker could
-- create malicious objects in a schema that appears first
-- in the search path.
-- =========================================================

-- Fix cleanup_rate_limits
CREATE OR REPLACE FUNCTION public.cleanup_rate_limits()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.rate_limits WHERE created_at < NOW() - INTERVAL '1 hour';
$$;

-- Fix generate_game_mode_hash
CREATE OR REPLACE FUNCTION public.generate_game_mode_hash(
  p_season INT,
  p_week INT,
  p_scoring_type TEXT,
  p_pass_td_points INT,
  p_qb_slots INT,
  p_rb_slots INT,
  p_wr_slots INT,
  p_te_slots INT,
  p_flex_slots INT,
  p_k_slots INT,
  p_dst_slots INT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT md5(
    p_season::text || ':' ||
    p_week::text || ':' ||
    COALESCE(p_scoring_type, 'standard') || ':' ||
    COALESCE(p_pass_td_points, 4)::text || ':' ||
    COALESCE(p_qb_slots, 1)::text || ':' ||
    COALESCE(p_rb_slots, 2)::text || ':' ||
    COALESCE(p_wr_slots, 2)::text || ':' ||
    COALESCE(p_te_slots, 1)::text || ':' ||
    COALESCE(p_flex_slots, 1)::text || ':' ||
    COALESCE(p_k_slots, 1)::text || ':' ||
    COALESCE(p_dst_slots, 1)::text
  );
$$;
