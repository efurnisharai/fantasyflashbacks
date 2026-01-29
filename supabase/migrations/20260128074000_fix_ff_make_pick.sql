-- Drop the conflicting function first
DROP FUNCTION IF EXISTS public.ff_make_pick(uuid, uuid, text, integer, text);
DROP FUNCTION IF EXISTS public.ff_make_pick(uuid, uuid, text, integer, text, integer);
