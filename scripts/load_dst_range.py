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
    df = nfl.load_team_stats(years).to_pandas()
    print("Loaded team rows:", len(df))

    cols = df.columns.tolist()
    season_c = pick_col(cols, ["season","year"])
    week_c   = pick_col(cols, ["week"])
    team_c   = pick_col(cols, ["team","posteam"])

    if any(c is None for c in [season_c, week_c, team_c]):
        raise RuntimeError("Missing required team columns season/week/team")

    pa_c   = pick_col(cols, ["points_allowed","opp_points","points_against"])
    sacks_c= pick_col(cols, ["sacks","def_sacks"])
    int_c  = pick_col(cols, ["interceptions","def_int"])
    fr_c   = pick_col(cols, ["fumbles_recovered","fumble_recoveries","def_fumble_rec"])
    saf_c  = pick_col(cols, ["safeties","def_safeties"])
    td_c   = pick_col(cols, ["def_tds","defensive_tds","td_def"])
    blk_c  = pick_col(cols, ["blocked_kicks","blocks","def_blocks"])
    ret_c  = pick_col(cols, ["return_tds","td_ret"])

    keep = [c for c in [season_c, week_c, team_c, pa_c, sacks_c, int_c, fr_c, saf_c, td_c, blk_c, ret_c] if c is not None]
    t = df[keep].copy()
    t.rename(columns={
        season_c:"season", week_c:"week", team_c:"team",
        pa_c:"points_allowed", sacks_c:"sacks", int_c:"interceptions",
        fr_c:"fumbles_recovered", saf_c:"safeties", td_c:"def_tds",
        blk_c:"blocked_kicks", ret_c:"return_tds"
    }, inplace=True)

    for col in ["points_allowed","sacks","interceptions","fumbles_recovered","safeties","def_tds","blocked_kicks","return_tds"]:
        if col not in t.columns:
            t[col] = 0
        t[col] = pd.to_numeric(t[col], errors="coerce").fillna(0).astype(int)

    rows = t.to_dict(orient="records")
    print("Upserting rows:", len(rows))

    for batch in chunker(rows, 500):
        sb.table("team_week_stats").upsert(batch, on_conflict="season,week,team").execute()

    print("Done DST:", year_start, year_end)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python scripts/load_dst_range.py 2010 2014")
        sys.exit(1)
    main(int(sys.argv[1]), int(sys.argv[2]))
