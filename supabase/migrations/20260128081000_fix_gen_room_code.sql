-- =========================================================
-- Fix: Replace gen_random_bytes with random() for room code generation
-- gen_random_bytes requires pgcrypto extension which may not be enabled
-- =========================================================

CREATE OR REPLACE FUNCTION public.ff_gen_room_code()
RETURNS text
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text := '';
  i int;
BEGIN
  FOR i IN 1..6 LOOP
    code := code || substr(chars, floor(random() * length(chars) + 1)::int, 1);
  END LOOP;
  RETURN code;
END $$;
