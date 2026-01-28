import os
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

def main():
    seasons = [2023]
    df = nfl.load_team_stats(seasons).to_pandas()
    print("Loaded team rows:", len(df))

    cols = df.columns.tolist()
    season_c = pick_col(cols, ["season", "year"])
    week_c   = pick_col(cols, ["week"])
    team_c   = pick_col(cols, ["team", "posteam"])

    if any(c is None for c in [season_c, week_c, team_c]):
        raise RuntimeError(f"Missing required columns season/week/team. Got: {season_c}, {week_c}, {team_c}")

    # Try common names; if missing, we fill with 0
    pa_c   = pick_col(cols, ["points_allowed", "opp_points", "points_against"])
    sacks_c= pick_col(cols, ["sacks", "def_sacks"])
    int_c  = pick_col(cols, ["interceptions", "def_int"])
    fr_c   = pick_col(cols, ["fumbles_recovered", "fumble_recoveries", "def_fumble_rec"])
    saf_c  = pick_col(cols, ["safeties", "def_safeties"])
    td_c   = pick_col(cols, ["def_tds", "defensive_tds", "td_def"])
    blk_c  = pick_col(cols, ["blocked_kicks", "blocks", "def_blocks"])
    ret_c  = pick_col(cols, ["return_tds", "td_ret"])

    keep = [c for c in [season_c, week_c, team_c, pa_c, sacks_c, int_c, fr_c, saf_c, td_c, blk_c, ret_c] if c is not None]
    t = df[keep].copy()

    t.rename(columns={
        season_c: "season",
        week_c: "week",
        team_c: "team",
        pa_c: "points_allowed",
        sacks_c: "sacks",
        int_c: "interceptions",
        fr_c: "fumbles_recovered",
        saf_c: "safeties",
        td_c: "def_tds",
        blk_c: "blocked_kicks",
        ret_c: "return_tds",
    }, inplace=True)

    # Ensure all needed columns exist
    for c in ["points_allowed","sacks","interceptions","fumbles_recovered","safeties","def_tds","blocked_kicks","return_tds"]:
        if c not in t.columns:
            t[c] = 0
        t[c] = pd.to_numeric(t[c], errors="coerce").fillna(0).astype(int)

    rows = t.to_dict(orient="records")
    print("Rows to upsert:", len(rows))

    for batch in chunker(rows, 500):
        sb.table("team_week_stats").upsert(batch, on_conflict="season,week,team").execute()

    print("Done.")

if __name__ == "__main__":
    main()
