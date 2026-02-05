-- =========================================================
-- Fix timestamp type mismatch in daily challenge function
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
  v_expires TIMESTAMPTZ;
BEGIN
  -- Calculate expiration time (4am next day)
  v_expires := (v_today + 1)::TIMESTAMPTZ + INTERVAL '4 hours';

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
      v_existing.expires_at::TIMESTAMPTZ,
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
    v_expires,
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
      v_existing.expires_at::TIMESTAMPTZ,
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
    v_expires,
    FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ff_assign_daily_challenge(UUID) TO anon, authenticated;
