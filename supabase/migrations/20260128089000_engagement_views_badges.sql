-- =========================================================
-- Engagement Views & Badge System
--
-- Creates views for:
--   - Comprehensive FP leaderboards
--   - Badge/achievement tracking
--   - Tier distribution stats
-- =========================================================

-- =========================================================
-- 1) COMPREHENSIVE LEADERBOARD VIEW
-- =========================================================

DROP VIEW IF EXISTS public.leaderboard_fp;
CREATE OR REPLACE VIEW public.leaderboard_fp AS
SELECT
  up.id,
  up.display_name,
  up.flashback_id,
  ue.flashback_points,
  ue.lifetime_fp,
  ue.tier,
  INITCAP(REPLACE(ue.tier::TEXT, '_', ' ')) AS tier_name,
  ue.current_streak,
  ue.longest_streak,
  ue.multiplayer_games,
  ue.solo_games,
  ue.games_with_friends,
  up.games_played,
  up.games_won,
  up.highest_score,
  CASE WHEN up.games_played > 0
    THEN ROUND((up.games_won::NUMERIC / up.games_played) * 100, 1)
    ELSE 0
  END AS win_rate,
  ROW_NUMBER() OVER (ORDER BY ue.flashback_points DESC) AS fp_rank
FROM public.user_profiles up
JOIN public.user_engagement ue ON up.id = ue.user_id
WHERE ue.flashback_points > 0
ORDER BY ue.flashback_points DESC
LIMIT 100;

GRANT SELECT ON public.leaderboard_fp TO anon, authenticated;

-- =========================================================
-- 2) TIER DISTRIBUTION VIEW (for stats)
-- =========================================================

CREATE OR REPLACE VIEW public.tier_distribution AS
SELECT
  tier,
  INITCAP(REPLACE(tier::TEXT, '_', ' ')) AS tier_name,
  COUNT(*) AS player_count,
  AVG(flashback_points) AS avg_fp,
  MAX(flashback_points) AS max_fp,
  AVG(current_streak) AS avg_streak,
  MAX(longest_streak) AS max_streak
FROM public.user_engagement
GROUP BY tier
ORDER BY public.get_tier_threshold(tier) DESC;

GRANT SELECT ON public.tier_distribution TO anon, authenticated;

-- =========================================================
-- 3) BADGE DEFINITIONS TABLE
-- =========================================================

CREATE TABLE IF NOT EXISTS public.badges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  badge_key TEXT UNIQUE NOT NULL,  -- e.g., 'streak_7', 'tier_elite', 'games_100'
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  icon TEXT,  -- Icon name or emoji
  category TEXT NOT NULL,  -- 'streak', 'tier', 'social', 'achievement', 'milestone'
  rarity TEXT NOT NULL DEFAULT 'common',  -- 'common', 'uncommon', 'rare', 'epic', 'legendary'

  -- Unlock criteria
  unlock_type TEXT NOT NULL,  -- 'streak', 'tier', 'games_played', 'games_won', 'fp_earned', 'friends', 'referrals', 'score'
  unlock_value INT,

  -- Display order
  sort_order INT NOT NULL DEFAULT 0,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.badges ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public_read_badges" ON public.badges
  FOR SELECT USING (true);

GRANT SELECT ON public.badges TO anon, authenticated;

-- =========================================================
-- 4) USER_BADGES TABLE (earned badges)
-- =========================================================

CREATE TABLE IF NOT EXISTS public.user_badges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  badge_id UUID NOT NULL REFERENCES public.badges(id) ON DELETE CASCADE,
  earned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Optional context
  earned_value INT,  -- e.g., the streak length or score that earned this
  game_id UUID REFERENCES public.games(id) ON DELETE SET NULL,

  UNIQUE(user_id, badge_id)
);

CREATE INDEX IF NOT EXISTS idx_user_badges_user ON public.user_badges(user_id);

ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;

CREATE POLICY "own_badges_read" ON public.user_badges
  FOR SELECT USING (user_id = auth.uid() OR TRUE);  -- Public for profile display

CREATE POLICY "service_write_badges" ON public.user_badges
  FOR INSERT WITH CHECK (false);

GRANT SELECT ON public.user_badges TO anon, authenticated;

-- =========================================================
-- 5) SEED BADGES
-- =========================================================

INSERT INTO public.badges (badge_key, name, description, icon, category, rarity, unlock_type, unlock_value, sort_order)
VALUES
  -- Tier badges
  ('tier_varsity', 'Varsity', 'Reached Varsity tier', '🎓', 'tier', 'common', 'tier', 500, 10),
  ('tier_pro', 'Pro', 'Reached Pro tier', '💼', 'tier', 'uncommon', 'tier', 2000, 20),
  ('tier_all_pro', 'All-Pro', 'Reached All-Pro tier', '⭐', 'tier', 'rare', 'tier', 5000, 30),
  ('tier_elite', 'Elite', 'Reached Elite tier', '💎', 'tier', 'epic', 'tier', 15000, 40),
  ('tier_legend', 'Legend', 'Reached Legend tier', '👑', 'tier', 'epic', 'tier', 50000, 50),
  ('tier_goat', 'GOAT', 'Reached GOAT tier - The Greatest', '🐐', 'tier', 'legendary', 'tier', 150000, 60),

  -- Streak badges
  ('streak_7', 'Week Warrior', '7-day play streak', '🔥', 'streak', 'common', 'streak', 7, 100),
  ('streak_14', 'Fortnight Fan', '14-day play streak', '🔥', 'streak', 'uncommon', 'streak', 14, 110),
  ('streak_30', 'Monthly MVP', '30-day play streak', '🔥', 'streak', 'rare', 'streak', 30, 120),
  ('streak_60', 'Dedicated Drafter', '60-day play streak', '🔥', 'streak', 'epic', 'streak', 60, 130),
  ('streak_100', 'Century Club', '100-day play streak', '🔥', 'streak', 'legendary', 'streak', 100, 140),

  -- Social badges
  ('friends_10', 'Social Butterfly', 'Played with 10 different friends', '🦋', 'social', 'uncommon', 'friends', 10, 200),
  ('friends_25', 'Popular Player', 'Played with 25 different friends', '🎉', 'social', 'rare', 'friends', 25, 210),
  ('friends_50', 'Fan Favorite', 'Played with 50 different friends', '🌟', 'social', 'epic', 'friends', 50, 220),

  -- Referral badges
  ('referrals_3', 'Recruiter', 'Referred 3 friends', '📢', 'social', 'uncommon', 'referrals', 3, 300),
  ('referrals_10', 'Talent Scout', 'Referred 10 friends', '🔍', 'social', 'rare', 'referrals', 10, 310),
  ('referrals_25', 'Head Hunter', 'Referred 25 friends', '🎯', 'social', 'epic', 'referrals', 25, 320),
  ('referrals_50', 'Community Leader', 'Referred 50 friends', '🏆', 'social', 'legendary', 'referrals', 50, 330),

  -- Achievement badges
  ('score_200', 'High Roller', 'Scored 200+ fantasy points in a game', '💰', 'achievement', 'rare', 'score', 200, 400),
  ('score_250', 'Fantasy King', 'Scored 250+ fantasy points in a game', '👑', 'achievement', 'epic', 'score', 250, 410),
  ('score_300', 'Legendary Performance', 'Scored 300+ fantasy points in a game', '🌟', 'achievement', 'legendary', 'score', 300, 420),

  -- Games played milestones
  ('games_10', 'Getting Started', 'Played 10 games', '🎮', 'milestone', 'common', 'games_played', 10, 500),
  ('games_50', 'Regular', 'Played 50 games', '🎮', 'milestone', 'uncommon', 'games_played', 50, 510),
  ('games_100', 'Veteran', 'Played 100 games', '🎮', 'milestone', 'rare', 'games_played', 100, 520),
  ('games_500', 'Expert', 'Played 500 games', '🎮', 'milestone', 'epic', 'games_played', 500, 530),
  ('games_1000', 'Master', 'Played 1000 games', '🎮', 'milestone', 'legendary', 'games_played', 1000, 540),

  -- Win milestones
  ('wins_10', 'Winner', 'Won 10 games', '🏅', 'milestone', 'common', 'games_won', 10, 600),
  ('wins_50', 'Champion', 'Won 50 games', '🏅', 'milestone', 'uncommon', 'games_won', 50, 610),
  ('wins_100', 'Legend', 'Won 100 games', '🏅', 'milestone', 'rare', 'games_won', 100, 620),
  ('wins_500', 'Dynasty', 'Won 500 games', '🏅', 'milestone', 'epic', 'games_won', 500, 630)
ON CONFLICT (badge_key) DO NOTHING;

-- =========================================================
-- 6) FUNCTION TO CHECK AND AWARD BADGES
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_check_and_award_badges(p_user_id UUID)
RETURNS TABLE (
  new_badge_key TEXT,
  new_badge_name TEXT,
  new_badge_rarity TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_engagement RECORD;
  v_profile RECORD;
  v_referral_count INT;
  v_badge RECORD;
BEGIN
  -- Get user stats
  SELECT * INTO v_engagement FROM public.user_engagement WHERE user_id = p_user_id;
  SELECT * INTO v_profile FROM public.user_profiles WHERE id = p_user_id;

  IF v_engagement IS NULL OR v_profile IS NULL THEN
    RETURN;
  END IF;

  -- Get referral count
  SELECT COUNT(*) INTO v_referral_count
  FROM public.referrals
  WHERE referrer_id = p_user_id AND status = 'completed';

  -- Check each badge type
  FOR v_badge IN
    SELECT * FROM public.badges b
    WHERE NOT EXISTS (
      SELECT 1 FROM public.user_badges ub
      WHERE ub.user_id = p_user_id AND ub.badge_id = b.id
    )
    ORDER BY b.sort_order
  LOOP
    -- Check if badge should be awarded
    IF (
      (v_badge.unlock_type = 'tier' AND public.get_tier_threshold(v_engagement.tier) >= v_badge.unlock_value) OR
      (v_badge.unlock_type = 'streak' AND v_engagement.longest_streak >= v_badge.unlock_value) OR
      (v_badge.unlock_type = 'friends' AND v_engagement.unique_friends_played_with >= v_badge.unlock_value) OR
      (v_badge.unlock_type = 'referrals' AND v_referral_count >= v_badge.unlock_value) OR
      (v_badge.unlock_type = 'games_played' AND v_profile.games_played >= v_badge.unlock_value) OR
      (v_badge.unlock_type = 'games_won' AND v_profile.games_won >= v_badge.unlock_value) OR
      (v_badge.unlock_type = 'score' AND v_profile.highest_score >= v_badge.unlock_value)
    ) THEN
      -- Award the badge
      INSERT INTO public.user_badges (user_id, badge_id)
      VALUES (p_user_id, v_badge.id)
      ON CONFLICT (user_id, badge_id) DO NOTHING;

      -- Return newly awarded badge
      RETURN QUERY SELECT v_badge.badge_key, v_badge.name, v_badge.rarity;
    END IF;
  END LOOP;
END;
$$;

-- =========================================================
-- 7) GET USER BADGES
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_user_badges(p_user_id UUID)
RETURNS TABLE (
  badge_key TEXT,
  name TEXT,
  description TEXT,
  icon TEXT,
  category TEXT,
  rarity TEXT,
  earned_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    b.badge_key,
    b.name,
    b.description,
    b.icon,
    b.category,
    b.rarity,
    ub.earned_at
  FROM public.user_badges ub
  JOIN public.badges b ON b.id = ub.badge_id
  WHERE ub.user_id = p_user_id
  ORDER BY ub.earned_at DESC;
END;
$$;

-- =========================================================
-- 8) GET ALL BADGES (with user's earned status)
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_all_badges(p_user_id UUID DEFAULT NULL)
RETURNS TABLE (
  badge_key TEXT,
  name TEXT,
  description TEXT,
  icon TEXT,
  category TEXT,
  rarity TEXT,
  unlock_type TEXT,
  unlock_value INT,
  is_earned BOOLEAN,
  earned_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    b.badge_key,
    b.name,
    b.description,
    b.icon,
    b.category,
    b.rarity,
    b.unlock_type,
    b.unlock_value,
    (ub.id IS NOT NULL) AS is_earned,
    ub.earned_at
  FROM public.badges b
  LEFT JOIN public.user_badges ub ON ub.badge_id = b.id AND ub.user_id = p_user_id
  ORDER BY b.sort_order;
END;
$$;

-- =========================================================
-- 9) GRANTS
-- =========================================================

GRANT EXECUTE ON FUNCTION public.ff_check_and_award_badges(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_user_badges(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ff_get_all_badges(UUID) TO anon, authenticated;
