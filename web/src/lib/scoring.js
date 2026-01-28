const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

export const SCORING_PRESETS = {
  standard: { reception: 0 },
  "half-ppr": { reception: 0.5 },
  ppr: { reception: 1 },
};

export const DEFAULT_RULES = {
  passing: { yardsPerPoint: 25, td: 4, interception: -2 },
  rushing: { yardsPerPoint: 10, td: 6 },
  receiving: { yardsPerPoint: 10, td: 6 },
  fumbleLost: -2,
  twoPoint: 2,

  kicker: {
    xpMade: 1,
    xpMiss: -1,
    fg_0_39: 3,
    fg_40_49: 4,
    fg_50_plus: 5,
    fgMiss: -1,
    fgAny: 3,
  },

  // ESPN-style DST with 10 base points + PA tiers
  dst: {
    base: 10,
    sack: 1,
    interception: 2,
    fumbleRecovered: 2,
    safety: 2,
    defTd: 6,
    returnTd: 6,
    blockedKick: 2,
    pointsAllowedTiers: [
      { min: 0, max: 0, pts: 10 },      // 0 PA
      { min: 1, max: 6, pts: 7 },       // 1–6
      { min: 7, max: 13, pts: 4 },      // 7–13
      { min: 14, max: 20, pts: 1 },     // 14–20
      { min: 21, max: 27, pts: 0 },     // 21–27
      { min: 28, max: 34, pts: -1 },    // 28–34
      { min: 35, max: Infinity, pts: -4 }, // 35+
    ],
  },
};

export function scorePlayerRow(row, scoringPreset = "standard", rulesOverride = {}) {
  const rules = {
    ...DEFAULT_RULES,
    ...rulesOverride,
    passing: { ...DEFAULT_RULES.passing, ...(rulesOverride.passing || {}) },
    rushing: { ...DEFAULT_RULES.rushing, ...(rulesOverride.rushing || {}) },
    receiving: { ...DEFAULT_RULES.receiving, ...(rulesOverride.receiving || {}) },
    kicker: { ...DEFAULT_RULES.kicker, ...(rulesOverride.kicker || {}) },
  };

  const pos = (row?.position || "").toUpperCase();
  const recPts = SCORING_PRESETS[scoringPreset]?.reception ?? 0;

  const passYds = num(row?.passing_yards);
  const passTD = num(row?.passing_tds);
  const ints = num(row?.interceptions);

  const rushYds = num(row?.rushing_yards);
  const rushTD = num(row?.rushing_tds);

  const rec = num(row?.receptions);
  const recYds = num(row?.receiving_yards);
  const recTD = num(row?.receiving_tds);

  const fumLost = num(row?.fumbles_lost);

  const pass2pt = num(row?.passing_2pt_conversions ?? row?.passing_two_point_conversions);
  const rush2pt = num(row?.rushing_2pt_conversions ?? row?.rushing_two_point_conversions);
  const rec2pt = num(row?.receiving_2pt_conversions ?? row?.receiving_two_point_conversions);

  const passPts =
    passYds / rules.passing.yardsPerPoint +
    passTD * rules.passing.td +
    ints * rules.passing.interception;

  const rushPts = rushYds / rules.rushing.yardsPerPoint + rushTD * rules.rushing.td;

  const recvPts =
    recYds / rules.receiving.yardsPerPoint + recTD * rules.receiving.td + rec * recPts;

  const fumPts = fumLost * rules.fumbleLost;
  const twoPtPts = (pass2pt + rush2pt + rec2pt) * rules.twoPoint;

  const xpm = num(row?.xpm ?? row?.xp_made ?? row?.extra_points_made);
  const xpa = num(row?.xpa ?? row?.xp_att ?? row?.extra_points_attempted);
  const fgm = num(row?.fgm ?? row?.fg_made ?? row?.field_goals_made);
  const fga = num(row?.fga ?? row?.fg_att ?? row?.field_goals_attempted);

  const fgm_0_39 = num(row?.fgm_0_39 ?? row?.fg_made_0_39);
  const fgm_40_49 = num(row?.fgm_40_49 ?? row?.fg_made_40_49);
  const fgm_50 = num(row?.fgm_50_plus ?? row?.fgm_50 ?? row?.fg_made_50_plus ?? row?.fg_made_50);

  const fgMisses = Math.max(0, fga - fgm);
  const xpMisses = Math.max(0, xpa - xpm);

  let points = 0;
  let breakdown = {};

  if (pos === "QB") {
    points = passPts + rushPts + recvPts + fumPts + twoPtPts;
    breakdown = { PASS: passPts, RUSH: rushPts, RECV: recvPts, FUM_L: fumPts, TWO_PT: twoPtPts };
  } else if (pos === "RB" || pos === "WR" || pos === "TE") {
    points = rushPts + recvPts + fumPts + twoPtPts;
    breakdown = { RUSH: rushPts, RECV: recvPts, FUM_L: fumPts, TWO_PT: twoPtPts };
  } else if (pos === "K" || pos === "PK") {
    const fgPts =
      (fgm_0_39 || fgm_40_49 || fgm_50)
        ? fgm_0_39 * rules.kicker.fg_0_39 +
          fgm_40_49 * rules.kicker.fg_40_49 +
          fgm_50 * rules.kicker.fg_50_plus
        : fgm * rules.kicker.fgAny;

    const xpPts = xpm * rules.kicker.xpMade;
    const missPts = fgMisses * rules.kicker.fgMiss + xpMisses * rules.kicker.xpMiss;

    points = fgPts + xpPts + missPts;
    breakdown = { FG: fgPts, XP: xpPts, MISSES: missPts };
  } else {
    points = 0;
    breakdown = {};
  }

  return { points: Math.round(points * 100) / 100, breakdown };
}

function pointsAllowedBucket(pa, tiers) {
  const p = Number.isFinite(pa) ? pa : 0;
  for (const t of tiers) {
    if (p >= t.min && p <= t.max) return t.pts;
  }
  // fallback
  return -4;
}

// ESPN DST scoring.
// IMPORTANT: pass opts.pointsAllowed (e.g., matchup.opp_score) to avoid broken points_allowed columns.
export function scoreDstRow(teamRow, opts = {}) {
  const rules = { ...DEFAULT_RULES.dst, ...(opts.rules || {}) };

  // Use matchup override when provided; fall back to team_row if it ever becomes reliable.
  const paRaw = opts.pointsAllowed;
  const pa =
    Number.isFinite(Number(paRaw))
      ? Number(paRaw)
      : Number.isFinite(Number(teamRow?.points_allowed))
        ? Number(teamRow.points_allowed)
        : null;

  const sacks = num(teamRow?.sacks);
  const interceptions = num(teamRow?.interceptions);
  const fumblesRecovered = num(teamRow?.fumbles_recovered);
  const safeties = num(teamRow?.safeties);
  const defTds = num(teamRow?.def_tds);
  const returnTds = num(teamRow?.return_tds);
  const blockedKicks = num(teamRow?.blocked_kicks);

  // ESPN PA tiers are TOTAL points for the PA component (10,7,4,1,0,-1,-4)
  // We keep rules.base as 10 and apply an adjustment so the PA tier replaces the base.
  const base = Number.isFinite(Number(rules.base)) ? Number(rules.base) : 10;
  const paTier = pointsAllowedBucket(Number.isFinite(pa) ? pa : 0, rules.pointsAllowedTiers);
  const paAdj = paTier - base;

  const points =
    base +
    sacks * rules.sack +
    interceptions * rules.interception +
    fumblesRecovered * rules.fumbleRecovered +
    safeties * rules.safety +
    defTds * rules.defTd +
    returnTds * rules.returnTd +
    blockedKicks * rules.blockedKick +
    paAdj;

  const breakdown = {
    BASE: base,
    SACKS: sacks * rules.sack,
    INTERCEPTIONS: interceptions * rules.interception,
    FUMBLES_RECOVERED: fumblesRecovered * rules.fumbleRecovered,
    SAFETIES: safeties * rules.safety,
    TOUCHDOWNS: defTds * rules.defTd + returnTds * rules.returnTd,
    BLOCKED_KICKS: blockedKicks * rules.blockedKick,
    POINTS_ALLOWED_ADJ: paAdj,     // this is what actually adjusts base->tier
    POINTS_ALLOWED_TIER: paTier,   // readable tier value (10/7/4/1/0/-1/-4)
    _PA_VALUE: Number.isFinite(pa) ? pa : null,
  };

  return { points: Math.round(points * 100) / 100, breakdown };
}