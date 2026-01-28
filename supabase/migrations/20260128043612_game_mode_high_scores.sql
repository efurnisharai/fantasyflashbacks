-- =========================================================
-- Game Mode High Scores
--
-- High scores are unique per combination of:
--   - Season + Week (the NFL week played)
--   - Roster construction (QB/RB/WR/TE/FLEX/K/DST slots)
--   - Scoring type (standard/half-ppr/ppr + passTdPoints)
--
-- If no one has played that exact configuration, the first
-- player automatically holds the high score.
-- =========================================================

-- =========================================================
-- 1) Add game mode columns to game_results
-- =========================================================

ALTER TABLE public.game_results
  ADD COLUMN IF NOT EXISTS game_mode_hash TEXT,
  ADD COLUMN IF NOT EXISTS scoring_type TEXT,
  ADD COLUMN IF NOT EXISTS pass_td_points INT,
  ADD COLUMN IF NOT EXISTS qb_slots INT,
  ADD COLUMN IF NOT EXISTS rb_slots INT,
  ADD COLUMN IF NOT EXISTS wr_slots INT,
  ADD COLUMN IF NOT EXISTS te_slots INT,
  ADD COLUMN IF NOT EXISTS flex_slots INT,
  ADD COLUMN IF NOT EXISTS k_slots INT,
  ADD COLUMN IF NOT EXISTS dst_slots INT;

-- Index for fast high score lookups
CREATE INDEX IF NOT EXISTS idx_game_results_mode_hash
  ON public.game_results(game_mode_hash, final_score DESC);

CREATE INDEX IF NOT EXISTS idx_game_results_week_mode
  ON public.game_results(season, week, game_mode_hash, final_score DESC);

-- =========================================================
-- 2) Function to generate game mode hash
-- =========================================================

CREATE OR REPLACE FUNCTION public.generate_game_mode_hash(
  p_season INT,
  p_week INT,
  p_scoring_type TEXT,
  p_pass_td_points INT,
  p_qb_slots INT,
  p_rb_slots INT,
  p_wr_slots INT,
  p_te_slots INT,
  p_flex_slots INT,
  p_k_slots INT,
  p_dst_slots INT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT md5(
    p_season::text || ':' ||
    p_week::text || ':' ||
    COALESCE(p_scoring_type, 'standard') || ':' ||
    COALESCE(p_pass_td_points, 4)::text || ':' ||
    COALESCE(p_qb_slots, 1)::text || ':' ||
    COALESCE(p_rb_slots, 2)::text || ':' ||
    COALESCE(p_wr_slots, 2)::text || ':' ||
    COALESCE(p_te_slots, 1)::text || ':' ||
    COALESCE(p_flex_slots, 1)::text || ':' ||
    COALESCE(p_k_slots, 1)::text || ':' ||
    COALESCE(p_dst_slots, 1)::text
  );
$$;

-- =========================================================
-- 3) Updated save game results function
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_save_game_results(
  p_game_id UUID,
  p_results JSONB,
  p_settings JSONB DEFAULT '{}'::JSONB
)
RETURNS TABLE (
  is_high_score BOOLEAN,
  high_score_user_id UUID,
  high_score_value NUMERIC,
  previous_high_score NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game_rec RECORD;
  r JSONB;
  sorted JSONB;
  rank INT;
  top_score NUMERIC;
  mode_hash TEXT;
  prev_high NUMERIC;
  new_high_user UUID;
  new_high_score NUMERIC;
  is_new_high BOOLEAN := FALSE;

  -- Settings
  v_scoring TEXT;
  v_pass_td INT;
  v_qb INT;
  v_rb INT;
  v_wr INT;
  v_te INT;
  v_flex INT;
  v_k INT;
  v_dst INT;
BEGIN
  -- Get game info
  SELECT season, week, settings INTO game_rec
  FROM public.games WHERE id = p_game_id;

  -- Extract settings (prefer passed settings, fall back to game settings)
  v_scoring := COALESCE(
    p_settings->>'scoring',
    game_rec.settings->>'scoring',
    'standard'
  );
  v_pass_td := COALESCE(
    (p_settings->>'passTdPoints')::INT,
    (game_rec.settings->>'passTdPoints')::INT,
    4
  );
  v_qb := COALESCE((p_settings->>'qbSlots')::INT, (game_rec.settings->>'qbSlots')::INT, 1);
  v_rb := COALESCE((p_settings->>'rbSlots')::INT, (game_rec.settings->>'rbSlots')::INT, 2);
  v_wr := COALESCE((p_settings->>'wrSlots')::INT, (game_rec.settings->>'wrSlots')::INT, 2);
  v_te := COALESCE((p_settings->>'teSlots')::INT, (game_rec.settings->>'teSlots')::INT, 1);
  v_flex := COALESCE((p_settings->>'flexSlots')::INT, (game_rec.settings->>'flexSlots')::INT, 1);
  v_k := COALESCE((p_settings->>'kSlots')::INT, (game_rec.settings->>'kSlots')::INT, 1);
  v_dst := COALESCE((p_settings->>'dstSlots')::INT, (game_rec.settings->>'dstSlots')::INT, 1);

  -- Generate the game mode hash
  mode_hash := public.generate_game_mode_hash(
    game_rec.season, game_rec.week,
    v_scoring, v_pass_td,
    v_qb, v_rb, v_wr, v_te, v_flex, v_k, v_dst
  );

  -- Get previous high score for this mode
  SELECT MAX(final_score) INTO prev_high
  FROM public.game_results
  WHERE game_mode_hash = mode_hash;

  -- Sort results by score descending
  sorted := (
    SELECT jsonb_agg(x ORDER BY (x->>'final_score')::NUMERIC DESC)
    FROM jsonb_array_elements(p_results) x
  );

  -- Get top score from this game
  top_score := (sorted->0->>'final_score')::NUMERIC;

  -- Check if this is a new high score
  IF prev_high IS NULL OR top_score > prev_high THEN
    is_new_high := TRUE;
    new_high_score := top_score;
    new_high_user := (sorted->0->>'user_id')::UUID;
  END IF;

  -- Insert each result
  rank := 0;
  FOR r IN SELECT * FROM jsonb_array_elements(sorted)
  LOOP
    rank := rank + 1;

    INSERT INTO public.game_results (
      game_id, user_id, display_name, seat, final_score,
      placement, is_winner, season, week,
      game_mode_hash, scoring_type, pass_td_points,
      qb_slots, rb_slots, wr_slots, te_slots, flex_slots, k_slots, dst_slots
    ) VALUES (
      p_game_id,
      (r->>'user_id')::UUID,
      r->>'display_name',
      (r->>'seat')::INT,
      (r->>'final_score')::NUMERIC,
      rank,
      (r->>'final_score')::NUMERIC >= top_score - 0.01,
      game_rec.season,
      game_rec.week,
      mode_hash,
      v_scoring,
      v_pass_td,
      v_qb, v_rb, v_wr, v_te, v_flex, v_k, v_dst
    )
    ON CONFLICT DO NOTHING;

    -- Update user profile stats
    UPDATE public.user_profiles
    SET
      games_played = games_played + 1,
      games_won = games_won + CASE WHEN (r->>'final_score')::NUMERIC >= top_score - 0.01 THEN 1 ELSE 0 END,
      highest_score = GREATEST(highest_score, (r->>'final_score')::NUMERIC),
      total_points = total_points + (r->>'final_score')::NUMERIC,
      updated_at = NOW()
    WHERE id = (r->>'user_id')::UUID;
  END LOOP;

  -- Return high score info
  RETURN QUERY SELECT
    is_new_high,
    new_high_user,
    new_high_score,
    prev_high;
END;
$$;

-- =========================================================
-- 4) Function to get high score for a game mode
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_get_high_score(
  p_season INT,
  p_week INT,
  p_settings JSONB
)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  high_score NUMERIC,
  achieved_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  mode_hash TEXT;
BEGIN
  mode_hash := public.generate_game_mode_hash(
    p_season,
    p_week,
    COALESCE(p_settings->>'scoring', 'standard'),
    COALESCE((p_settings->>'passTdPoints')::INT, 4),
    COALESCE((p_settings->>'qbSlots')::INT, 1),
    COALESCE((p_settings->>'rbSlots')::INT, 2),
    COALESCE((p_settings->>'wrSlots')::INT, 2),
    COALESCE((p_settings->>'teSlots')::INT, 1),
    COALESCE((p_settings->>'flexSlots')::INT, 1),
    COALESCE((p_settings->>'kSlots')::INT, 1),
    COALESCE((p_settings->>'dstSlots')::INT, 1)
  );

  RETURN QUERY
  SELECT
    gr.user_id,
    gr.display_name,
    gr.final_score AS high_score,
    gr.created_at AS achieved_at
  FROM public.game_results gr
  WHERE gr.game_mode_hash = mode_hash
  ORDER BY gr.final_score DESC
  LIMIT 1;
END;
$$;

-- =========================================================
-- 5) View for game mode leaderboards
-- =========================================================

CREATE OR REPLACE VIEW public.game_mode_high_scores AS
SELECT DISTINCT ON (game_mode_hash)
  game_mode_hash,
  season,
  week,
  scoring_type,
  pass_td_points,
  qb_slots,
  rb_slots,
  wr_slots,
  te_slots,
  flex_slots,
  k_slots,
  dst_slots,
  user_id,
  display_name,
  final_score AS high_score,
  created_at AS achieved_at
FROM public.game_results
WHERE game_mode_hash IS NOT NULL
ORDER BY game_mode_hash, final_score DESC;

GRANT SELECT ON public.game_mode_high_scores TO anon, authenticated;
