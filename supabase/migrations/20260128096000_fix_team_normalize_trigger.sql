-- Fix apply_nfl_team_normalization() to not directly reference new.opponent,
-- which fails at PL/pgSQL compile time for tables without that column
-- (e.g. player_week_stats).
create or replace function public.apply_nfl_team_normalization()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  _rec jsonb;
  _opp text;
begin
  if new.team is not null then
    new.team := public.normalize_nfl_team_code(new.team);
  end if;

  -- Dynamically check for opponent column without direct field reference
  _rec := to_jsonb(new);
  if (_rec ? 'opponent') then
    _opp := _rec->>'opponent';
    if _opp is not null then
      new := jsonb_populate_record(new, jsonb_build_object('opponent', public.normalize_nfl_team_code(_opp)));
    end if;
  end if;

  return new;
end $$;
