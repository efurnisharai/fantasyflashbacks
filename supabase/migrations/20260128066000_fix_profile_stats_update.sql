-- Fix: Ensure profile stats are updated even if profile needs to be created
-- Also adds unique constraint on game_results to prevent duplicate entries

-- Add unique constraint on game_results if not exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'game_results_game_user_unique'
  ) THEN
    ALTER TABLE public.game_results 
    ADD CONSTRAINT game_results_game_user_unique UNIQUE (game_id, user_id);
  END IF;
END $$;

-- Update the save function to use UPSERT for profiles
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
  v_user_id UUID;
  v_final_score NUMERIC;
  v_is_winner BOOLEAN;

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

  IF game_rec IS NULL THEN
    RAISE WARNING 'Game not found: %', p_game_id;
    RETURN;
  END IF;

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

  IF sorted IS NULL OR jsonb_array_length(sorted) = 0 THEN
    RAISE WARNING 'No results to save';
    RETURN;
  END IF;

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
    v_user_id := (r->>'user_id')::UUID;
    v_final_score := (r->>'final_score')::NUMERIC;
    v_is_winner := v_final_score >= top_score - 0.01;

    -- Insert game result (skip if already exists for this game/user)
    INSERT INTO public.game_results (
      game_id, user_id, display_name, seat, final_score,
      placement, is_winner, season, week,
      game_mode_hash, scoring_type, pass_td_points,
      qb_slots, rb_slots, wr_slots, te_slots, flex_slots, k_slots, dst_slots
    ) VALUES (
      p_game_id,
      v_user_id,
      r->>'display_name',
      (r->>'seat')::INT,
      v_final_score,
      rank,
      v_is_winner,
      game_rec.season,
      game_rec.week,
      mode_hash,
      v_scoring,
      v_pass_td,
      v_qb, v_rb, v_wr, v_te, v_flex, v_k, v_dst
    )
    ON CONFLICT (game_id, user_id) DO NOTHING;

    -- Only update stats if this is a new result (check if we just inserted)
    IF FOUND THEN
      -- Update or create user profile stats using UPSERT
      INSERT INTO public.user_profiles (id, display_name, games_played, games_won, highest_score, total_points, updated_at)
      VALUES (
        v_user_id,
        r->>'display_name',
        1,
        CASE WHEN v_is_winner THEN 1 ELSE 0 END,
        v_final_score,
        v_final_score,
        NOW()
      )
      ON CONFLICT (id) DO UPDATE SET
        games_played = user_profiles.games_played + 1,
        games_won = user_profiles.games_won + CASE WHEN v_is_winner THEN 1 ELSE 0 END,
        highest_score = GREATEST(user_profiles.highest_score, v_final_score),
        total_points = user_profiles.total_points + v_final_score,
        updated_at = NOW();
    END IF;
  END LOOP;

  -- Return high score info
  RETURN QUERY SELECT
    is_new_high,
    new_high_user,
    new_high_score,
    prev_high;
END;
$$;
