-- =========================================================
-- Avatar Emoji Support
--
-- Adds avatar_url to return types of friend/leaderboard/search
-- functions so users can see each other's chosen emoji icons.
--
-- Must DROP then CREATE because CREATE OR REPLACE cannot
-- change the return type of an existing function.
-- =========================================================

-- Drop existing functions (signature must match)
DROP FUNCTION IF EXISTS public.ff_get_friends(UUID);
DROP FUNCTION IF EXISTS public.ff_get_friends_leaderboard(UUID, INT);
DROP FUNCTION IF EXISTS public.ff_search_user_by_flashback_id(TEXT, UUID);
DROP FUNCTION IF EXISTS public.ff_get_recent_players(UUID, INT);

-- =========================================================
-- 1) ff_get_friends — add friend_avatar_url
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_friends(p_user_id UUID)
RETURNS TABLE (
  friendship_id UUID,
  friend_user_id UUID,
  friend_display_name TEXT,
  friend_flashback_id TEXT,
  friend_avatar_url TEXT,
  friend_tier public.flashback_tier,
  friend_current_streak INT,
  games_together INT,
  status public.friendship_status,
  since TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    f.id AS friendship_id,
    CASE WHEN f.user_id = p_user_id THEN f.friend_id ELSE f.user_id END AS friend_user_id,
    up.display_name AS friend_display_name,
    up.flashback_id AS friend_flashback_id,
    up.avatar_url AS friend_avatar_url,
    COALESCE(ue.tier, 'rookie'::public.flashback_tier) AS friend_tier,
    COALESCE(ue.current_streak, 0) AS friend_current_streak,
    f.games_together,
    f.status,
    f.created_at AS since
  FROM public.friendships f
  JOIN public.user_profiles up ON up.id = CASE
    WHEN f.user_id = p_user_id THEN f.friend_id
    ELSE f.user_id
  END
  LEFT JOIN public.user_engagement ue ON ue.user_id = up.id
  WHERE (f.user_id = p_user_id OR f.friend_id = p_user_id)
    AND f.status = 'accepted'
  ORDER BY f.games_together DESC, up.display_name ASC;
END;
$$;

-- =========================================================
-- 2) ff_get_friends_leaderboard — add avatar_url
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_friends_leaderboard(
  p_user_id UUID,
  p_limit INT DEFAULT 50
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  flashback_id TEXT,
  avatar_url TEXT,
  flashback_points BIGINT,
  tier TEXT,
  current_streak INT,
  skill_score NUMERIC(5,2),
  win_rate NUMERIC(5,2),
  games_played INT,
  games_won INT,
  games_together INT,
  is_current_user BOOLEAN,
  rank BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH friend_ids AS (
    SELECT
      CASE
        WHEN f.user_id = p_user_id THEN f.friend_id
        ELSE f.user_id
      END AS friend_user_id,
      f.games_together
    FROM public.friendships f
    WHERE (f.user_id = p_user_id OR f.friend_id = p_user_id)
      AND f.status = 'accepted'
  ),
  all_users AS (
    -- Friends
    SELECT
      up.id AS user_id,
      up.display_name,
      up.flashback_id,
      up.avatar_url,
      COALESCE(ue.flashback_points, 0) AS flashback_points,
      COALESCE(ue.tier::TEXT, 'rookie') AS tier,
      COALESCE(ue.current_streak, 0) AS current_streak,
      up.games_played,
      up.games_won,
      fi.games_together,
      FALSE AS is_current_user
    FROM friend_ids fi
    JOIN public.user_profiles up ON up.id = fi.friend_user_id
    LEFT JOIN public.user_engagement ue ON ue.user_id = up.id

    UNION ALL

    -- Current user
    SELECT
      up.id AS user_id,
      up.display_name,
      up.flashback_id,
      up.avatar_url,
      COALESCE(ue.flashback_points, 0) AS flashback_points,
      COALESCE(ue.tier::TEXT, 'rookie') AS tier,
      COALESCE(ue.current_streak, 0) AS current_streak,
      up.games_played,
      up.games_won,
      0 AS games_together,
      TRUE AS is_current_user
    FROM public.user_profiles up
    LEFT JOIN public.user_engagement ue ON ue.user_id = up.id
    WHERE up.id = p_user_id
  ),
  ranked_users AS (
    SELECT
      au.*,
      ROW_NUMBER() OVER (ORDER BY au.flashback_points DESC, au.games_won DESC, au.display_name ASC) AS rank
    FROM all_users au
  )
  SELECT
    ru.user_id,
    ru.display_name,
    ru.flashback_id,
    ru.avatar_url,
    ru.flashback_points,
    ru.tier,
    ru.current_streak,
    COALESCE(sr.skill_score, 0) AS skill_score,
    COALESCE(sr.win_rate, 0) AS win_rate,
    ru.games_played,
    ru.games_won,
    ru.games_together,
    ru.is_current_user,
    ru.rank
  FROM ranked_users ru
  LEFT JOIN LATERAL (
    SELECT s.skill_score, s.win_rate
    FROM public.ff_calculate_skill_rating(ru.user_id) s
  ) sr ON TRUE
  ORDER BY ru.rank ASC
  LIMIT p_limit;
END;
$$;

-- =========================================================
-- 3) ff_search_user_by_flashback_id — add avatar_url
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_search_user_by_flashback_id(
  p_flashback_id TEXT,
  p_searcher_id UUID DEFAULT NULL
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  flashback_id TEXT,
  avatar_url TEXT,
  tier public.flashback_tier,
  current_streak INT,
  games_played INT,
  is_friend BOOLEAN,
  has_pending_request BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_normalized_id TEXT;
BEGIN
  v_normalized_id := UPPER(TRIM(p_flashback_id));
  IF NOT v_normalized_id LIKE 'FF-%' THEN
    v_normalized_id := 'FF-' || v_normalized_id;
  END IF;

  RETURN QUERY
  SELECT
    up.id AS user_id,
    up.display_name,
    up.flashback_id,
    up.avatar_url,
    COALESCE(ue.tier, 'rookie'::public.flashback_tier) AS tier,
    COALESCE(ue.current_streak, 0) AS current_streak,
    up.games_played,
    EXISTS(
      SELECT 1 FROM public.friendships f
      WHERE ((f.user_id = p_searcher_id AND f.friend_id = up.id) OR
             (f.friend_id = p_searcher_id AND f.user_id = up.id))
        AND f.status = 'accepted'
    ) AS is_friend,
    EXISTS(
      SELECT 1 FROM public.friendships f
      WHERE ((f.user_id = p_searcher_id AND f.friend_id = up.id) OR
             (f.friend_id = p_searcher_id AND f.user_id = up.id))
        AND f.status = 'pending'
    ) AS has_pending_request
  FROM public.user_profiles up
  LEFT JOIN public.user_engagement ue ON ue.user_id = up.id
  WHERE up.flashback_id = v_normalized_id
    AND up.id != COALESCE(p_searcher_id, '00000000-0000-0000-0000-000000000000'::UUID);
END;
$$;

-- =========================================================
-- 4) ff_get_recent_players — add avatar_url
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_recent_players(
  p_user_id UUID,
  p_limit INT DEFAULT 10
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  flashback_id TEXT,
  avatar_url TEXT,
  tier public.flashback_tier,
  games_together INT,
  last_played TIMESTAMPTZ,
  is_friend BOOLEAN,
  has_pending_request BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH recent_games AS (
    SELECT DISTINCT
      gp2.user_id AS other_user_id,
      MAX(gr.created_at) AS last_played,
      COUNT(DISTINCT gr.game_id) AS games_count
    FROM public.game_results gr
    JOIN public.game_results gr2 ON gr.game_id = gr2.game_id AND gr2.user_id != p_user_id
    JOIN public.game_players gp2 ON gp2.game_id = gr.game_id AND gp2.user_id = gr2.user_id
    WHERE gr.user_id = p_user_id
    GROUP BY gp2.user_id
    ORDER BY MAX(gr.created_at) DESC
    LIMIT p_limit
  )
  SELECT
    up.id AS user_id,
    up.display_name,
    up.flashback_id,
    up.avatar_url,
    COALESCE(ue.tier, 'rookie'::public.flashback_tier) AS tier,
    rg.games_count::INT AS games_together,
    rg.last_played,
    EXISTS(
      SELECT 1 FROM public.friendships f
      WHERE ((f.user_id = p_user_id AND f.friend_id = up.id) OR
             (f.friend_id = p_user_id AND f.user_id = up.id))
        AND f.status = 'accepted'
    ) AS is_friend,
    EXISTS(
      SELECT 1 FROM public.friendships f
      WHERE ((f.user_id = p_user_id AND f.friend_id = up.id) OR
             (f.friend_id = p_user_id AND f.user_id = up.id))
        AND f.status = 'pending'
    ) AS has_pending_request
  FROM recent_games rg
  JOIN public.user_profiles up ON up.id = rg.other_user_id
  LEFT JOIN public.user_engagement ue ON ue.user_id = up.id
  WHERE up.id != p_user_id
  ORDER BY rg.last_played DESC;
END;
$$;

-- =========================================================
-- 5) GRANTS (re-grant after CREATE OR REPLACE)
-- =========================================================

GRANT EXECUTE ON FUNCTION public.ff_get_friends(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_friends_leaderboard(UUID, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_search_user_by_flashback_id(TEXT, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_recent_players(UUID, INT) TO anon, authenticated;
