-- =========================================================
-- Fantasy Flashback — Auth, RLS, and User Profiles
--
-- Goals:
--   1. Enable RLS on all tables WITHOUT breaking functionality
--   2. Keep anonymous auth working (optional sign-up)
--   3. Prepare for Google/Apple OAuth (no email/password storage)
--   4. User profiles for high scores and leaderboards
--
-- Key insight: Your SECURITY DEFINER functions (ff_create_room,
-- ff_make_pick, etc.) bypass RLS automatically. We just need
-- SELECT policies for reads.
-- =========================================================

-- =========================================================
-- 1) USER PROFILES TABLE
-- =========================================================

create table if not exists public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,

  -- Stats
  games_played int not null default 0,
  games_won int not null default 0,
  highest_score numeric(10,2) default 0,
  total_points numeric(12,2) default 0,

  -- OAuth provider info (optional, for display)
  provider text, -- 'anonymous', 'google', 'apple'

  -- Premium status (for future monetization)
  is_premium boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Index for leaderboards
create index if not exists idx_user_profiles_highest_score on public.user_profiles(highest_score desc);
create index if not exists idx_user_profiles_games_won on public.user_profiles(games_won desc);

-- =========================================================
-- 2) GAME RESULTS TABLE (for history/leaderboards)
-- =========================================================

create table if not exists public.game_results (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null,

  display_name text not null,
  seat int not null,
  final_score numeric(10,2) not null default 0,
  placement int not null default 1, -- 1st, 2nd, 3rd, etc.
  is_winner boolean not null default false,

  season int,
  week int,

  created_at timestamptz not null default now()
);

create index if not exists idx_game_results_user on public.game_results(user_id);
create index if not exists idx_game_results_game on public.game_results(game_id);
create index if not exists idx_game_results_score on public.game_results(final_score desc);

-- =========================================================
-- 3) HELPER: Check if user is in a game
-- =========================================================

create or replace function public.user_in_game(p_game_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.game_players
    where game_id = p_game_id and user_id = p_user_id
  );
$$;

-- =========================================================
-- 4) ENABLE RLS ON ALL TABLES
-- =========================================================

-- Stats tables (NFL data - public read)
alter table public.player_week_stats enable row level security;
alter table public.team_week_stats enable row level security;
alter table public.team_week_matchups enable row level security;

-- Game tables
alter table public.games enable row level security;
alter table public.game_players enable row level security;
alter table public.game_picks enable row level security;
alter table public.matchmaking_queue enable row level security;

-- New tables
alter table public.user_profiles enable row level security;
alter table public.game_results enable row level security;

-- =========================================================
-- 5) RLS POLICIES - Stats Tables (Public Read)
-- These are just NFL historical data, no write needed from client
-- =========================================================

-- Drop old policies if they exist (clean slate)
drop policy if exists "Stats are publicly readable" on public.player_week_stats;
drop policy if exists "Team stats are publicly readable" on public.team_week_stats;
drop policy if exists "Matchups are publicly readable" on public.team_week_matchups;

-- Anyone can read stats (anon or authenticated)
create policy "anon_read_player_stats" on public.player_week_stats
  for select using (true);

create policy "anon_read_team_stats" on public.team_week_stats
  for select using (true);

create policy "anon_read_matchups" on public.team_week_matchups
  for select using (true);

-- =========================================================
-- 6) RLS POLICIES - Games Table
-- Read: Anyone can read games (needed for room code lookup)
-- Write: Handled by SECURITY DEFINER functions
-- =========================================================

drop policy if exists "Games are publicly readable" on public.games;
drop policy if exists "Authenticated users can create games" on public.games;
drop policy if exists "Authenticated users can update games" on public.games;

-- Anyone can read games (for join by code, lobby polling)
create policy "anon_read_games" on public.games
  for select using (true);

-- Only allow inserts via SECURITY DEFINER functions
-- This policy allows the service role and function owners
create policy "service_insert_games" on public.games
  for insert with check (false); -- Blocked at client level; functions bypass this

-- Updates only for participants (fallback for heartbeat, status)
create policy "participant_update_games" on public.games
  for update using (
    exists (
      select 1 from public.game_players gp
      where gp.game_id = id and gp.user_id = auth.uid()
    )
  );

-- =========================================================
-- 7) RLS POLICIES - Game Players Table
-- Read: Anyone can read (needed for lobby display)
-- Write: Handled by SECURITY DEFINER functions
-- =========================================================

drop policy if exists "Game players are publicly readable" on public.game_players;
drop policy if exists "Authenticated users can join games" on public.game_players;
drop policy if exists "Users can update their own player record" on public.game_players;

-- Anyone can read game players (for lobby, draft board)
create policy "anon_read_game_players" on public.game_players
  for select using (true);

-- Inserts blocked at client level; functions bypass
create policy "service_insert_game_players" on public.game_players
  for insert with check (false);

-- Users can update their own record (heartbeat fallback)
create policy "self_update_game_players" on public.game_players
  for update using (user_id = auth.uid());

-- =========================================================
-- 8) RLS POLICIES - Game Picks Table
-- Read: Anyone in the game can read picks
-- Write: Handled by SECURITY DEFINER functions
-- =========================================================

drop policy if exists "Game picks are publicly readable" on public.game_picks;
drop policy if exists "Authenticated users can make picks" on public.game_picks;

-- Participants can read picks for their game
create policy "participant_read_picks" on public.game_picks
  for select using (
    exists (
      select 1 from public.game_players gp
      where gp.game_id = game_id and gp.user_id = auth.uid()
    )
  );

-- Inserts blocked at client level; ff_make_pick handles this
create policy "service_insert_picks" on public.game_picks
  for insert with check (false);

-- =========================================================
-- 9) RLS POLICIES - Matchmaking Queue
-- All operations via SECURITY DEFINER functions
-- =========================================================

create policy "service_only_matchmaking" on public.matchmaking_queue
  for all using (false);

-- =========================================================
-- 10) RLS POLICIES - User Profiles
-- Read: Public (for leaderboards)
-- Write: Own profile only
-- =========================================================

-- Anyone can read profiles (leaderboards)
create policy "public_read_profiles" on public.user_profiles
  for select using (true);

-- Users can insert their own profile
create policy "self_insert_profile" on public.user_profiles
  for insert with check (id = auth.uid());

-- Users can update their own profile
create policy "self_update_profile" on public.user_profiles
  for update using (id = auth.uid());

-- =========================================================
-- 11) RLS POLICIES - Game Results
-- Read: Public (for history/leaderboards)
-- Write: Via function only
-- =========================================================

create policy "public_read_results" on public.game_results
  for select using (true);

create policy "service_insert_results" on public.game_results
  for insert with check (false); -- Via SECURITY DEFINER function

-- =========================================================
-- 12) AUTO-CREATE PROFILE ON SIGN-UP (Trigger)
-- Works for both anonymous and OAuth users
-- =========================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  provider_name text;
  display text;
begin
  -- Determine provider
  provider_name := coalesce(
    new.raw_app_meta_data->>'provider',
    'anonymous'
  );

  -- Generate display name
  display := coalesce(
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'name',
    'Player'
  );

  -- Create profile
  insert into public.user_profiles (id, display_name, provider, created_at)
  values (new.id, display, provider_name, now())
  on conflict (id) do nothing;

  return new;
end;
$$;

-- Drop existing trigger if any
drop trigger if exists on_auth_user_created on auth.users;

-- Create trigger
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =========================================================
-- 13) FUNCTION: Save Game Results (call from client on game end)
-- =========================================================

create or replace function public.ff_save_game_results(
  p_game_id uuid,
  p_results jsonb -- array of {user_id, display_name, seat, final_score}
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  game_rec record;
  r jsonb;
  sorted jsonb;
  rank int;
  top_score numeric;
begin
  -- Get game info
  select season, week into game_rec
  from public.games where id = p_game_id;

  -- Sort results by score descending
  sorted := (
    select jsonb_agg(x order by (x->>'final_score')::numeric desc)
    from jsonb_array_elements(p_results) x
  );

  -- Get top score
  top_score := (sorted->0->>'final_score')::numeric;

  -- Insert each result
  rank := 0;
  for r in select * from jsonb_array_elements(sorted)
  loop
    rank := rank + 1;

    insert into public.game_results (
      game_id, user_id, display_name, seat, final_score,
      placement, is_winner, season, week
    ) values (
      p_game_id,
      (r->>'user_id')::uuid,
      r->>'display_name',
      (r->>'seat')::int,
      (r->>'final_score')::numeric,
      rank,
      (r->>'final_score')::numeric >= top_score - 0.01, -- winner(s)
      game_rec.season,
      game_rec.week
    )
    on conflict do nothing;

    -- Update user profile stats
    update public.user_profiles
    set
      games_played = games_played + 1,
      games_won = games_won + case when (r->>'final_score')::numeric >= top_score - 0.01 then 1 else 0 end,
      highest_score = greatest(highest_score, (r->>'final_score')::numeric),
      total_points = total_points + (r->>'final_score')::numeric,
      updated_at = now()
    where id = (r->>'user_id')::uuid;
  end loop;
end;
$$;

-- =========================================================
-- 14) FUNCTION: Link Anonymous Account to OAuth
-- Call this when user signs in with Google/Apple after playing anonymously
-- =========================================================

create or replace function public.ff_link_anonymous_to_oauth(
  p_anonymous_user_id uuid,
  p_oauth_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Transfer game_players records
  update public.game_players
  set user_id = p_oauth_user_id
  where user_id = p_anonymous_user_id;

  -- Transfer game_picks records
  update public.game_picks
  set user_id = p_oauth_user_id
  where user_id = p_anonymous_user_id;

  -- Transfer game_results records
  update public.game_results
  set user_id = p_oauth_user_id
  where user_id = p_anonymous_user_id;

  -- Merge profile stats
  update public.user_profiles oauth
  set
    games_played = oauth.games_played + anon.games_played,
    games_won = oauth.games_won + anon.games_won,
    highest_score = greatest(oauth.highest_score, anon.highest_score),
    total_points = oauth.total_points + anon.total_points,
    updated_at = now()
  from public.user_profiles anon
  where oauth.id = p_oauth_user_id
    and anon.id = p_anonymous_user_id;

  -- Delete anonymous profile
  delete from public.user_profiles where id = p_anonymous_user_id;
end;
$$;

-- =========================================================
-- 15) LEADERBOARD VIEWS
-- =========================================================

create or replace view public.leaderboard_all_time as
select
  id,
  display_name,
  games_played,
  games_won,
  highest_score,
  total_points,
  case when games_played > 0
    then round((games_won::numeric / games_played) * 100, 1)
    else 0
  end as win_rate,
  provider
from public.user_profiles
where games_played > 0
order by highest_score desc
limit 100;

create or replace view public.leaderboard_wins as
select
  id,
  display_name,
  games_played,
  games_won,
  highest_score,
  case when games_played > 0
    then round((games_won::numeric / games_played) * 100, 1)
    else 0
  end as win_rate
from public.user_profiles
where games_played >= 3 -- minimum games for leaderboard
order by games_won desc, win_rate desc
limit 100;

-- Grant access to views
grant select on public.leaderboard_all_time to anon, authenticated;
grant select on public.leaderboard_wins to anon, authenticated;

-- =========================================================
-- 16) GRANT PERMISSIONS
-- =========================================================

-- Ensure anon and authenticated can use the tables
grant usage on schema public to anon, authenticated;

grant select on public.player_week_stats to anon, authenticated;
grant select on public.team_week_stats to anon, authenticated;
grant select on public.team_week_matchups to anon, authenticated;

grant select on public.games to anon, authenticated;
grant update on public.games to anon, authenticated;

grant select on public.game_players to anon, authenticated;
grant update on public.game_players to anon, authenticated;

grant select on public.game_picks to anon, authenticated;

grant select, insert, update on public.user_profiles to anon, authenticated;
grant select on public.game_results to anon, authenticated;

-- =========================================================
-- 17) BACKFILL: Create profiles for existing users
-- =========================================================

insert into public.user_profiles (id, display_name, provider, created_at)
select
  id,
  coalesce(raw_user_meta_data->>'full_name', 'Player'),
  coalesce(raw_app_meta_data->>'provider', 'anonymous'),
  created_at
from auth.users
where id not in (select id from public.user_profiles)
on conflict (id) do nothing;
