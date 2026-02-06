-- =========================================================
-- Friend System Functions
--
-- Implements:
--   - Send/accept/decline friend requests
--   - Get friends list
--   - Search users by Flashback ID
--   - Track first game with friend bonus
-- =========================================================

-- =========================================================
-- 1) SEND FRIEND REQUEST
-- =========================================================

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

  -- Create the friend request (bidirectional entry)
  INSERT INTO public.friendships (user_id, friend_id, initiated_by, status)
  VALUES (p_user_id, v_friend_id, p_user_id, 'pending')
  RETURNING id INTO v_friendship_id;

  RETURN QUERY SELECT TRUE, 'Friend request sent!'::TEXT, v_friendship_id;
END;
$$;

-- =========================================================
-- 2) ACCEPT FRIEND REQUEST
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_accept_friend_request(
  p_user_id UUID,
  p_friendship_id UUID
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_friendship RECORD;
BEGIN
  -- Get the friendship
  SELECT * INTO v_friendship
  FROM public.friendships
  WHERE id = p_friendship_id;

  IF v_friendship IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Friend request not found'::TEXT;
    RETURN;
  END IF;

  -- Make sure the current user is the one receiving the request
  IF v_friendship.friend_id != p_user_id THEN
    RETURN QUERY SELECT FALSE, 'You cannot accept this friend request'::TEXT;
    RETURN;
  END IF;

  IF v_friendship.status != 'pending' THEN
    RETURN QUERY SELECT FALSE, 'This friend request is no longer pending'::TEXT;
    RETURN;
  END IF;

  -- Accept the request
  UPDATE public.friendships
  SET status = 'accepted', updated_at = NOW()
  WHERE id = p_friendship_id;

  RETURN QUERY SELECT TRUE, 'Friend request accepted!'::TEXT;
END;
$$;

-- =========================================================
-- 3) DECLINE/REMOVE FRIEND
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_remove_friend(
  p_user_id UUID,
  p_friendship_id UUID
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_friendship RECORD;
BEGIN
  -- Get the friendship
  SELECT * INTO v_friendship
  FROM public.friendships
  WHERE id = p_friendship_id;

  IF v_friendship IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Friendship not found'::TEXT;
    RETURN;
  END IF;

  -- Make sure the current user is part of the friendship
  IF v_friendship.user_id != p_user_id AND v_friendship.friend_id != p_user_id THEN
    RETURN QUERY SELECT FALSE, 'You cannot modify this friendship'::TEXT;
    RETURN;
  END IF;

  -- Delete the friendship
  DELETE FROM public.friendships WHERE id = p_friendship_id;

  RETURN QUERY SELECT TRUE, 'Friend removed'::TEXT;
END;
$$;

-- =========================================================
-- 4) GET FRIENDS LIST
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_friends(p_user_id UUID)
RETURNS TABLE (
  friendship_id UUID,
  friend_user_id UUID,
  friend_display_name TEXT,
  friend_flashback_id TEXT,
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
-- 5) GET PENDING FRIEND REQUESTS
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_friend_requests(p_user_id UUID)
RETURNS TABLE (
  friendship_id UUID,
  from_user_id UUID,
  from_display_name TEXT,
  from_flashback_id TEXT,
  from_tier public.flashback_tier,
  requested_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    f.id AS friendship_id,
    f.user_id AS from_user_id,
    up.display_name AS from_display_name,
    up.flashback_id AS from_flashback_id,
    COALESCE(ue.tier, 'rookie'::public.flashback_tier) AS from_tier,
    f.created_at AS requested_at
  FROM public.friendships f
  JOIN public.user_profiles up ON up.id = f.user_id
  LEFT JOIN public.user_engagement ue ON ue.user_id = up.id
  WHERE f.friend_id = p_user_id
    AND f.status = 'pending'
  ORDER BY f.created_at DESC;
END;
$$;

-- =========================================================
-- 6) SEARCH USER BY FLASHBACK ID
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_search_user_by_flashback_id(
  p_flashback_id TEXT,
  p_searcher_id UUID DEFAULT NULL
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  flashback_id TEXT,
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
  -- Normalize the search ID (uppercase, handle with/without FF- prefix)
  v_normalized_id := UPPER(TRIM(p_flashback_id));
  IF NOT v_normalized_id LIKE 'FF-%' THEN
    v_normalized_id := 'FF-' || v_normalized_id;
  END IF;

  RETURN QUERY
  SELECT
    up.id AS user_id,
    up.display_name,
    up.flashback_id,
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
-- 7) GET RECENTLY PLAYED WITH (for quick-add)
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_recent_players(
  p_user_id UUID,
  p_limit INT DEFAULT 10
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  flashback_id TEXT,
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
-- 8) AWARD FIRST GAME WITH FRIEND BONUS
-- Called from ff_save_game_results
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_award_first_friend_game_bonus(
  p_user_id UUID,
  p_game_id UUID
)
RETURNS INT  -- Returns total bonus FP awarded
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bonus_total INT := 0;
  v_friend_record RECORD;
BEGIN
  -- Find friends in this game who haven't received first-game bonus yet
  FOR v_friend_record IN
    SELECT f.id AS friendship_id, gp.user_id AS friend_id
    FROM public.friendships f
    JOIN public.game_players gp ON gp.game_id = p_game_id
    WHERE gp.user_id != p_user_id
      AND f.status = 'accepted'
      AND f.first_game_bonus_awarded = FALSE
      AND (
        (f.user_id = p_user_id AND f.friend_id = gp.user_id) OR
        (f.friend_id = p_user_id AND f.user_id = gp.user_id)
      )
  LOOP
    -- Mark bonus as awarded
    UPDATE public.friendships
    SET first_game_bonus_awarded = TRUE, updated_at = NOW()
    WHERE id = v_friend_record.friendship_id;

    -- Award 50 FP bonus
    v_bonus_total := v_bonus_total + 50;
  END LOOP;

  -- If we earned any bonus, add to user's FP
  IF v_bonus_total > 0 THEN
    PERFORM set_config('app.allow_stat_update', 'true', true);

    UPDATE public.user_engagement
    SET
      flashback_points = flashback_points + v_bonus_total,
      lifetime_fp = lifetime_fp + v_bonus_total,
      tier = public.calculate_tier(lifetime_fp + v_bonus_total),
      updated_at = NOW()
    WHERE user_id = p_user_id;

    -- Log transaction
    INSERT INTO public.fp_transactions (
      user_id, amount, balance_after, reason, game_id, multipliers
    )
    SELECT
      p_user_id,
      v_bonus_total,
      ue.flashback_points,
      'first_friend_game',
      p_game_id,
      jsonb_build_object('new_friends_count', v_bonus_total / 50)
    FROM public.user_engagement ue
    WHERE ue.user_id = p_user_id;
  END IF;

  RETURN v_bonus_total;
END;
$$;

-- =========================================================
-- 9) GRANTS
-- =========================================================

GRANT EXECUTE ON FUNCTION public.ff_send_friend_request(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_accept_friend_request(UUID, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_remove_friend(UUID, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_friends(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_friend_requests(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_search_user_by_flashback_id(TEXT, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_recent_players(UUID, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_award_first_friend_game_bonus(UUID, UUID) TO anon, authenticated;
