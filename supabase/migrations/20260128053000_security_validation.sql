-- =========================================================
-- Security Validation Triggers
-- Prevents bad actors from manipulating game data directly
-- =========================================================

-- =========================================================
-- 1) PROTECT GAME_RESULTS - Validate inserts
-- =========================================================

CREATE OR REPLACE FUNCTION public.validate_game_result()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game_rec RECORD;
  was_player BOOLEAN;
BEGIN
  -- Check game exists and is in valid state
  SELECT * INTO game_rec FROM public.games WHERE id = NEW.game_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid game_id';
  END IF;

  -- Game must be in scoring or complete status
  IF game_rec.status NOT IN ('scoring', 'complete') THEN
    RAISE EXCEPTION 'Game is not in scoring phase';
  END IF;

  -- User must have been a player in this game
  SELECT EXISTS (
    SELECT 1 FROM public.game_players
    WHERE game_id = NEW.game_id AND user_id = NEW.user_id
  ) INTO was_player;

  IF NOT was_player THEN
    RAISE EXCEPTION 'User was not a player in this game';
  END IF;

  -- Prevent duplicate results for same user/game
  IF EXISTS (
    SELECT 1 FROM public.game_results
    WHERE game_id = NEW.game_id AND user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Result already recorded for this user';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_game_result_trigger ON public.game_results;
CREATE TRIGGER validate_game_result_trigger
  BEFORE INSERT ON public.game_results
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_game_result();

-- =========================================================
-- 2) PROTECT GAME_PICKS - Validate inserts
-- =========================================================

CREATE OR REPLACE FUNCTION public.validate_game_pick()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game_rec RECORD;
  drafter_rec RECORD;
BEGIN
  -- Check game exists and is drafting
  SELECT * INTO game_rec FROM public.games WHERE id = NEW.game_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid game_id';
  END IF;

  IF game_rec.status <> 'drafting' THEN
    RAISE EXCEPTION 'Game is not in drafting phase';
  END IF;

  -- Check it's this user's turn
  SELECT * INTO drafter_rec FROM public.game_players
  WHERE game_id = NEW.game_id AND draft_position = game_rec.current_drafter;

  IF drafter_rec.user_id <> NEW.user_id THEN
    RAISE EXCEPTION 'Not your turn to pick';
  END IF;

  -- Check player not already picked
  IF EXISTS (
    SELECT 1 FROM public.game_picks
    WHERE game_id = NEW.game_id AND player_id = NEW.player_id
  ) THEN
    RAISE EXCEPTION 'Player already drafted';
  END IF;

  -- Validate pick_number matches game state
  IF NEW.pick_number <> game_rec.pick_number THEN
    RAISE EXCEPTION 'Invalid pick number';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_game_pick_trigger ON public.game_picks;
CREATE TRIGGER validate_game_pick_trigger
  BEFORE INSERT ON public.game_picks
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_game_pick();

-- =========================================================
-- 3) PROTECT USER_PROFILES - Prevent direct stat manipulation
-- =========================================================

CREATE OR REPLACE FUNCTION public.validate_profile_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only allow updating display_name and avatar_url directly
  -- Stats should only change through ff_save_game_results

  -- If stats are being changed, verify it's from a trusted source
  -- by checking if this is a self-update (from client)
  IF (
    NEW.games_played <> OLD.games_played OR
    NEW.games_won <> OLD.games_won OR
    NEW.highest_score <> OLD.highest_score OR
    NEW.total_points <> OLD.total_points
  ) THEN
    -- Only allow if the caller is a SECURITY DEFINER function (superuser context)
    -- Regular users can't escalate their stats
    IF current_setting('role') = 'authenticated' THEN
      -- Reset stats to old values - don't allow client manipulation
      NEW.games_played := OLD.games_played;
      NEW.games_won := OLD.games_won;
      NEW.highest_score := OLD.highest_score;
      NEW.total_points := OLD.total_points;
    END IF;
  END IF;

  -- Ensure updated_at is set
  NEW.updated_at := NOW();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_profile_update_trigger ON public.user_profiles;
CREATE TRIGGER validate_profile_update_trigger
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_profile_update();

-- =========================================================
-- 4) PROTECT GAMES TABLE - Validate status changes
-- =========================================================

CREATE OR REPLACE FUNCTION public.validate_game_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Prevent invalid status transitions
  -- Valid: lobby -> drafting -> scoring -> complete

  IF OLD.status = 'complete' THEN
    -- Can't change a completed game
    RAISE EXCEPTION 'Cannot modify completed game';
  END IF;

  IF OLD.status = 'scoring' AND NEW.status NOT IN ('scoring', 'complete') THEN
    RAISE EXCEPTION 'Invalid status transition from scoring';
  END IF;

  IF OLD.status = 'drafting' AND NEW.status NOT IN ('drafting', 'scoring') THEN
    RAISE EXCEPTION 'Invalid status transition from drafting';
  END IF;

  IF OLD.status = 'lobby' AND NEW.status NOT IN ('lobby', 'drafting') THEN
    RAISE EXCEPTION 'Invalid status transition from lobby';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_game_update_trigger ON public.games;
CREATE TRIGGER validate_game_update_trigger
  BEFORE UPDATE ON public.games
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_game_update();

-- =========================================================
-- 5) PROTECT GAME_PLAYERS - Validate joins
-- =========================================================

CREATE OR REPLACE FUNCTION public.validate_game_player()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game_rec RECORD;
  player_count INT;
BEGIN
  -- Check game exists and is in lobby
  SELECT * INTO game_rec FROM public.games WHERE id = NEW.game_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid game_id';
  END IF;

  IF game_rec.status <> 'lobby' THEN
    RAISE EXCEPTION 'Cannot join game - not in lobby';
  END IF;

  -- Check max players
  SELECT COUNT(*) INTO player_count FROM public.game_players WHERE game_id = NEW.game_id;

  IF player_count >= game_rec.max_players THEN
    RAISE EXCEPTION 'Game is full';
  END IF;

  -- Prevent duplicate joins
  IF EXISTS (
    SELECT 1 FROM public.game_players
    WHERE game_id = NEW.game_id AND user_id = NEW.user_id
  ) THEN
    -- Allow - this is a rejoin, let the function handle it
    RETURN NULL; -- Skip insert, function will update instead
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_game_player_trigger ON public.game_players;
CREATE TRIGGER validate_game_player_trigger
  BEFORE INSERT ON public.game_players
  FOR EACH ROW
  EXECUTE FUNCTION public.validate_game_player();

-- =========================================================
-- 6) Add rate limiting helper (optional, for future use)
-- =========================================================

CREATE TABLE IF NOT EXISTS public.rate_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  action TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_user_action
  ON public.rate_limits(user_id, action, created_at DESC);

-- Clean up old rate limit entries (run periodically)
CREATE OR REPLACE FUNCTION public.cleanup_rate_limits()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  DELETE FROM public.rate_limits WHERE created_at < NOW() - INTERVAL '1 hour';
$$;

-- =========================================================
-- 7) Grant necessary permissions
-- =========================================================

-- Rate limits table (if we use it)
ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "rate_limits_policy" ON public.rate_limits FOR ALL USING (false);

COMMENT ON FUNCTION public.validate_game_result() IS 'Validates game results cannot be faked';
COMMENT ON FUNCTION public.validate_game_pick() IS 'Validates picks follow game rules';
COMMENT ON FUNCTION public.validate_profile_update() IS 'Prevents direct stat manipulation';
COMMENT ON FUNCTION public.validate_game_update() IS 'Enforces valid game state transitions';
COMMENT ON FUNCTION public.validate_game_player() IS 'Validates player joins';
