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
    df = nfl.load_schedules(years).to_pandas()
    print("Loaded schedule rows:", len(df))

    cols = df.columns.tolist()
    season_c = pick_col(cols, ["season","year"])
    week_c   = pick_col(cols, ["week"])
    home_c   = pick_col(cols, ["home_team"])
    away_c   = pick_col(cols, ["away_team"])
    hs_c     = pick_col(cols, ["home_score"])
    as_c     = pick_col(cols, ["away_score"])
    gid_c    = pick_col(cols, ["game_id","gsis_id"])

    if any(c is None for c in [season_c, week_c, home_c, away_c, hs_c, as_c]):
        raise RuntimeError("Missing required schedule columns")

    d = df[[c for c in [season_c, week_c, home_c, away_c, hs_c, as_c, gid_c] if c is not None]].copy()
    d.rename(columns={
        season_c:"season", week_c:"week",
        home_c:"home_team", away_c:"away_team",
        hs_c:"home_score", as_c:"away_score",
        gid_c:"game_id"
    }, inplace=True)

    d = d.dropna(subset=["home_score","away_score"])
    d["home_score"] = pd.to_numeric(d["home_score"], errors="coerce").fillna(0).astype(int)
    d["away_score"] = pd.to_numeric(d["away_score"], errors="coerce").fillna(0).astype(int)

    rows = []
    for _, r in d.iterrows():
        season = int(r["season"])
        week = int(r["week"])
        home = str(r["home_team"]).upper()
        away = str(r["away_team"]).upper()
        hs = int(r["home_score"])
        ays = int(r["away_score"])
        gid = str(r["game_id"]) if "game_id" in r and pd.notna(r["game_id"]) else None

        rows.append({"season":season,"week":week,"team":home,"opponent":away,"team_score":hs,"opp_score":ays,"is_home":True,"game_id":gid})
        rows.append({"season":season,"week":week,"team":away,"opponent":home,"team_score":ays,"opp_score":hs,"is_home":False,"game_id":gid})

    print("Upserting matchup rows:", len(rows))
    for batch in chunker(rows, 500):
        sb.table("team_week_matchups").upsert(batch, on_conflict="season,week,team").execute()

    print("Done matchups:", year_start, year_end)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python scripts/load_matchups_range.py 2010 2014")
        sys.exit(1)
    main(int(sys.argv[1]), int(sys.argv[2]))
