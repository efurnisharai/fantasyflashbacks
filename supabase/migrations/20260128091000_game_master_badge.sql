-- =========================================================
-- Game Master Badge - Ultra Rare Creator Badge
--
-- Special badge for the game creator with mythic rarity
-- =========================================================

-- Add 'mythic' as a valid rarity option (update check constraint if one exists)
-- First, let's add the Game Master badge

INSERT INTO public.badges (badge_key, name, description, icon, category, rarity, unlock_type, unlock_value, sort_order)
VALUES (
  'game_master',
  'Game Master',
  'The creator of Fantasy Flashback. A true legend.',
  '🎮',
  'achievement',
  'mythic',
  'manual',  -- Manual unlock type - only awarded by admin
  NULL,
  0  -- Highest priority in sort order
)
ON CONFLICT (badge_key) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  rarity = EXCLUDED.rarity,
  sort_order = EXCLUDED.sort_order;

-- =========================================================
-- Function to manually award Game Master badge to a user
-- This should only be called once for the creator
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_award_game_master_badge(p_user_email TEXT)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_badge_id UUID;
BEGIN
  -- Find user by email
  SELECT id INTO v_user_id
  FROM auth.users
  WHERE email = p_user_email;

  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'User not found with that email'::TEXT;
    RETURN;
  END IF;

  -- Get the Game Master badge ID
  SELECT id INTO v_badge_id
  FROM public.badges
  WHERE badge_key = 'game_master';

  IF v_badge_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Game Master badge not found'::TEXT;
    RETURN;
  END IF;

  -- Award the badge
  INSERT INTO public.user_badges (user_id, badge_id)
  VALUES (v_user_id, v_badge_id)
  ON CONFLICT (user_id, badge_id) DO NOTHING;

  RETURN QUERY SELECT TRUE, 'Game Master badge awarded!'::TEXT;
END;
$$;

-- Only allow service role to call this function (not public)
REVOKE EXECUTE ON FUNCTION public.ff_award_game_master_badge(TEXT) FROM anon, authenticated;
