-- =========================================================
-- Fantasy Flashback: Points & Engagement System
--
-- Implements:
--   - Flashback Points (FP) for engagement tracking
--   - Flashback Rating (FR) for skill-based matchmaking
--   - Streaks and daily incentives
--   - Friends and referral systems
--   - Tier progression
-- =========================================================

-- =========================================================
-- 1) TIER ENUM TYPE
-- =========================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'flashback_tier') THEN
    CREATE TYPE public.flashback_tier AS ENUM (
      'rookie',    -- 0 FP
      'varsity',   -- 500 FP
      'pro',       -- 2,000 FP
      'all_pro',   -- 5,000 FP
      'elite',     -- 15,000 FP
      'legend',    -- 50,000 FP
      'goat'       -- 150,000 FP
    );
  END IF;
END$$;

-- =========================================================
-- 2) USER_PROFILES ADDITIONS
-- =========================================================

-- Add flashback_id for friend system (e.g., "FF-ABC1234")
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS flashback_id TEXT UNIQUE;

-- Add referral_code for referral system
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS referral_code TEXT UNIQUE;

-- Generate flashback_id for existing users
UPDATE public.user_profiles
SET flashback_id = 'FF-' || UPPER(SUBSTRING(md5(id::text) FROM 1 FOR 7))
WHERE flashback_id IS NULL;

-- Generate referral_code for existing users
UPDATE public.user_profiles
SET referral_code = UPPER(SUBSTRING(md5(id::text || 'ref') FROM 1 FOR 8))
WHERE referral_code IS NULL;

-- Function to generate flashback_id for new users
CREATE OR REPLACE FUNCTION public.generate_flashback_id()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  new_id TEXT;
  attempts INT := 0;
BEGIN
  LOOP
    new_id := 'FF-' || UPPER(SUBSTRING(md5(random()::text || clock_timestamp()::text) FROM 1 FOR 7));

    -- Check if this ID already exists
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE flashback_id = new_id) THEN
      NEW.flashback_id := new_id;
      NEW.referral_code := UPPER(SUBSTRING(md5(random()::text || clock_timestamp()::text || 'ref') FROM 1 FOR 8));
      EXIT;
    END IF;

    attempts := attempts + 1;
    IF attempts > 100 THEN
      -- Fallback to UUID-based
      NEW.flashback_id := 'FF-' || UPPER(SUBSTRING(NEW.id::text FROM 1 FOR 7));
      NEW.referral_code := UPPER(SUBSTRING(md5(NEW.id::text || 'ref') FROM 1 FOR 8));
      EXIT;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

-- Trigger to auto-generate flashback_id
DROP TRIGGER IF EXISTS generate_flashback_id_trigger ON public.user_profiles;
CREATE TRIGGER generate_flashback_id_trigger
  BEFORE INSERT ON public.user_profiles
  FOR EACH ROW
  WHEN (NEW.flashback_id IS NULL)
  EXECUTE FUNCTION public.generate_flashback_id();

-- Index for friend lookup by flashback_id
CREATE INDEX IF NOT EXISTS idx_user_profiles_flashback_id
  ON public.user_profiles(flashback_id);

-- =========================================================
-- 3) USER_ENGAGEMENT TABLE
-- =========================================================

CREATE TABLE IF NOT EXISTS public.user_engagement (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Flashback Points (engagement currency)
  flashback_points BIGINT NOT NULL DEFAULT 0,
  lifetime_fp BIGINT NOT NULL DEFAULT 0,  -- Never decreases, for tier calculation

  -- Current tier (calculated from lifetime_fp)
  tier public.flashback_tier NOT NULL DEFAULT 'rookie',

  -- Streak tracking
  current_streak INT NOT NULL DEFAULT 0,
  longest_streak INT NOT NULL DEFAULT 0,
  last_game_date DATE,
  streak_freezes_available INT NOT NULL DEFAULT 1,
  streak_freeze_last_used DATE,

  -- Daily tracking
  games_today INT NOT NULL DEFAULT 0,
  first_game_bonus_claimed_today BOOLEAN NOT NULL DEFAULT FALSE,
  last_activity_date DATE,

  -- Weekly tracking
  games_this_week INT NOT NULL DEFAULT 0,
  week_start_date DATE,

  -- Multiplayer stats
  multiplayer_games INT NOT NULL DEFAULT 0,
  solo_games INT NOT NULL DEFAULT 0,

  -- Friend game stats
  games_with_friends INT NOT NULL DEFAULT 0,
  unique_friends_played_with INT NOT NULL DEFAULT 0,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for leaderboards
CREATE INDEX IF NOT EXISTS idx_user_engagement_fp
  ON public.user_engagement(flashback_points DESC);
CREATE INDEX IF NOT EXISTS idx_user_engagement_tier
  ON public.user_engagement(tier, flashback_points DESC);
CREATE INDEX IF NOT EXISTS idx_user_engagement_streak
  ON public.user_engagement(current_streak DESC);

-- =========================================================
-- 4) USER_RATINGS TABLE (Glicko-2 style)
-- =========================================================

CREATE TABLE IF NOT EXISTS public.user_ratings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_mode_hash TEXT NOT NULL,  -- Same hash as game_results

  -- Glicko-2 parameters
  rating NUMERIC(8,2) NOT NULL DEFAULT 1000,  -- Skill rating (starts at 1000)
  rating_deviation NUMERIC(8,2) NOT NULL DEFAULT 350,  -- Uncertainty (starts high)
  volatility NUMERIC(8,6) NOT NULL DEFAULT 0.06,  -- How much rating changes

  -- Stats
  games_rated INT NOT NULL DEFAULT 0,
  wins INT NOT NULL DEFAULT 0,

  -- Peak tracking
  peak_rating NUMERIC(8,2) NOT NULL DEFAULT 1000,
  peak_date TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE(user_id, game_mode_hash)
);

CREATE INDEX IF NOT EXISTS idx_user_ratings_rating
  ON public.user_ratings(game_mode_hash, rating DESC);
CREATE INDEX IF NOT EXISTS idx_user_ratings_user
  ON public.user_ratings(user_id);

-- =========================================================
-- 5) FRIENDSHIPS TABLE
-- =========================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'friendship_status') THEN
    CREATE TYPE public.friendship_status AS ENUM (
      'pending',   -- Request sent, awaiting acceptance
      'accepted',  -- Friends
      'blocked'    -- Blocked by one party
    );
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.friendships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  friend_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  status public.friendship_status NOT NULL DEFAULT 'pending',

  -- Who initiated (for pending requests)
  initiated_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Bonus tracking
  first_game_bonus_awarded BOOLEAN NOT NULL DEFAULT FALSE,
  games_together INT NOT NULL DEFAULT 0,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Ensure no duplicate friendships
  UNIQUE(user_id, friend_id),
  -- Ensure user can't friend themselves
  CHECK(user_id != friend_id)
);

CREATE INDEX IF NOT EXISTS idx_friendships_user
  ON public.friendships(user_id, status);
CREATE INDEX IF NOT EXISTS idx_friendships_friend
  ON public.friendships(friend_id, status);

-- =========================================================
-- 6) REFERRALS TABLE
-- =========================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'referral_status') THEN
    CREATE TYPE public.referral_status AS ENUM (
      'pending',    -- Referee signed up but hasn't completed a game
      'completed',  -- Referee completed first game, rewards given
      'expired'     -- 30 days passed without completion
    );
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.referrals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  referee_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  referral_code TEXT NOT NULL,  -- The code used
  status public.referral_status NOT NULL DEFAULT 'pending',

  -- Rewards
  referrer_reward_fp INT,  -- FP awarded to referrer (100)
  referee_reward_fp INT,   -- FP awarded to referee (50)
  referee_streak_freeze BOOLEAN NOT NULL DEFAULT FALSE,

  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE(referee_id)  -- Each user can only be referred once
);

CREATE INDEX IF NOT EXISTS idx_referrals_referrer
  ON public.referrals(referrer_id, status);
CREATE INDEX IF NOT EXISTS idx_referrals_code
  ON public.referrals(referral_code);

-- =========================================================
-- 7) FP_TRANSACTIONS TABLE (Audit Log)
-- =========================================================

CREATE TABLE IF NOT EXISTS public.fp_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  amount INT NOT NULL,  -- Positive for earned, negative for spent
  balance_after BIGINT NOT NULL,  -- FP balance after transaction

  -- Reason/type
  reason TEXT NOT NULL,  -- 'game_complete', 'streak_milestone', 'referral', 'daily_bonus', etc.

  -- Context
  game_id UUID REFERENCES public.games(id) ON DELETE SET NULL,

  -- Breakdown of multipliers applied (for game completions)
  multipliers JSONB,  -- {party: 2.0, streak: 1.3, friend: 1.25, ...}

  -- Base amounts before multipliers
  base_fp INT,
  win_bonus_fp INT,
  fantasy_points_fp INT,
  first_game_bonus_fp INT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fp_transactions_user
  ON public.fp_transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_fp_transactions_game
  ON public.fp_transactions(game_id);
CREATE INDEX IF NOT EXISTS idx_fp_transactions_date
  ON public.fp_transactions(created_at DESC);

-- =========================================================
-- 8) CHALLENGES TABLES
-- =========================================================

CREATE TABLE IF NOT EXISTS public.challenges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Challenge definition
  name TEXT NOT NULL,
  description TEXT NOT NULL,

  -- Requirements
  challenge_type TEXT NOT NULL,  -- 'play_games', 'score_points', 'win_games', 'play_with_friends', etc.
  target_value INT NOT NULL,     -- e.g., play 3 games, score 150+ points

  -- Rewards
  fp_reward INT NOT NULL,

  -- Availability
  is_daily BOOLEAN NOT NULL DEFAULT TRUE,  -- Daily vs weekly challenge
  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  -- Difficulty weighting
  difficulty INT NOT NULL DEFAULT 1,  -- 1=easy, 2=medium, 3=hard

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.user_challenges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  challenge_id UUID NOT NULL REFERENCES public.challenges(id) ON DELETE CASCADE,

  -- Progress
  current_value INT NOT NULL DEFAULT 0,
  is_completed BOOLEAN NOT NULL DEFAULT FALSE,
  completed_at TIMESTAMPTZ,

  -- When this challenge was assigned
  assigned_date DATE NOT NULL DEFAULT CURRENT_DATE,
  expires_at TIMESTAMPTZ NOT NULL,

  -- Reward claimed
  reward_claimed BOOLEAN NOT NULL DEFAULT FALSE,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One challenge per type per day per user
  UNIQUE(user_id, challenge_id, assigned_date)
);

CREATE INDEX IF NOT EXISTS idx_user_challenges_user
  ON public.user_challenges(user_id, assigned_date);
CREATE INDEX IF NOT EXISTS idx_user_challenges_active
  ON public.user_challenges(user_id, is_completed, expires_at);

-- =========================================================
-- 9) GAME_RESULTS ADDITIONS
-- =========================================================

-- Add FP tracking to game_results
ALTER TABLE public.game_results
  ADD COLUMN IF NOT EXISTS is_solo BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS is_ranked BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS fp_earned INT,
  ADD COLUMN IF NOT EXISTS rating_before NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS rating_after NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS rating_change NUMERIC(8,2);

-- =========================================================
-- 10) GAMES TABLE ADDITIONS
-- =========================================================

ALTER TABLE public.games
  ADD COLUMN IF NOT EXISTS is_solo BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS is_ranked BOOLEAN NOT NULL DEFAULT TRUE;

-- =========================================================
-- 11) HELPER FUNCTIONS
-- =========================================================

-- Function to calculate tier from lifetime FP
CREATE OR REPLACE FUNCTION public.calculate_tier(p_lifetime_fp BIGINT)
RETURNS public.flashback_tier
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_lifetime_fp >= 150000 THEN 'goat'::public.flashback_tier
    WHEN p_lifetime_fp >= 50000 THEN 'legend'::public.flashback_tier
    WHEN p_lifetime_fp >= 15000 THEN 'elite'::public.flashback_tier
    WHEN p_lifetime_fp >= 5000 THEN 'all_pro'::public.flashback_tier
    WHEN p_lifetime_fp >= 2000 THEN 'pro'::public.flashback_tier
    WHEN p_lifetime_fp >= 500 THEN 'varsity'::public.flashback_tier
    ELSE 'rookie'::public.flashback_tier
  END;
$$;

-- Function to get tier threshold
CREATE OR REPLACE FUNCTION public.get_tier_threshold(p_tier public.flashback_tier)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_tier
    WHEN 'goat' THEN 150000
    WHEN 'legend' THEN 50000
    WHEN 'elite' THEN 15000
    WHEN 'all_pro' THEN 5000
    WHEN 'pro' THEN 2000
    WHEN 'varsity' THEN 500
    ELSE 0
  END::BIGINT;
$$;

-- Function to get next tier
CREATE OR REPLACE FUNCTION public.get_next_tier(p_tier public.flashback_tier)
RETURNS public.flashback_tier
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_tier
    WHEN 'rookie' THEN 'varsity'::public.flashback_tier
    WHEN 'varsity' THEN 'pro'::public.flashback_tier
    WHEN 'pro' THEN 'all_pro'::public.flashback_tier
    WHEN 'all_pro' THEN 'elite'::public.flashback_tier
    WHEN 'elite' THEN 'legend'::public.flashback_tier
    WHEN 'legend' THEN 'goat'::public.flashback_tier
    ELSE 'goat'::public.flashback_tier  -- Already max
  END;
$$;

-- Function to calculate streak multiplier
CREATE OR REPLACE FUNCTION public.calculate_streak_multiplier(p_streak INT)
RETURNS NUMERIC(4,2)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_streak >= 7 THEN 1.50
    WHEN p_streak >= 6 THEN 1.40
    WHEN p_streak >= 5 THEN 1.30
    WHEN p_streak >= 4 THEN 1.20
    WHEN p_streak >= 3 THEN 1.15
    WHEN p_streak >= 2 THEN 1.10
    WHEN p_streak >= 1 THEN 1.05
    ELSE 1.00
  END::NUMERIC(4,2);
$$;

-- Function to calculate party size multiplier
CREATE OR REPLACE FUNCTION public.calculate_party_multiplier(p_player_count INT, p_is_solo BOOLEAN)
RETURNS NUMERIC(4,2)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_is_solo THEN 1.00
    WHEN p_player_count >= 7 THEN 3.00
    WHEN p_player_count >= 5 THEN 2.50
    WHEN p_player_count >= 3 THEN 2.00
    WHEN p_player_count >= 2 THEN 1.50
    ELSE 1.00
  END::NUMERIC(4,2);
$$;

-- Function to calculate friend bonus multiplier
CREATE OR REPLACE FUNCTION public.calculate_friend_multiplier(p_friends_in_game INT)
RETURNS NUMERIC(4,2)
LANGUAGE sql
IMMUTABLE
AS $$
  -- +25% per friend, capped at +100% (2.0x)
  SELECT LEAST(1.00 + (p_friends_in_game * 0.25), 2.00)::NUMERIC(4,2);
$$;

-- =========================================================
-- 12) ENABLE RLS
-- =========================================================

ALTER TABLE public.user_engagement ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fp_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_challenges ENABLE ROW LEVEL SECURITY;

-- =========================================================
-- 13) RLS POLICIES
-- =========================================================

-- User Engagement: Public read (leaderboards), own write via functions
CREATE POLICY "public_read_engagement" ON public.user_engagement
  FOR SELECT USING (true);

CREATE POLICY "service_insert_engagement" ON public.user_engagement
  FOR INSERT WITH CHECK (false);

CREATE POLICY "self_update_engagement" ON public.user_engagement
  FOR UPDATE USING (user_id = auth.uid());

-- User Ratings: Public read, write via functions
CREATE POLICY "public_read_ratings" ON public.user_ratings
  FOR SELECT USING (true);

CREATE POLICY "service_write_ratings" ON public.user_ratings
  FOR ALL USING (false);

-- Friendships: Users can see their own friendships
CREATE POLICY "own_friendships_read" ON public.friendships
  FOR SELECT USING (user_id = auth.uid() OR friend_id = auth.uid());

CREATE POLICY "own_friendships_insert" ON public.friendships
  FOR INSERT WITH CHECK (user_id = auth.uid() OR friend_id = auth.uid());

CREATE POLICY "own_friendships_update" ON public.friendships
  FOR UPDATE USING (user_id = auth.uid() OR friend_id = auth.uid());

CREATE POLICY "own_friendships_delete" ON public.friendships
  FOR DELETE USING (user_id = auth.uid() OR friend_id = auth.uid());

-- Referrals: Users can see their own referrals
CREATE POLICY "own_referrals_read" ON public.referrals
  FOR SELECT USING (referrer_id = auth.uid() OR referee_id = auth.uid());

CREATE POLICY "service_write_referrals" ON public.referrals
  FOR INSERT WITH CHECK (false);

-- FP Transactions: Users can see their own transactions
CREATE POLICY "own_transactions_read" ON public.fp_transactions
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "service_write_transactions" ON public.fp_transactions
  FOR INSERT WITH CHECK (false);

-- Challenges: Public read
CREATE POLICY "public_read_challenges" ON public.challenges
  FOR SELECT USING (true);

-- User Challenges: Own only
CREATE POLICY "own_challenges_read" ON public.user_challenges
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "service_write_user_challenges" ON public.user_challenges
  FOR ALL USING (false);

-- =========================================================
-- 14) GRANTS
-- =========================================================

GRANT SELECT ON public.user_engagement TO anon, authenticated;
GRANT UPDATE ON public.user_engagement TO anon, authenticated;

GRANT SELECT ON public.user_ratings TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.friendships TO anon, authenticated;

GRANT SELECT ON public.referrals TO anon, authenticated;

GRANT SELECT ON public.fp_transactions TO anon, authenticated;

GRANT SELECT ON public.challenges TO anon, authenticated;
GRANT SELECT ON public.user_challenges TO anon, authenticated;

-- =========================================================
-- 15) SEED DEFAULT CHALLENGES
-- =========================================================

INSERT INTO public.challenges (name, description, challenge_type, target_value, fp_reward, is_daily, difficulty)
VALUES
  ('Daily Draft', 'Complete 1 game today', 'play_games', 1, 15, TRUE, 1),
  ('Double Down', 'Complete 2 games today', 'play_games', 2, 20, TRUE, 2),
  ('Triple Threat', 'Complete 3 games today', 'play_games', 3, 25, TRUE, 3),
  ('High Scorer', 'Score 150+ fantasy points in a game', 'score_points', 150, 20, TRUE, 2),
  ('Fantasy Star', 'Score 200+ fantasy points in a game', 'score_points', 200, 30, TRUE, 3),
  ('Winner Winner', 'Win a multiplayer game', 'win_games', 1, 15, TRUE, 2),
  ('Social Gamer', 'Play a game with a friend', 'play_with_friends', 1, 20, TRUE, 2),
  ('Party Time', 'Play a game with 3+ players', 'party_game', 3, 20, TRUE, 2)
ON CONFLICT DO NOTHING;

-- =========================================================
-- 16) AUTO-CREATE ENGAGEMENT FOR NEW USERS
-- =========================================================

-- Update handle_new_user to also create engagement record
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  provider_name TEXT;
  display TEXT;
BEGIN
  -- Determine provider
  provider_name := COALESCE(
    new.raw_app_meta_data->>'provider',
    'anonymous'
  );

  -- Generate display name
  display := COALESCE(
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'name',
    'Player'
  );

  -- Create profile
  INSERT INTO public.user_profiles (id, display_name, provider, created_at)
  VALUES (new.id, display, provider_name, NOW())
  ON CONFLICT (id) DO NOTHING;

  -- Create engagement record
  INSERT INTO public.user_engagement (user_id, created_at)
  VALUES (new.id, NOW())
  ON CONFLICT (user_id) DO NOTHING;

  RETURN new;
END;
$$;

-- =========================================================
-- 17) BACKFILL ENGAGEMENT FOR EXISTING USERS
-- =========================================================

INSERT INTO public.user_engagement (user_id, created_at)
SELECT id, created_at
FROM public.user_profiles
WHERE id NOT IN (SELECT user_id FROM public.user_engagement)
ON CONFLICT (user_id) DO NOTHING;

-- =========================================================
-- 18) FP LEADERBOARD VIEWS
-- =========================================================

CREATE OR REPLACE VIEW public.leaderboard_fp AS
SELECT
  up.id,
  up.display_name,
  up.flashback_id,
  ue.flashback_points,
  ue.tier,
  ue.current_streak,
  ue.longest_streak,
  ue.multiplayer_games,
  ue.solo_games,
  up.games_played,
  up.games_won
FROM public.user_profiles up
JOIN public.user_engagement ue ON up.id = ue.user_id
WHERE ue.flashback_points > 0
ORDER BY ue.flashback_points DESC
LIMIT 100;

CREATE OR REPLACE VIEW public.leaderboard_streaks AS
SELECT
  up.id,
  up.display_name,
  up.flashback_id,
  ue.current_streak,
  ue.longest_streak,
  ue.flashback_points,
  ue.tier
FROM public.user_profiles up
JOIN public.user_engagement ue ON up.id = ue.user_id
WHERE ue.longest_streak > 0
ORDER BY ue.longest_streak DESC, ue.current_streak DESC
LIMIT 100;

GRANT SELECT ON public.leaderboard_fp TO anon, authenticated;
GRANT SELECT ON public.leaderboard_streaks TO anon, authenticated;

-- =========================================================
-- 19) UPDATE PROTECT_PROFILE_STATS TO INCLUDE ENGAGEMENT
-- =========================================================

-- Update the trigger to also protect engagement stats
CREATE OR REPLACE FUNCTION public.block_direct_stat_updates()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Check if this update is authorized (set by SECURITY DEFINER function)
  IF current_setting('app.allow_stat_update', true) = 'true' THEN
    -- Authorized, allow the update
    RETURN NEW;
  END IF;

  -- Not authorized - only allow non-stat field changes
  -- Reset stat fields to their old values
  NEW.games_played := OLD.games_played;
  NEW.games_won := OLD.games_won;
  NEW.highest_score := OLD.highest_score;
  NEW.total_points := OLD.total_points;

  -- Allow other fields (display_name, name_changed, updated_at) to be updated
  RETURN NEW;
END;
$$;
