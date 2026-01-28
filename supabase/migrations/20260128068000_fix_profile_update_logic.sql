-- Fix: Profile stats should update regardless of whether game_results insert was a duplicate
-- The previous logic only updated profiles when FOUND was true (new insert), 
-- which meant re-saving would never update profiles

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
  v_is_authenticated BOOLEAN;
  v_already_saved BOOLEAN;

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
    RETURN;
  END IF;

  -- Extract settings
  v_scoring := COALESCE(p_settings->>'scoring', game_rec.settings->>'scoring', 'standard');
  v_pass_td := COALESCE((p_settings->>'passTdPoints')::INT, (game_rec.settings->>'passTdPoints')::INT, 4);
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
    RETURN;
  END IF;

  -- Get top score from this game
  top_score := (sorted->0->>'final_score')::NUMERIC;

  -- Process each result
  rank := 0;
  FOR r IN SELECT * FROM jsonb_array_elements(sorted)
  LOOP
    rank := rank + 1;
    v_user_id := (r->>'user_id')::UUID;
    v_final_score := (r->>'final_score')::NUMERIC;
    v_is_winner := v_final_score >= top_score - 0.01;

    -- Check if this game result already exists
    SELECT EXISTS(
      SELECT 1 FROM public.game_results 
      WHERE game_id = p_game_id AND user_id = v_user_id
    ) INTO v_already_saved;

    -- Check if user is authenticated (not anonymous)
    SELECT (raw_app_meta_data->>'provider') IS DISTINCT FROM 'anonymous' 
           AND (raw_app_meta_data->>'provider') IS NOT NULL
    INTO v_is_authenticated
    FROM auth.users
    WHERE id = v_user_id;

    -- Insert game result if not already saved
    IF NOT v_already_saved THEN
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
      );

      -- Only update profile stats for authenticated users AND only for new results
      IF v_is_authenticated THEN
        -- Check for high score from authenticated user
        IF (prev_high IS NULL OR v_final_score > prev_high) AND NOT is_new_high THEN
          is_new_high := TRUE;
          new_high_score := v_final_score;
          new_high_user := v_user_id;
        END IF;

        -- Update user profile stats
        UPDATE public.user_profiles
        SET
          games_played = games_played + 1,
          games_won = games_won + CASE WHEN v_is_winner THEN 1 ELSE 0 END,
          highest_score = GREATEST(highest_score, v_final_score),
          total_points = total_points + v_final_score,
          updated_at = NOW()
        WHERE id = v_user_id;
      END IF;
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
