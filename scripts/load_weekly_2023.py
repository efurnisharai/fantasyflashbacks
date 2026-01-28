import os
import pandas as pd
import nfl_data_py as nfl
from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
sb = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

def chunker(seq, n=500):
    for i in range(0, len(seq), n):
        yield seq[i:i+n]

def pick_col(df, candidates):
    for c in candidates:
        if c in df.columns:
            return c
    return None

def main():
    years = [2023]
    df = nfl.import_weekly_data(years)
    print("Imported rows:", len(df))
    print("Unique positions raw (sample):", sorted(set(df.get("position", pd.Series(dtype=str)).dropna().astype(str).str.upper().unique()))[:30])

    col_player_id   = pick_col(df, ["player_id", "gsis_id", "player_gsis_id"])
    col_player_name = pick_col(df, ["player_name", "name", "player_display_name"])
    col_pos         = pick_col(df, ["position", "pos"])
    col_team        = pick_col(df, ["recent_team", "team", "posteam"])
    col_jersey      = pick_col(df, ["jersey_number"])

    if not all([col_player_id, col_player_name, col_pos]):
        raise RuntimeError(f"Missing required columns: player_id={col_player_id}, name={col_player_name}, pos={col_pos}")

    col_map = {
        "season": "season",
        "week": "week",
        col_player_id: "player_id",
        col_player_name: "player_name",
        col_pos: "position",
    }
    if col_team: col_map[col_team] = "team"
    if col_jersey: col_map[col_jersey] = "jersey_number"

    stat_candidates = {
        "passing_yards": ["passing_yards", "pass_yards"],
        "passing_tds": ["passing_tds", "pass_tds"],
        "interceptions": ["interceptions", "pass_int"],
        "rushing_yards": ["rushing_yards", "rush_yards"],
        "rushing_tds": ["rushing_tds", "rush_tds"],
        "receptions": ["receptions", "rec"],
        "receiving_yards": ["receiving_yards", "rec_yards"],
        "receiving_tds": ["receiving_tds", "rec_tds"],
        "fumbles_lost": ["fumbles_lost"],
    }
    for target, cands in stat_candidates.items():
        c = pick_col(df, cands)
        if c:
            col_map[c] = target

    df2 = df[list(col_map.keys())].rename(columns=col_map)

    # Normalize positions and KEEP kickers:
    df2["position"] = df2["position"].astype(str).str.upper().replace({"PK": "K"})

    # Keep fantasy positions (K included)
    df2 = df2[df2["position"].isin(["QB", "RB", "WR", "TE", "K"])].copy()

    print("Unique positions after filter:", sorted(df2["position"].unique().tolist()))
    print("Rows after filter:", len(df2))

    # Normalize numeric columns
    for c in df2.columns:
        if c in ["player_id", "player_name", "position", "team"]:
            continue
        df2[c] = pd.to_numeric(df2[c], errors="coerce").fillna(0).astype(int)

    rows = df2.to_dict(orient="records")

    for batch in chunker(rows, 500):
        sb.table("player_week_stats").upsert(batch, on_conflict="season,week,player_id").execute()

    print("Upserted rows:", len(rows))
    print("Done.")

if __name__ == "__main__":
    main()
