-- =========================================================
-- Fix column references in skill rating and challenge functions
-- =========================================================

-- =========================================================
-- 1) FIX SKILL RATING - use final_score instead of score
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
      gr.final_score AS my_score,
      (
        SELECT AVG(gr2.final_score)
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
      AND gr.final_score IS NOT NULL
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
-- 2) FIX DAILY CHALLENGE - rename output column to avoid ambiguity
-- =========================================================

DROP FUNCTION IF EXISTS public.ff_assign_daily_challenge(UUID);

CREATE OR REPLACE FUNCTION public.ff_assign_daily_challenge(p_user_id UUID)
RETURNS TABLE (
  out_challenge_id UUID,
  challenge_name TEXT,
  challenge_description TEXT,
  out_challenge_type TEXT,
  out_target_value INT,
  out_current_value INT,
  out_fp_reward INT,
  out_expires_at TIMESTAMPTZ,
  already_had_challenge BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today DATE := CURRENT_DATE;
  v_existing RECORD;
  v_challenge RECORD;
  v_user_challenge_id UUID;
BEGIN
  -- Check if user already has a challenge for today
  SELECT
    uc.challenge_id,
    c.name,
    c.description,
    c.challenge_type,
    c.target_value,
    uc.current_value,
    c.fp_reward,
    uc.expires_at
  INTO v_existing
  FROM public.user_challenges uc
  JOIN public.challenges c ON c.id = uc.challenge_id
  WHERE uc.user_id = p_user_id
    AND uc.assigned_date = v_today
    AND uc.expires_at > NOW();

  IF v_existing IS NOT NULL THEN
    RETURN QUERY SELECT
      v_existing.challenge_id,
      v_existing.name::TEXT,
      v_existing.description::TEXT,
      v_existing.challenge_type::TEXT,
      v_existing.target_value,
      v_existing.current_value,
      v_existing.fp_reward,
      v_existing.expires_at,
      TRUE;
    RETURN;
  END IF;

  -- Pick a random daily challenge
  SELECT * INTO v_challenge
  FROM public.challenges
  WHERE is_daily = TRUE AND is_active = TRUE
  ORDER BY RANDOM()
  LIMIT 1;

  IF v_challenge IS NULL THEN
    -- No challenges available
    RETURN;
  END IF;

  -- Assign the challenge
  INSERT INTO public.user_challenges (
    user_id,
    challenge_id,
    assigned_date,
    expires_at,
    current_value
  ) VALUES (
    p_user_id,
    v_challenge.id,
    v_today,
    (v_today + 1)::TIMESTAMP + INTERVAL '4 hours',
    0
  )
  ON CONFLICT (user_id, challenge_id, assigned_date) DO NOTHING
  RETURNING id INTO v_user_challenge_id;

  IF v_user_challenge_id IS NULL THEN
    -- Challenge already assigned (race condition), fetch it
    SELECT
      uc.challenge_id,
      c.name,
      c.description,
      c.challenge_type,
      c.target_value,
      uc.current_value,
      c.fp_reward,
      uc.expires_at
    INTO v_existing
    FROM public.user_challenges uc
    JOIN public.challenges c ON c.id = uc.challenge_id
    WHERE uc.user_id = p_user_id
      AND uc.assigned_date = v_today;

    RETURN QUERY SELECT
      v_existing.challenge_id,
      v_existing.name::TEXT,
      v_existing.description::TEXT,
      v_existing.challenge_type::TEXT,
      v_existing.target_value,
      v_existing.current_value,
      v_existing.fp_reward,
      v_existing.expires_at,
      TRUE;
    RETURN;
  END IF;

  RETURN QUERY SELECT
    v_challenge.id,
    v_challenge.name::TEXT,
    v_challenge.description::TEXT,
    v_challenge.challenge_type::TEXT,
    v_challenge.target_value,
    0,
    v_challenge.fp_reward,
    (v_today + 1)::TIMESTAMP + INTERVAL '4 hours',
    FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ff_assign_daily_challenge(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_calculate_skill_rating(UUID) TO anon, authenticated;
