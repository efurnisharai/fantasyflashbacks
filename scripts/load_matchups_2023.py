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

    # nflreadpy mirrors nflreadr; schedules contain home/away + scores
    df = nfl.load_schedules(seasons).to_pandas()
    print("Schedule rows:", len(df))

    cols = df.columns.tolist()
    season_c = pick_col(cols, ["season", "year"])
    week_c   = pick_col(cols, ["week"])
    home_c   = pick_col(cols, ["home_team"])
    away_c   = pick_col(cols, ["away_team"])
    hscore_c = pick_col(cols, ["home_score"])
    ascore_c = pick_col(cols, ["away_score"])
    gid_c    = pick_col(cols, ["game_id", "gsis_id"])

    if any(c is None for c in [season_c, week_c, home_c, away_c, hscore_c, ascore_c]):
        raise RuntimeError("Missing required schedule columns (season/week/home/away/scores).")

    # Keep only rows with completed scores (regular season)
    d = df[[c for c in [season_c, week_c, home_c, away_c, hscore_c, ascore_c, gid_c] if c is not None]].copy()
    d.rename(columns={
        season_c: "season",
        week_c: "week",
        home_c: "home_team",
        away_c: "away_team",
        hscore_c: "home_score",
        ascore_c: "away_score",
        gid_c: "game_id",
    }, inplace=True)

    # Drop games without final scores
    d = d.dropna(subset=["home_score", "away_score"])

    # Convert scores to ints
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

        # home perspective
        rows.append({
            "season": season, "week": week, "team": home, "opponent": away,
            "team_score": hs, "opp_score": ays, "is_home": True, "game_id": gid
        })
        # away perspective
        rows.append({
            "season": season, "week": week, "team": away, "opponent": home,
            "team_score": ays, "opp_score": hs, "is_home": False, "game_id": gid
        })

    print("Team-week matchup rows to upsert:", len(rows))

    for batch in chunker(rows, 500):
        sb.table("team_week_matchups").upsert(batch, on_conflict="season,week,team").execute()

    print("Done.")

if __name__ == "__main__":
    main()
