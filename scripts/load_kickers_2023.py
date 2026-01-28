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

    # nflreadpy mirrors nflreadr; kicking data is available via player stats.
    # Depending on nflreadpy version, stat_type may be accepted or deprecated.
    try:
        df = nfl.load_player_stats(seasons, stat_type="kicking").to_pandas()
    except TypeError:
        # If stat_type is deprecated and it returns all stats, filter to kickers
        df = nfl.load_player_stats(seasons).to_pandas()

    print("Loaded rows:", len(df))
    cols = df.columns.tolist()

    season_c = pick_col(cols, ["season", "year"])
    week_c   = pick_col(cols, ["week"])
    pid_c    = pick_col(cols, ["player_id", "gsis_id", "player_gsis_id"])
    name_c   = pick_col(cols, ["player_name", "name", "player_display_name"])
    pos_c    = pick_col(cols, ["position", "pos"])
    team_c   = pick_col(cols, ["team", "recent_team", "posteam"])
    jersey_c = pick_col(cols, ["jersey_number"])

    # Core kicking fields (names vary by dataset/version)
    xpm_c = pick_col(cols, ["xpm", "xp_made", "extra_points_made"])
    xpa_c = pick_col(cols, ["xpa", "xp_att", "extra_points_attempted"])
    fgm_c = pick_col(cols, ["fgm", "fg_made", "field_goals_made"])
    fga_c = pick_col(cols, ["fga", "fg_att", "field_goals_attempted"])

    # Optional distance buckets (if available)
    fgm_0_39_c   = pick_col(cols, ["fgm_0_39", "fg_made_0_39", "fgm_0_39_yards"])
    fgm_40_49_c  = pick_col(cols, ["fgm_40_49", "fg_made_40_49", "fgm_40_49_yards"])
    fgm_50_plus_c= pick_col(cols, ["fgm_50_plus", "fgm_50+", "fg_made_50_plus", "fg_made_50p"])

    required = [season_c, week_c, pid_c, name_c, pos_c]
    if any(c is None for c in required):
        raise RuntimeError(f"Missing required columns: {required}")

    keep = [c for c in [
        season_c, week_c, pid_c, name_c, pos_c, team_c, jersey_c,
        xpm_c, xpa_c, fgm_c, fga_c, fgm_0_39_c, fgm_40_49_c, fgm_50_plus_c
    ] if c is not None]

    d = df[keep].copy()
    d.rename(columns={
        season_c:"season", week_c:"week", pid_c:"player_id", name_c:"player_name", pos_c:"position",
        team_c:"team", jersey_c:"jersey_number",
        xpm_c:"xpm", xpa_c:"xpa", fgm_c:"fgm", fga_c:"fga",
        fgm_0_39_c:"fgm_0_39", fgm_40_49_c:"fgm_40_49", fgm_50_plus_c:"fgm_50_plus"
    }, inplace=True)

    d["position"] = d["position"].astype(str).str.upper().replace({"PK":"K"})
    # Keep only kickers
    d = d[d["position"].isin(["K"])].copy()

    # Fill missing stat columns with 0
    for col in ["xpm","xpa","fgm","fga","fgm_0_39","fgm_40_49","fgm_50_plus","jersey_number"]:
        if col not in d.columns:
            d[col] = 0
        d[col] = pd.to_numeric(d[col], errors="coerce").fillna(0).astype(int)

    rows = d.to_dict(orient="records")
    print("Kicker rows to upsert:", len(rows))

    for batch in chunker(rows, 500):
        sb.table("player_week_stats").upsert(batch, on_conflict="season,week,player_id").execute()

    print("Done.")

if __name__ == "__main__":
    main()
