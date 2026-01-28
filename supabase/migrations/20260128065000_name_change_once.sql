-- Add name_changed flag to track if user has customized their display name
-- This allows one-time name change for signed-in users

ALTER TABLE public.user_profiles 
ADD COLUMN IF NOT EXISTS name_changed boolean NOT NULL DEFAULT false;

-- Comment for documentation
COMMENT ON COLUMN public.user_profiles.name_changed IS 'True if user has customized their display name (one-time change allowed)';
