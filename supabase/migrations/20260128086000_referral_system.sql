-- =========================================================
-- Referral System Functions
--
-- Implements:
--   - Apply referral code on signup
--   - Award double-sided rewards (referrer + referee)
--   - Track referral milestones
--   - Complete referral on first game
-- =========================================================

-- =========================================================
-- 1) APPLY REFERRAL CODE
-- Called when a new user signs up with a referral code
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_apply_referral_code(
  p_referee_id UUID,
  p_referral_code TEXT
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  referrer_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer_id UUID;
  v_referrer_name TEXT;
  v_existing RECORD;
BEGIN
  -- Check if user already has a referral
  SELECT * INTO v_existing
  FROM public.referrals
  WHERE referee_id = p_referee_id;

  IF v_existing IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'You have already used a referral code'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Find referrer by code
  SELECT id, display_name INTO v_referrer_id, v_referrer_name
  FROM public.user_profiles
  WHERE referral_code = UPPER(TRIM(p_referral_code));

  IF v_referrer_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid referral code'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Can't refer yourself
  IF v_referrer_id = p_referee_id THEN
    RETURN QUERY SELECT FALSE, 'You cannot use your own referral code'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Create the referral (pending until first game)
  INSERT INTO public.referrals (
    referrer_id,
    referee_id,
    referral_code,
    status
  ) VALUES (
    v_referrer_id,
    p_referee_id,
    UPPER(TRIM(p_referral_code)),
    'pending'
  );

  -- Give referee a bonus streak freeze immediately
  UPDATE public.user_engagement
  SET streak_freezes_available = streak_freezes_available + 1
  WHERE user_id = p_referee_id;

  RETURN QUERY SELECT TRUE, 'Referral code applied! Complete your first game to receive your bonus.'::TEXT, v_referrer_name;
END;
$$;

-- =========================================================
-- 2) COMPLETE REFERRAL (called on first game completion)
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_complete_referral(p_referee_id UUID)
RETURNS TABLE (
  referral_completed BOOLEAN,
  referrer_bonus INT,
  referee_bonus INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral RECORD;
  v_referrer_bonus INT := 100;
  v_referee_bonus INT := 50;
  v_referrer_total_referrals INT;
  v_milestone_bonus INT := 0;
BEGIN
  -- Check for pending referral
  SELECT * INTO v_referral
  FROM public.referrals
  WHERE referee_id = p_referee_id
    AND status = 'pending';

  IF v_referral IS NULL THEN
    RETURN QUERY SELECT FALSE, 0, 0;
    RETURN;
  END IF;

  PERFORM set_config('app.allow_stat_update', 'true', true);

  -- Mark referral as completed
  UPDATE public.referrals
  SET
    status = 'completed',
    referrer_reward_fp = v_referrer_bonus,
    referee_reward_fp = v_referee_bonus,
    referee_streak_freeze = TRUE,
    completed_at = NOW()
  WHERE id = v_referral.id;

  -- Award referee bonus
  UPDATE public.user_engagement
  SET
    flashback_points = flashback_points + v_referee_bonus,
    lifetime_fp = lifetime_fp + v_referee_bonus,
    tier = public.calculate_tier(lifetime_fp + v_referee_bonus),
    updated_at = NOW()
  WHERE user_id = p_referee_id;

  -- Log referee transaction
  INSERT INTO public.fp_transactions (user_id, amount, balance_after, reason, multipliers)
  SELECT
    p_referee_id,
    v_referee_bonus,
    ue.flashback_points,
    'referral_bonus_referee',
    jsonb_build_object('referrer_id', v_referral.referrer_id)
  FROM public.user_engagement ue
  WHERE ue.user_id = p_referee_id;

  -- Count referrer's total referrals to check milestones
  SELECT COUNT(*) INTO v_referrer_total_referrals
  FROM public.referrals
  WHERE referrer_id = v_referral.referrer_id
    AND status = 'completed';

  -- Check for milestone bonuses (3, 10, 25, 50 referrals)
  IF v_referrer_total_referrals = 3 THEN
    v_milestone_bonus := 250;
  ELSIF v_referrer_total_referrals = 10 THEN
    v_milestone_bonus := 500;
  ELSIF v_referrer_total_referrals = 25 THEN
    v_milestone_bonus := 1000;
  ELSIF v_referrer_total_referrals = 50 THEN
    v_milestone_bonus := 2500;
  END IF;

  -- Award referrer bonus
  UPDATE public.user_engagement
  SET
    flashback_points = flashback_points + v_referrer_bonus + v_milestone_bonus,
    lifetime_fp = lifetime_fp + v_referrer_bonus + v_milestone_bonus,
    tier = public.calculate_tier(lifetime_fp + v_referrer_bonus + v_milestone_bonus),
    updated_at = NOW()
  WHERE user_id = v_referral.referrer_id;

  -- Log referrer transaction
  INSERT INTO public.fp_transactions (user_id, amount, balance_after, reason, multipliers)
  SELECT
    v_referral.referrer_id,
    v_referrer_bonus,
    ue.flashback_points,
    'referral_bonus_referrer',
    jsonb_build_object('referee_id', p_referee_id, 'total_referrals', v_referrer_total_referrals)
  FROM public.user_engagement ue
  WHERE ue.user_id = v_referral.referrer_id;

  -- Log milestone bonus if applicable
  IF v_milestone_bonus > 0 THEN
    INSERT INTO public.fp_transactions (user_id, amount, balance_after, reason, multipliers)
    SELECT
      v_referral.referrer_id,
      v_milestone_bonus,
      ue.flashback_points,
      'referral_milestone_' || v_referrer_total_referrals::TEXT,
      jsonb_build_object('milestone', v_referrer_total_referrals, 'bonus', v_milestone_bonus)
    FROM public.user_engagement ue
    WHERE ue.user_id = v_referral.referrer_id;
  END IF;

  RETURN QUERY SELECT TRUE, v_referrer_bonus + v_milestone_bonus, v_referee_bonus;
END;
$$;

-- =========================================================
-- 3) GET REFERRAL STATS
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_referral_stats(p_user_id UUID)
RETURNS TABLE (
  referral_code TEXT,
  total_referrals INT,
  completed_referrals INT,
  pending_referrals INT,
  total_fp_earned INT,
  next_milestone INT,
  referrals_to_next_milestone INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total INT;
  v_completed INT;
  v_pending INT;
  v_fp_earned INT;
  v_code TEXT;
  v_next_milestone INT;
  v_to_next INT;
BEGIN
  -- Get user's referral code
  SELECT up.referral_code INTO v_code
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  -- Count referrals
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'completed'),
    COUNT(*) FILTER (WHERE status = 'pending')
  INTO v_total, v_completed, v_pending
  FROM public.referrals
  WHERE referrer_id = p_user_id;

  -- Calculate total FP earned from referrals
  SELECT COALESCE(SUM(amount), 0) INTO v_fp_earned
  FROM public.fp_transactions
  WHERE user_id = p_user_id
    AND (reason LIKE 'referral_%' OR reason LIKE 'referral_milestone_%');

  -- Calculate next milestone
  IF v_completed < 3 THEN
    v_next_milestone := 3;
    v_to_next := 3 - v_completed;
  ELSIF v_completed < 10 THEN
    v_next_milestone := 10;
    v_to_next := 10 - v_completed;
  ELSIF v_completed < 25 THEN
    v_next_milestone := 25;
    v_to_next := 25 - v_completed;
  ELSIF v_completed < 50 THEN
    v_next_milestone := 50;
    v_to_next := 50 - v_completed;
  ELSE
    v_next_milestone := NULL;
    v_to_next := 0;
  END IF;

  RETURN QUERY SELECT
    v_code,
    v_total,
    v_completed,
    v_pending,
    v_fp_earned,
    v_next_milestone,
    v_to_next;
END;
$$;

-- =========================================================
-- 4) GET REFERRAL HISTORY (list of people referred)
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_referral_history(
  p_user_id UUID,
  p_limit INT DEFAULT 20
)
RETURNS TABLE (
  referee_display_name TEXT,
  status public.referral_status,
  fp_reward INT,
  created_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    up.display_name AS referee_display_name,
    r.status,
    r.referrer_reward_fp AS fp_reward,
    r.created_at,
    r.completed_at
  FROM public.referrals r
  JOIN public.user_profiles up ON up.id = r.referee_id
  WHERE r.referrer_id = p_user_id
  ORDER BY r.created_at DESC
  LIMIT p_limit;
END;
$$;

-- =========================================================
-- 5) CHECK IF USER WAS REFERRED (for UI display)
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_my_referral(p_user_id UUID)
RETURNS TABLE (
  was_referred BOOLEAN,
  referrer_name TEXT,
  status public.referral_status,
  bonus_received INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    TRUE,
    up.display_name,
    r.status,
    r.referee_reward_fp
  FROM public.referrals r
  JOIN public.user_profiles up ON up.id = r.referrer_id
  WHERE r.referee_id = p_user_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, NULL::TEXT, NULL::public.referral_status, NULL::INT;
  END IF;
END;
$$;

-- =========================================================
-- 6) GRANTS
-- =========================================================

GRANT EXECUTE ON FUNCTION public.ff_apply_referral_code(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_complete_referral(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_referral_stats(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_referral_history(UUID, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_my_referral(UUID) TO anon, authenticated;
