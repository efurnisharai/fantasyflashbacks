-- =========================================================
-- Integrate Challenges & Referrals into Game Completion
--
-- Updates ff_save_game_results to:
--   - Check and complete pending referrals on first game
--   - Update daily challenge progress
--   - Award first-friend-game bonus
-- =========================================================

-- =========================================================
-- 1) UPDATED FF_SAVE_GAME_RESULTS WITH FULL INTEGRATION
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
  previous_high_score NUMERIC,
  fp_awarded JSONB
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
  v_already_saved BOOLEAN;
  v_profile_exists BOOLEAN;

  v_scoring TEXT;
  v_pass_td INT;
  v_qb INT;
  v_rb INT;
  v_wr INT;
  v_te INT;
  v_flex INT;
  v_k INT;
  v_dst INT;

  -- FP calculation variables
  v_player_count INT;
  v_is_solo BOOLEAN;
  v_friends_in_game INT;
  v_base_fp INT;
  v_win_bonus INT;
  v_fantasy_fp INT;
  v_first_game_bonus INT;
  v_total_fp INT;
  v_multipliers JSONB;
  v_party_mult NUMERIC(4,2);
  v_streak_mult NUMERIC(4,2);
  v_friend_mult NUMERIC(4,2);
  v_final_mult NUMERIC(6,3);
  v_engagement RECORD;
  v_is_first_game_today BOOLEAN;
  v_is_first_game_ever BOOLEAN;
  v_today DATE := CURRENT_DATE;
  v_streak_milestone_bonus INT;
  v_new_streak INT;
  v_fp_results JSONB := '{}'::JSONB;

  -- Additional bonuses
  v_friend_game_bonus INT;
  v_challenge_bonus INT;
  v_referral_bonus INT;
  v_challenge_result RECORD;
BEGIN
  -- Set session variable to authorize stat updates
  PERFORM set_config('app.allow_stat_update', 'true', true);

  -- Get game info
  SELECT
    g.season,
    g.week,
    g.settings,
    COALESCE(g.is_solo, FALSE) AS is_solo,
    (SELECT COUNT(*) FROM public.game_players gp WHERE gp.game_id = g.id) AS player_count
  INTO game_rec
  FROM public.games g
  WHERE g.id = p_game_id;

  IF game_rec IS NULL THEN
    RETURN;
  END IF;

  v_is_solo := game_rec.is_solo;
  v_player_count := game_rec.player_count;

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

  -- Generate game mode hash
  mode_hash := public.generate_game_mode_hash(
    game_rec.season, game_rec.week,
    v_scoring, v_pass_td,
    v_qb, v_rb, v_wr, v_te, v_flex, v_k, v_dst
  );

  -- Get previous high score
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

  top_score := (sorted->0->>'final_score')::NUMERIC;

  -- Calculate party multiplier (same for all players)
  v_party_mult := public.calculate_party_multiplier(v_player_count, v_is_solo);

  -- Process each player
  rank := 0;
  FOR r IN SELECT * FROM jsonb_array_elements(sorted)
  LOOP
    rank := rank + 1;
    v_user_id := (r->>'user_id')::UUID;
    v_final_score := (r->>'final_score')::NUMERIC;
    v_is_winner := v_final_score >= top_score - 0.01;

    -- Check if already saved
    SELECT EXISTS(
      SELECT 1 FROM public.game_results
      WHERE game_id = p_game_id AND user_id = v_user_id
    ) INTO v_already_saved;

    IF NOT v_already_saved THEN
      -- =====================================================
      -- FP CALCULATION
      -- =====================================================

      -- Get or create user's engagement data
      SELECT * INTO v_engagement
      FROM public.user_engagement
      WHERE user_id = v_user_id;

      IF v_engagement IS NULL THEN
        INSERT INTO public.user_engagement (user_id)
        VALUES (v_user_id)
        ON CONFLICT (user_id) DO NOTHING;

        SELECT * INTO v_engagement
        FROM public.user_engagement
        WHERE user_id = v_user_id;
      END IF;

      -- Check if first game today and first game ever
      v_is_first_game_today := (v_engagement.last_activity_date IS NULL OR v_engagement.last_activity_date < v_today);
      v_is_first_game_ever := (v_engagement.multiplayer_games + v_engagement.solo_games) = 0;

      -- Calculate streak
      IF v_engagement.last_game_date IS NULL THEN
        v_new_streak := 1;
      ELSIF v_engagement.last_game_date = v_today THEN
        v_new_streak := v_engagement.current_streak;
      ELSIF v_engagement.last_game_date = v_today - 1 THEN
        v_new_streak := v_engagement.current_streak + 1;
      ELSIF v_engagement.last_game_date = v_today - 2 AND v_engagement.streak_freezes_available > 0 THEN
        v_new_streak := v_engagement.current_streak + 1;
      ELSE
        v_new_streak := 1;
      END IF;

      -- Calculate base FP
      IF v_is_solo THEN
        v_base_fp := 10;
        v_win_bonus := CASE WHEN v_final_score >= (top_score * 0.8) THEN 5 ELSE 0 END;
      ELSIF v_player_count >= 3 THEN
        v_base_fp := 40;
        v_win_bonus := CASE WHEN v_is_winner THEN 25 ELSE 0 END;
      ELSE
        v_base_fp := 25;
        v_win_bonus := CASE WHEN v_is_winner THEN 15 ELSE 0 END;
      END IF;

      -- Calculate FP from fantasy points scored
      IF v_is_solo THEN
        v_fantasy_fp := FLOOR(v_final_score * 0.05);
      ELSIF v_player_count >= 3 THEN
        v_fantasy_fp := FLOOR(v_final_score * 0.15);
      ELSE
        v_fantasy_fp := FLOOR(v_final_score * 0.1);
      END IF;

      -- First game of day bonus
      IF v_is_first_game_today THEN
        v_first_game_bonus := CASE WHEN v_is_solo THEN 10 ELSE 25 END;
      ELSE
        v_first_game_bonus := 0;
      END IF;

      -- Calculate streak multiplier
      v_streak_mult := public.calculate_streak_multiplier(v_new_streak);

      -- Calculate friend bonus
      SELECT COUNT(*) INTO v_friends_in_game
      FROM public.friendships f
      JOIN public.game_players gp ON (
        (f.friend_id = gp.user_id AND f.user_id = v_user_id) OR
        (f.user_id = gp.user_id AND f.friend_id = v_user_id)
      )
      WHERE gp.game_id = p_game_id
        AND f.status = 'accepted'
        AND gp.user_id != v_user_id;

      v_friend_mult := CASE WHEN v_is_solo THEN 1.00 ELSE public.calculate_friend_multiplier(v_friends_in_game) END;

      -- Calculate final multiplier
      v_final_mult := v_party_mult * v_streak_mult * v_friend_mult;

      -- Calculate base total FP
      v_total_fp := FLOOR((v_base_fp + v_win_bonus + v_fantasy_fp) * v_final_mult) + v_first_game_bonus;

      -- Check for streak milestone bonus
      v_streak_milestone_bonus := 0;
      IF v_engagement.current_streak < 7 AND v_new_streak >= 7 THEN
        v_streak_milestone_bonus := 100;
      ELSIF v_engagement.current_streak < 14 AND v_new_streak >= 14 THEN
        v_streak_milestone_bonus := 250;
      ELSIF v_engagement.current_streak < 30 AND v_new_streak >= 30 THEN
        v_streak_milestone_bonus := 500;
      END IF;

      v_total_fp := v_total_fp + v_streak_milestone_bonus;

      -- Build multipliers JSON
      v_multipliers := jsonb_build_object(
        'party', v_party_mult,
        'streak', v_streak_mult,
        'friend', v_friend_mult,
        'final', v_final_mult,
        'streak_day', v_new_streak,
        'friends_count', v_friends_in_game,
        'player_count', v_player_count
      );

      -- =====================================================
      -- INSERT GAME RESULT
      -- =====================================================

      INSERT INTO public.game_results (
        game_id, user_id, display_name, seat, final_score,
        placement, is_winner, season, week,
        game_mode_hash, scoring_type, pass_td_points,
        qb_slots, rb_slots, wr_slots, te_slots, flex_slots, k_slots, dst_slots,
        is_solo, fp_earned
      ) VALUES (
        p_game_id, v_user_id, r->>'display_name', (r->>'seat')::INT, v_final_score,
        rank, v_is_winner, game_rec.season, game_rec.week,
        mode_hash, v_scoring, v_pass_td,
        v_qb, v_rb, v_wr, v_te, v_flex, v_k, v_dst,
        v_is_solo, v_total_fp
      );

      -- =====================================================
      -- COMPLETE REFERRAL IF FIRST GAME EVER
      -- =====================================================

      v_referral_bonus := 0;
      IF v_is_first_game_ever THEN
        SELECT referee_bonus INTO v_referral_bonus
        FROM public.ff_complete_referral(v_user_id);

        IF v_referral_bonus IS NOT NULL AND v_referral_bonus > 0 THEN
          v_total_fp := v_total_fp + v_referral_bonus;
        END IF;
      END IF;

      -- =====================================================
      -- UPDATE DAILY CHALLENGE PROGRESS
      -- =====================================================

      v_challenge_bonus := 0;
      SELECT fp_reward INTO v_challenge_bonus
      FROM public.ff_update_challenge_progress(
        v_user_id,
        p_game_id,
        v_final_score,
        v_is_winner,
        v_player_count,
        v_friends_in_game
      )
      WHERE challenge_completed = TRUE;

      IF v_challenge_bonus IS NOT NULL AND v_challenge_bonus > 0 THEN
        v_total_fp := v_total_fp + v_challenge_bonus;
      END IF;

      -- =====================================================
      -- FIRST GAME WITH FRIEND BONUS
      -- =====================================================

      v_friend_game_bonus := 0;
      IF v_friends_in_game > 0 AND NOT v_is_solo THEN
        SELECT public.ff_award_first_friend_game_bonus(v_user_id, p_game_id) INTO v_friend_game_bonus;
        IF v_friend_game_bonus IS NOT NULL AND v_friend_game_bonus > 0 THEN
          v_total_fp := v_total_fp + v_friend_game_bonus;
        END IF;
      END IF;

      -- =====================================================
      -- UPDATE USER ENGAGEMENT
      -- =====================================================

      UPDATE public.user_engagement
      SET
        flashback_points = flashback_points + v_total_fp,
        lifetime_fp = lifetime_fp + v_total_fp,
        tier = public.calculate_tier(lifetime_fp + v_total_fp),
        current_streak = v_new_streak,
        longest_streak = GREATEST(longest_streak, v_new_streak),
        last_game_date = v_today,
        last_activity_date = v_today,
        games_today = CASE WHEN last_activity_date = v_today THEN games_today + 1 ELSE 1 END,
        first_game_bonus_claimed_today = CASE WHEN last_activity_date = v_today THEN first_game_bonus_claimed_today ELSE v_first_game_bonus > 0 END,
        multiplayer_games = multiplayer_games + CASE WHEN v_is_solo THEN 0 ELSE 1 END,
        solo_games = solo_games + CASE WHEN v_is_solo THEN 1 ELSE 0 END,
        games_with_friends = games_with_friends + CASE WHEN v_friends_in_game > 0 THEN 1 ELSE 0 END,
        unique_friends_played_with = unique_friends_played_with + CASE WHEN v_friend_game_bonus > 0 THEN (v_friend_game_bonus / 50) ELSE 0 END,
        streak_freezes_available = CASE
          WHEN v_engagement.last_game_date = v_today - 2 AND v_engagement.streak_freezes_available > 0
          THEN streak_freezes_available - 1
          ELSE streak_freezes_available
        END,
        streak_freeze_last_used = CASE
          WHEN v_engagement.last_game_date = v_today - 2 AND v_engagement.streak_freezes_available > 0
          THEN v_today
          ELSE streak_freeze_last_used
        END,
        updated_at = NOW()
      WHERE user_id = v_user_id;

      -- =====================================================
      -- LOG FP TRANSACTION
      -- =====================================================

      INSERT INTO public.fp_transactions (
        user_id, amount, balance_after, reason, game_id,
        multipliers, base_fp, win_bonus_fp, fantasy_points_fp, first_game_bonus_fp
      )
      SELECT
        v_user_id,
        v_total_fp,
        ue.flashback_points,
        'game_complete',
        p_game_id,
        v_multipliers || jsonb_build_object(
          'streak_milestone', v_streak_milestone_bonus,
          'challenge_bonus', v_challenge_bonus,
          'referral_bonus', v_referral_bonus,
          'friend_game_bonus', v_friend_game_bonus
        ),
        v_base_fp,
        v_win_bonus,
        v_fantasy_fp,
        v_first_game_bonus
      FROM public.user_engagement ue
      WHERE ue.user_id = v_user_id;

      -- Add to results (total FP earned including all bonuses)
      v_fp_results := v_fp_results || jsonb_build_object(v_user_id::TEXT, v_total_fp);

      -- =====================================================
      -- UPDATE USER PROFILE STATS
      -- =====================================================

      SELECT EXISTS(SELECT 1 FROM public.user_profiles WHERE id = v_user_id) INTO v_profile_exists;

      IF v_profile_exists THEN
        UPDATE public.user_profiles
        SET
          games_played = games_played + 1,
          games_won = games_won + CASE WHEN v_is_winner THEN 1 ELSE 0 END,
          highest_score = GREATEST(highest_score, v_final_score),
          total_points = total_points + v_final_score,
          updated_at = NOW()
        WHERE id = v_user_id;

        -- Track high score
        IF (prev_high IS NULL OR v_final_score > prev_high) AND NOT is_new_high THEN
          is_new_high := TRUE;
          new_high_score := v_final_score;
          new_high_user := v_user_id;
        END IF;
      END IF;

      -- Update game result with final FP earned
      UPDATE public.game_results
      SET fp_earned = v_total_fp
      WHERE game_id = p_game_id AND user_id = v_user_id;

    END IF;
  END LOOP;

  -- Return high score info + FP results
  RETURN QUERY SELECT is_new_high, new_high_user, new_high_score, prev_high, v_fp_results;
END;
$$;
