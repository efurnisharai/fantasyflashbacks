-- =========================================================
-- Skill Rating Display & Friends FP Leaderboard
--
-- Implements:
--   - ff_calculate_skill_rating: Calculate skill score from available data
--   - ff_get_friends_leaderboard: Friends-only FP leaderboard
-- =========================================================

-- =========================================================
-- 1) SKILL RATING CALCULATION
--
-- Calculates a skill score (0-100) based on:
--   - Win rate (40%): games_won / games_played
--   - Margin bonus (30%): avg(your_score - avg_opponent_score)
--   - Opponent count bonus (30%): More opponents = harder games
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_calculate_skill_rating(p_user_id UUID)
RETURNS TABLE (
  skill_score NUMERIC(5,2),
  win_rate NUMERIC(5,2),
  avg_margin NUMERIC(8,2),
  avg_opponents NUMERIC(4,2),
  games_rated INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_games_played INT;
  v_games_won INT;
  v_win_rate NUMERIC(5,2);
  v_avg_margin NUMERIC(8,2);
  v_avg_opponents NUMERIC(4,2);
  v_games_rated INT;
  v_margin_bonus NUMERIC(5,2);
  v_opponent_bonus NUMERIC(5,2);
  v_skill_score NUMERIC(5,2);
BEGIN
  -- Get basic stats from user_profiles
  SELECT
    COALESCE(up.games_played, 0),
    COALESCE(up.games_won, 0)
  INTO v_games_played, v_games_won
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  -- If no games played, return zero skill
  IF v_games_played = 0 OR v_games_played IS NULL THEN
    RETURN QUERY SELECT
      0::NUMERIC(5,2) AS skill_score,
      0::NUMERIC(5,2) AS win_rate,
      0::NUMERIC(8,2) AS avg_margin,
      0::NUMERIC(4,2) AS avg_opponents,
      0::INT AS games_rated;
    RETURN;
  END IF;

  -- Calculate win rate (0-100)
  v_win_rate := (v_games_won::NUMERIC / v_games_played::NUMERIC) * 100;

  -- Calculate average margin and opponent count from game_results
  -- For each game, calculate your score vs average of other players
  WITH game_margins AS (
    SELECT
      gr.game_id,
      gr.score AS my_score,
      (
        SELECT AVG(gr2.score)
        FROM public.game_results gr2
        WHERE gr2.game_id = gr.game_id
          AND gr2.user_id != p_user_id
      ) AS avg_opponent_score,
      (
        SELECT COUNT(*)
        FROM public.game_results gr2
        WHERE gr2.game_id = gr.game_id
          AND gr2.user_id != p_user_id
      ) AS opponent_count
    FROM public.game_results gr
    WHERE gr.user_id = p_user_id
      AND gr.score IS NOT NULL
  )
  SELECT
    COALESCE(AVG(my_score - avg_opponent_score), 0),
    COALESCE(AVG(opponent_count), 1) + 1,  -- +1 to include self for total players
    COUNT(*)::INT
  INTO v_avg_margin, v_avg_opponents, v_games_rated
  FROM game_margins
  WHERE avg_opponent_score IS NOT NULL;

  -- Normalize margin to 0-100 scale
  -- Typical margin range is roughly -100 to +100, so we scale accordingly
  -- +50 margin = 100 score, -50 margin = 0 score, 0 margin = 50 score
  v_margin_bonus := GREATEST(0, LEAST(100, 50 + v_avg_margin));

  -- Opponent count bonus (0-100 scale)
  -- 2 players (1 opponent) = 60 points
  -- 3 players (2 opponents) = 75 points
  -- 4+ players (3+ opponents) = 90 points
  v_opponent_bonus := CASE
    WHEN v_avg_opponents >= 4 THEN 90
    WHEN v_avg_opponents >= 3 THEN 80
    WHEN v_avg_opponents >= 2.5 THEN 75
    WHEN v_avg_opponents >= 2 THEN 70
    ELSE 60
  END;

  -- Calculate final skill score (0-100)
  -- 40% win rate + 30% margin bonus + 30% opponent count bonus
  v_skill_score := (v_win_rate * 0.40) + (v_margin_bonus * 0.30) + (v_opponent_bonus * 0.30);

  -- Clamp to 0-100
  v_skill_score := GREATEST(0, LEAST(100, v_skill_score));

  RETURN QUERY SELECT
    v_skill_score,
    v_win_rate,
    v_avg_margin,
    v_avg_opponents,
    v_games_rated;
END;
$$;

-- =========================================================
-- 2) FRIENDS FP LEADERBOARD
--
-- Returns friends + current user sorted by FP
-- Includes skill score for each person
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_friends_leaderboard(
  p_user_id UUID,
  p_limit INT DEFAULT 50
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  flashback_id TEXT,
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
    -- Get all friend user IDs
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
-- 3) GRANTS
-- =========================================================

GRANT EXECUTE ON FUNCTION public.ff_calculate_skill_rating(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_friends_leaderboard(UUID, INT) TO anon, authenticated;
