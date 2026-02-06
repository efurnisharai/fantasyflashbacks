-- =========================================================
-- Daily Challenge System
--
-- Implements:
--   - Assign daily challenges to users
--   - Track challenge progress during games
--   - Award FP on completion
--   - Reset challenges daily
-- =========================================================

-- =========================================================
-- 1) ASSIGN DAILY CHALLENGE
-- Call on first login of the day or on demand
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_assign_daily_challenge(p_user_id UUID)
RETURNS TABLE (
  challenge_id UUID,
  challenge_name TEXT,
  challenge_description TEXT,
  challenge_type TEXT,
  target_value INT,
  current_value INT,
  fp_reward INT,
  expires_at TIMESTAMPTZ,
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
  SELECT * INTO v_existing
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
    (v_today + 1)::TIMESTAMP + INTERVAL '4 hours',  -- Expires at 4am next day
    0
  )
  ON CONFLICT (user_id, challenge_id, assigned_date) DO NOTHING
  RETURNING id INTO v_user_challenge_id;

  IF v_user_challenge_id IS NULL THEN
    -- Challenge already assigned (race condition), fetch it
    SELECT uc.*, c.name, c.description, c.challenge_type, c.target_value, c.fp_reward
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

-- =========================================================
-- 2) UPDATE CHALLENGE PROGRESS
-- Called after game completion
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_update_challenge_progress(
  p_user_id UUID,
  p_game_id UUID,
  p_final_score NUMERIC,
  p_is_winner BOOLEAN,
  p_player_count INT,
  p_friends_in_game INT
)
RETURNS TABLE (
  challenge_completed BOOLEAN,
  challenge_name TEXT,
  fp_reward INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_challenge RECORD;
  v_new_value INT;
  v_completed BOOLEAN := FALSE;
  v_reward INT := 0;
  v_name TEXT := NULL;
BEGIN
  -- Get user's active daily challenge
  SELECT uc.*, c.name, c.challenge_type, c.target_value, c.fp_reward
  INTO v_challenge
  FROM public.user_challenges uc
  JOIN public.challenges c ON c.id = uc.challenge_id
  WHERE uc.user_id = p_user_id
    AND uc.is_completed = FALSE
    AND uc.expires_at > NOW()
  ORDER BY uc.assigned_date DESC
  LIMIT 1;

  IF v_challenge IS NULL THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, 0;
    RETURN;
  END IF;

  -- Calculate progress based on challenge type
  v_new_value := v_challenge.current_value;

  CASE v_challenge.challenge_type
    WHEN 'play_games' THEN
      v_new_value := v_new_value + 1;

    WHEN 'score_points' THEN
      IF p_final_score >= v_challenge.target_value THEN
        v_new_value := v_challenge.target_value;
      END IF;

    WHEN 'win_games' THEN
      IF p_is_winner THEN
        v_new_value := v_new_value + 1;
      END IF;

    WHEN 'play_with_friends' THEN
      IF p_friends_in_game > 0 THEN
        v_new_value := v_new_value + 1;
      END IF;

    WHEN 'party_game' THEN
      IF p_player_count >= v_challenge.target_value THEN
        v_new_value := v_challenge.target_value;
      END IF;

    ELSE
      -- Unknown challenge type, count as game played
      v_new_value := v_new_value + 1;
  END CASE;

  -- Check if challenge is now complete
  IF v_new_value >= v_challenge.target_value AND NOT v_challenge.is_completed THEN
    v_completed := TRUE;
    v_reward := v_challenge.fp_reward;
    v_name := v_challenge.name;

    -- Mark as completed
    UPDATE public.user_challenges
    SET
      current_value = v_new_value,
      is_completed = TRUE,
      completed_at = NOW()
    WHERE id = v_challenge.id;

    -- Award FP
    PERFORM set_config('app.allow_stat_update', 'true', true);

    UPDATE public.user_engagement
    SET
      flashback_points = flashback_points + v_reward,
      lifetime_fp = lifetime_fp + v_reward,
      tier = public.calculate_tier(lifetime_fp + v_reward),
      updated_at = NOW()
    WHERE user_id = p_user_id;

    -- Log transaction
    INSERT INTO public.fp_transactions (user_id, amount, balance_after, reason, game_id, multipliers)
    SELECT
      p_user_id,
      v_reward,
      ue.flashback_points,
      'daily_challenge',
      p_game_id,
      jsonb_build_object('challenge_id', v_challenge.challenge_id, 'challenge_name', v_name)
    FROM public.user_engagement ue
    WHERE ue.user_id = p_user_id;

  ELSE
    -- Just update progress
    UPDATE public.user_challenges
    SET current_value = v_new_value
    WHERE id = v_challenge.id;
  END IF;

  RETURN QUERY SELECT v_completed, v_name, v_reward;
END;
$$;

-- =========================================================
-- 3) GET ACTIVE CHALLENGES
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_active_challenges(p_user_id UUID)
RETURNS TABLE (
  user_challenge_id UUID,
  challenge_name TEXT,
  challenge_description TEXT,
  challenge_type TEXT,
  target_value INT,
  current_value INT,
  fp_reward INT,
  is_completed BOOLEAN,
  expires_at TIMESTAMPTZ,
  progress_percent NUMERIC(5,2)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    uc.id AS user_challenge_id,
    c.name::TEXT AS challenge_name,
    c.description::TEXT AS challenge_description,
    c.challenge_type::TEXT,
    c.target_value,
    uc.current_value,
    c.fp_reward,
    uc.is_completed,
    uc.expires_at,
    LEAST((uc.current_value::NUMERIC / c.target_value::NUMERIC) * 100, 100)::NUMERIC(5,2) AS progress_percent
  FROM public.user_challenges uc
  JOIN public.challenges c ON c.id = uc.challenge_id
  WHERE uc.user_id = p_user_id
    AND uc.expires_at > NOW()
  ORDER BY uc.is_completed ASC, uc.expires_at ASC;
END;
$$;

-- =========================================================
-- 4) CLAIM CHALLENGE REWARD
-- For challenges that require manual claim
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_claim_challenge_reward(
  p_user_id UUID,
  p_user_challenge_id UUID
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  fp_awarded INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_challenge RECORD;
BEGIN
  -- Get the challenge
  SELECT uc.*, c.fp_reward, c.name
  INTO v_challenge
  FROM public.user_challenges uc
  JOIN public.challenges c ON c.id = uc.challenge_id
  WHERE uc.id = p_user_challenge_id
    AND uc.user_id = p_user_id;

  IF v_challenge IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Challenge not found'::TEXT, 0;
    RETURN;
  END IF;

  IF NOT v_challenge.is_completed THEN
    RETURN QUERY SELECT FALSE, 'Challenge not yet completed'::TEXT, 0;
    RETURN;
  END IF;

  IF v_challenge.reward_claimed THEN
    RETURN QUERY SELECT FALSE, 'Reward already claimed'::TEXT, 0;
    RETURN;
  END IF;

  -- Mark as claimed
  UPDATE public.user_challenges
  SET reward_claimed = TRUE
  WHERE id = p_user_challenge_id;

  RETURN QUERY SELECT TRUE, 'Reward claimed!'::TEXT, v_challenge.fp_reward;
END;
$$;

-- =========================================================
-- 5) CLEANUP EXPIRED CHALLENGES (cron job)
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_cleanup_expired_challenges()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INT;
BEGIN
  -- Delete expired uncompleted challenges older than 7 days
  DELETE FROM public.user_challenges
  WHERE expires_at < NOW() - INTERVAL '7 days'
    AND is_completed = FALSE;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

-- =========================================================
-- 6) GRANTS
-- =========================================================

GRANT EXECUTE ON FUNCTION public.ff_assign_daily_challenge(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_update_challenge_progress(UUID, UUID, NUMERIC, BOOLEAN, INT, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_active_challenges(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_claim_challenge_reward(UUID, UUID) TO anon, authenticated;
