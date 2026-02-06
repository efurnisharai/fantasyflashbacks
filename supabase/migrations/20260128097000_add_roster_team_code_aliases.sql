-- Add nflreadpy roster variant abbreviations to team code normalization
create or replace function public.normalize_nfl_team_code(t text)
returns text
language sql
set search_path = public
immutable
as $$
  select case upper(trim(coalesce(t,'')))
    when '' then null
    when 'WSH' then 'WAS'
    when 'JAC' then 'JAX'
    when 'LA'  then 'LAR'
    when 'BLT' then 'BAL'
    when 'ARZ' then 'ARI'
    when 'CLV' then 'CLE'
    when 'HST' then 'HOU'
    when 'SL'  then 'STL'
    else upper(trim(t))
  end;
$$;
