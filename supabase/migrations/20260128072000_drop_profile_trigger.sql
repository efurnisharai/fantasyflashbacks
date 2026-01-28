-- The validate_profile_update_trigger is blocking ALL stat updates,
-- even from SECURITY DEFINER functions. Drop it.
-- Stats are already protected by RLS - only ff_save_game_results can update them.

DROP TRIGGER IF EXISTS validate_profile_update_trigger ON public.user_profiles;
DROP FUNCTION IF EXISTS public.validate_profile_update();
