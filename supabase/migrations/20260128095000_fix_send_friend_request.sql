-- Fix ff_send_friend_request to normalize flashback_id the same way
-- the search function does (trim, uppercase, add FF- prefix if missing).
-- Also drop any stale overload that may exist with (UUID, UUID) signature.

-- Drop old overload if it exists (original version may have taken UUID instead of TEXT)
DROP FUNCTION IF EXISTS public.ff_send_friend_request(UUID, UUID);

CREATE OR REPLACE FUNCTION public.ff_send_friend_request(
  p_user_id UUID,
  p_friend_flashback_id TEXT
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  friendship_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_friend_id UUID;
  v_existing_id UUID;
  v_friendship_id UUID;
  v_normalized_id TEXT;
BEGIN
  -- Normalize the flashback_id (same logic as ff_search_user_by_flashback_id)
  v_normalized_id := UPPER(TRIM(p_friend_flashback_id));
  IF v_normalized_id IS NULL OR v_normalized_id = '' THEN
    RETURN QUERY SELECT FALSE, 'Flashback ID is required'::TEXT, NULL::UUID;
    RETURN;
  END IF;
  IF NOT v_normalized_id LIKE 'FF-%' THEN
    v_normalized_id := 'FF-' || v_normalized_id;
  END IF;

  -- Find the friend by flashback_id
  SELECT id INTO v_friend_id
  FROM public.user_profiles
  WHERE flashback_id = v_normalized_id;

  IF v_friend_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'User not found with that Flashback ID'::TEXT, NULL::UUID;
    RETURN;
  END IF;

  -- Can't friend yourself
  IF v_friend_id = p_user_id THEN
    RETURN QUERY SELECT FALSE, 'You cannot add yourself as a friend'::TEXT, NULL::UUID;
    RETURN;
  END IF;

  -- Check for existing friendship
  SELECT id INTO v_existing_id
  FROM public.friendships
  WHERE (user_id = p_user_id AND friend_id = v_friend_id)
     OR (user_id = v_friend_id AND friend_id = p_user_id);

  IF v_existing_id IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'Friend request already exists or you are already friends'::TEXT, v_existing_id;
    RETURN;
  END IF;

  -- Create the friend request
  INSERT INTO public.friendships (user_id, friend_id, initiated_by, status)
  VALUES (p_user_id, v_friend_id, p_user_id, 'pending')
  RETURNING id INTO v_friendship_id;

  RETURN QUERY SELECT TRUE, 'Friend request sent!'::TEXT, v_friendship_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ff_send_friend_request(UUID, TEXT) TO anon, authenticated;
