-- Simple test function to update profile directly
CREATE OR REPLACE FUNCTION public.ff_test_update_profile(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_games INT;
  v_new_games INT;
BEGIN
  -- Get current value
  SELECT games_played INTO v_old_games FROM public.user_profiles WHERE id = p_user_id;
  
  IF v_old_games IS NULL THEN
    RETURN 'Profile not found for user: ' || p_user_id;
  END IF;
  
  -- Update
  UPDATE public.user_profiles
  SET games_played = games_played + 1, updated_at = NOW()
  WHERE id = p_user_id;
  
  -- Get new value
  SELECT games_played INTO v_new_games FROM public.user_profiles WHERE id = p_user_id;
  
  RETURN 'Updated games_played from ' || v_old_games || ' to ' || v_new_games;
END;
$$;
