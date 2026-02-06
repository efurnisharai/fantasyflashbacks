import os, sys
import pandas as pd
import nflreadpy as nfl
from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
sb = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

def chunker(seq, n=500):
    for i in range(0, len(seq), n):
        yield seq[i:i+n]

def pick_col(cols, candidates):
    s = set(cols)
    for c in candidates:
        if c in s:
            return c
    return None

def main(year_start: int, year_end: int):
    years = list(range(year_start, year_end + 1))
    df = nfl.load_player_stats(years).to_pandas()
    print("Loaded player rows:", len(df))

    cols = df.columns.tolist()
    season_c = pick_col(cols, ["season","year"])
    week_c   = pick_col(cols, ["week"])
    pid_c    = pick_col(cols, ["player_id","gsis_id","player_gsis_id"])
    name_c   = pick_col(cols, ["player_name","name","player_display_name"])
    pos_c    = pick_col(cols, ["position","pos"])
    recent_team_c = pick_col(cols, ["recent_team","team","posteam"])

    # Load roster data to get correct historical team per (player, season)
    rosters = nfl.load_rosters(years).to_pandas()
    roster_cols = rosters.columns.tolist()
    roster_pid_c = pick_col(roster_cols, ["player_id","gsis_id","player_gsis_id"])
    roster_team_c = pick_col(roster_cols, ["team","recent_team"])
    roster_season_c = pick_col(roster_cols, ["season","year"])
    if roster_pid_c and roster_team_c and roster_season_c:
        roster_team_map = rosters[[roster_pid_c, roster_season_c, roster_team_c]].drop_duplicates(
            subset=[roster_pid_c, roster_season_c], keep="last"
        )
        roster_team_map = roster_team_map.rename(columns={
            roster_pid_c: pid_c, roster_season_c: season_c, roster_team_c: "roster_team"
        })
        df = df.merge(roster_team_map, on=[pid_c, season_c], how="left")
        # Prefer roster team, fall back to recent_team
        df["_hist_team"] = df["roster_team"].fillna(df.get(recent_team_c, pd.Series(dtype=str)))
        team_c = "_hist_team"
        print("Merged roster data for historical teams")
    else:
        team_c = recent_team_c
        print("Warning: could not load roster team data, falling back to recent_team")
    jersey_c = pick_col(cols, ["jersey_number"])

    pass_yds = pick_col(cols, ["passing_yards","pass_yards"])
    pass_td  = pick_col(cols, ["passing_tds","pass_tds"])
    ints     = pick_col(cols, ["interceptions","pass_int"])
    rush_yds = pick_col(cols, ["rushing_yards","rush_yards"])
    rush_td  = pick_col(cols, ["rushing_tds","rush_tds"])
    rec      = pick_col(cols, ["receptions","rec"])
    rec_yds  = pick_col(cols, ["receiving_yards","rec_yards"])
    rec_td   = pick_col(cols, ["receiving_tds","rec_tds"])
    fum_lost = pick_col(cols, ["fumbles_lost"])

    # Kicking columns (may exist in combined player_stats; if not, they stay absent here)
    xpm = pick_col(cols, ["xpm","xp_made","extra_points_made"])
    xpa = pick_col(cols, ["xpa","xp_att","extra_points_attempted"])
    fgm = pick_col(cols, ["fgm","fg_made","field_goals_made"])
    fga = pick_col(cols, ["fga","fg_att","field_goals_attempted"])
    fgm_0_39    = pick_col(cols, ["fgm_0_39","fg_made_0_39"])
    fgm_40_49   = pick_col(cols, ["fgm_40_49","fg_made_40_49"])
    fgm_50_plus = pick_col(cols, ["fgm_50_plus","fg_made_50_plus","fg_made_50p"])

    required = [season_c, week_c, pid_c, name_c, pos_c]
    if any(c is None for c in required):
        raise RuntimeError(f"Missing required columns: {required}")

    keep = [c for c in [
        season_c, week_c, pid_c, name_c, pos_c, team_c, jersey_c,
        pass_yds, pass_td, ints, rush_yds, rush_td, rec, rec_yds, rec_td, fum_lost,
        xpm, xpa, fgm, fga, fgm_0_39, fgm_40_49, fgm_50_plus
    ] if c is not None]

    d = df[keep].copy()
    d.rename(columns={
        season_c:"season", week_c:"week", pid_c:"player_id", name_c:"player_name", pos_c:"position",
        team_c:"team", jersey_c:"jersey_number",
        pass_yds:"passing_yards", pass_td:"passing_tds", ints:"interceptions",
        rush_yds:"rushing_yards", rush_td:"rushing_tds",
        rec:"receptions", rec_yds:"receiving_yards", rec_td:"receiving_tds",
        fum_lost:"fumbles_lost",
        xpm:"xpm", xpa:"xpa", fgm:"fgm", fga:"fga",
        fgm_0_39:"fgm_0_39", fgm_40_49:"fgm_40_49", fgm_50_plus:"fgm_50_plus"
    }, inplace=True)

    d["position"] = d["position"].astype(str).str.upper().replace({"PK":"K"})
    d = d[d["position"].isin(["QB","RB","WR","TE","K"])].copy()

    # fill numeric
    for col in ["passing_yards","passing_tds","interceptions","rushing_yards","rushing_tds",
                "receptions","receiving_yards","receiving_tds","fumbles_lost",
                "xpm","xpa","fgm","fga","fgm_0_39","fgm_40_49","fgm_50_plus","jersey_number"]:
        if col not in d.columns:
            d[col] = 0
        d[col] = pd.to_numeric(d[col], errors="coerce").fillna(0).astype(int)

    rows = d.to_dict(orient="records")
    print("Upserting rows:", len(rows))

    for batch in chunker(rows, 500):
        sb.table("player_week_stats").upsert(batch, on_conflict="season,week,player_id").execute()

    print("Done players:", year_start, year_end)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python scripts/load_players_range.py 2010 2014")
        sys.exit(1)
    main(int(sys.argv[1]), int(sys.argv[2]))
