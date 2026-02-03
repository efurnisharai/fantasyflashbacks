-- Drop the overloaded ff_auto_pick_if_needed function with two parameters
-- Keep only the single-parameter version from 20260128030249_fix_rls_and_functions.sql

DROP FUNCTION IF EXISTS public.ff_auto_pick_if_needed(uuid, int);
DROP FUNCTION IF EXISTS public.ff_auto_pick_if_needed(uuid, integer);
