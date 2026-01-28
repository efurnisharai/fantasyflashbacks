-- Fix: Add missing round column to game_picks
ALTER TABLE public.game_picks ADD COLUMN IF NOT EXISTS round INT;
