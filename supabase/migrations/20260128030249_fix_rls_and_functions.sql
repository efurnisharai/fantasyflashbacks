-- =========================================================
-- Fantasy Flashback — 2–4 PLAYER MULTIPLAYER NOW (SCALABLE TO 12+)
-- + GLOBAL MATCHMAKING + DRAFT TIMER + AUTOPICK
-- + TEAM CODE NORMALIZATION (prevents .single() scoring crashes)
--
-- NEW IN THIS REVISION:
--  F) Randomized draft order + SNAKE DRAFT
--     - games gets: draft_order uuid[], draft_pos int, draft_dir int, snake_draft boolean
--     - ff_start_draft randomizes draft_order once per game and initializes snake state
--     - ff_make_pick / ff_auto_pick_if_needed advance using snake state (authoritative server-side)
--
-- IMPORTANT RULES ENFORCED SERVER-SIDE:
--  - If player_count <= 2: ALWAYS alternate (non-snake), regardless of snakeDraft setting.
--  - If player_count >= 3: snakeDraft controls standard snake:
--      1-2-3-3-2-1-1-2-3-3-2-1...
--    (first pick is single; double-picks happen at both ends after round 1)
--
-- Last verified: 2026-01-27
-- =========================================================

create extension if not exists pgcrypto;

-- =========================================================
-- 0) TEAM NORMALIZATION HELPERS (WSH/JAC/LA -> WAS/JAX/LAR)
-- =========================================================

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
    else upper(trim(t))
  end;
$$;

create or replace function public.apply_nfl_team_normalization()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.team is not null then
    new.team := public.normalize_nfl_team_code(new.team);
  end if;

  if to_jsonb(new) ? 'opponent' and new.opponent is not null then
    new.opponent := public.normalize_nfl_team_code(new.opponent);
  end if;

  return new;
end $$;

-- =========================================================
-- 0.5) ROOM CODE GENERATOR (6 chars)
-- =========================================================

create or replace function public.ff_gen_room_code()
returns text
language plpgsql
set search_path = public
as $$
declare
  code text;
begin
  code := upper(substring(encode(gen_random_bytes(4), 'hex') from 1 for 6));
  return code;
end $$;

-- =========================================================
-- 1) GAMES
-- =========================================================

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  room_code text unique not null,
  status text not null default 'lobby',
  settings jsonb not null default '{}'::jsonb,
  season int,
  week int,
  turn_user_id uuid,
  pick_number int not null default 1,
  turn_deadline_at timestamptz,
  created_at timestamptz not null default now(),

  max_players int not null default 2,
  join_mode text not null default 'code',
  settings_hash text,

  draft_order uuid[],
  draft_pos int not null default 1,
  draft_dir int not null default 1,
  snake_draft boolean not null default true
);

alter table public.games
  add column if not exists room_code text,
  add column if not exists status text not null default 'lobby',
  add column if not exists settings jsonb not null default '{}'::jsonb,
  add column if not exists season int,
  add column if not exists week int,
  add column if not exists turn_user_id uuid,
  add column if not exists pick_number int,
  add column if not exists turn_deadline_at timestamptz,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists max_players int,
  add column if not exists join_mode text,
  add column if not exists settings_hash text,
  add column if not exists draft_order uuid[],
  add column if not exists draft_pos int,
  add column if not exists draft_dir int,
  add column if not exists snake_draft boolean;

update public.games set pick_number = 1 where pick_number is null;

update public.games
set max_players = coalesce(max_players, greatest(2, least(12, coalesce((settings->>'maxPlayers')::int, 2))))
where max_players is null;

update public.games
set join_mode = coalesce(join_mode, coalesce(settings->>'joinMode','code'))
where join_mode is null;

update public.games
set draft_pos = coalesce(draft_pos, 1),
    draft_dir = coalesce(draft_dir, 1),
    snake_draft = coalesce(snake_draft, true)
where draft_pos is null or draft_dir is null or snake_draft is null;

do $$
begin
  execute 'alter table public.games alter column pick_number set not null';
  execute 'alter table public.games alter column pick_number set default 1';
exception when others then null;
end $$;

do $$
begin
  execute 'alter table public.games alter column draft_pos set not null';
  execute 'alter table public.games alter column draft_pos set default 1';
exception when others then null;
end $$;

do $$
begin
  execute 'alter table public.games alter column draft_dir set not null';
  execute 'alter table public.games alter column draft_dir set default 1';
exception when others then null;
end $$;

do $$
begin
  execute 'alter table public.games alter column snake_draft set not null';
  execute 'alter table public.games alter column snake_draft set default true';
exception when others then null;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'games_room_code_key'
      and conrelid = 'public.games'::regclass
  ) then
    execute 'alter table public.games add constraint games_room_code_key unique (room_code)';
  end if;
exception when others then null;
end $$;

create index if not exists idx_games_room_code on public.games(room_code);
create index if not exists idx_games_status on public.games(status);
create index if not exists idx_games_turn_deadline_at on public.games(turn_deadline_at);
create index if not exists idx_games_lobby_match on public.games(status, join_mode, settings_hash, max_players, created_at);

alter table public.games disable row level security;
alter table public.games no force row level security;

-- =========================================================
-- 2) GAME_PLAYERS
-- =========================================================

create table if not exists public.game_players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null,
  display_name text not null,
  seat int not null,
  ready boolean not null default true,
  is_active boolean not null default true,
  left_at timestamptz,
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.game_players
  add column if not exists game_id uuid,
  add column if not exists user_id uuid,
  add column if not exists display_name text,
  add column if not exists seat int,
  add column if not exists ready boolean not null default true,
  add column if not exists is_active boolean not null default true,
  add column if not exists left_at timestamptz,
  add column if not exists last_seen timestamptz not null default now(),
  add column if not exists created_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'game_players_game_id_fkey'
      and conrelid = 'public.game_players'::regclass
  ) then
    execute 'alter table public.game_players add constraint game_players_game_id_fkey foreign key (game_id) references public.games(id) on delete cascade';
  end if;
exception when others then null;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='game_players_game_id_user_id_key' and conrelid='public.game_players'::regclass) then
    execute 'alter table public.game_players add constraint game_players_game_id_user_id_key unique (game_id, user_id)';
  end if;
  if not exists (select 1 from pg_constraint where conname='game_players_game_id_seat_key' and conrelid='public.game_players'::regclass) then
    execute 'alter table public.game_players add constraint game_players_game_id_seat_key unique (game_id, seat)';
  end if;
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from pg_constraint where conname='game_players_seat_check' and conrelid='public.game_players'::regclass) then
    execute 'alter table public.game_players drop constraint game_players_seat_check';
  end if;
exception when others then null;
end $$;

do $$
begin
  execute 'alter table public.game_players add constraint game_players_seat_check check (seat >= 1 and seat <= 12)';
exception when duplicate_object then null;
end $$;

create index if not exists idx_game_players_game on public.game_players(game_id);
create index if not exists idx_game_players_user on public.game_players(user_id);
create index if not exists idx_game_players_game_seat on public.game_players(game_id, seat);
create index if not exists idx_game_players_game_active on public.game_players(game_id, is_active);
create index if not exists idx_game_players_game_last_seen on public.game_players(game_id, last_seen);

alter table public.game_players disable row level security;
alter table public.game_players no force row level security;

-- =========================================================
-- 3) GAME_PICKS
-- =========================================================

create table if not exists public.game_picks (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null,
  seat int not null,
  pick_number int not null,
  slot_index int not null,
  slot_position text not null,
  player_id text not null,
  created_at timestamptz not null default now()
);

alter table public.game_picks
  add column if not exists game_id uuid,
  add column if not exists user_id uuid,
  add column if not exists seat int,
  add column if not exists pick_number int,
  add column if not exists slot_index int,
  add column if not exists slot_position text,
  add column if not exists player_id text,
  add column if not exists created_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'game_picks_game_id_fkey'
      and conrelid = 'public.game_picks'::regclass
  ) then
    execute 'alter table public.game_picks add constraint game_picks_game_id_fkey foreign key (game_id) references public.games(id) on delete cascade';
  end if;
exception when others then null;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='game_picks_game_id_pick_number_key' and conrelid='public.game_picks'::regclass) then
    execute 'alter table public.game_picks add constraint game_picks_game_id_pick_number_key unique (game_id, pick_number)';
  end if;

  if not exists (select 1 from pg_constraint where conname='game_picks_game_id_player_id_key' and conrelid='public.game_picks'::regclass) then
    execute 'alter table public.game_picks add constraint game_picks_game_id_player_id_key unique (game_id, player_id)';
  end if;
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from pg_constraint where conname='game_picks_seat_check' and conrelid='public.game_picks'::regclass) then
    execute 'alter table public.game_picks drop constraint game_picks_seat_check';
  end if;
exception when others then null;
end $$;

do $$
begin
  execute 'alter table public.game_picks add constraint game_picks_seat_check check (seat >= 1 and seat <= 12)';
exception when duplicate_object then null;
end $$;

create index if not exists idx_game_picks_game on public.game_picks(game_id);
create index if not exists idx_game_picks_game_pick on public.game_picks(game_id, pick_number);

alter table public.game_picks disable row level security;
alter table public.game_picks no force row level security;

update public.game_picks p
set seat = gp.seat
from public.game_players gp
where p.game_id = gp.game_id
  and p.user_id = gp.user_id
  and (p.seat is null);

update public.game_picks set seat = 1 where seat is null;

do $$
begin
  execute 'alter table public.game_picks alter column seat set not null';
  execute 'alter table public.game_picks alter column pick_number set not null';
  execute 'alter table public.game_picks alter column slot_index set not null';
  execute 'alter table public.game_picks alter column slot_position set not null';
  execute 'alter table public.game_picks alter column player_id set not null';
exception when others then null;
end $$;

-- =========================================================
-- 4) NORMALIZE EXISTING TEAM CODES IN STATS TABLES
-- =========================================================

do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='team_week_stats' and column_name='team') then
    execute $q$
      update public.team_week_stats
      set team = public.normalize_nfl_team_code(team)
      where team is not null
        and team <> public.normalize_nfl_team_code(team)
    $q$;
  end if;
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='team_week_matchups' and column_name='team') then
    execute $q$
      update public.team_week_matchups
      set team = public.normalize_nfl_team_code(team)
      where team is not null
        and team <> public.normalize_nfl_team_code(team)
    $q$;
  end if;

  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='team_week_matchups' and column_name='opponent') then
    execute $q$
      update public.team_week_matchups
      set opponent = public.normalize_nfl_team_code(opponent)
      where opponent is not null
        and opponent <> public.normalize_nfl_team_code(opponent)
    $q$;
  end if;
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='player_week_stats' and column_name='team') then
    execute $q$
      update public.player_week_stats
      set team = public.normalize_nfl_team_code(team)
      where team is not null
        and team <> public.normalize_nfl_team_code(team)
    $q$;
  end if;
exception when others then null;
end $$;

-- =========================================================
-- 5) KEEP TEAM CODES NORMALIZED GOING FORWARD (TRIGGERS)
-- =========================================================

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='team_week_stats') then
    execute 'drop trigger if exists trg_team_week_stats_normalize on public.team_week_stats';
    execute '
      create trigger trg_team_week_stats_normalize
      before insert or update on public.team_week_stats
      for each row execute function public.apply_nfl_team_normalization()
    ';
  end if;
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='team_week_matchups') then
    execute 'drop trigger if exists trg_team_week_matchups_normalize on public.team_week_matchups';
    execute '
      create trigger trg_team_week_matchups_normalize
      before insert or update on public.team_week_matchups
      for each row execute function public.apply_nfl_team_normalization()
    ';
  end if;
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='player_week_stats') then
    execute 'drop trigger if exists trg_player_week_stats_normalize on public.player_week_stats';
    execute '
      create trigger trg_player_week_stats_normalize
      before insert or update on public.player_week_stats
      for each row execute function public.apply_nfl_team_normalization()
    ';
  end if;
exception when others then null;
end $$;

-- =========================================================
-- 6) UNIQUENESS + INDEXES (STATS)
-- =========================================================

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='player_week_stats') then
    begin
      execute 'alter table public.player_week_stats add constraint player_week_stats_one_row unique (season, week, player_id)';
    exception when duplicate_object then null;
    end;
  end if;

  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='team_week_stats') then
    begin
      execute 'alter table public.team_week_stats add constraint team_week_stats_one_row unique (season, week, team)';
    exception when duplicate_object then null;
    end;
  end if;
exception when others then null;
end $$;

create index if not exists idx_player_week_stats_season_week on public.player_week_stats(season, week);
create index if not exists idx_player_week_stats_season_week_player on public.player_week_stats(season, week, player_id);
create index if not exists idx_player_week_stats_season_week_position on public.player_week_stats(season, week, position);
create index if not exists idx_player_week_stats_season_week_team on public.player_week_stats(season, week, team);
create index if not exists idx_team_week_stats_season_week_team on public.team_week_stats(season, week, team);
create index if not exists idx_team_week_matchups_season_week_team on public.team_week_matchups(season, week, team);

-- =========================================================
-- 6.5) STATS TABLE ACCESS (PROTOTYPE)
-- =========================================================

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='player_week_stats') then
    execute 'alter table public.player_week_stats disable row level security';
    execute 'alter table public.player_week_stats no force row level security';
  end if;

  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='team_week_stats') then
    execute 'alter table public.team_week_stats disable row level security';
    execute 'alter table public.team_week_stats no force row level security';
  end if;

  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='team_week_matchups') then
    execute 'alter table public.team_week_matchups disable row level security';
    execute 'alter table public.team_week_matchups no force row level security';
  end if;
exception when others then null;
end $$;

grant usage on schema public to anon, authenticated;
grant select on table public.player_week_stats to anon, authenticated;
grant select on table public.team_week_stats to anon, authenticated;
grant select on table public.team_week_matchups to anon, authenticated;

-- =========================================================
-- 7) RANDOM WEEK PICKER
-- =========================================================

create or replace function public.pick_random_game_week(year_start int, year_end int)
returns table(season int, week int)
language sql
set search_path = public
volatile
as $$
  with bounds as (
    select least(year_start, year_end) as y0, greatest(year_start, year_end) as y1
  ),
  candidates as (
    select p.season, p.week
    from public.player_week_stats p
    cross join bounds b
    where p.season between b.y0 and b.y1
      and p.week between 1 and 17
    group by p.season, p.week
  )
  select c.season, c.week
  from candidates c
  order by random()
  limit 1;
$$;

-- =========================================================
-- 8) MATCHMAKING QUEUE (GLOBAL)
-- =========================================================

create table if not exists public.matchmaking_queue (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique,
  display_name text not null,
  settings_hash text not null,
  max_players int not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_matchmaking_queue_bucket on public.matchmaking_queue(settings_hash, max_players, created_at);

alter table public.matchmaking_queue disable row level security;
alter table public.matchmaking_queue no force row level security;

-- =========================================================
-- 9) HEARTBEAT / LEFT MARKERS
-- =========================================================

create or replace function public.ff_heartbeat(p_game_id uuid, p_user_id uuid)
returns void
language sql
set search_path = public
as $$
  update public.game_players
  set last_seen = now(),
      is_active = true
  where game_id = p_game_id
    and user_id = p_user_id;
$$;

create or replace function public.ff_mark_left(p_game_id uuid, p_user_id uuid)
returns void
language sql
set search_path = public
as $$
  update public.game_players
  set is_active = false,
      left_at = now()
  where game_id = p_game_id
    and user_id = p_user_id;
$$;

-- =========================================================
-- 10) ROOM CREATE/JOIN (ATOMIC SEAT ASSIGNMENT)
-- =========================================================

create or replace function public.ff_create_room(
  p_room_code text,
  p_settings jsonb,
  p_host_user_id uuid,
  p_host_name text
)
returns table(id uuid, room_code text)
language plpgsql
set search_path = public
as $$
declare
  v_room_code text;
  mp int;
  jmode text;
  sh text;
  g_id uuid;
begin
  mp := greatest(2, least(12, coalesce((p_settings->>'maxPlayers')::int, 2)));
  jmode := coalesce(p_settings->>'joinMode','code');
  sh := p_settings->>'settingsHash';
  if sh is null then sh := md5(p_settings::text); end if;

  v_room_code := upper(trim(coalesce(p_room_code,'')));
  if v_room_code = '' then
    loop
      v_room_code := public.ff_gen_room_code();
      exit when not exists (select 1 from public.games gg where gg.room_code = v_room_code);
    end loop;
  end if;

  insert into public.games(room_code, status, settings, pick_number, max_players, join_mode, settings_hash)
  values (v_room_code, 'lobby', p_settings, 1, mp, jmode, sh)
  returning public.games.id into g_id;

  insert into public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
  values (g_id, p_host_user_id, p_host_name, 1, true, true, now());

  return query select g_id, v_room_code;
end $$;

create or replace function public.ff_join_room(
  p_room_code text,
  p_user_id uuid,
  p_name text
)
returns table(game_id uuid, seat int)
language plpgsql
set search_path = public
as $$
declare
  g record;
  mp int;
  taken int[];
  s int;
begin
  select * into g
  from public.games gg
  where gg.room_code = upper(trim(p_room_code))
  for update;

  if not found then raise exception 'room not found'; end if;
  if g.status <> 'lobby' then raise exception 'room not joinable'; end if;

  mp := greatest(2, least(12, coalesce(g.max_players, coalesce((g.settings->>'maxPlayers')::int, 2))));

  if exists (select 1 from public.game_players gp where gp.game_id = g.id and gp.user_id = p_user_id) then
    select gp.seat into s from public.game_players gp where gp.game_id = g.id and gp.user_id = p_user_id limit 1;
    return query select g.id, s;
    return;
  end if;

  select array_agg(seat order by seat) into taken
  from public.game_players gp
  where gp.game_id = g.id;

  for s in 1..mp loop
    if taken is null or not (s = any(taken)) then
      insert into public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
      values (g.id, p_user_id, p_name, s, true, true, now());
      return query select g.id, s;
      return;
    end if;
  end loop;

  raise exception 'room is full';
end $$;

-- =========================================================
-- 11) GLOBAL MATCHMAKE OR JOIN
-- =========================================================

create or replace function public.ff_matchmake_or_join(
  p_user_id uuid,
  p_name text,
  p_max_players int,
  p_settings_hash text,
  p_settings jsonb
)
returns table(game_id uuid, room_code text, seat int)
language plpgsql
set search_path = public
as $$
declare
  mp int;
  sh text;
  g_id uuid;
  v_room_code text;
  s int;
begin
  mp := greatest(2, least(12, coalesce(p_max_players, 2)));
  sh := coalesce(nullif(trim(p_settings_hash),''), md5(p_settings::text));

  delete from public.matchmaking_queue mq
  where mq.updated_at < now() - interval '2 minutes';

  insert into public.matchmaking_queue(user_id, display_name, settings_hash, max_players, created_at, updated_at)
  values (p_user_id, p_name, sh, mp, now(), now())
  on conflict (user_id) do update
    set display_name = excluded.display_name,
        settings_hash = excluded.settings_hash,
        max_players = excluded.max_players,
        updated_at = now();

  perform pg_advisory_xact_lock(hashtext(sh || ':' || mp::text));

  for g_id, v_room_code in
    select g.id, g.room_code
    from public.games g
    where g.status = 'lobby'
      and g.join_mode = 'global'
      and g.settings_hash = sh
      and g.max_players = mp
    order by g.created_at asc
    limit 10
  loop
    begin
      select gp.seat into s
      from public.game_players gp
      where gp.game_id = g_id and gp.user_id = p_user_id
      limit 1;

      if s is not null then
        delete from public.matchmaking_queue mq where mq.user_id = p_user_id;
        return query select g_id, v_room_code, s;
        return;
      end if;

      select min(x) into s
      from generate_series(1, mp) x
      where not exists (
        select 1 from public.game_players gp2
        where gp2.game_id = g_id and gp2.seat = x
      );

      if s is null then
        continue;
      end if;

      insert into public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
      values (g_id, p_user_id, p_name, s, true, true, now());

      delete from public.matchmaking_queue mq where mq.user_id = p_user_id;
      return query select g_id, v_room_code, s;
      return;

    exception when unique_violation then
      continue;
    end;
  end loop;

  loop
    v_room_code := public.ff_gen_room_code();
    exit when not exists (select 1 from public.games gg where gg.room_code = v_room_code);
  end loop;

  insert into public.games(room_code, status, settings, pick_number, max_players, join_mode, settings_hash)
  values (v_room_code, 'lobby', p_settings, 1, mp, 'global', sh)
  returning id into g_id;

  insert into public.game_players(game_id, user_id, display_name, seat, ready, is_active, last_seen)
  values (g_id, p_user_id, p_name, 1, true, true, now());

  delete from public.matchmaking_queue mq where mq.user_id = p_user_id;

  return query select g_id, v_room_code, 1;
end $$;

-- =========================================================
-- 12) DRAFT ADVANCE HELPER (RANDOM ORDER + SNAKE)
-- Server-enforced:
--   - n<=2 => always non-snake alternating
--   - n>=3 => snake if p_snake = true
-- =========================================================

create or replace function public.ff_advance_draft_state(
  p_order uuid[],
  p_pos int,
  p_dir int,
  p_snake boolean
)
returns table(next_pos int, next_dir int)
language plpgsql
set search_path = public
as $$
declare
  n int;
  pos int := coalesce(p_pos, 1);
  dir int := case when coalesce(p_dir,1) >= 0 then 1 else -1 end;
  snake_mode boolean;
begin
  n := coalesce(array_length(p_order, 1), 0);

  if n <= 0 then
    return query select 1, 1;
    return;
  end if;

  -- Force alternating for 2 players (and 1 player)
  snake_mode := (coalesce(p_snake, false) and n >= 3);

  if not snake_mode then
    pos := pos + 1;
    if pos > n then pos := 1; end if;
    return query select pos, 1;
    return;
  end if;

  -- Standard snake:
  -- round1: 1..n
  -- then bounce: n..1, with double-picks at both ends starting after pick #n
  if dir = 1 then
    if pos < n then
      pos := pos + 1;
    else
      dir := -1; -- stay at n for the first "double pick" at the turn
    end if;
  else
    if pos > 1 then
      pos := pos - 1;
    else
      dir := 1; -- stay at 1 for the first "double pick" at the turn
    end if;
  end if;

  return query select pos, dir;
end $$;

-- =========================================================
-- 13) DRAFT START (HOST) — RANDOMIZE ORDER + INIT SNAKE
-- Enforces: if actual player_count <=2 => snake_draft = false
-- =========================================================

create or replace function public.ff_start_draft(
  p_game_id uuid,
  p_host_user_id uuid,
  p_season int,
  p_week int,
  p_settings jsonb
)
returns table(id uuid, status text, season int, week int, turn_user_id uuid, pick_number int, turn_deadline_at timestamptz)
language plpgsql
set search_path = public
as $$
declare
  pick_time int;
  mp int;
  ord uuid[];
  requested_snake boolean;
  snake boolean;
  first_user uuid;
  nplayers int;
begin
  pick_time := coalesce((p_settings->>'pickTime')::int, 30);
  mp := greatest(2, least(12, coalesce((p_settings->>'maxPlayers')::int, 2)));
  requested_snake := coalesce((p_settings->>'snakeDraft')::boolean, true);

  select array_agg(gp.user_id order by random())
  into ord
  from public.game_players gp
  where gp.game_id = p_game_id;

  if ord is null or array_length(ord,1) is null then
    raise exception 'no players in game';
  end if;

  nplayers := array_length(ord, 1);
  snake := (requested_snake and nplayers >= 3);

  first_user := ord[1];

  update public.games g
  set status = 'draft',
      season = p_season,
      week = p_week,
      settings = p_settings,
      max_players = mp,
      snake_draft = snake,
      draft_order = ord,
      draft_pos = 1,
      draft_dir = 1,
      turn_user_id = first_user,
      pick_number = 1,
      turn_deadline_at = now() + make_interval(secs => pick_time)
  where g.id = p_game_id;

  return query
    select g.id, g.status, g.season, g.week, g.turn_user_id, g.pick_number, g.turn_deadline_at
    from public.games g
    where g.id = p_game_id;
end $$;

-- =========================================================
-- 14) ATOMIC PICK — USE RANDOM+SNAKE STATE
-- (snake enforced by ff_advance_draft_state)
-- =========================================================

create or replace function public.ff_make_pick(
  p_game_id uuid,
  p_user_id uuid,
  p_player_id text,
  p_slot_index int,
  p_slot_position text
)
returns table(turn_user_id uuid, pick_number int, turn_deadline_at timestamptz)
language plpgsql
set search_path = public
as $$
declare
  g record;
  seat_val int;
  pick_time int;
  ord uuid[];
  pos int;
  dir int;
  snake boolean;
  next_pos int;
  next_dir int;
  next_user uuid;
begin
  select * into g
  from public.games
  where id = p_game_id
  for update;

  if not found then raise exception 'game not found'; end if;
  if g.status <> 'draft' then raise exception 'not drafting'; end if;
  if g.turn_user_id <> p_user_id then raise exception 'not your turn'; end if;

  select seat into seat_val
  from public.game_players
  where game_id = p_game_id and user_id = p_user_id
  limit 1;

  if seat_val is null then raise exception 'player not in game'; end if;

  insert into public.game_picks(game_id, user_id, seat, pick_number, slot_index, slot_position, player_id)
  values (p_game_id, p_user_id, seat_val, g.pick_number, p_slot_index, p_slot_position, p_player_id);

  pick_time := coalesce((g.settings->>'pickTime')::int, 30);

  ord := g.draft_order;
  if ord is null or array_length(ord,1) is null then
    select array_agg(gp.user_id order by gp.seat asc) into ord
    from public.game_players gp
    where gp.game_id = p_game_id;
  end if;

  snake := coalesce(g.snake_draft, true);
  pos := coalesce(g.draft_pos, 1);
  dir := coalesce(g.draft_dir, 1);

  select a.next_pos, a.next_dir into next_pos, next_dir
  from public.ff_advance_draft_state(ord, pos, dir, snake) a;

  if next_pos is null then next_pos := 1; end if;
  if next_dir is null then next_dir := 1; end if;

  next_user := ord[next_pos];

  update public.games
  set draft_order = ord,
      snake_draft = snake,
      draft_pos = next_pos,
      draft_dir = next_dir,
      turn_user_id = next_user,
      pick_number = g.pick_number + 1,
      turn_deadline_at = now() + make_interval(secs => pick_time)
  where id = p_game_id;

  return query
    select g2.turn_user_id, g2.pick_number, g2.turn_deadline_at
    from public.games g2
    where g2.id = p_game_id;
end $$;

-- =========================================================
-- 15) ATOMIC AUTOPICK — USE RANDOM+SNAKE STATE
-- (snake enforced by ff_advance_draft_state)
-- =========================================================

create or replace function public.ff_auto_pick_if_needed(p_game_id uuid)
returns table(turn_user_id uuid, pick_number int, turn_deadline_at timestamptz)
language plpgsql
set search_path = public
as $$
declare
  g record;
  pick_time int;
  seat_val int;
  slot_needed text;
  slot_idx int;
  ord uuid[];
  pos int;
  dir int;
  snake boolean;
  next_pos int;
  next_dir int;
  next_user uuid;
  chosen_player_id text;
begin
  select * into g
  from public.games
  where id = p_game_id
  for update;

  if not found then return; end if;
  if g.status <> 'draft' then return; end if;
  if g.turn_deadline_at is null then return; end if;

  if now() < g.turn_deadline_at then
    return query select g.turn_user_id, g.pick_number, g.turn_deadline_at;
    return;
  end if;

  select seat into seat_val
  from public.game_players
  where game_id = p_game_id and user_id = g.turn_user_id
  limit 1;

  if seat_val is null then
    return query select g.turn_user_id, g.pick_number, g.turn_deadline_at;
    return;
  end if;

  with slots as (
    select row_number() over () - 1 as idx, slot
    from (
      select unnest(
        array_cat(
          array_cat(
            array_cat(
              array_cat(
                array_cat(
                  array_cat(
                    array_fill('QB'::text, array[coalesce((g.settings->>'qbSlots')::int,1)]),
                    array_fill('RB'::text, array[coalesce((g.settings->>'rbSlots')::int,2)])
                  ),
                  array_fill('WR'::text, array[coalesce((g.settings->>'wrSlots')::int,2)])
                ),
                array_fill('TE'::text, array[coalesce((g.settings->>'teSlots')::int,1)])
              ),
              array_fill('FLEX'::text, array[coalesce((g.settings->>'flexSlots')::int,1)])
            ),
            array_fill('K'::text, array[coalesce((g.settings->>'kSlots')::int,1)])
          ),
          array_fill('DST'::text, array[coalesce((g.settings->>'dstSlots')::int,1)])
        )
      ) as slot
    ) s
  ),
  my_filled as (
    select slot_index
    from public.game_picks
    where game_id = p_game_id and user_id = g.turn_user_id
  ),
  first_empty as (
    select s.idx, s.slot
    from slots s
    left join my_filled f on f.slot_index = s.idx
    where f.slot_index is null
    order by s.idx asc
    limit 1
  )
  select idx, slot into slot_idx, slot_needed from first_empty;

  if slot_idx is null then
    pick_time := coalesce((g.settings->>'pickTime')::int, 30);

    ord := g.draft_order;
    if ord is null or array_length(ord,1) is null then
      select array_agg(gp.user_id order by gp.seat asc) into ord
      from public.game_players gp
      where gp.game_id = p_game_id;
    end if;

    snake := coalesce(g.snake_draft, true);
    pos := coalesce(g.draft_pos, 1);
    dir := coalesce(g.draft_dir, 1);

    select a.next_pos, a.next_dir into next_pos, next_dir
    from public.ff_advance_draft_state(ord, pos, dir, snake) a;

    if next_pos is null then next_pos := 1; end if;
    if next_dir is null then next_dir := 1; end if;

    next_user := ord[next_pos];

    update public.games
    set draft_order = ord,
        snake_draft = snake,
        draft_pos = next_pos,
        draft_dir = next_dir,
        turn_user_id = next_user,
        pick_number = g.pick_number + 1,
        turn_deadline_at = now() + make_interval(secs => pick_time)
    where id = p_game_id;

    return query select g2.turn_user_id, g2.pick_number, g2.turn_deadline_at from public.games g2 where g2.id = p_game_id;
    return;
  end if;

  with drafted as (select player_id from public.game_picks where game_id = p_game_id),
  candidates as (
    select p.player_id as pid
    from public.player_week_stats p
    where p.season = g.season and p.week = g.week
      and p.player_id not in (select player_id from drafted)
      and (
        (slot_needed = 'FLEX' and upper(p.position) in ('RB','WR','TE')) or
        (slot_needed <> 'FLEX' and upper(replace(p.position,'PK','K')) = slot_needed)
      )
    union all
    select ('DST_' || public.normalize_nfl_team_code(t.team))::text as pid
    from public.team_week_stats t
    where t.season = g.season and t.week = g.week
      and slot_needed = 'DST'
      and ('DST_' || public.normalize_nfl_team_code(t.team))::text not in (select player_id from drafted)
  )
  select pid into chosen_player_id
  from candidates
  order by random()
  limit 1;

  if chosen_player_id is null then
    return query select g.turn_user_id, g.pick_number, g.turn_deadline_at;
    return;
  end if;

  insert into public.game_picks(game_id, user_id, seat, pick_number, slot_index, slot_position, player_id)
  values (p_game_id, g.turn_user_id, seat_val, g.pick_number, slot_idx, slot_needed, chosen_player_id);

  pick_time := coalesce((g.settings->>'pickTime')::int, 30);

  ord := g.draft_order;
  if ord is null or array_length(ord,1) is null then
    select array_agg(gp.user_id order by gp.seat asc) into ord
    from public.game_players gp
    where gp.game_id = p_game_id;
  end if;

  snake := coalesce(g.snake_draft, true);
  pos := coalesce(g.draft_pos, 1);
  dir := coalesce(g.draft_dir, 1);

  select a.next_pos, a.next_dir into next_pos, next_dir
  from public.ff_advance_draft_state(ord, pos, dir, snake) a;

  if next_pos is null then next_pos := 1; end if;
  if next_dir is null then next_dir := 1; end if;

  next_user := ord[next_pos];

  update public.games
  set draft_order = ord,
      snake_draft = snake,
      draft_pos = next_pos,
      draft_dir = next_dir,
      turn_user_id = next_user,
      pick_number = g.pick_number + 1,
      turn_deadline_at = now() + make_interval(secs => pick_time)
  where id = p_game_id;

  return query
    select g2.turn_user_id, g2.pick_number, g2.turn_deadline_at
    from public.games g2
    where g2.id = p_game_id;
end $$;

-- =========================================================
-- 16) CLEAN OUT OLD POLICIES (optional)
-- =========================================================
do $$
begin
  execute 'drop policy if exists games_read_participants on public.games';
  execute 'drop policy if exists games_insert_authed on public.games';
  execute 'drop policy if exists games_update_participants on public.games';

  execute 'drop policy if exists game_players_read_participants on public.game_players';
  execute 'drop policy if exists game_players_insert_self on public.game_players';
  execute 'drop policy if exists game_players_update_self on public.game_players';
  execute 'drop policy if exists game_players_delete_self on public.game_players';

  execute 'drop policy if exists picks_read_participants on public.game_picks';
  execute 'drop policy if exists picks_insert_self on public.game_picks';
exception when others then null;
end $$;

drop function if exists public.is_player_in_game(uuid, uuid);

-- =========================================================
-- 17) OPTIONAL QUICK SANITY CHECKS
-- =========================================================
-- select room_code, snake_draft, draft_pos, draft_dir, array_length(draft_order,1) from public.games order by created_at desc limit 20;

-- (kept for safety) Ensure defaults + backfill for older rows
alter table public.games add column if not exists draft_pos int;
alter table public.games add column if not exists draft_dir int;
alter table public.games add column if not exists snake_draft boolean;

alter table public.games alter column draft_pos set default 1;
alter table public.games alter column draft_dir set default 1;
alter table public.games alter column snake_draft set default true;

update public.games
set draft_pos = coalesce(draft_pos, 1),
    draft_dir = coalesce(draft_dir, 1),
    snake_draft = coalesce(snake_draft, true)
where draft_pos is null
   or draft_dir is null
   or snake_draft is null;

do $$
begin
  execute 'alter table public.games alter column draft_pos set not null';
exception when others then null;
end $$;

do $$
begin
  execute 'alter table public.games alter column draft_dir set not null';
exception when others then null;
end $$;

do $$
begin
  execute 'alter table public.games alter column snake_draft set not null';
exception when others then null;
end $$;

