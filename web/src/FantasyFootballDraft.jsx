// src/FantasyFootballDraft.jsx
import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  Users,
  Trophy,
  Clock,
  Copy,
  Check,
  Search,
  AlertCircle,
  X,
  Link as LinkIcon,
  Star,
  Share2,
  ChevronDown,
  Flame,
  Zap,
  TrendingUp,
  Gift,
} from "lucide-react";
import { supabase } from "./lib/supabaseClient";
import { scorePlayerRow, scoreDstRow } from "./lib/scoring";
import { hapticLight, hapticMedium, hapticSuccess, hapticError, shareInvite, isNative } from "./utils/native";

const NFL_TEAMS = {
  ARI: { primary: "#97233F", secondary: "#000000" },
  ATL: { primary: "#A71930", secondary: "#000000" },
  BAL: { primary: "#241773", secondary: "#000000" },
  BUF: { primary: "#00338D", secondary: "#C60C30" },
  CAR: { primary: "#0085CA", secondary: "#101820" },
  CHI: { primary: "#C83803", secondary: "#0B162A" },
  CIN: { primary: "#FB4F14", secondary: "#000000" },
  CLE: { primary: "#311D00", secondary: "#FF3C00" },
  DAL: { primary: "#003594", secondary: "#869397" },
  DEN: { primary: "#FB4F14", secondary: "#002244" },
  DET: { primary: "#0076B6", secondary: "#B0B7BC" },
  GB: { primary: "#203731", secondary: "#FFB612" },
  HOU: { primary: "#03202F", secondary: "#A71930" },
  IND: { primary: "#002C5F", secondary: "#A2AAAD" },
  JAX: { primary: "#006778", secondary: "#D7A22A" },
  KC: { primary: "#E31837", secondary: "#FFB81C" },
  LV: { primary: "#000000", secondary: "#A5ACAF" },
  LAC: { primary: "#0080C6", secondary: "#FFC20E" },
  LAR: { primary: "#003594", secondary: "#FFA300" },
  MIA: { primary: "#008E97", secondary: "#FC4C02" },
  MIN: { primary: "#4F2683", secondary: "#FFC62F" },
  NE: { primary: "#002244", secondary: "#C60C30" },
  NO: { primary: "#D3BC8D", secondary: "#101820" },
  NYG: { primary: "#0B2265", secondary: "#A71930" },
  NYJ: { primary: "#125740", secondary: "#000000" },
  PHI: { primary: "#004C54", secondary: "#A5ACAF" },
  PIT: { primary: "#FFB612", secondary: "#101820" },
  SF: { primary: "#AA0000", secondary: "#B3995D" },
  SEA: { primary: "#002244", secondary: "#69BE28" },
  TB: { primary: "#D50A0A", secondary: "#FF7900" },
  TEN: { primary: "#0C2340", secondary: "#4B92DB" },
  WAS: { primary: "#5A1414", secondary: "#FFB612" },
  // Historical / relocated teams
  STL: { primary: "#002244", secondary: "#C9B074" },  // St. Louis Rams
  SD:  { primary: "#002A5E", secondary: "#FFC20E" },  // San Diego Chargers
  OAK: { primary: "#000000", secondary: "#A5ACAF" },  // Oakland Raiders
};

const NFL_TEAM_ABBRS = Object.keys(NFL_TEAMS).sort();

const POSITION_COLORS = {
  QB: { bg: "bg-red-900/50", border: "border-red-500", text: "text-red-400" },
  RB: { bg: "bg-green-900/50", border: "border-green-500", text: "text-green-400" },
  WR: { bg: "bg-blue-900/50", border: "border-blue-500", text: "text-blue-400" },
  TE: { bg: "bg-yellow-900/50", border: "border-yellow-500", text: "text-yellow-400" },
  FLEX: { bg: "bg-purple-900/50", border: "border-purple-500", text: "text-purple-400" },
  K: { bg: "bg-orange-900/50", border: "border-orange-500", text: "text-orange-400" },
  DST: { bg: "bg-cyan-900/50", border: "border-cyan-500", text: "text-cyan-400" },
};

const normalizeTeam = (team) => {
  if (!team) return null;
  const t = String(team).toUpperCase().trim();
  const map = { LA: "LAR", JAC: "JAX", WSH: "WAS", BLT: "BAL", ARZ: "ARI", CLV: "CLE", HST: "HOU", SL: "STL" };
  return map[t] || t;
};

const normalizePos = (pos) => {
  const p = String(pos || "").toUpperCase();
  return p === "PK" ? "K" : p;
};

const PROFILE_EMOJIS = [
  "\u{1F3C8}","\u26A1","\u{1F525}","\u{1F3C6}","\u{1F985}","\u{1F43B}","\u{1F981}","\u{1F42F}","\u{1F42C}","\u{1F40E}",
  "\u{1F9AC}","\u{1F43A}","\u{1F417}","\u{1F99C}","\u{1F427}","\u{1F988}","\u{1F40A}","\u{1F9A9}","\u{1F41D}","\u{1F409}",
  "\u{1F451}","\u{1F48E}","\u2B50","\u{1F3AF}","\u{1F4AA}","\u{1F3AE}","\u{1F680}","\u{1F480}","\u{1F916}","\u{1F47D}",
];

const genRoomCode = () => Math.random().toString(36).substring(2, 8).toUpperCase();
const clampWeek = (w) => Math.max(1, Math.min(17, Number(w || 1)));
const safeMsg = (e) =>
  e?.message || e?.error_description || (typeof e === "string" ? e : null) || JSON.stringify(e);

const toMs = (ts) => {
  if (!ts) return null;
  const t = new Date(ts).getTime();
  return Number.isFinite(t) ? t : null;
};

const nowIso = () => new Date().toISOString();

const isStale = (ts, maxAgeMs) => {
  const ms = toMs(ts);
  if (!ms) return true;
  return Date.now() - ms > maxAgeMs;
};

const hashSettingsForMatchmaking = (s) => {
  const pick = {
    qbSlots: s.qbSlots,
    rbSlots: s.rbSlots,
    wrSlots: s.wrSlots,
    teSlots: s.teSlots,
    flexSlots: s.flexSlots,
    kSlots: s.kSlots,
    dstSlots: s.dstSlots,
    yearStart: s.yearStart,
    yearEnd: s.yearEnd,
    scoring: s.scoring,
    passTdPoints: s.passTdPoints,
    pickTime: s.pickTime,
    maxPlayers: s.maxPlayers,
    snakeDraft: !!s.snakeDraft,
  };
  return JSON.stringify(pick);
};

export default function FantasyFootballDraft() {
  const [screen, setScreen] = useState("setup");

  const [gameSettings, setGameSettings] = useState({
    qbSlots: 1,
    rbSlots: 2,
    wrSlots: 2,
    teSlots: 1,
    flexSlots: 1,
    kSlots: 1,
    dstSlots: 1,
    yearStart: 2010,
    yearEnd: 2025,
    difficulty: "easy",
    scoring: "standard",
    pickTime: 30,
    passTdPoints: 4,

    maxPlayers: 2,
    joinMode: "code",
    autoStartWhenFull: true,
    lobbyMode: "fixed", // "fixed" = wait for exact player count, "open" = start with 2+ players
    gameMode: "multiplayer", // "multiplayer" or "solo"

    // Only applicable when maxPlayers >= 3. For 2 players, server should always run alternating.
    snakeDraft: true,
  });

  const [notice, setNotice] = useState("");
  const noticeTimerRef = useRef(null);
  const flashNotice = (msg) => {
    if (noticeTimerRef.current) clearTimeout(noticeTimerRef.current);
    setNotice(msg || "");
    if (msg) {
      noticeTimerRef.current = setTimeout(() => setNotice(""), 1500);
    }
  };

  const rosterSlots = useMemo(() => {
    const s = [];
    for (let i = 0; i < gameSettings.qbSlots; i++) s.push("QB");
    for (let i = 0; i < gameSettings.rbSlots; i++) s.push("RB");
    for (let i = 0; i < gameSettings.wrSlots; i++) s.push("WR");
    for (let i = 0; i < gameSettings.teSlots; i++) s.push("TE");
    for (let i = 0; i < gameSettings.flexSlots; i++) s.push("FLEX");
    for (let i = 0; i < gameSettings.kSlots; i++) s.push("K");
    for (let i = 0; i < gameSettings.dstSlots; i++) s.push("DST");
    return s;
  }, [gameSettings]);

  const rosterSize = rosterSlots.length;

  const [busy, setBusy] = useState(false);
  const [draftBusy, setDraftBusy] = useState(false);

  const [userId, setUserId] = useState(null);
  const [gameId, setGameId] = useState(null);
  const [mySeat, setMySeat] = useState(null);

  const [roomCode, setRoomCode] = useState("");
  const [playerName, setPlayerName] = useState("");

  const [players, setPlayers] = useState([]);
  const [gameWeek, setGameWeek] = useState(null);

  const [turnUserId, setTurnUserId] = useState(null);
  const [pickNumber, setPickNumber] = useState(1);
  const [isMyTurn, setIsMyTurn] = useState(false);

  const [turnDeadlineAtMs, setTurnDeadlineAtMs] = useState(null);
  const [timeRemaining, setTimeRemaining] = useState(gameSettings.pickTime);

  const [weeklyRoster, setWeeklyRoster] = useState([]);
  const [draftedPlayerIds, setDraftedPlayerIds] = useState(new Set());

  const [teamsByUser, setTeamsByUser] = useState({});

  const [posFilter, setPosFilter] = useState("ALL");
  const [teamFilter, setTeamFilter] = useState("ALL");
  const [teamDropdownOpen, setTeamDropdownOpen] = useState(false);
  const [teamSearchQuery, setTeamSearchQuery] = useState("");
  const [searchQuery, setSearchQuery] = useState("");
  const [searchLimit, setSearchLimit] = useState(25);
  const [searchingMore, setSearchingMore] = useState(false);
  const [searchTotal, setSearchTotal] = useState(0);
  const [searchResults, setSearchResults] = useState([]);

  const [pinnedByPos, setPinnedByPos] = useState({});
  const pinsFor = (pos) => (pinnedByPos[pos] || []).filter((id) => !draftedPlayerIds.has(id));

  const [loadingStats, setLoadingStats] = useState(false);
  const [resultsByUser, setResultsByUser] = useState({});
  const [weeklyRankInfoById, setWeeklyRankInfoById] = useState({});
  const [globalBestLineup, setGlobalBestLineup] = useState(null);

  const [copied, setCopied] = useState(false);
  const [inviteRoom, setInviteRoom] = useState(null);
  const [matchmakingStatus, setMatchmakingStatus] = useState("");
  const [draftView, setDraftView] = useState("SEARCH");

  const [shareCopied, setShareCopied] = useState(false);

  // Rematch state
  const [rematchRequested, setRematchRequested] = useState(false);
  const [rematchStatus, setRematchStatus] = useState({ ready: 0, total: 0 });
  const [rematchPending, setRematchPending] = useState(false);

  // User profile state
  const [userProfile, setUserProfile] = useState(null);
  const [isAnonymous, setIsAnonymous] = useState(true);
  const [showSignIn, setShowSignIn] = useState(false);
  const [editingName, setEditingName] = useState(false);
  const [editNameValue, setEditNameValue] = useState("");
  const [showEmojiPicker, setShowEmojiPicker] = useState(false);

  // Engagement system state
  const [engagementStats, setEngagementStats] = useState(null);
  const [userBadges, setUserBadges] = useState([]);
  const [lastGameFpEarned, setLastGameFpEarned] = useState(null); // FP earned in the most recent game

  // Friends system state
  const [friendsList, setFriendsList] = useState([]);
  const [friendRequests, setFriendRequests] = useState([]);
  const [sentRequests, setSentRequests] = useState([]);
  const [recentPlayers, setRecentPlayers] = useState([]);
  const [showFriendsModal, setShowFriendsModal] = useState(false);
  const [friendsTab, setFriendsTab] = useState("friends"); // "friends", "requests", "add"
  const [friendSearchId, setFriendSearchId] = useState("");
  const [friendSearchResult, setFriendSearchResult] = useState(null);
  const [friendSearchError, setFriendSearchError] = useState("");
  const [btnConfirm, setBtnConfirm] = useState(null); // inline button confirmation key

  // Daily challenge state
  const [dailyChallenge, setDailyChallenge] = useState(null);
  const [challengeTimeLeft, setChallengeTimeLeft] = useState("");

  // Referral system state
  const [referralStats, setReferralStats] = useState(null);
  const [showReferralModal, setShowReferralModal] = useState(false);
  const [referralCodeInput, setReferralCodeInput] = useState("");
  const [referralApplyResult, setReferralApplyResult] = useState(null);

  // Skill rating state
  const [skillRating, setSkillRating] = useState(null);

  // Friends leaderboard state
  const [friendsLeaderboard, setFriendsLeaderboard] = useState([]);

  const rosterLoadedRef = useRef(false);
  const resultsComputedRef = useRef(false);
  const autoPickInFlightRef = useRef(false);
  const lastAutoPickTryRef = useRef({ gameId: null, pickNumber: null });
  const teamDropdownRef = useRef(null);

  // Keep the throttle, but NEVER use alert/popups for it.
  const lastActionAtRef = useRef({ create: 0, join: 0, match: 0 });
  const canDoAction = (kind, ms = 900) => {
    const now = Date.now();
    const last = lastActionAtRef.current[kind] || 0;
    if (now - last < ms) return false;
    lastActionAtRef.current[kind] = now;
    return true;
  };

  // INVITE auto-join refs (debounced so it doesn't fire after 1 character)
  const inviteAutoJoinRef = useRef(false);
  const inviteDebounceRef = useRef(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const room = params.get("room");
    if (room) {
      const code = room.toUpperCase();
      setInviteRoom(code);
      setRoomCode(code);
      setGameSettings((p) => ({ ...p, joinMode: "code" }));
      setScreen("setup");
    }
  }, []);

  // Close team dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (e) => {
      if (teamDropdownRef.current && !teamDropdownRef.current.contains(e.target)) {
        setTeamDropdownOpen(false);
      }
    };
    if (teamDropdownOpen) {
      document.addEventListener("mousedown", handleClickOutside);
      return () => document.removeEventListener("mousedown", handleClickOutside);
    }
  }, [teamDropdownOpen]);

  const effectiveMaxPlayers = useMemo(() => {
    const n = Number(gameSettings.maxPlayers || 2);
    return Math.max(2, Math.min(12, n));
  }, [gameSettings.maxPlayers]);

  // Snake draft UI/setting rules:
// - 2 players: snake is not available (effective OFF), but we do NOT mutate state
// - 3+ players: allow toggle; default can remain true in initial state
const snakeAllowed = effectiveMaxPlayers >= 3;
const snakeDraftToSend = snakeAllowed ? !!gameSettings.snakeDraft : false;
const snakeChecked = snakeDraftToSend; // use this for the checkbox "checked" prop

  const activePlayers = useMemo(() => {
    const STALE_MS = 90000;
    return (players || []).map((p) => {
      const stale = isStale(p.last_seen, STALE_MS);
      const active = p.is_active !== false && !stale;
      return { ...p, _activeEffective: active, _stale: stale };
    });
  }, [players]);

  const inactivePlayers = useMemo(() => activePlayers.filter((p) => !p._activeEffective), [activePlayers]);

  const ensureAnonUser = async () => {
    const { data: sess } = await supabase.auth.getSession();
    const existing = sess?.session?.user?.id;
    if (existing) return existing;
    const { data, error } = await supabase.auth.signInAnonymously();
    if (error) throw error;
    return data.user.id;
  };

  const rpc = async (fn, args) => {
    const { data, error } = await supabase.rpc(fn, args);
    if (error) throw error;
    return data;
  };

  // Fetch user profile
  const fetchProfile = async (uid, fallbackName = null) => {
    try {
      const { data, error } = await supabase
        .from("user_profiles")
        .select("*")
        .eq("id", uid)
        .single();
      if (error && error.code !== "PGRST116") throw error; // PGRST116 = not found
      if (data) {
        setUserProfile(data);
        // Use profile's display_name if available, otherwise fall back to Google/Apple name
        if (data.display_name) {
          setPlayerName(data.display_name);
        } else if (fallbackName) {
          setPlayerName(fallbackName);
        }
      } else if (fallbackName) {
        setPlayerName(fallbackName);
      }
      // Also fetch engagement stats
      fetchEngagementStats(uid);
    } catch (e) {
      console.warn("Failed to fetch profile:", e);
      if (fallbackName) setPlayerName(fallbackName);
    }
  };

  const RARITY_COLORS = {
    common: "from-slate-500 to-slate-600 border-slate-400",
    uncommon: "from-emerald-600 to-emerald-700 border-emerald-400",
    rare: "from-blue-600 to-blue-700 border-blue-400",
    epic: "from-purple-600 to-purple-700 border-purple-400",
    legendary: "from-amber-500 to-orange-600 border-amber-400",
    mythic: "from-pink-500 via-purple-500 to-cyan-500 border-pink-400 animate-pulse",
  };

  // Fetch engagement stats (Flashback Points, tier, streak, etc.)
  const fetchEngagementStats = async (uid) => {
    try {
      const data = await rpc("ff_get_engagement_stats", { p_user_id: uid });
      if (data && data.length > 0) {
        setEngagementStats(data[0]);
      } else if (data) {
        setEngagementStats(data);
      }
    } catch (e) {
      console.warn("Failed to fetch engagement stats:", e);
    }
  };

  // Fetch user badges
  const fetchUserBadges = async (uid) => {
    try {
      const data = await rpc("ff_get_user_badges", { p_user_id: uid });
      if (data && Array.isArray(data)) {
        setUserBadges(data);
      }
    } catch (e) {
      console.warn("Failed to fetch user badges:", e);
    }
  };

  // Fetch friends list
  const fetchFriends = async (uid) => {
    try {
      // Fetch accepted friends
      const data = await rpc("ff_get_friends", { p_user_id: uid });
      if (data && Array.isArray(data)) {
        setFriendsList(data);
      }
      // Fetch incoming friend requests directly from table
      const { data: incomingData } = await supabase
        .from("friendships")
        .select("id, user_id, friend_id, created_at")
        .eq("friend_id", uid)
        .eq("status", "pending");
      if (incomingData && incomingData.length > 0) {
        const senderIds = incomingData.map(r => r.user_id);
        const { data: senderProfiles } = await supabase
          .from("user_profiles")
          .select("id, display_name, flashback_id, avatar_url")
          .in("id", senderIds);
        const senderMap = {};
        (senderProfiles || []).forEach(p => { senderMap[p.id] = p; });
        setFriendRequests(incomingData.map(r => ({
          ...r,
          sender_user_id: r.user_id,
          display_name: senderMap[r.user_id]?.display_name || "Unknown",
          flashback_id: senderMap[r.user_id]?.flashback_id || "",
          avatar_url: senderMap[r.user_id]?.avatar_url || null,
        })));
      } else {
        setFriendRequests([]);
      }
      // Fetch outgoing sent requests
      const { data: sentData } = await supabase
        .from("friendships")
        .select("id, friend_id, created_at")
        .eq("user_id", uid)
        .eq("status", "pending");
      if (sentData && sentData.length > 0) {
        // Look up display names for sent requests
        const friendIds = sentData.map(s => s.friend_id);
        const { data: profiles } = await supabase
          .from("user_profiles")
          .select("id, display_name, flashback_id, avatar_url")
          .in("id", friendIds);
        const profileMap = {};
        (profiles || []).forEach(p => { profileMap[p.id] = p; });
        setSentRequests(sentData.map(s => ({
          ...s,
          display_name: profileMap[s.friend_id]?.display_name || "Unknown",
          flashback_id: profileMap[s.friend_id]?.flashback_id || "",
          avatar_url: profileMap[s.friend_id]?.avatar_url || null,
        })));
      } else {
        setSentRequests([]);
      }
    } catch (e) {
      console.warn("Failed to fetch friends:", e);
    }
  };

  // Fetch recent players
  const fetchRecentPlayers = async (uid) => {
    try {
      const data = await rpc("ff_get_recent_players", { p_user_id: uid, p_limit: 10 });
      if (data && Array.isArray(data)) {
        setRecentPlayers(data);
      }
    } catch (e) {
      console.warn("Failed to fetch recent players:", e);
    }
  };

  // Fetch skill rating
  const fetchSkillRating = async (uid) => {
    try {
      const data = await rpc("ff_calculate_skill_rating", { p_user_id: uid });
      console.log("Skill rating data:", data);
      if (data && data.length > 0) {
        setSkillRating(data[0]);
      } else if (data && typeof data.skill_score !== "undefined") {
        setSkillRating(data);
      } else {
        // Set default values if no data returned
        setSkillRating({ skill_score: 0, win_rate: 0, avg_margin: 0, avg_opponents: 2, games_rated: 0 });
      }
    } catch (e) {
      console.warn("Failed to fetch skill rating:", e);
      // Set default values on error so the section still shows
      setSkillRating({ skill_score: 0, win_rate: 0, avg_margin: 0, avg_opponents: 2, games_rated: 0 });
    }
  };

  // Fetch friends leaderboard
  const fetchFriendsLeaderboard = async (uid) => {
    try {
      const data = await rpc("ff_get_friends_leaderboard", { p_user_id: uid, p_limit: 50 });
      if (data && Array.isArray(data)) {
        setFriendsLeaderboard(data);
      }
    } catch (e) {
      console.warn("Failed to fetch friends leaderboard:", e);
    }
  };

  // Search for user by Flashback ID
  const searchUserByFlashbackId = async (flashbackId) => {
    setFriendSearchError("");
    setFriendSearchResult(null);
    if (!flashbackId || flashbackId.length < 6) {
      setFriendSearchError("Enter a valid Flashback ID (e.g., FF-ABC1234)");
      return;
    }
    try {
      const data = await rpc("ff_search_user_by_flashback_id", { p_flashback_id: flashbackId.toUpperCase() });
      if (data && data.length > 0) {
        setFriendSearchResult(data[0]);
      } else if (data && data.user_id) {
        setFriendSearchResult(data);
      } else {
        setFriendSearchError("No user found with that Flashback ID");
      }
    } catch (e) {
      console.warn("Failed to search user:", e);
      setFriendSearchError("Failed to search. Please try again.");
    }
  };

  // Send friend request
  const sendFriendRequest = async (friendUserId) => {
    try {
      if (friendUserId === userId) {
        setBtnConfirm("friend-error:Can't add yourself");
        return;
      }
      // Check for existing friendship
      const { data: existing } = await supabase
        .from("friendships")
        .select("id")
        .or(`and(user_id.eq.${userId},friend_id.eq.${friendUserId}),and(user_id.eq.${friendUserId},friend_id.eq.${userId})`)
        .limit(1);
      if (existing && existing.length > 0) {
        setBtnConfirm("friend-error:Already sent or friends");
        return;
      }
      const { error } = await supabase
        .from("friendships")
        .insert({ user_id: userId, friend_id: friendUserId, initiated_by: userId, status: "pending" });
      if (error) throw error;
      setBtnConfirm("friend-sent");
      fetchFriends(userId);
    } catch (e) {
      console.warn("Failed to send friend request:", e);
      setBtnConfirm("friend-error:Failed, try again");
    }
  };

  // Accept friend request
  const acceptFriendRequest = async (senderUserId) => {
    try {
      const { error } = await supabase
        .from("friendships")
        .update({ status: "accepted", updated_at: new Date().toISOString() })
        .eq("user_id", senderUserId)
        .eq("friend_id", userId)
        .eq("status", "pending");
      if (error) throw error;
      setBtnConfirm(`accepted-${senderUserId}`);
      fetchFriends(userId);
    } catch (e) {
      console.warn("Failed to accept friend request:", e);
    }
  };

  // Challenge type icons
  const CHALLENGE_ICONS = {
    play_games: "🎮",
    score_points: "🎯",
    win_games: "🏆",
    play_with_friends: "👥",
    party_game: "🎉",
  };

  // Fetch daily challenge
  const fetchDailyChallenge = async (uid) => {
    try {
      const data = await rpc("ff_assign_daily_challenge", { p_user_id: uid });
      console.log("Daily challenge data:", data);
      if (data && data.length > 0) {
        const d = data[0];
        // Map the prefixed column names from the SQL function
        setDailyChallenge({
          challenge_id: d.out_challenge_id || d.challenge_id,
          challenge_name: d.challenge_name,
          challenge_description: d.challenge_description,
          challenge_type: d.out_challenge_type || d.challenge_type,
          target_value: d.out_target_value ?? d.target_value,
          current_value: d.out_current_value ?? d.current_value,
          fp_reward: d.out_fp_reward ?? d.fp_reward,
          expires_at: d.out_expires_at || d.expires_at,
          is_completed: (d.out_current_value ?? d.current_value) >= (d.out_target_value ?? d.target_value),
        });
      } else if (data && (data.out_challenge_id || data.challenge_id)) {
        setDailyChallenge({
          challenge_id: data.out_challenge_id || data.challenge_id,
          challenge_name: data.challenge_name,
          challenge_description: data.challenge_description,
          challenge_type: data.out_challenge_type || data.challenge_type,
          target_value: data.out_target_value ?? data.target_value,
          current_value: data.out_current_value ?? data.current_value,
          fp_reward: data.out_fp_reward ?? data.fp_reward,
          expires_at: data.out_expires_at || data.expires_at,
          is_completed: (data.out_current_value ?? data.current_value) >= (data.out_target_value ?? data.target_value),
        });
      } else {
        console.log("No daily challenge returned from database");
      }
    } catch (e) {
      console.warn("Failed to fetch daily challenge:", e);
    }
  };

  // Referral milestone thresholds
  const REFERRAL_MILESTONES = [
    { count: 3, bonus: 250, badge: "Recruiter" },
    { count: 10, bonus: 500, badge: "Talent Scout" },
    { count: 25, bonus: 1000, badge: "Head Hunter" },
    { count: 50, bonus: 2500, badge: "Community Leader" },
  ];

  // Fetch referral stats
  const fetchReferralStats = async (uid) => {
    try {
      const data = await rpc("ff_get_referral_stats", { p_user_id: uid });
      if (data && data.length > 0) {
        setReferralStats(data[0]);
      } else if (data && data.referral_code) {
        setReferralStats(data);
      }
    } catch (e) {
      console.warn("Failed to fetch referral stats:", e);
    }
  };

  // Apply referral code
  const applyReferralCode = async (code) => {
    setReferralApplyResult(null);
    if (!code || code.length < 4) {
      setReferralApplyResult({ success: false, message: "Enter a valid referral code" });
      return;
    }
    try {
      const data = await rpc("ff_apply_referral_code", {
        p_referee_id: userId,
        p_referral_code: code.toUpperCase(),
      });
      if (data && data.length > 0) {
        setReferralApplyResult(data[0]);
      } else if (data) {
        setReferralApplyResult(data);
      }
      if (data?.success) {
        setReferralCodeInput("");
        fetchReferralStats(userId);
      }
    } catch (e) {
      console.warn("Failed to apply referral code:", e);
      setReferralApplyResult({ success: false, message: "Failed to apply code. Please try again." });
    }
  };

  // Check auth state on mount
  useEffect(() => {
    const checkAuth = async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (session?.user) {
        setUserId(session.user.id);
        const provider = session.user.app_metadata?.provider || "anonymous";
        setIsAnonymous(provider === "anonymous");
        // Pass Google/Apple name as fallback - profile's display_name takes priority
        const fallbackName = session.user.user_metadata?.full_name || null;
        fetchProfile(session.user.id, fallbackName);
        fetchUserBadges(session.user.id);
        fetchFriends(session.user.id);
        fetchRecentPlayers(session.user.id);
        fetchDailyChallenge(session.user.id);
        fetchReferralStats(session.user.id);
        fetchSkillRating(session.user.id);
      }
    };
    checkAuth();

    // Listen for auth changes
    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (session?.user) {
        setUserId(session.user.id);
        const provider = session.user.app_metadata?.provider || "anonymous";
        setIsAnonymous(provider === "anonymous");
        const fallbackName = session.user.user_metadata?.full_name || null;
        fetchProfile(session.user.id, fallbackName);
        fetchUserBadges(session.user.id);
        fetchFriends(session.user.id);
        fetchRecentPlayers(session.user.id);
        fetchDailyChallenge(session.user.id);
        fetchReferralStats(session.user.id);
        fetchSkillRating(session.user.id);
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  // Auto-refresh daily challenge when it expires or when user returns to app
  useEffect(() => {
    if (!userId) return;

    // Check every 60s if current challenge has expired
    const interval = setInterval(() => {
      if (dailyChallenge?.expires_at) {
        const expiresAt = new Date(dailyChallenge.expires_at).getTime();
        if (Date.now() >= expiresAt) {
          fetchDailyChallenge(userId);
        }
      }
    }, 60_000);

    // Also refresh when user returns to the app (tab/app becomes visible)
    const handleVisibility = () => {
      if (document.visibilityState === "visible" && userId) {
        const expiresAt = dailyChallenge?.expires_at
          ? new Date(dailyChallenge.expires_at).getTime()
          : 0;
        if (!dailyChallenge || Date.now() >= expiresAt) {
          fetchDailyChallenge(userId);
        }
      }
    };
    document.addEventListener("visibilitychange", handleVisibility);

    return () => {
      clearInterval(interval);
      document.removeEventListener("visibilitychange", handleVisibility);
    };
  }, [userId, dailyChallenge]);

  // Live countdown timer for daily challenge
  useEffect(() => {
    if (!dailyChallenge?.expires_at) {
      setChallengeTimeLeft("");
      return;
    }
    const tick = () => {
      const diff = new Date(dailyChallenge.expires_at).getTime() - Date.now();
      if (diff <= 0) {
        setChallengeTimeLeft("Expired");
        return;
      }
      const h = Math.floor(diff / 3_600_000);
      const m = Math.floor((diff % 3_600_000) / 60_000);
      const s = Math.floor((diff % 60_000) / 1000);
      setChallengeTimeLeft(`${h}h ${m}m ${s}s`);
    };
    tick();
    const timer = setInterval(tick, 1000);
    return () => clearInterval(timer);
  }, [dailyChallenge?.expires_at]);

  // OAuth sign-in (Google)
  const signInWithGoogle = async () => {
    try {
      const { error } = await supabase.auth.signInWithOAuth({
        provider: "google",
        options: {
          redirectTo: window.location.origin,
        },
      });
      if (error) throw error;
    } catch (e) {
      flashNotice(`Sign in failed: ${safeMsg(e)}`);
    }
  };

  // OAuth sign-in (Apple)
  const signInWithApple = async () => {
    try {
      const { error } = await supabase.auth.signInWithOAuth({
        provider: "apple",
        options: {
          redirectTo: window.location.origin,
        },
      });
      if (error) throw error;
    } catch (e) {
      flashNotice(`Sign in failed: ${safeMsg(e)}`);
    }
  };

  // Sign out
  const signOut = async () => {
    await supabase.auth.signOut();
    setUserId(null);
    setUserProfile(null);
    setIsAnonymous(true);
    setShowSignIn(false);
  };

  // Update display name (one-time change for signed-in users)
  const updateDisplayName = async () => {
    if (!userId || !editNameValue.trim()) return;
    try {
      const { error } = await supabase
        .from("user_profiles")
        .update({
          display_name: editNameValue.trim(),
          name_changed: true,
          updated_at: new Date().toISOString()
        })
        .eq("id", userId);
      if (error) throw error;
      setUserProfile((prev) => prev ? { ...prev, display_name: editNameValue.trim(), name_changed: true } : prev);
      setPlayerName(editNameValue.trim());
      setEditingName(false);
      flashNotice("Name updated!");
    } catch (e) {
      flashNotice(`Update failed: ${safeMsg(e)}`);
    }
  };

  const updateAvatar = async (emoji) => {
    if (!userId) return;
    try {
      const { error } = await supabase
        .from("user_profiles")
        .update({ avatar_url: emoji || null, updated_at: new Date().toISOString() })
        .eq("id", userId);
      if (error) throw error;
      setUserProfile(prev => prev ? { ...prev, avatar_url: emoji || null } : prev);
      setShowEmojiPicker(false);
      flashNotice(emoji ? "Icon updated!" : "Icon cleared!");
    } catch (e) {
      flashNotice(`Update failed: ${safeMsg(e)}`);
    }
  };

  useEffect(() => {
    if (!gameId || !userId) return;
    if (!["lobby", "draft", "results"].includes(screen)) return;

    let stopped = false;

    const tick = async () => {
      if (stopped) return;
      try {
        try {
          await rpc("ff_heartbeat", { p_game_id: gameId, p_user_id: userId });
        } catch (_) {
          await supabase
            .from("game_players")
            .update({ last_seen: nowIso(), is_active: true })
            .eq("game_id", gameId)
            .eq("user_id", userId);
        }
      } catch (_) {}
    };

    tick();
    const t = setInterval(tick, 20000);
    return () => {
      stopped = true;
      clearInterval(t);
    };
  }, [gameId, userId, screen]);

  const markLeft = async () => {
    if (!gameId || !userId) return;
    try {
      try {
        await rpc("ff_mark_left", { p_game_id: gameId, p_user_id: userId });
      } catch (_) {
        await supabase
          .from("game_players")
          .update({ is_active: false, left_at: nowIso() })
          .eq("game_id", gameId)
          .eq("user_id", userId);
      }
    } catch (_) {}
  };

  useEffect(() => {
    const handler = () => {
      markLeft();
      supabase.auth.signOut();
    };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [gameId, userId]);

  const fetchPlayers = async (gid) => {
    const { data, error } = await supabase
      .from("game_players")
      .select("*")
      .eq("game_id", gid)
      .order("seat", { ascending: true });
    if (error) throw error;
    return data ?? [];
  };

  const fetchGameState = async (gid) => {
    const { data, error } = await supabase
      .from("games")
      .select("id,status,season,week,turn_user_id,pick_number,turn_deadline_at,settings,room_code")
      .eq("id", gid)
      .single();
    if (error) throw error;
    return data;
  };

  const loadWeeklyRosterForGameWeek = async (season, week) => {
    const safeWeek = clampWeek(week);

    const { data: rosterRows, error: rErr } = await supabase
      .from("player_week_stats")
      .select("player_id, player_name, position, team, jersey_number")
      .eq("season", season)
      .eq("week", safeWeek);
    if (rErr) throw rErr;

    // Fetch matchups so draft search can show opponent
    const { data: matchupRows, error: mErr } = await supabase
      .from("team_week_matchups")
      .select("team, opponent, is_home")
      .eq("season", season)
      .eq("week", safeWeek);
    const matchupMap = new Map();
    if (!mErr && matchupRows) {
      matchupRows.forEach((m) => matchupMap.set(normalizeTeam(m.team), { opponent: normalizeTeam(m.opponent), is_home: m.is_home }));
    }

    const roster = (rosterRows ?? []).map((r) => {
      const team = normalizeTeam(r.team);
      return {
        id: r.player_id,
        name: r.player_name,
        position: normalizePos(r.position),
        team,
        number: r.jersey_number ?? 0,
        matchup: matchupMap.get(team) || null,
      };
    });

    let dstRoster = [];
    const { data: teamRows, error: dErr } = await supabase
      .from("team_week_stats")
      .select("team")
      .eq("season", season)
      .eq("week", safeWeek);
    if (!dErr && teamRows && teamRows.length > 0) {
      dstRoster = teamRows.map((t) => {
        const team = normalizeTeam(t.team);
        return { id: `DST_${team}`, name: `${team} Defense`, position: "DST", team, number: 0, matchup: matchupMap.get(team) || null };
      });
    }

    return [...roster, ...dstRoster];
  };

  const pickRandomWeekWithData = async (yearStart, yearEnd) => {
    const y0 = Math.min(Number(yearStart || 2010), Number(yearEnd || 2025));
    const y1 = Math.max(Number(yearStart || 2010), Number(yearEnd || 2025));

    let season = null;
    let week = null;

    try {
      const rpcData = await rpc("pick_random_game_week", { year_start: y0, year_end: y1 });
      const row = Array.isArray(rpcData) ? rpcData[0] : rpcData;
      if (row && Number.isFinite(row.season) && Number.isFinite(row.week)) {
        season = row.season;
        week = row.week;
      }
    } catch (_) {}

    if (!Number.isFinite(season) || !Number.isFinite(week)) {
      const { data: rows, error } = await supabase
        .from("player_week_stats")
        .select("season,week")
        .gte("season", y0)
        .lte("season", y1)
        .gte("week", 1)
        .lte("week", 17)
        .limit(20000);
      if (error) throw error;

      const uniq = new Map();
      (rows ?? []).forEach((r) => {
        const key = `${r.season}:${r.week}`;
        if (!uniq.has(key)) uniq.set(key, { season: r.season, week: r.week });
      });
      const choices = [...uniq.values()];
      const pick = choices.length ? choices[Math.floor(Math.random() * choices.length)] : null;
      if (!pick) return null;
      season = pick.season;
      week = pick.week;
    }

    const roster = await loadWeeklyRosterForGameWeek(season, week);
    if (!roster || roster.length === 0) return null;

    return { season, week, roster };
  };

  const inviteUrl = roomCode ? `${window.location.origin}/?room=${encodeURIComponent(roomCode)}` : "";

  const copyToClipboard = async (text) => {
    // Try modern clipboard API first
    if (navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (e) {
        // Fall through to fallback
      }
    }
    // Fallback for older browsers / non-HTTPS
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.focus();
    textarea.select();
    try {
      document.execCommand("copy");
      return true;
    } catch (e) {
      return false;
    } finally {
      document.body.removeChild(textarea);
    }
  };

  const copyInviteLink = async () => {
    if (!roomCode) return;
    // Try native share first on mobile
    if (isNative || navigator.share) {
      const shared = await shareInvite(roomCode);
      if (shared) {
        hapticLight();
        return;
      }
    }
    // Fallback to clipboard
    const text = `Join my Fantasy Flashbacks room: ${roomCode}\n${inviteUrl}`;
    const success = await copyToClipboard(text);
    if (success) {
      hapticLight();
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } else {
      flashNotice(`Link: ${inviteUrl}`);
    }
  };

  const copyRoomCodeOnly = async () => {
    if (!roomCode) return;
    const success = await copyToClipboard(roomCode);
    if (success) {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } else {
      flashNotice(`Code: ${roomCode}`);
    }
  };

  const createRoom = async () => {
    if (busy) return;
    if (!playerName.trim()) return;
    if (!canDoAction("create")) return; // no popup

    try {
      setBusy(true);
      flashNotice("");
      const uid = await ensureAnonUser();
      setUserId(uid);

      const code = genRoomCode();
      const settings = { ...gameSettings, maxPlayers: effectiveMaxPlayers, joinMode: "code", snakeDraft: snakeDraftToSend };

      let game = null;
      try {
        const rpcData = await rpc("ff_create_room", {
          p_room_code: code,
          p_settings: settings,
          p_host_user_id: uid,
          p_host_name: playerName.trim(),
        });
        game = Array.isArray(rpcData) ? rpcData[0] : rpcData;
      } catch (_) {
        const { data: g, error: gErr } = await supabase
          .from("games")
          .insert({ room_code: code, status: "lobby", settings, pick_number: 1 })
          .select("*")
          .single();
        if (gErr) throw gErr;
        game = g;

        const { error: pErr } = await supabase.from("game_players").insert({
          game_id: game.id,
          user_id: uid,
          display_name: playerName.trim(),
          seat: 1,
          ready: true,
          is_active: true,
          last_seen: nowIso(),
        });
        if (pErr) throw pErr;
      }

      setRoomCode(game.room_code || code);
      setGameId(game.id);
      setMySeat(1);
      hapticLight(); // Room created
      setScreen("lobby");
    } catch (e) {
      flashNotice(`Create room failed: ${safeMsg(e)}`);
    } finally {
      setBusy(false);
    }
  };

  // Handle transition to a rematch game
  const handleRematchStart = (newGameId, newRoomCode) => {
    // Reset refs
    rosterLoadedRef.current = false;
    resultsComputedRef.current = false;
    autoPickInFlightRef.current = false;
    lastAutoPickTryRef.current = { gameId: null, pickNumber: null };

    // Clear game-specific state but preserve settings
    setDraftedPlayerIds(new Set());
    setPinnedByPos({});
    setTeamsByUser({});
    setResultsByUser({});
    setWeeklyRankInfoById({});
    setGlobalBestLineup(null);
    setGameWeek(null);
    setPosFilter("ALL");
    setTeamFilter("ALL");
    setSearchQuery("");
    setSearchResults([]);
    setTurnDeadlineAtMs(null);
    setTimeRemaining(gameSettings.pickTime || 30);
    setDraftBusy(false);
    setMatchmakingStatus("");
    setDraftView("SEARCH");
    setWeeklyRoster([]);
    setPlayers([]);

    // Reset rematch state
    setRematchRequested(false);
    setRematchStatus({ ready: 0, total: 0 });
    setRematchPending(false);

    // Reset engagement tracking for new game
    setLastGameFpEarned(null);

    // Set new game info
    setGameId(newGameId);
    setRoomCode(newRoomCode);
    setMySeat(null); // Will be updated via realtime subscription

    // Go to lobby
    hapticSuccess();
    setScreen("lobby");
  };

  // Request a rematch with all players
  const requestRematch = async () => {
    if (rematchPending || !gameId || !userId) return;

    try {
      setRematchPending(true);
      setRematchRequested(true);
      hapticLight();

      const result = await rpc("ff_request_rematch", {
        p_game_id: gameId,
        p_user_id: userId,
      });

      const row = Array.isArray(result) ? result[0] : result;

      if (row?.rematch_ready && row?.new_game_id) {
        // All players ready - transition to new game
        handleRematchStart(row.new_game_id, row.new_room_code);
      } else {
        // Update status display
        setRematchStatus({
          ready: row?.players_ready || 1,
          total: row?.players_total || players.filter((p) => p.is_active).length,
        });
      }
    } catch (e) {
      console.error("Rematch error:", e);
      flashNotice(`Rematch failed: ${safeMsg(e)}`);
      setRematchRequested(false);
    } finally {
      setRematchPending(false);
    }
  };

  const joinRoom = async () => {
    if (busy) return;
    if (!playerName.trim()) return;
    if (roomCode.trim().length < 4) return;
    if (!canDoAction("join")) return; // no popup

    try {
      setBusy(true);
      flashNotice("");
      const uid = await ensureAnonUser();
      setUserId(uid);

      const code = roomCode.trim().toUpperCase();

      try {
        const rpcData = await rpc("ff_join_room", { p_room_code: code, p_user_id: uid, p_name: playerName.trim() });
        const row = Array.isArray(rpcData) ? rpcData[0] : rpcData;
        if (!row?.game_id || !row?.seat) throw new Error("Join failed.");
        setGameId(row.game_id);
        setMySeat(Number(row.seat));
        hapticLight(); // Joined room
        setScreen("lobby");
        return;
      } catch (_) {}

      const { data: game, error: gErr } = await supabase.from("games").select("*").eq("room_code", code).single();
      if (gErr) {
        flashNotice("Room not found.");
        return;
      }

      const s = game?.settings && typeof game.settings === "object" ? game.settings : {};
      setGameSettings((prev) => ({ ...prev, ...s }));
      const maxP = Math.max(2, Math.min(12, Number(s.maxPlayers || 2)));

      const existing = await fetchPlayers(game.id);
      if (existing.length >= maxP) {
        flashNotice("Room is full.");
        return;
      }

      const seatsTaken = new Set(existing.map((p) => Number(p.seat)));
      let seat = null;
      for (let i = 1; i <= maxP; i++) {
        if (!seatsTaken.has(i)) {
          seat = i;
          break;
        }
      }
      if (!seat) {
        flashNotice("Room is full.");
        return;
      }

      const { error: insErr } = await supabase.from("game_players").insert({
        game_id: game.id,
        user_id: uid,
        display_name: playerName.trim(),
        seat,
        ready: true,
        is_active: true,
        last_seen: nowIso(),
      });
      if (insErr) throw insErr;

      setGameId(game.id);
      setMySeat(seat);
      hapticLight(); // Joined room
      setScreen("lobby");
    } catch (e) {
      flashNotice(`Join room failed: ${safeMsg(e)}`);
    } finally {
      setBusy(false);
    }
  };

  // Invite auto-join: longer debounce + only fires once + requires >= 2 chars.
  // This avoids the "one letter then it joins" behavior.
  useEffect(() => {
    if (!inviteRoom) return;
    if (busy) return;

    const name = playerName.trim();
    if (name.length < 2) return;

    if (inviteDebounceRef.current) clearTimeout(inviteDebounceRef.current);
    inviteDebounceRef.current = setTimeout(() => {
      if (inviteAutoJoinRef.current) return;
      inviteAutoJoinRef.current = true;
      joinRoom().catch(() => {
        inviteAutoJoinRef.current = false;
      });
    }, 2500);

    return () => {
      if (inviteDebounceRef.current) clearTimeout(inviteDebounceRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inviteRoom, playerName, busy]);

  const startGlobalMatchmaking = async () => {
    if (busy) return;
    if (!playerName.trim()) return;
    if (!canDoAction("match")) return; // no popup

    try {
      setBusy(true);
      setMatchmakingStatus("Finding a match…");
      flashNotice("");
      const uid = await ensureAnonUser();
      setUserId(uid);

      const settings = { ...gameSettings, maxPlayers: effectiveMaxPlayers, joinMode: "global", snakeDraft: snakeDraftToSend };
      const settingsHash = hashSettingsForMatchmaking(settings);

      const rpcData = await rpc("ff_matchmake_or_join", {
        p_user_id: uid,
        p_name: playerName.trim(),
        p_max_players: effectiveMaxPlayers,
        p_settings_hash: settingsHash,
        p_settings: settings,
      });

      const row = Array.isArray(rpcData) ? rpcData[0] : rpcData;
      if (!row?.game_id || !row?.seat) throw new Error("Matchmaking failed.");

      setRoomCode(row.room_code || "");
      setGameId(row.game_id);
      setMySeat(Number(row.seat));
      setScreen("lobby");
      setMatchmakingStatus("");
    } catch (e) {
      setMatchmakingStatus("");
      flashNotice(`Matchmaking failed: ${safeMsg(e)}`);
    } finally {
      setBusy(false);
    }
  };

  const startDraft = async () => {
    try {
      if (!gameId) return flashNotice("Start failed: missing gameId");
      if (!userId) return flashNotice("Start failed: missing userId");
      if (mySeat !== 1) return flashNotice("Only the host can start.");
      if (busy) return;

      setBusy(true);
      flashNotice("");

      const pick = await pickRandomWeekWithData(gameSettings.yearStart, gameSettings.yearEnd);
      if (!pick) return flashNotice("No data found for that year range.");

      let started = null;
      try {
        const rpcData = await rpc("ff_start_draft", {
          p_game_id: gameId,
          p_host_user_id: userId,
          p_season: pick.season,
          p_week: clampWeek(pick.week),
          p_settings: { ...gameSettings, maxPlayers: effectiveMaxPlayers, snakeDraft: snakeDraftToSend, totalRounds: rosterSize },
        });
        started = Array.isArray(rpcData) ? rpcData[0] : rpcData;
      } catch (_) {
        const deadlineIso = new Date(Date.now() + (gameSettings.pickTime || 30) * 1000).toISOString();
        const { data: updated, error } = await supabase
          .from("games")
          .update({
            status: "draft",
            season: pick.season,
            week: clampWeek(pick.week),
            settings: { ...gameSettings, maxPlayers: effectiveMaxPlayers, snakeDraft: snakeDraftToSend },
            turn_user_id: userId,
            pick_number: 1,
            turn_deadline_at: deadlineIso,
          })
          .eq("id", gameId)
          .select("*")
          .single();
        if (error) throw error;
        started = updated;
      }

      rosterLoadedRef.current = true;
      resultsComputedRef.current = false;

      setPinnedByPos({});
      setDraftedPlayerIds(new Set());
      setTeamsByUser({});

      setPosFilter("ALL");
      setTeamFilter("ALL");
      setSearchQuery("");
      setSearchLimit(25);

      setWeeklyRoster(pick.roster || []);
      setGameWeek({ season: started.season, week: clampWeek(started.week) });

      setTurnUserId(started.turn_user_id);
      setPickNumber(Number(started.pick_number || 1));
      setIsMyTurn(started.turn_user_id === userId);

      const ms = toMs(started.turn_deadline_at);
      setTurnDeadlineAtMs(ms);
      setTimeRemaining(ms ? Math.max(0, Math.ceil((ms - Date.now()) / 1000)) : gameSettings.pickTime || 30);

      setDraftView("SEARCH");
      hapticSuccess(); // Draft starting!
      setScreen("draft");
    } catch (e) {
      flashNotice(`Start draft failed: ${safeMsg(e)}`);
    } finally {
      setBusy(false);
    }
  };

  // Start a solo practice game - skips lobby entirely
  const startSoloGame = async () => {
    if (busy) return;
    if (!playerName.trim()) return;
    if (!canDoAction("create")) return;

    try {
      setBusy(true);
      flashNotice("");
      const uid = await ensureAnonUser();
      setUserId(uid);

      // Pick a random week with data
      const pick = await pickRandomWeekWithData(gameSettings.yearStart, gameSettings.yearEnd);
      if (!pick) {
        flashNotice("No data found for that year range.");
        setBusy(false);
        return;
      }

      const code = genRoomCode();
      const settings = {
        ...gameSettings,
        maxPlayers: 1,
        joinMode: "code",
        snakeDraft: false,
        gameMode: "solo",
      };

      // Create game and immediately start draft
      const deadlineIso = new Date(Date.now() + (gameSettings.pickTime || 30) * 1000).toISOString();

      const { data: game, error: gErr } = await supabase
        .from("games")
        .insert({
          room_code: code,
          status: "draft",
          settings,
          pick_number: 1,
          season: pick.season,
          week: clampWeek(pick.week),
          turn_deadline_at: deadlineIso,
          is_solo: true,
        })
        .select("*")
        .single();
      if (gErr) throw gErr;

      // Add ourselves as the only player
      const { error: pErr } = await supabase.from("game_players").insert({
        game_id: game.id,
        user_id: uid,
        display_name: playerName.trim(),
        seat: 1,
        ready: true,
        is_active: true,
        last_seen: nowIso(),
      });
      if (pErr) throw pErr;

      // Update turn_user_id
      await supabase
        .from("games")
        .update({ turn_user_id: uid })
        .eq("id", game.id);

      // Set up local state for draft
      setRoomCode(code);
      setGameId(game.id);
      setMySeat(1);
      setPlayers([{ user_id: uid, display_name: playerName.trim(), seat: 1, is_active: true }]);

      rosterLoadedRef.current = true;
      resultsComputedRef.current = false;

      setPinnedByPos({});
      setDraftedPlayerIds(new Set());
      setTeamsByUser({});

      setPosFilter("ALL");
      setTeamFilter("ALL");
      setSearchQuery("");
      setSearchLimit(25);

      setWeeklyRoster(pick.roster || []);
      setGameWeek({ season: game.season, week: clampWeek(game.week) });

      setTurnUserId(uid);
      setPickNumber(1);
      setIsMyTurn(true);

      const ms = toMs(deadlineIso);
      setTurnDeadlineAtMs(ms);
      setTimeRemaining(ms ? Math.max(0, Math.ceil((ms - Date.now()) / 1000)) : gameSettings.pickTime || 30);

      setDraftView("SEARCH");
      hapticSuccess();
      setScreen("draft");
    } catch (e) {
      flashNotice(`Start solo game failed: ${safeMsg(e)}`);
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    if (!gameId) return;
    let cancelled = false;

    const refresh = async () => {
      try {
        const list = await fetchPlayers(gameId);
        if (cancelled) return;
        setPlayers(list);
        // Find and set our seat from the players list
        if (userId) {
          const me = list.find((p) => p.user_id === userId);
          if (me) setMySeat((prev) => prev ?? me.seat);
        }
      } catch (_) {}
    };

    const channel = supabase
      .channel(`lobby:${gameId}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "game_players", filter: `game_id=eq.${gameId}` }, refresh)
      .subscribe();

    const poll = setInterval(() => {
      if (screen === "lobby") refresh();
    }, 1500);

    refresh();

    return () => {
      cancelled = true;
      clearInterval(poll);
      supabase.removeChannel(channel);
    };
  }, [gameId, screen, userId]);

  // Subscribe to rematch updates on results screen
  useEffect(() => {
    if (!gameId || screen !== "results") return;
    let cancelled = false;

    const checkRematchStatus = async () => {
      if (cancelled) return;

      try {
        const { data: playerList } = await supabase
          .from("game_players")
          .select("user_id, is_active, rematch_requested")
          .eq("game_id", gameId);

        if (cancelled || !playerList) return;

        const active = playerList.filter((p) => p.is_active);
        const ready = active.filter((p) => p.rematch_requested);

        setRematchStatus({
          ready: ready.length,
          total: active.length,
        });

        // Check if everyone is ready (but we didn't initiate the final trigger)
        if (ready.length === active.length && active.length >= 2 && !rematchPending) {
          // Poll for the new game that was created
          const { data: newGame } = await supabase
            .from("games")
            .select("id, room_code")
            .eq("rematch_of_game_id", gameId)
            .maybeSingle();

          if (newGame && !cancelled) {
            handleRematchStart(newGame.id, newGame.room_code);
          }
        }
      } catch (_) {}
    };

    const channel = supabase
      .channel(`rematch:${gameId}`)
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "game_players", filter: `game_id=eq.${gameId}` },
        checkRematchStatus
      )
      .subscribe();

    // Initial check
    checkRematchStatus();

    // Also poll as backup
    const poll = setInterval(checkRematchStatus, 2000);

    return () => {
      cancelled = true;
      clearInterval(poll);
      supabase.removeChannel(channel);
    };
  }, [gameId, screen, rematchPending]);

  useEffect(() => {
    if (!gameId) return;
    if (screen === "results") return; // Stop polling once on results

    const poll = setInterval(async () => {
      try {
        const g = await fetchGameState(gameId);
        if (!g) return;

        if (g.room_code) setRoomCode(g.room_code);

        const s = g.settings && typeof g.settings === "object" ? g.settings : {};
        if (s) setGameSettings((prev) => ({ ...prev, ...s }));

        setTurnUserId(g.turn_user_id);
        setPickNumber(Number(g.pick_number || 1));
        if (userId) setIsMyTurn(g.turn_user_id === userId);

        const ms = toMs(g.turn_deadline_at);
        if (ms) setTurnDeadlineAtMs(ms);

        if (g.status === "draft") {
          setGameWeek({ season: g.season, week: clampWeek(g.week) });
          setScreen("draft");
        }
        if (g.status === "scoring" || g.status === "done") {
          if (!resultsComputedRef.current) {
            setGameWeek({ season: g.season, week: clampWeek(g.week) });
          }
          setScreen("results");
        }
      } catch (_) {}
    }, 800);

    return () => clearInterval(poll);
  }, [gameId, userId, screen]);

  // Trigger stats calculation when entering results screen
  useEffect(() => {
    if (screen !== "results") return;
    if (resultsComputedRef.current) return;
    if (!gameWeek?.season || !gameWeek?.week) return;
    if (!teamsByUser || Object.keys(teamsByUser).length === 0) return;

    resultsComputedRef.current = true;
    fetchStatsAndCalculateAll(teamsByUser);
  }, [screen, gameWeek, teamsByUser]);

  useEffect(() => {
    if (screen !== "lobby") return;
    if (mySeat !== 1) return;
    if (!gameId || !userId) return;
    if (!gameSettings.autoStartWhenFull) return;
    // Only auto-start in fixed mode when full (open lobby requires manual start)
    if (gameSettings.lobbyMode === "open") return;

    const maxP = effectiveMaxPlayers;
    if ((players?.length || 0) >= maxP) {
      startDraft().catch(() => {});
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [screen, mySeat, players, gameSettings.autoStartWhenFull, gameSettings.lobbyMode, effectiveMaxPlayers, gameId, userId]);

  useEffect(() => {
    if (!gameWeek || !gameId) return;
    if (screen !== "draft") return;
    if (rosterLoadedRef.current && weeklyRoster.length) return;

    (async () => {
      try {
        const roster = await loadWeeklyRosterForGameWeek(gameWeek.season, gameWeek.week);
        setWeeklyRoster(roster);
        rosterLoadedRef.current = true;
      } catch (e) {
        rosterLoadedRef.current = false;
        flashNotice(`Roster load failed: ${safeMsg(e)}`);
      }
    })();
  }, [gameWeek, gameId, screen]); // intentional

  useEffect(() => {
    if (!turnDeadlineAtMs) {
      setTimeRemaining(gameSettings.pickTime || 30);
      return;
    }
    const t = setInterval(() => {
      const rem = Math.max(0, Math.ceil((turnDeadlineAtMs - Date.now()) / 1000));
      setTimeRemaining(rem);
    }, 200);
    return () => clearInterval(t);
  }, [turnDeadlineAtMs, gameSettings.pickTime]);

  useEffect(() => {
    if (!gameId || !userId) return;
    let cancelled = false;

    const rebuild = async () => {
      const { data: picks, error } = await supabase
        .from("game_picks")
        .select("user_id,slot_index,slot_position,player_id,created_at")
        .eq("game_id", gameId)
        .order("created_at", { ascending: true });

      if (error) throw error;
      if (cancelled) return;

      const drafted = new Set();
      const teams = {};

      (players || []).forEach((p) => {
        teams[p.user_id] = Array(rosterSize).fill(null);
      });

      (picks ?? []).forEach((pk) => {
        drafted.add(pk.player_id);

        const found = weeklyRoster.find((x) => x.id === pk.player_id);
        const display =
          found ||
          (String(pk.player_id).startsWith("DST_")
            ? {
                id: pk.player_id,
                name: `${pk.player_id.replace("DST_", "")} Defense`,
                position: "DST",
                team: pk.player_id.replace("DST_", ""),
                number: 0,
              }
            : { id: pk.player_id, name: pk.player_id, position: pk.slot_position, team: null, number: 0 });

        if (!teams[pk.user_id]) teams[pk.user_id] = Array(rosterSize).fill(null);
        teams[pk.user_id][pk.slot_index] = display;
      });

      setDraftedPlayerIds(drafted);
      setTeamsByUser(teams);

      // Use actual player count (not maxPlayers setting) for completion check
      const actualPlayerCount = players?.length || 2;
      const totalPicks = (picks ?? []).length;

      if (totalPicks >= rosterSize * actualPlayerCount && gameWeek && !resultsComputedRef.current) {
        resultsComputedRef.current = true;
        await fetchStatsAndCalculateAll(teams);
        hapticSuccess(); // Game complete!
        setScreen("results");
        if (mySeat === 1) await supabase.from("games").update({ status: "done" }).eq("id", gameId);
      }
    };

    const channel = supabase
      .channel(`picks:${gameId}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "game_picks", filter: `game_id=eq.${gameId}` }, () =>
        rebuild().catch(() => {})
      )
      .subscribe();

    const poll = setInterval(() => {
      if (screen === "draft") rebuild().catch(() => {});
    }, 1100);

    rebuild().catch(() => {});

    return () => {
      cancelled = true;
      clearInterval(poll);
      supabase.removeChannel(channel);
    };
  }, [gameId, userId, rosterSize, weeklyRoster, gameWeek, screen, mySeat, players]);

  const togglePinned = (bucketPos, playerId) => {
    setPinnedByPos((prev) => {
      const cur = prev[bucketPos] ? [...prev[bucketPos]] : [];
      const i = cur.indexOf(playerId);
      if (i >= 0) cur.splice(i, 1);
      else cur.unshift(playerId);
      return { ...prev, [bucketPos]: cur };
    });
  };

  useEffect(() => {
    setSearchLimit(25);
  }, [posFilter, teamFilter]);

  useEffect(() => {
    if (!weeklyRoster.length) {
      setSearchResults([]);
      setSearchTotal(0);
      return;
    }

    const q = searchQuery.trim().toLowerCase();
    const allowedPositions = (() => {
      if (posFilter === "ALL") return ["QB", "RB", "WR", "TE", "K", "DST"];
      if (posFilter === "FLEX") return ["RB", "WR", "TE"];
      return [posFilter];
    })();

    const filtered = weeklyRoster.filter((p) => {
      if (draftedPlayerIds.has(p.id)) return false;
      if (!allowedPositions.includes(p.position)) return false;
      if (teamFilter !== "ALL") {
        const normalizedPlayerTeam = normalizeTeam(p.team);
        if (normalizedPlayerTeam !== teamFilter) return false;
      }
      if (!q) return true;
      return (p.name || "").toLowerCase().includes(q) || (p.team || "").toLowerCase().includes(q);
    });

    filtered.sort((a, b) => (a.name || "").localeCompare(b.name || ""));

    const bucketForRow = (row) => (posFilter === "ALL" ? row.position : posFilter === "FLEX" ? row.position : posFilter);

    const pinnedSet = new Set();
    filtered.forEach((row) => {
      const bucket = bucketForRow(row);
      (pinnedByPos[bucket] || []).forEach((id) => pinnedSet.add(id));
    });

    const pinnedRows = filtered.filter((p) => pinnedSet.has(p.id));
    const restRows = filtered.filter((p) => !pinnedSet.has(p.id));
    const combined = [...pinnedRows, ...restRows];

    setSearchTotal(combined.length);
    setSearchResults(combined.slice(0, Math.min(500, Math.max(searchLimit, pinnedRows.length))));
  }, [weeklyRoster, draftedPlayerIds, posFilter, teamFilter, searchQuery, searchLimit, pinnedByPos]);

  const showMoreResults = () => {
    setSearchingMore(true);
    setTimeout(() => {
      setSearchLimit((v) => Math.min(v + 25, 500));
      setSearchingMore(false);
    }, 200);
  };

  const myTeam = useMemo(() => {
    if (!userId) return Array(rosterSize).fill(null);
    return teamsByUser?.[userId] || Array(rosterSize).fill(null);
  }, [teamsByUser, userId, rosterSize]);

  const openSlotIndexForPos = (pos) => {
    for (let i = 0; i < rosterSlots.length; i++) {
      if (myTeam[i]) continue;
      const slot = rosterSlots[i];
      if (slot === pos) return i;
      if (slot === "FLEX" && ["RB", "WR", "TE"].includes(pos)) return i;
    }
    return -1;
  };

  const hasOpenForPos = (pos) => openSlotIndexForPos(pos) !== -1;

  const manualDraft = async (player) => {
    if (!isMyTurn) return;
    if (!gameId || !userId) return;
    if (draftBusy) return;

    const slotIndex = openSlotIndexForPos(player.position);
    if (slotIndex === -1) {
      flashNotice(`No open slot remaining for ${player.position}.`);
      return;
    }

    setDraftBusy(true);
    try {
      const rpcData = await rpc("ff_make_pick", {
        p_game_id: gameId,
        p_user_id: userId,
        p_player_id: player.id,
        p_slot_index: slotIndex,
        p_slot_position: rosterSlots[slotIndex],
      });

      const row = Array.isArray(rpcData) ? rpcData[0] : rpcData;
      if (row) {
        hapticMedium(); // Haptic feedback on successful pick
        setTurnUserId(row.turn_user_id);
        setPickNumber(Number(row.pick_number || pickNumber + 1));
        setIsMyTurn(row.turn_user_id === userId);
        const ms = toMs(row.turn_deadline_at);
        if (ms) setTurnDeadlineAtMs(ms);
      }
    } catch (e) {
      hapticError(); // Haptic feedback on error
      flashNotice(`Pick failed: ${safeMsg(e)}`);
    } finally {
      setDraftBusy(false);
    }
  };

  // Server-side autopick: ANY connected player can trigger this when deadline passes
  const triggerServerAutoPick = async () => {
    if (!gameId) return;
    if (autoPickInFlightRef.current) return;

    autoPickInFlightRef.current = true;
    try {
      const rpcData = await rpc("ff_auto_pick_if_needed", { p_game_id: gameId });
      const row = Array.isArray(rpcData) ? rpcData[0] : rpcData;
      if (row) {
        setTurnUserId(row.turn_user_id);
        setPickNumber(Number(row.pick_number || pickNumber));
        if (userId) setIsMyTurn(row.turn_user_id === userId);
        const ms = toMs(row.turn_deadline_at);
        if (ms) setTurnDeadlineAtMs(ms);
      }
    } catch (_) {
      // Server handles autopick
    } finally {
      autoPickInFlightRef.current = false;
    }
  };

  // Client-side autopick for when it's MY turn (uses pinned players)
  const autoPickIfNeeded = async () => {
    if (!gameId) return;
    if (!isMyTurn) return;
    if (autoPickInFlightRef.current) return;

    autoPickInFlightRef.current = true;
    try {
      let g = null;
      try {
        g = await fetchGameState(gameId);
      } catch (_) {
        return;
      }
      if (!g || g.status !== "draft") return;
      if (g.turn_user_id !== userId) return;

      const serverDeadline = toMs(g.turn_deadline_at);
      if (serverDeadline && serverDeadline > Date.now()) {
        return;
      }

      if (lastAutoPickTryRef.current.gameId === gameId && lastAutoPickTryRef.current.pickNumber === g.pick_number) {
        return;
      }
      lastAutoPickTryRef.current = { gameId, pickNumber: g.pick_number };

      // Find open positions
      const openPositions = [];
      for (let i = 0; i < rosterSlots.length; i++) {
        if (!myTeam[i]) {
          openPositions.push({ index: i, slot: rosterSlots[i] });
        }
      }

      if (openPositions.length === 0) return;

      // Check for pinned players in open positions
      let playerToPick = null;
      let slotIndex = -1;
      let slotPosition = null;

      for (const { index, slot } of openPositions) {
        const positions = slot === "FLEX" ? ["RB", "WR", "TE"] : [slot];
        for (const pos of positions) {
          const pinned = pinsFor(pos);
          if (pinned.length > 0) {
            const pinnedPlayer = weeklyRoster.find((p) => p.id === pinned[0] && !draftedPlayerIds.has(p.id));
            if (pinnedPlayer) {
              playerToPick = pinnedPlayer;
              slotIndex = index;
              slotPosition = slot;
              break;
            }
          }
        }
        if (playerToPick) break;
      }

      // If no pinned player, pick randomly
      if (!playerToPick) {
        for (const { index, slot } of openPositions) {
          const positions = slot === "FLEX" ? ["RB", "WR", "TE"] : [slot];
          const available = weeklyRoster.filter(
            (p) => positions.includes(p.position) && !draftedPlayerIds.has(p.id)
          );
          if (available.length > 0) {
            const randomIndex = Math.floor(Math.random() * available.length);
            playerToPick = available[randomIndex];
            slotIndex = index;
            slotPosition = slot;
            break;
          }
        }
      }

      if (playerToPick && slotIndex !== -1) {
        flashNotice(`Auto-picking ${playerToPick.name} (timer expired)`);
        try {
          const rpcData = await rpc("ff_make_pick", {
            p_game_id: gameId,
            p_user_id: userId,
            p_player_id: playerToPick.id,
            p_slot_index: slotIndex,
            p_slot_position: slotPosition,
          });
          const row = Array.isArray(rpcData) ? rpcData[0] : rpcData;
          if (row) {
            setTurnUserId(row.new_turn_user_id);
            setPickNumber(Number(row.new_pick_number || pickNumber));
            if (userId) setIsMyTurn(row.new_turn_user_id === userId);
            const ms = toMs(row.new_turn_deadline_at);
            if (ms) setTurnDeadlineAtMs(ms);
          }
        } catch (e) {
          flashNotice(`Auto-pick failed: ${e?.message || "Unknown error"}`);
        }
      }
    } catch (_) {
      // ignore
    } finally {
      autoPickInFlightRef.current = false;
    }
  };

  // When timer hits 0: if it's my turn, try client-side autopick (with pins)
  useEffect(() => {
    if (screen !== "draft") return;
    if (!turnDeadlineAtMs) return;
    if (timeRemaining !== 0) return;
    if (!isMyTurn) return;

    autoPickIfNeeded().catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [timeRemaining, screen, turnDeadlineAtMs, isMyTurn]);

  // Poll for server-side autopick when deadline has passed and it's NOT my turn
  // This allows any connected player to trigger autopick for disconnected players
  useEffect(() => {
    if (screen !== "draft") return;
    if (!turnDeadlineAtMs) return;
    if (!gameId) return;

    // Poll every 2 seconds to check if deadline passed and trigger autopick
    const interval = setInterval(async () => {
      const deadlinePassed = Date.now() > turnDeadlineAtMs;
      if (!deadlinePassed) return;
      if (isMyTurn) return;
      if (autoPickInFlightRef.current) return;
      await triggerServerAutoPick();
    }, 2000);

    return () => clearInterval(interval);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [screen, turnDeadlineAtMs, gameId, isMyTurn]);

  const buildWeeklyRanksFromPool = (pool) => {
    const byPos = new Map();
    for (const p of pool || []) {
      const pos = normalizePos(p?.position);
      if (!pos) continue;
      if (!byPos.has(pos)) byPos.set(pos, []);
      byPos.get(pos).push(p);
    }

    const out = {};
    for (const [pos, arr] of byPos.entries()) {
      const sorted = (arr || [])
        .filter((x) => Number.isFinite(x?.points))
        .sort((a, b) => {
          const dp = (b.points ?? 0) - (a.points ?? 0);
          if (dp !== 0) return dp;
          return String(a.name || "").localeCompare(String(b.name || ""));
        });

      const total = sorted.length;
      let prevPts = null;
      let prevRank = 0;
      let prevId = null;
      let idx = 0;

      for (const pl of sorted) {
        idx += 1;
        const pts = pl.points ?? 0;
        let rank = idx;
        let tied = false;

        if (prevPts !== null && pts === prevPts) {
          rank = prevRank;
          tied = true;
          if (prevId && out[prevId]) out[prevId] = { ...out[prevId], tied: true };
        }

        out[pl.id] = { pos, rank, total, tied };
        prevPts = pts;
        prevRank = rank;
        prevId = pl.id;
      }
    }

    return out;
  };

  const computeGlobalBestLineupFromPool = (pool) => {
    const sorted = (pool || [])
      .filter((p) => Number.isFinite(p?.points))
      .sort((a, b) => (b.points ?? 0) - (a.points ?? 0));

    const used = new Set();
    const slotsOrdered = [...rosterSlots.filter((s) => s !== "FLEX"), ...rosterSlots.filter((s) => s === "FLEX")];

    const slots = [];
    let total = 0;

    for (const slot of slotsOrdered) {
      const eligible = slot === "FLEX" ? ["RB", "WR", "TE"] : [slot];
      let pick = null;

      for (const p of sorted) {
        if (used.has(p.id)) continue;
        if (!eligible.includes(p.position)) continue;
        pick = p;
        break;
      }

      if (pick) {
        used.add(pick.id);
        slots.push({ slot, player: pick });
        total += pick.points ?? 0;
      } else {
        slots.push({ slot, player: { id: `EMPTY_${slot}`, name: "—", team: null, position: slot, points: 0 } });
      }
    }

    return { total, slots };
  };

const fetchStatsAndCalculateAll = async (teams) => {
  setLoadingStats(true);
  try {
    if (!gameWeek?.season || !gameWeek?.week) return;

    const season = gameWeek.season;
    const week = clampWeek(gameWeek.week);

    const [{ data: allPlayers, error: pErr }, { data: allTeams, error: tErr }] = await Promise.all([
      supabase.from("player_week_stats").select("*").eq("season", season).eq("week", week),
      supabase.from("team_week_stats").select("*").eq("season", season).eq("week", week),
    ]);
    if (pErr) throw pErr;
    if (tErr) throw tErr;

    const playerRowById = new Map((allPlayers ?? []).map((r) => [r.player_id, r]));
    const teamRowByTeam = new Map((allTeams ?? []).map((r) => [normalizeTeam(r.team), r]));

    // Pull ALL matchups for the week (≈32 rows). Needed for DST points allowed + UI.
    let matchupMap = new Map();
    {
      const { data: matchups, error: mErr } = await supabase
        .from("team_week_matchups")
        .select("team, opponent, team_score, opp_score, is_home")
        .eq("season", season)
        .eq("week", week);
      if (mErr) throw mErr;
      matchupMap = new Map((matchups ?? []).map((m) => [normalizeTeam(m.team), m]));
    }

const sample = [...matchupMap.entries()].slice(0, 5);
console.log("DST matchup sanity:", sample.map(([t, m]) => ({ team: t, opp_score: m?.opp_score, team_score: m?.team_score })));

    // Global player pool
    const playerPool = (allPlayers ?? []).map((row) => {
      const pos = normalizePos(row.position);
      const team = normalizeTeam(row.team);
      const { points } = scorePlayerRow(row, gameSettings.scoring, {
        passing: { td: gameSettings.passTdPoints, yardsPerPoint: 25 },
      });
      return { id: row.player_id, name: row.player_name, position: pos, team, points: Number(points || 0) };
    });

    // Global DST pool (IMPORTANT: use matchup opp_score as "points allowed")
    const dstPool = (allTeams ?? []).map((row) => {
      const team = normalizeTeam(row.team);
      const matchup = matchupMap.get(team) || null;

      const pa =
        matchup && matchup.opp_score !== null && matchup.opp_score !== undefined
          ? Number(matchup.opp_score)
          : row.points_allowed !== null && row.points_allowed !== undefined
            ? Number(row.points_allowed)
            : null;

      const { points } = scoreDstRow(row, { pointsAllowed: pa });

      return { id: `DST_${team}`, name: `${team} Defense`, position: "DST", team, points: Number(points || 0) };
    });

    const globalPool = [...playerPool, ...dstPool];
    setWeeklyRankInfoById(buildWeeklyRanksFromPool(globalPool));
    setGlobalBestLineup(computeGlobalBestLineupFromPool(globalPool));

    // Score each user roster
    const res = {};
    for (const [uid, arr] of Object.entries(teams || {})) {
      const rows = await Promise.all(
        (arr || []).map(async (pl) => {
          if (!pl) return null;

          const teamCode = normalizeTeam(pl.team);
          const matchup = teamCode ? matchupMap.get(teamCode) || null : null;

          if (pl.position === "DST") {
            const tr = teamCode ? teamRowByTeam.get(teamCode) || null : null;
            if (!tr) return { ...pl, stats: null, points: 0, breakdown: {}, matchup };

            const pa =
              matchup && matchup.opp_score !== null && matchup.opp_score !== undefined
                ? Number(matchup.opp_score)
                : tr.points_allowed !== null && tr.points_allowed !== undefined
                  ? Number(tr.points_allowed)
                  : null;

            const { points, breakdown } = scoreDstRow(tr, { pointsAllowed: pa });

            // Optional: include what PA value we used so UI/debugging is obvious
            return { ...pl, stats: tr, points: Number(points || 0), breakdown, matchup };
          }

          const pr = playerRowById.get(pl.id) || null;
          if (!pr) return { ...pl, stats: null, points: 0, breakdown: {}, matchup };

          const { points, breakdown } = scorePlayerRow(pr, gameSettings.scoring, {
            passing: { td: gameSettings.passTdPoints, yardsPerPoint: 25 },
          });

          return { ...pl, stats: pr, points: Number(points || 0), breakdown, matchup };
        })
      );

      const clean = rows.filter(Boolean);
      const total = clean.reduce((s, p) => s + (p.points || 0), 0);
      res[uid] = { rows: clean, total };
    }

    setResultsByUser(res);

    // Save game results to database (for leaderboards/history)
    // Only seat 1 saves to avoid duplicate inserts, but all players get stats updated
    if (gameId && mySeat === 1) {
      try {
        const resultsArray = Object.entries(res).map(([uid, v]) => {
          const playerInfo = players.find((p) => p.user_id === uid);
          return {
            user_id: uid,
            display_name: playerInfo?.display_name || "Player",
            seat: playerInfo?.seat || 1,
            final_score: Number(v?.total || 0),
          };
        });

        const highScoreResult = await rpc("ff_save_game_results", {
          p_game_id: gameId,
          p_results: resultsArray,
          p_settings: gameSettings,
        });

        // Check if someone set a new high score
        const hsData = Array.isArray(highScoreResult) ? highScoreResult[0] : highScoreResult;
        if (hsData?.is_high_score) {
          const winner = resultsArray.find((r) => r.user_id === hsData.high_score_user_id);
          const prevHigh = hsData.previous_high_score;
          if (prevHigh) {
            flashNotice(`NEW HIGH SCORE! ${winner?.display_name || "Player"} beat the record of ${prevHigh.toFixed(1)}!`);
          } else {
            flashNotice(`FIRST HIGH SCORE! ${winner?.display_name || "Player"} set the record at ${hsData.high_score_value?.toFixed(1)}!`);
          }
        }

        // Capture FP awarded for display
        if (hsData?.fp_awarded && userId) {
          const myFp = hsData.fp_awarded[userId];
          if (myFp !== undefined) {
            setLastGameFpEarned(myFp);
          }
        }
      } catch (saveErr) {
        console.warn("Failed to save game results:", saveErr);
      }
    }

    // Refresh profile and engagement stats to show updated stats
    if (userId) {
      fetchProfile(userId);
      fetchEngagementStats(userId);
      fetchDailyChallenge(userId); // Refresh challenge progress
    }
  } catch (e) {
    flashNotice(`Scoring failed: ${safeMsg(e)}`);
  } finally {
    setLoadingStats(false);
  }
};

  const getKeyStats = (player) => {
    const pos = String(player.position || "").toUpperCase();
    const s = player.stats || {};
    const lines = [];
    const add = (label, value) => lines.push({ label, value: value === null || value === undefined ? "—" : String(value) });

    if (pos === "QB") {
      add("Pass Yds", s.passing_yards);
      add("Pass TD", s.passing_tds);
      add("INT", s.interceptions);
      add("Rush Yds", s.rushing_yards);
      add("Rush TD", s.rushing_tds);
      add("FumL", s.fumbles_lost);
      return lines;
    }
    if (pos === "RB" || pos === "WR" || pos === "TE") {
      add("Rush Yds", s.rushing_yards);
      add("Rush TD", s.rushing_tds);
      add("Rec", s.receptions);
      add("Rec Yds", s.receiving_yards);
      add("Rec TD", s.receiving_tds);
      add("FumL", s.fumbles_lost);
      return lines;
    }
    if (pos === "K") {
      add("FGM", s.fgm);
      add("FGA", s.fga);
      add("XPM", s.xpm);
      add("XPA", s.xpa);
      add("FG 50+", s.fgm_50_plus);
      return lines;
    }
    if (pos === "DST") {
      // Display the same PA used for scoring (matchup opponent score).
      const pa =
        player.matchup && player.matchup.opp_score !== null && player.matchup.opp_score !== undefined
          ? player.matchup.opp_score
          : s.points_allowed;

      add("Pts Allowed", pa);
      add("Sacks", s.sacks);
      add("INT", s.interceptions);
      add("Fum Rec", s.fumbles_recovered);
      add("Def TD", s.def_tds);
      return lines;
    }
    return lines;
  };

  const MatchupLine = ({ matchup }) => {
    if (!matchup) return null;
    const margin = matchup.team_score - matchup.opp_score;
    return (
      <span className="text-xs text-slate-400 ml-2">
        {matchup.is_home ? "vs" : "at"} {normalizeTeam(matchup.opponent)} • {matchup.team_score}-{matchup.opp_score} (
        {margin >= 0 ? "+" : ""}
        {margin})
      </span>
    );
  };

  const TeamColorBadge = ({ team }) => {
    const t = normalizeTeam(team);
    const info = t ? NFL_TEAMS[t] : null;
    if (!info) {
      return (
        <div className="flex items-center gap-1">
          <div className="w-3 h-3 rounded-sm bg-slate-500" />
          <span className="text-xs font-medium">{t || "—"}</span>
        </div>
      );
    }
    return (
      <div className="flex items-center gap-1">
        <div
          className="w-3 h-3 rounded-sm"
          style={{ background: `linear-gradient(135deg, ${info.primary} 50%, ${info.secondary} 50%)` }}
        />
        <span className="text-xs font-medium">{t}</span>
      </div>
    );
  };

  const TeamFilterDropdown = () => {
    const filteredTeams = NFL_TEAM_ABBRS.filter((abbr) =>
      abbr.toLowerCase().includes(teamSearchQuery.toLowerCase())
    );

    return (
      <div className="relative" ref={teamDropdownRef}>
        <button
          onClick={() => {
            setTeamDropdownOpen((v) => !v);
            setTeamSearchQuery("");
          }}
          className={`flex items-center gap-2 px-3 py-2 rounded text-xs font-bold transition ${
            teamFilter !== "ALL"
              ? "bg-slate-600 text-white"
              : "bg-slate-700 text-slate-300 hover:bg-slate-600"
          }`}
        >
          {teamFilter === "ALL" ? (
            <span>All Teams</span>
          ) : (
            <>
              <div
                className="w-3 h-3 rounded-sm"
                style={{
                  background: `linear-gradient(135deg, ${NFL_TEAMS[teamFilter]?.primary || "#666"} 50%, ${NFL_TEAMS[teamFilter]?.secondary || "#333"} 50%)`,
                }}
              />
              <span>{teamFilter}</span>
            </>
          )}
          <ChevronDown size={14} className={`transition-transform ${teamDropdownOpen ? "rotate-180" : ""}`} />
        </button>

        {teamDropdownOpen && (
          <div className="absolute z-50 mt-1 w-40 bg-slate-800 border border-slate-600 rounded-lg shadow-xl overflow-hidden">
            <div className="p-2 border-b border-slate-600">
              <input
                type="text"
                placeholder="Search teams..."
                value={teamSearchQuery}
                onChange={(e) => setTeamSearchQuery(e.target.value)}
                className="w-full bg-slate-700 rounded px-2 py-1.5 text-xs text-white placeholder-slate-400"
                autoFocus
              />
            </div>
            <div className="max-h-64 overflow-y-auto">
              {teamSearchQuery === "" && (
                <button
                  onClick={() => {
                    setTeamFilter("ALL");
                    setTeamDropdownOpen(false);
                  }}
                  className={`w-full px-3 py-2 text-left text-xs flex items-center gap-2 hover:bg-slate-700 ${
                    teamFilter === "ALL" ? "bg-slate-600" : ""
                  }`}
                >
                  <div className="w-3 h-3 rounded-sm bg-slate-500" />
                  <span>All Teams</span>
                </button>
              )}
              {filteredTeams.length > 0 ? (
                filteredTeams.map((abbr) => {
                  const info = NFL_TEAMS[abbr];
                  return (
                    <button
                      key={abbr}
                      onClick={() => {
                        setTeamFilter(abbr);
                        setTeamDropdownOpen(false);
                      }}
                      className={`w-full px-3 py-2 text-left text-xs flex items-center gap-2 hover:bg-slate-700 ${
                        teamFilter === abbr ? "bg-slate-600" : ""
                      }`}
                    >
                      <div
                        className="w-3 h-3 rounded-sm"
                        style={{ background: `linear-gradient(135deg, ${info.primary} 50%, ${info.secondary} 50%)` }}
                      />
                      <span>{abbr}</span>
                    </button>
                  );
                })
              ) : (
                <div className="px-3 py-2 text-xs text-slate-400">No teams match</div>
              )}
            </div>
          </div>
        )}
      </div>
    );
  };

  const pickDisplay = draftedPlayerIds.size + 1;

  const handleShareResults = async () => {
    try {
      const scoreboard = Object.entries(resultsByUser || {})
        .map(([uid, v]) => ({
          user_id: uid,
          total: Number(v?.total || 0),
          name: players.find((p) => p.user_id === uid)?.display_name || "Player",
          seat: Number(players.find((p) => p.user_id === uid)?.seat || 999),
        }))
        .sort((a, b) => b.total - a.total || a.seat - b.seat);

      const top = scoreboard.length ? scoreboard[0].total : 0;
      const winners = scoreboard.filter((x) => Math.abs(x.total - top) < 1e-9);
      const header =
        winners.length === 0
          ? "Fantasy Flashbacks Results"
          : winners.length === 1
          ? `Fantasy Flashbacks Winner: ${winners[0].name}`
          : `Fantasy Flashbacks Tie: ${winners.map((w) => w.name).join(", ")}`;

      const wk = gameWeek ? `Week ${gameWeek.week}, ${gameWeek.season}` : "";
      const lines = scoreboard.map((s, i) => `${i + 1}. ${s.name} — ${s.total.toFixed(1)}`);

      const text = [header, wk, "", ...lines, "", window.location.href].filter(Boolean).join("\n");

      if (navigator.share) {
        await navigator.share({ title: "Fantasy Flashbacks Results", text });
      } else {
        await navigator.clipboard.writeText(text);
        setShareCopied(true);
        setTimeout(() => setShareCopied(false), 1500);
      }
    } catch (e) {
      flashNotice(`Share failed: ${safeMsg(e)}`);
    }
  };

  if (screen === "setup") {
    const handleNameKeyDown = (e) => {
      if (e.key !== "Enter") return;

      if (inviteRoom) {
        if (playerName.trim().length < 2) return;
        joinRoom().catch(() => {});
        return;
      }

      if (gameSettings.joinMode === "global") {
        startGlobalMatchmaking().catch(() => {});
        return;
      }

      if (roomCode.trim().length >= 4) joinRoom().catch(() => {});
    };

    const modeBtn = (id, label) => (
      <button
        onClick={() => setGameSettings((p) => ({ ...p, joinMode: id }))}
        className={`py-3 rounded font-bold transition ${
          gameSettings.joinMode === id ? "bg-blue-600 text-white" : "bg-slate-700/70 text-slate-200 hover:bg-slate-600"
        }`}
      >
        {label}
      </button>
    );

    const sizeBtn = (n) => (
      <button
        onClick={() => setGameSettings((p) => ({ ...p, maxPlayers: n }))}
        className={`py-3 rounded font-bold transition ${
          Number(gameSettings.maxPlayers) === n ? "bg-emerald-600 text-white" : "bg-slate-700/70 text-slate-200 hover:bg-slate-600"
        }`}
      >
        {n} Players
      </button>
    );

    const rosterControl = (key, label) => (
      <div className="flex items-center justify-between bg-slate-700/60 border border-slate-600 rounded p-3">
        <span className="text-sm font-semibold text-slate-100">{label}</span>
        <input
          type="number"
          min="0"
          max="6"
          value={gameSettings[key]}
          onChange={(e) => setGameSettings((p) => ({ ...p, [key]: parseInt(e.target.value, 10) || 0 }))}
          className="w-16 bg-slate-800/70 border border-slate-600 rounded px-2 py-1 text-center"
        />
      </div>
    );

    if (inviteRoom) {
      return (
        <div className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950 text-white p-4">
          <div className="max-w-xl mx-auto py-10">
            <div className="bg-slate-800/60 border border-slate-700 rounded-2xl p-6 shadow-[0_0_30px_rgba(99,102,241,0.15)]">
              <div className="flex items-center gap-3 mb-4">
                <img
                  src="/favicon.svg"
                  alt="Fantasy Flashbacks"
                  className="w-10 h-10"
                  onError={(e) => {
                    e.currentTarget.src = "/favicon.ico";
                  }}
                />
                <div>
                  <div className="text-lg font-bold">You’ve been invited</div>
                  <div className="text-xs text-slate-300">
                    Room: <span className="font-mono font-semibold">{inviteRoom}</span>
                  </div>
                </div>
              </div>

              <div className="text-sm text-slate-300 mb-4">Enter your name to join.</div>

              <input
                type="text"
                placeholder="Your display name"
                value={playerName}
                onChange={(e) => setPlayerName(e.target.value)}
                onKeyDown={handleNameKeyDown}
                className="w-full bg-slate-900/60 border border-slate-700 rounded-lg px-4 py-3 text-white placeholder-slate-400"
              />

              {notice ? <div className="mt-2 text-xs text-amber-200">{notice}</div> : null}

              <button
                onClick={() => joinRoom().catch(() => {})}
                disabled={busy || playerName.trim().length < 2}
                className="mt-4 w-full bg-gradient-to-r from-emerald-600 to-emerald-700 hover:from-emerald-500 hover:to-emerald-600 disabled:from-slate-700 disabled:to-slate-700 py-3 rounded-lg font-bold transition"
              >
                {busy ? "Joining…" : "Join Room"}
              </button>

              <button
                onClick={() => {
                  setInviteRoom(null);
                  setRoomCode("");
                  window.history.replaceState({}, "", window.location.pathname);
                }}
                className="mt-2 w-full bg-slate-700 hover:bg-slate-600 py-2 rounded-lg text-sm font-medium transition"
              >
                Back to Menu
              </button>

              <div className="mt-3 text-xs text-slate-400">Auto-join will start a couple seconds after you stop typing.</div>
            </div>
          </div>
        </div>
      );
    }

    return (
      <div className="min-h-screen text-white p-4 bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950">
        <div className="max-w-5xl mx-auto py-10">
          <div className="relative overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/40 p-6 mb-6">
            <div className="absolute -top-24 -right-24 w-80 h-80 bg-purple-500/10 rounded-full blur-3xl pointer-events-none" />
            <div className="absolute -bottom-24 -left-24 w-80 h-80 bg-emerald-500/10 rounded-full blur-3xl pointer-events-none" />

            <div className="relative z-10 flex items-center justify-between gap-4">
              <div className="flex items-center gap-3">
                <img
                  src="/favicon.svg"
                  alt="Fantasy Flashbacks"
                  className="w-10 h-10"
                  onError={(e) => {
                    e.currentTarget.src = "/favicon.ico";
                  }}
                />
                <div>
                  <h1 className="text-3xl md:text-4xl font-extrabold tracking-tight">
                    <span className="bg-gradient-to-r from-emerald-300 to-purple-300 bg-clip-text text-transparent">
                      Fantasy Flashbacks
                    </span>
                  </h1>
                  <p className="text-slate-300 text-sm mt-1">Draft Classic NFL Weeks Live</p>
                </div>
              </div>

              <div className="flex items-center gap-4">
                <div className="hidden md:block text-right">
                  <div className="text-xs text-slate-400">Realtime draft • Auto-draft on disconnect</div>
                  <div className="text-xs text-slate-400">Draft order randomized at start</div>
                </div>

                {/* Profile / Sign-in button */}
                <button
                  onClick={() => setShowSignIn(true)}
                  className="flex items-center gap-2 bg-slate-700/60 hover:bg-slate-600/60 border border-slate-600 rounded-lg px-3 py-2 transition"
                >
                  {userProfile ? (
                    <>
                      <div className="w-7 h-7 rounded-full bg-emerald-600 flex items-center justify-center text-xs font-bold">
                        {userProfile.avatar_url || (userProfile.display_name || "P")[0].toUpperCase()}
                      </div>
                      <div className="hidden sm:block text-left">
                        <div className="text-xs font-semibold truncate max-w-[80px]">{userProfile.display_name || "Player"}</div>
                        <div className="text-[10px] text-slate-400 flex items-center gap-1">
                          {engagementStats && (
                            <>
                              <Zap className="w-3 h-3 text-amber-400" />
                              <span className="text-amber-400">{(engagementStats.flashback_points || 0).toLocaleString()}</span>
                              {engagementStats.current_streak > 0 && (
                                <>
                                  <span className="mx-0.5">•</span>
                                  <Flame className="w-3 h-3 text-orange-400" />
                                  <span className="text-orange-400">{engagementStats.current_streak}</span>
                                </>
                              )}
                            </>
                          )}
                          {!engagementStats && (
                            <span>{userProfile.games_won}W • {userProfile.highest_score?.toFixed(1) || 0} best</span>
                          )}
                        </div>
                      </div>
                    </>
                  ) : (
                    <>
                      <Users className="w-4 h-4" />
                      <span className="text-xs font-medium">Sign In</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          </div>

          {/* Sign-in / Profile Modal */}
          {showSignIn && (
            <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
              <div className="bg-slate-800 border border-slate-700 rounded-2xl p-6 w-full max-w-sm shadow-2xl">
                <div className="flex items-center justify-between mb-4">
                  <h3 className="text-lg font-bold">
                    {userProfile && !isAnonymous ? "Your Profile" : "Sign In"}
                  </h3>
                  <button onClick={() => setShowSignIn(false)} className="text-slate-400 hover:text-white">
                    <X className="w-5 h-5" />
                  </button>
                </div>

                {userProfile && !isAnonymous ? (
                  /* Signed-in profile view */
                  <div>
                    <div className="flex items-center gap-3 mb-4">
                      <button
                        onClick={() => setShowEmojiPicker(v => !v)}
                        className="relative w-12 h-12 rounded-full bg-emerald-600 flex items-center justify-center text-xl font-bold group hover:ring-2 hover:ring-emerald-400 transition"
                        title="Change profile icon"
                      >
                        {userProfile.avatar_url || (userProfile.display_name || "P")[0].toUpperCase()}
                        <span className="absolute inset-0 rounded-full bg-black/40 opacity-0 group-hover:opacity-100 flex items-center justify-center transition text-xs">
                          ✏️
                        </span>
                      </button>
                      <div className="flex-1">
                        {editingName ? (
                          <div className="flex gap-2">
                            <input
                              type="text"
                              value={editNameValue}
                              onChange={(e) => setEditNameValue(e.target.value)}
                              onKeyDown={(e) => e.key === "Enter" && updateDisplayName()}
                              className="flex-1 bg-slate-700 border border-slate-600 rounded px-2 py-1 text-sm"
                              autoFocus
                              maxLength={20}
                            />
                            <button
                              onClick={updateDisplayName}
                              className="bg-emerald-600 hover:bg-emerald-500 px-2 py-1 rounded text-xs font-medium"
                            >
                              Save
                            </button>
                            <button
                              onClick={() => setEditingName(false)}
                              className="bg-slate-600 hover:bg-slate-500 px-2 py-1 rounded text-xs"
                            >
                              Cancel
                            </button>
                          </div>
                        ) : (
                          <div className="flex items-center gap-2">
                            <span className="font-semibold">{userProfile.display_name || "Player"}</span>
                            {!userProfile.name_changed && (
                              <button
                                onClick={() => {
                                  setEditNameValue(userProfile.display_name || "");
                                  setEditingName(true);
                                }}
                                className="text-slate-400 hover:text-white text-xs"
                              >
                                (edit)
                              </button>
                            )}
                          </div>
                        )}
                        <div className="text-xs text-slate-400">
                          via {userProfile.provider === "google" ? "Google" : userProfile.provider === "apple" ? "Apple" : "Account"}
                        </div>
                      </div>
                    </div>

                    {/* Emoji Picker */}
                    {showEmojiPicker && (
                      <div className="mb-4 bg-slate-700/50 border border-slate-600 rounded-lg p-3">
                        <div className="text-xs font-semibold text-slate-400 mb-2">Choose Profile Icon</div>
                        <div className="grid grid-cols-10 gap-1">
                          {PROFILE_EMOJIS.map((emoji) => (
                            <button
                              key={emoji}
                              onClick={() => updateAvatar(emoji)}
                              className={`w-8 h-8 flex items-center justify-center rounded hover:bg-slate-600 transition text-lg ${
                                userProfile?.avatar_url === emoji ? "bg-emerald-600/40 ring-1 ring-emerald-400" : ""
                              }`}
                            >
                              {emoji}
                            </button>
                          ))}
                        </div>
                        {userProfile?.avatar_url && (
                          <button
                            onClick={() => updateAvatar(null)}
                            className="mt-2 text-xs text-slate-400 hover:text-white transition"
                          >
                            Clear icon (use initial)
                          </button>
                        )}
                      </div>
                    )}

                    {/* Engagement Stats Section */}
                    {engagementStats && (
                      <div className="bg-gradient-to-r from-amber-900/20 to-orange-900/20 border border-amber-500/20 rounded-lg p-3 mb-4">
                        <div className="flex items-center justify-between mb-2">
                          <div className="flex items-center gap-2">
                            <Zap className="w-5 h-5 text-amber-400" />
                            <span className="text-sm font-semibold text-amber-200">
                              {(engagementStats.flashback_points || 0).toLocaleString()} FP
                            </span>
                          </div>
                          <div className="flex items-center gap-1 text-xs">
                            <span className="px-2 py-0.5 rounded bg-amber-500/20 text-amber-300 capitalize font-medium">
                              {engagementStats.tier_name || "Rookie"}
                            </span>
                          </div>
                        </div>

                        {/* Tier Progress */}
                        {engagementStats.tier !== "goat" && (
                          <div className="mb-2">
                            <div className="flex justify-between text-[10px] text-slate-400 mb-1">
                              <span>Progress to {(engagementStats.next_tier || "").replace("_", " ")}</span>
                              <span>{Math.round(engagementStats.tier_progress_percent || 0)}%</span>
                            </div>
                            <div className="h-1.5 bg-slate-700 rounded-full overflow-hidden">
                              <div
                                className="h-full bg-gradient-to-r from-amber-500 to-orange-500"
                                style={{ width: `${Math.min(engagementStats.tier_progress_percent || 0, 100)}%` }}
                              />
                            </div>
                          </div>
                        )}

                        {/* Streak Info */}
                        <div className="flex items-center justify-between text-xs">
                          <div className="flex items-center gap-1">
                            <Flame className={`w-4 h-4 ${engagementStats.current_streak > 0 ? "text-orange-400" : "text-slate-500"}`} />
                            <span className={engagementStats.current_streak > 0 ? "text-orange-300" : "text-slate-500"}>
                              {engagementStats.current_streak || 0} day streak
                            </span>
                          </div>
                          {engagementStats.longest_streak > 0 && (
                            <span className="text-slate-500">Best: {engagementStats.longest_streak}</span>
                          )}
                        </div>

                        {/* Streak Multiplier Info */}
                        {engagementStats.streak_multiplier > 1 && (
                          <div className="mt-2 text-[10px] text-emerald-400 text-center">
                            {engagementStats.streak_multiplier}x streak bonus active
                          </div>
                        )}
                      </div>
                    )}

                    <div className="grid grid-cols-3 gap-3 mb-4">
                      <div className="bg-slate-700/50 rounded-lg p-3 text-center">
                        <div className="text-xl font-bold text-emerald-400">{userProfile.games_won || 0}</div>
                        <div className="text-[10px] text-slate-400 uppercase">Wins</div>
                      </div>
                      <div className="bg-slate-700/50 rounded-lg p-3 text-center">
                        <div className="text-xl font-bold text-blue-400">{userProfile.games_played || 0}</div>
                        <div className="text-[10px] text-slate-400 uppercase">Played</div>
                      </div>
                      <div className="bg-slate-700/50 rounded-lg p-3 text-center">
                        <div className="text-xl font-bold text-purple-400">{userProfile.highest_score?.toFixed(1) || 0}</div>
                        <div className="text-[10px] text-slate-400 uppercase">Best</div>
                      </div>
                    </div>

                    {/* Game Type Stats */}
                    {engagementStats && (engagementStats.multiplayer_games > 0 || engagementStats.solo_games > 0) && (
                      <div className="grid grid-cols-2 gap-3 mb-4">
                        <div className="bg-slate-700/30 rounded-lg p-2 text-center">
                          <div className="text-sm font-bold text-blue-300">{engagementStats.multiplayer_games || 0}</div>
                          <div className="text-[10px] text-slate-400">Multiplayer</div>
                        </div>
                        <div className="bg-slate-700/30 rounded-lg p-2 text-center">
                          <div className="text-sm font-bold text-slate-300">{engagementStats.solo_games || 0}</div>
                          <div className="text-[10px] text-slate-400">Solo</div>
                        </div>
                      </div>
                    )}

                    {/* Skill Rating Section */}
                    {skillRating && (() => {
                      const sr = skillRating;
                      const skillScore = Math.round(sr.skill_score || 0);
                      const winRate = (sr.win_rate || 0);
                      const avgMargin = sr.avg_margin || 0;
                      const avgOpponents = sr.avg_opponents || 2;
                      const gamesRated = sr.games_rated || 0;

                      // Calculate individual component contributions
                      const winRateContrib = (winRate * 0.40);
                      const marginBonus = Math.max(0, Math.min(100, 50 + avgMargin));
                      const marginContrib = (marginBonus * 0.30);
                      const opponentBonus = avgOpponents >= 4 ? 90 : avgOpponents >= 3 ? 80 : avgOpponents >= 2.5 ? 75 : avgOpponents >= 2 ? 70 : 60;
                      const opponentContrib = (opponentBonus * 0.30);

                      // Skill rating color based on score
                      const skillColor = skillScore >= 80 ? "text-amber-400" :
                                        skillScore >= 60 ? "text-emerald-400" :
                                        skillScore >= 40 ? "text-blue-400" : "text-slate-400";
                      const skillBg = skillScore >= 80 ? "from-amber-900/30 to-yellow-900/30 border-amber-500/30" :
                                     skillScore >= 60 ? "from-emerald-900/30 to-green-900/30 border-emerald-500/30" :
                                     skillScore >= 40 ? "from-blue-900/30 to-cyan-900/30 border-blue-500/30" :
                                     "from-slate-700/30 to-slate-800/30 border-slate-500/30";
                      return (
                        <div className={`relative group bg-gradient-to-r ${skillBg} border rounded-lg p-3 mb-4 cursor-help`}>
                          {/* Hover tooltip */}
                          <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 w-64 bg-slate-900 border border-slate-600 rounded-lg p-3 opacity-0 group-hover:opacity-100 transition-opacity z-20 pointer-events-none shadow-xl">
                            <div className="text-xs font-semibold text-slate-200 mb-2 text-center">Skill Rating Breakdown</div>
                            <div className="space-y-2 text-[11px]">
                              <div className="flex justify-between items-center">
                                <span className="text-slate-400">Win Rate <span className="text-slate-500">(40%)</span></span>
                                <span className="text-emerald-400 font-medium">+{winRateContrib.toFixed(1)} pts</span>
                              </div>
                              <div className="flex justify-between text-[10px] text-slate-500 -mt-1 pl-2">
                                <span>{winRate.toFixed(1)}% wins</span>
                              </div>
                              <div className="flex justify-between items-center">
                                <span className="text-slate-400">Margin Bonus <span className="text-slate-500">(30%)</span></span>
                                <span className="text-blue-400 font-medium">+{marginContrib.toFixed(1)} pts</span>
                              </div>
                              <div className="flex justify-between text-[10px] text-slate-500 -mt-1 pl-2">
                                <span>Avg {avgMargin >= 0 ? "+" : ""}{avgMargin.toFixed(1)} vs opponents</span>
                              </div>
                              <div className="flex justify-between items-center">
                                <span className="text-slate-400">Opponent Bonus <span className="text-slate-500">(30%)</span></span>
                                <span className="text-purple-400 font-medium">+{opponentContrib.toFixed(1)} pts</span>
                              </div>
                              <div className="flex justify-between text-[10px] text-slate-500 -mt-1 pl-2">
                                <span>Avg {avgOpponents.toFixed(1)} players/game</span>
                              </div>
                              <div className="border-t border-slate-700 pt-2 mt-2 flex justify-between items-center font-semibold">
                                <span className="text-slate-300">Total Skill Score</span>
                                <span className={skillColor}>{skillScore}</span>
                              </div>
                            </div>
                            {/* Tooltip arrow */}
                            <div className="absolute top-full left-1/2 -translate-x-1/2 border-8 border-transparent border-t-slate-600" />
                          </div>

                          <div className="flex items-center justify-between mb-2">
                            <div className="flex items-center gap-2">
                              <TrendingUp className={`w-5 h-5 ${skillColor}`} />
                              <span className="text-sm font-semibold text-slate-200">Skill Rating</span>
                              <span className="text-[10px] text-slate-500">(hover for details)</span>
                            </div>
                            <div className={`text-2xl font-bold ${skillColor}`}>
                              {skillScore}
                            </div>
                          </div>
                          <div className="flex justify-between text-xs text-slate-400">
                            <span>Win Rate: <span className="text-slate-200">{winRate.toFixed(1)}%</span></span>
                            <span>Games Rated: <span className="text-slate-200">{gamesRated}</span></span>
                          </div>
                          {/* Skill bar visualization */}
                          <div className="mt-2 h-1.5 bg-slate-700 rounded-full overflow-hidden">
                            <div
                              className={`h-full ${skillScore >= 80 ? "bg-gradient-to-r from-amber-500 to-yellow-400" :
                                                  skillScore >= 60 ? "bg-gradient-to-r from-emerald-500 to-green-400" :
                                                  skillScore >= 40 ? "bg-gradient-to-r from-blue-500 to-cyan-400" :
                                                  "bg-slate-500"}`}
                              style={{ width: `${skillScore}%` }}
                            />
                          </div>
                        </div>
                      );
                    })()}

                    {/* Flashback ID for friends */}
                    {userProfile.flashback_id && (
                      <div className="bg-slate-700/30 rounded-lg p-2 mb-4 text-center">
                        <div className="text-[10px] text-slate-400 mb-1">Your Flashback ID</div>
                        <div className="text-sm font-mono font-bold text-emerald-400">{userProfile.flashback_id}</div>
                      </div>
                    )}

                    {/* User Badges */}
                    {userBadges.length > 0 && (
                      <div className="mb-4">
                        <div className="text-xs font-semibold text-slate-300 mb-2">Badges Earned ({userBadges.length})</div>
                        <div className="grid grid-cols-5 gap-2">
                          {userBadges.slice(0, 10).map((badge) => (
                            <div
                              key={badge.badge_key}
                              className={`relative group aspect-square rounded-lg bg-gradient-to-br ${RARITY_COLORS[badge.rarity] || RARITY_COLORS.common} border flex items-center justify-center cursor-pointer hover:scale-110 transition-transform`}
                              title={`${badge.name}: ${badge.rarity}`}
                            >
                              <span className="text-xl">{badge.icon}</span>
                              <div className="absolute -bottom-8 left-1/2 -translate-x-1/2 bg-slate-900 border border-slate-600 rounded px-2 py-1 text-[10px] whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity z-10 pointer-events-none">
                                <div className="font-semibold">{badge.name}</div>
                                <div className="text-slate-400 capitalize">{badge.rarity}</div>
                              </div>
                            </div>
                          ))}
                        </div>
                        {userBadges.length > 10 && (
                          <div className="text-[10px] text-slate-500 text-center mt-2">
                            +{userBadges.length - 10} more badges
                          </div>
                        )}
                      </div>
                    )}

                    {/* Friends & Referrals Buttons */}
                    <div className="grid grid-cols-2 gap-2 mb-2">
                      <button
                        onClick={() => {
                          setShowSignIn(false);
                          setShowFriendsModal(true);
                        }}
                        className="bg-blue-600 hover:bg-blue-500 py-2 rounded-lg text-sm font-medium transition flex items-center justify-center gap-1"
                      >
                        <Users size={14} />
                        Friends{friendsList.length > 0 && ` (${friendsList.length})`}
                        {friendRequests.length > 0 && (
                          <span className="bg-red-500 text-white text-[10px] px-1 rounded-full">{friendRequests.length}</span>
                        )}
                      </button>
                      <button
                        onClick={() => {
                          setShowSignIn(false);
                          setShowReferralModal(true);
                        }}
                        className="bg-purple-600 hover:bg-purple-500 py-2 rounded-lg text-sm font-medium transition flex items-center justify-center gap-1"
                      >
                        <Gift size={14} />
                        Referrals
                      </button>
                    </div>

                    <button
                      onClick={signOut}
                      className="w-full bg-slate-700 hover:bg-slate-600 py-2 rounded-lg text-sm font-medium transition"
                    >
                      Sign Out
                    </button>
                  </div>
                ) : (
                  /* Sign-in options */
                  <div>
                    <p className="text-sm text-slate-300 mb-4">
                      Sign in to save your stats, appear on leaderboards, and keep your game history.
                    </p>

                    {userProfile && (
                      <div className="bg-slate-700/30 border border-slate-600 rounded-lg p-3 mb-4">
                        <div className="text-xs text-slate-400 mb-1">Playing as guest</div>
                        <div className="font-semibold">{playerName || "Anonymous"}</div>
                        <div className="text-xs text-slate-400 mt-1">
                          {userProfile.games_played || 0} games • {userProfile.games_won || 0} wins
                        </div>
                      </div>
                    )}

                    <div className="space-y-3">
                      <button
                        onClick={signInWithGoogle}
                        className="w-full flex items-center justify-center gap-3 bg-white hover:bg-gray-100 text-gray-800 py-3 rounded-lg font-medium transition"
                      >
                        <svg className="w-5 h-5" viewBox="0 0 24 24">
                          <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
                          <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
                          <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>
                          <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
                        </svg>
                        Continue with Google
                      </button>

                      {/* Apple Sign-In - uncomment when configured
                      <button
                        onClick={signInWithApple}
                        className="w-full flex items-center justify-center gap-3 bg-black hover:bg-gray-900 text-white py-3 rounded-lg font-medium transition border border-slate-600"
                      >
                        <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                          <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.81-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/>
                        </svg>
                        Continue with Apple
                      </button>
                      */}
                    </div>

                    <div className="mt-4 text-center">
                      <button
                        onClick={() => setShowSignIn(false)}
                        className="text-sm text-slate-400 hover:text-white"
                      >
                        Continue as guest
                      </button>
                    </div>
                  </div>
                )}
              </div>
            </div>
          )}

          {/* Friends Modal */}
          {showFriendsModal && (
            <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
              <div className="bg-slate-800 border border-slate-700 rounded-2xl p-6 w-full max-w-md shadow-2xl max-h-[80vh] overflow-hidden flex flex-col">
                <div className="flex items-center justify-between mb-4">
                  <h3 className="text-lg font-bold">Friends</h3>
                  <button onClick={() => { setShowFriendsModal(false); setBtnConfirm(null); setFriendSearchResult(null); setFriendSearchId(""); }} className="text-slate-400 hover:text-white">
                    <X className="w-5 h-5" />
                  </button>
                </div>

                {/* Tabs */}
                <div className="flex gap-1 mb-4 bg-slate-700/50 rounded-lg p-1">
                  <button
                    onClick={() => setFriendsTab("friends")}
                    className={`flex-1 py-2 px-2 rounded-md text-xs font-medium transition ${
                      friendsTab === "friends" ? "bg-blue-600 text-white" : "text-slate-400 hover:text-white"
                    }`}
                  >
                    Friends
                  </button>
                  <button
                    onClick={() => {
                      setFriendsTab("leaderboard");
                      if (userId) {
                        fetchFriendsLeaderboard(userId);
                      }
                    }}
                    className={`flex-1 py-2 px-2 rounded-md text-xs font-medium transition ${
                      friendsTab === "leaderboard" ? "bg-blue-600 text-white" : "text-slate-400 hover:text-white"
                    }`}
                  >
                    Leaderboard
                  </button>
                  <button
                    onClick={() => setFriendsTab("requests")}
                    className={`flex-1 py-2 px-2 rounded-md text-xs font-medium transition relative ${
                      friendsTab === "requests" ? "bg-blue-600 text-white" : "text-slate-400 hover:text-white"
                    }`}
                  >
                    Requests
                    {friendRequests.length > 0 && (
                      <span className="absolute -top-1 -right-1 bg-red-500 text-white text-xs w-5 h-5 rounded-full flex items-center justify-center">
                        {friendRequests.length}
                      </span>
                    )}
                  </button>
                  <button
                    onClick={() => setFriendsTab("add")}
                    className={`flex-1 py-2 px-2 rounded-md text-xs font-medium transition ${
                      friendsTab === "add" ? "bg-blue-600 text-white" : "text-slate-400 hover:text-white"
                    }`}
                  >
                    Add
                  </button>
                </div>

                {/* Tab Content */}
                <div className="flex-1 overflow-y-auto">
                  {friendsTab === "friends" && (
                    <div className="space-y-2">
                      {friendsList.length === 0 ? (
                        <div className="text-center py-8 text-slate-400">
                          <Users className="w-12 h-12 mx-auto mb-2 opacity-50" />
                          <p>No friends yet</p>
                          <p className="text-sm">Add friends to play together!</p>
                        </div>
                      ) : (
                        friendsList.map((friend) => (
                          <div key={friend.friend_user_id || friend.friendship_id} className="flex items-center gap-3 bg-slate-700/50 rounded-lg p-3">
                            <div className="relative">
                              <div className="w-10 h-10 rounded-full bg-blue-600 flex items-center justify-center font-bold">
                                {friend.friend_avatar_url || friend.avatar_url || (friend.friend_display_name || friend.display_name || "?")[0].toUpperCase()}
                              </div>
                              {friend.is_online && (
                                <div className="absolute -bottom-0.5 -right-0.5 w-3 h-3 bg-emerald-500 rounded-full border-2 border-slate-700" />
                              )}
                            </div>
                            <div className="flex-1 min-w-0">
                              <div className="font-semibold truncate">{friend.friend_display_name || friend.display_name}</div>
                              <div className="text-xs text-slate-400 flex items-center gap-2">
                                <span className="capitalize">{(friend.friend_tier || friend.tier || "rookie").replace("_", " ")}</span>
                                {friend.games_together > 0 && (
                                  <span>• {friend.games_together} games together</span>
                                )}
                              </div>
                            </div>
                            <button
                              onClick={() => {
                                // TODO: Invite to game
                                setShowFriendsModal(false);
                              }}
                              className="bg-emerald-600 hover:bg-emerald-500 px-3 py-1.5 rounded text-xs font-medium"
                            >
                              Invite
                            </button>
                          </div>
                        ))
                      )}
                    </div>
                  )}

                  {friendsTab === "leaderboard" && (
                    <div className="space-y-2">
                      {friendsLeaderboard.length === 0 ? (
                        <div className="text-center py-8 text-slate-400">
                          <Trophy className="w-12 h-12 mx-auto mb-2 opacity-50" />
                          <p>No leaderboard data</p>
                          <p className="text-sm">Add friends to compare FP!</p>
                        </div>
                      ) : (
                        <>
                          {/* Leaderboard Header */}
                          <div className="grid grid-cols-12 gap-2 px-2 py-1 text-[10px] font-semibold text-slate-400 uppercase">
                            <div className="col-span-1">#</div>
                            <div className="col-span-5">Player</div>
                            <div className="col-span-3 text-right">FP</div>
                            <div className="col-span-3 text-right">Skill</div>
                          </div>
                          {friendsLeaderboard.map((entry) => (
                            <div
                              key={entry.user_id}
                              className={`grid grid-cols-12 gap-2 items-center rounded-lg p-2 ${
                                entry.is_current_user
                                  ? "bg-gradient-to-r from-blue-900/40 to-blue-800/40 border border-blue-500/30"
                                  : "bg-slate-700/30"
                              }`}
                            >
                              {/* Rank */}
                              <div className="col-span-1">
                                <span className={`text-sm font-bold ${
                                  entry.rank === 1 ? "text-amber-400" :
                                  entry.rank === 2 ? "text-slate-300" :
                                  entry.rank === 3 ? "text-orange-400" : "text-slate-400"
                                }`}>
                                  {entry.rank}
                                </span>
                              </div>

                              {/* Player Info */}
                              <div className="col-span-5 flex items-center gap-2 min-w-0">
                                <div className={`w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold ${
                                  entry.is_current_user ? "bg-blue-600" : "bg-slate-600"
                                }`}>
                                  {entry.avatar_url || (entry.display_name || "?")[0].toUpperCase()}
                                </div>
                                <div className="min-w-0">
                                  <div className={`text-sm font-medium truncate ${entry.is_current_user ? "text-blue-200" : ""}`}>
                                    {entry.is_current_user ? "You" : entry.display_name}
                                  </div>
                                  <div className="text-[10px] text-slate-400 flex items-center gap-1">
                                    <span className="capitalize">{(entry.tier || "rookie").replace("_", " ")}</span>
                                    {entry.current_streak > 0 && (
                                      <span className="text-orange-400">🔥{entry.current_streak}</span>
                                    )}
                                  </div>
                                </div>
                              </div>

                              {/* FP */}
                              <div className="col-span-3 text-right">
                                <div className="text-sm font-bold text-amber-400">
                                  {(entry.flashback_points || 0).toLocaleString()}
                                </div>
                                <div className="text-[10px] text-slate-500">
                                  {entry.win_rate?.toFixed(0) || 0}% win
                                </div>
                              </div>

                              {/* Skill Score */}
                              <div className="col-span-3 text-right">
                                <div className={`text-sm font-bold ${
                                  (entry.skill_score || 0) >= 80 ? "text-amber-400" :
                                  (entry.skill_score || 0) >= 60 ? "text-emerald-400" :
                                  (entry.skill_score || 0) >= 40 ? "text-blue-400" : "text-slate-400"
                                }`}>
                                  {Math.round(entry.skill_score || 0)}
                                </div>
                                {!entry.is_current_user && entry.games_together > 0 && (
                                  <div className="text-[10px] text-slate-500">
                                    {entry.games_together} games
                                  </div>
                                )}
                              </div>
                            </div>
                          ))}
                        </>
                      )}
                    </div>
                  )}

                  {friendsTab === "requests" && (
                    <div className="space-y-2">
                      {/* Incoming requests */}
                      {friendRequests.length > 0 && (
                        <>
                          <div className="text-xs font-semibold text-slate-400 mb-2">Incoming Requests</div>
                          {friendRequests.map((request) => (
                            <div key={request.sender_user_id || request.id} className="flex items-center gap-3 bg-slate-700/50 rounded-lg p-3">
                              <div className="w-10 h-10 rounded-full bg-purple-600 flex items-center justify-center font-bold">
                                {request.avatar_url || (request.display_name || "?")[0].toUpperCase()}
                              </div>
                              <div className="flex-1 min-w-0">
                                <div className="font-semibold truncate">{request.display_name}</div>
                                <div className="text-xs text-slate-400">
                                  {request.flashback_id}
                                </div>
                              </div>
                              <div className="flex gap-2">
                                {btnConfirm === `accepted-${request.sender_user_id}` ? (
                                  <span className="text-xs text-green-400 font-medium px-3 py-1.5 flex items-center gap-1"><Check size={12} /> Accepted</span>
                                ) : (
                                  <>
                                    <button
                                      onClick={() => acceptFriendRequest(request.sender_user_id)}
                                      className="bg-emerald-600 hover:bg-emerald-500 px-3 py-1.5 rounded text-xs font-medium"
                                    >
                                      Accept
                                    </button>
                                    <button
                                      className="bg-slate-600 hover:bg-slate-500 px-3 py-1.5 rounded text-xs font-medium"
                                    >
                                      Decline
                                    </button>
                                  </>
                                )}
                              </div>
                            </div>
                          ))}
                        </>
                      )}

                      {/* Sent requests (pending) */}
                      {sentRequests.length > 0 && (
                        <>
                          <div className="text-xs font-semibold text-slate-400 mt-4 mb-2">Sent Requests</div>
                          {sentRequests.map((request) => (
                            <div key={request.user_id || request.friend_id} className="flex items-center gap-3 bg-slate-700/30 rounded-lg p-3">
                              <div className="w-10 h-10 rounded-full bg-blue-600 flex items-center justify-center font-bold">
                                {request.avatar_url || (request.display_name || "?")[0].toUpperCase()}
                              </div>
                              <div className="flex-1 min-w-0">
                                <div className="font-semibold truncate">{request.display_name}</div>
                                <div className="text-xs text-slate-400">
                                  {request.flashback_id}
                                </div>
                              </div>
                              <span className="text-xs text-amber-400 font-medium px-3 py-1.5">Pending</span>
                            </div>
                          ))}
                        </>
                      )}

                      {friendRequests.length === 0 && sentRequests.length === 0 && (
                        <div className="text-center py-8 text-slate-400">
                          <p>No pending requests</p>
                        </div>
                      )}

                      {/* Recent Players Section */}
                      {recentPlayers.length > 0 && (
                        <>
                          <div className="text-xs font-semibold text-slate-400 mt-4 mb-2">Recently Played With</div>
                          {recentPlayers.filter(p => !p.is_friend).map((player) => (
                            <div key={player.user_id} className="flex items-center gap-3 bg-slate-700/30 rounded-lg p-3">
                              <div className="w-10 h-10 rounded-full bg-slate-600 flex items-center justify-center font-bold">
                                {player.avatar_url || (player.display_name || "?")[0].toUpperCase()}
                              </div>
                              <div className="flex-1 min-w-0">
                                <div className="font-semibold truncate">{player.display_name}</div>
                                <div className="text-xs text-slate-400">{player.flashback_id}</div>
                              </div>
                              <button
                                onClick={() => sendFriendRequest(player.user_id)}
                                className="bg-blue-600 hover:bg-blue-500 px-3 py-1.5 rounded text-xs font-medium"
                              >
                                Add
                              </button>
                            </div>
                          ))}
                        </>
                      )}
                    </div>
                  )}

                  {friendsTab === "add" && (
                    <div>
                      <div className="mb-4">
                        <label className="block text-sm font-medium text-slate-300 mb-2">
                          Add by Flashback ID
                        </label>
                        <div className="flex gap-2">
                          <input
                            type="text"
                            value={friendSearchId}
                            onChange={(e) => setFriendSearchId(e.target.value.toUpperCase())}
                            placeholder="FF-ABC1234"
                            className="flex-1 bg-slate-700 border border-slate-600 rounded-lg px-3 py-2 text-sm placeholder-slate-500 focus:outline-none focus:border-blue-500"
                          />
                          <button
                            onClick={() => searchUserByFlashbackId(friendSearchId)}
                            className="bg-blue-600 hover:bg-blue-500 px-4 py-2 rounded-lg text-sm font-medium"
                          >
                            Search
                          </button>
                        </div>
                        {friendSearchError && (
                          <p className="text-red-400 text-xs mt-2">{friendSearchError}</p>
                        )}
                      </div>

                      {/* Search Result */}
                      {friendSearchResult && (
                        <div className="bg-slate-700/50 rounded-lg p-4">
                          <div className="flex items-center gap-3">
                            <div className="w-12 h-12 rounded-full bg-emerald-600 flex items-center justify-center text-xl font-bold">
                              {friendSearchResult.avatar_url || (friendSearchResult.display_name || "?")[0].toUpperCase()}
                            </div>
                            <div className="flex-1">
                              <div className="font-semibold">{friendSearchResult.display_name}</div>
                              <div className="text-xs text-slate-400">
                                {friendSearchResult.flashback_id} • {(friendSearchResult.tier || "rookie").replace("_", " ")}
                              </div>
                            </div>
                          </div>
                          <button
                            onClick={() => { if (!btnConfirm?.startsWith("friend-")) sendFriendRequest(friendSearchResult.user_id); }}
                            disabled={!!btnConfirm?.startsWith("friend-")}
                            className={`w-full mt-3 py-2 rounded-lg text-sm font-medium transition-all ${
                              btnConfirm === "friend-sent" ? "bg-green-600 cursor-default" :
                              btnConfirm?.startsWith("friend-error") ? "bg-red-600 cursor-default" :
                              "bg-emerald-600 hover:bg-emerald-500"
                            }`}
                          >
                            {btnConfirm === "friend-sent"
                              ? <span className="flex items-center justify-center gap-2"><Check size={16} /> Request Sent!</span>
                              : btnConfirm?.startsWith("friend-error:")
                              ? btnConfirm.split(":")[1]
                              : "Send Friend Request"}
                          </button>
                        </div>
                      )}

                      {/* Your Flashback ID */}
                      <div className="mt-6 bg-slate-700/30 rounded-lg p-4 text-center">
                        <div className="text-xs text-slate-400 mb-1">Share your Flashback ID</div>
                        <div className="text-lg font-mono font-bold text-emerald-400">
                          {userProfile?.flashback_id || "Sign in to get ID"}
                        </div>
                        <button
                          onClick={async () => {
                            const id = userProfile?.flashback_id || "";
                            if (id) {
                              const ok = await copyToClipboard(id);
                              if (ok) {
                                setBtnConfirm("flashback-id");
                                setTimeout(() => setBtnConfirm(null), 2000);
                              }
                            }
                          }}
                          className={`mt-2 text-xs transition-colors ${btnConfirm === "flashback-id" ? "text-green-400" : "text-blue-400 hover:text-blue-300"}`}
                        >
                          {btnConfirm === "flashback-id" ? "Copied!" : "Tap to copy"}
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              </div>
            </div>
          )}

          {/* Referral Modal */}
          {showReferralModal && (
            <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
              <div className="bg-slate-800 border border-slate-700 rounded-2xl p-6 w-full max-w-md shadow-2xl max-h-[80vh] overflow-y-auto">
                <div className="flex items-center justify-between mb-4">
                  <h3 className="text-lg font-bold flex items-center gap-2">
                    <Gift className="w-5 h-5 text-purple-400" />
                    Referrals
                  </h3>
                  <button onClick={() => setShowReferralModal(false)} className="text-slate-400 hover:text-white">
                    <X className="w-5 h-5" />
                  </button>
                </div>

                {(() => {
                  const stats = referralStats;
                  const code = stats?.referral_code || userProfile?.referral_code || null;

                  return (
                    <>
                      {/* Your Referral Code */}
                      <div className="bg-gradient-to-r from-purple-900/30 to-indigo-900/30 border border-purple-500/30 rounded-xl p-4 mb-4">
                        <div className="text-center">
                          <div className="text-xs text-purple-300 font-semibold mb-1">YOUR REFERRAL CODE</div>
                          <div className="text-2xl font-mono font-bold text-purple-300 mb-2">
                            {code || "Sign in to get code"}
                          </div>
                          {code && (
                            <div className="flex gap-2 justify-center">
                              <button
                                onClick={async () => {
                                  const ok = await copyToClipboard(code);
                                  if (ok) {
                                    setBtnConfirm("referral-code");
                                    setTimeout(() => setBtnConfirm(null), 2000);
                                  }
                                }}
                                className={`px-4 py-2 rounded-lg text-sm font-medium flex items-center gap-2 transition-colors ${btnConfirm === "referral-code" ? "bg-green-600" : "bg-purple-600 hover:bg-purple-500"}`}
                              >
                                {btnConfirm === "referral-code" ? <><Check size={14} /> Copied!</> : <><Copy size={14} /> Copy Code</>}
                              </button>
                              <button
                                onClick={async () => {
                                  const text = `Join me on Fantasy Flashbacks! Use my referral code ${code} to get bonus rewards. https://fantasyflashbacks.com`;
                                  if (navigator.share) {
                                    navigator.share({ text });
                                  } else {
                                    const ok = await copyToClipboard(text);
                                    if (ok) {
                                      setBtnConfirm("referral-share");
                                      setTimeout(() => setBtnConfirm(null), 2000);
                                    }
                                  }
                                }}
                                className={`px-4 py-2 rounded-lg text-sm font-medium flex items-center gap-2 transition-colors ${btnConfirm === "referral-share" ? "bg-green-600" : "bg-slate-600 hover:bg-slate-500"}`}
                              >
                                {btnConfirm === "referral-share" ? <><Check size={14} /> Copied!</> : <><Share2 size={14} /> Share</>}
                              </button>
                            </div>
                          )}
                        </div>
                        <div className="text-xs text-slate-400 text-center mt-3">
                          You get <span className="text-amber-400 font-semibold">+100 FP</span> for each friend who joins!
                        </div>
                      </div>

                      {/* Referral Stats */}
                      {stats && (
                        <div className="grid grid-cols-3 gap-3 mb-4">
                          <div className="bg-slate-700/50 rounded-lg p-3 text-center">
                            <div className="text-xl font-bold text-emerald-400">{stats.completed_referrals || 0}</div>
                            <div className="text-[10px] text-slate-400">Completed</div>
                          </div>
                          <div className="bg-slate-700/50 rounded-lg p-3 text-center">
                            <div className="text-xl font-bold text-amber-400">{stats.pending_referrals || 0}</div>
                            <div className="text-[10px] text-slate-400">Pending</div>
                          </div>
                          <div className="bg-slate-700/50 rounded-lg p-3 text-center">
                            <div className="text-xl font-bold text-purple-400">{(stats.total_fp_earned || 0).toLocaleString()}</div>
                            <div className="text-[10px] text-slate-400">FP Earned</div>
                          </div>
                        </div>
                      )}

                      {/* Milestone Progress */}
                      {stats && stats.next_milestone && (
                        <div className="bg-slate-700/30 rounded-lg p-3 mb-4">
                          <div className="flex justify-between text-xs text-slate-400 mb-1">
                            <span>Next milestone: {stats.next_milestone} referrals</span>
                            <span>{stats.completed_referrals || 0} / {stats.next_milestone}</span>
                          </div>
                          <div className="h-2 bg-slate-700 rounded-full overflow-hidden">
                            <div
                              className="h-full bg-gradient-to-r from-purple-500 to-indigo-500"
                              style={{ width: `${((stats.completed_referrals || 0) / stats.next_milestone) * 100}%` }}
                            />
                          </div>
                          <div className="text-xs text-slate-500 mt-1">
                            {stats.referrals_to_next_milestone} more for milestone bonus!
                          </div>
                        </div>
                      )}

                      {/* Milestone Rewards */}
                      <div className="mb-4">
                        <div className="text-xs font-semibold text-slate-300 mb-2">Milestone Rewards</div>
                        <div className="space-y-2">
                          {REFERRAL_MILESTONES.map((m) => {
                            const isAchieved = (stats?.completed_referrals || 0) >= m.count;
                            return (
                              <div
                                key={m.count}
                                className={`flex items-center justify-between p-2 rounded-lg ${
                                  isAchieved ? "bg-emerald-900/30 border border-emerald-500/30" : "bg-slate-700/30"
                                }`}
                              >
                                <div className="flex items-center gap-2">
                                  <span className="text-lg">{isAchieved ? "✅" : "🎯"}</span>
                                  <div>
                                    <div className="text-sm font-medium">{m.badge}</div>
                                    <div className="text-xs text-slate-400">{m.count} referrals</div>
                                  </div>
                                </div>
                                <div className={`text-sm font-bold ${isAchieved ? "text-emerald-400" : "text-amber-400"}`}>
                                  +{m.bonus} FP
                                </div>
                              </div>
                            );
                          })}
                        </div>
                      </div>

                      {/* Enter Referral Code */}
                      <div className="border-t border-slate-700 pt-4">
                        <div className="text-xs font-semibold text-slate-300 mb-2">Have a referral code?</div>
                        <div className="flex gap-2">
                          <input
                            type="text"
                            value={referralCodeInput}
                            onChange={(e) => setReferralCodeInput(e.target.value.toUpperCase())}
                            placeholder="Enter code"
                            className="flex-1 bg-slate-700 border border-slate-600 rounded-lg px-3 py-2 text-sm placeholder-slate-500 focus:outline-none focus:border-purple-500"
                          />
                          <button
                            onClick={() => applyReferralCode(referralCodeInput)}
                            className="bg-purple-600 hover:bg-purple-500 px-4 py-2 rounded-lg text-sm font-medium"
                          >
                            Apply
                          </button>
                        </div>
                        {referralApplyResult && (
                          <div className={`mt-2 text-xs p-2 rounded ${
                            referralApplyResult.success
                              ? "bg-emerald-900/30 text-emerald-400"
                              : "bg-red-900/30 text-red-400"
                          }`}>
                            {referralApplyResult.message}
                            {referralApplyResult.referrer_name && (
                              <span> Referred by: <strong>{referralApplyResult.referrer_name}</strong></span>
                            )}
                          </div>
                        )}
                      </div>
                    </>
                  );
                })()}
              </div>
            </div>
          )}

          {/* Daily Challenge Card */}
          {dailyChallenge && (
            (() => {
              const challenge = dailyChallenge;
              const progress = Math.min((challenge.current_value / challenge.target_value) * 100, 100);
              const isComplete = challenge.current_value >= challenge.target_value;

              return (
                <div className={`mb-6 rounded-xl border p-4 ${
                  isComplete
                    ? "bg-gradient-to-r from-emerald-900/30 to-green-900/30 border-emerald-500/30"
                    : "bg-gradient-to-r from-indigo-900/30 to-purple-900/30 border-indigo-500/30"
                }`}>
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex items-center gap-3">
                      <div className={`w-12 h-12 rounded-xl flex items-center justify-center text-2xl ${
                        isComplete ? "bg-emerald-500/20" : "bg-indigo-500/20"
                      }`}>
                        {isComplete ? "✅" : (CHALLENGE_ICONS[challenge.challenge_type] || "🎯")}
                      </div>
                      <div>
                        <div className="flex items-center gap-2">
                          <span className="text-xs font-semibold text-indigo-300 uppercase tracking-wide">Daily Challenge</span>
                          {challengeTimeLeft && (
                            <span className="text-xs text-slate-400">
                              {isComplete ? `Resets in ${challengeTimeLeft}` : challengeTimeLeft}
                            </span>
                          )}
                        </div>
                        <div className="font-bold text-lg">{challenge.challenge_name}</div>
                        <div className="text-sm text-slate-400">{challenge.challenge_description}</div>
                      </div>
                    </div>
                    <div className="text-right shrink-0">
                      <div className={`text-xl font-bold ${isComplete ? "text-emerald-400" : "text-amber-400"}`}>
                        +{challenge.fp_reward} FP
                      </div>
                      {isComplete && (
                        <div className="text-xs text-emerald-400 font-semibold">COMPLETE!</div>
                      )}
                    </div>
                  </div>

                  {/* Progress Bar */}
                  {!isComplete && challenge.target_value > 1 && (
                    <div className="mt-3">
                      <div className="flex justify-between text-xs text-slate-400 mb-1">
                        <span>Progress</span>
                        <span>{challenge.current_value} / {challenge.target_value}</span>
                      </div>
                      <div className="h-2 bg-slate-700 rounded-full overflow-hidden">
                        <div
                          className="h-full bg-gradient-to-r from-indigo-500 to-purple-500 transition-all"
                          style={{ width: `${progress}%` }}
                        />
                      </div>
                    </div>
                  )}
                </div>
              );
            })()
          )}

          {notice ? (
            <div className="mb-4 rounded-xl border border-amber-500/30 bg-amber-900/15 px-4 py-3 text-sm text-amber-100">
              {notice}
            </div>
          ) : null}

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="bg-slate-800/60 border border-slate-700 rounded-2xl p-6">
              <h2 className="text-xl font-bold mb-4">Game Settings</h2>

              <label className="block text-sm font-semibold mb-2">Game Mode</label>
              <div className="grid grid-cols-2 gap-3 mb-4">
                <button
                  onClick={() => setGameSettings((p) => ({ ...p, gameMode: "multiplayer", lobbyMode: "fixed", maxPlayers: 2 }))}
                  className={`p-3 rounded-lg text-sm font-medium transition ${
                    gameSettings.gameMode !== "solo"
                      ? "bg-emerald-600 text-white"
                      : "bg-slate-700 text-slate-300 hover:bg-slate-600"
                  }`}
                >
                  <div className="flex items-center justify-center gap-2">
                    <Users size={18} />
                    Multiplayer
                  </div>
                  <div className="text-xs opacity-70 mt-1">Play with friends (2-3x FP)</div>
                </button>
                <button
                  onClick={() => setGameSettings((p) => ({ ...p, gameMode: "solo", maxPlayers: 1 }))}
                  className={`p-3 rounded-lg text-sm font-medium transition ${
                    gameSettings.gameMode === "solo"
                      ? "bg-purple-600 text-white"
                      : "bg-slate-700 text-slate-300 hover:bg-slate-600"
                  }`}
                >
                  <div className="flex items-center justify-center gap-2">
                    <Star size={18} />
                    Solo Practice
                  </div>
                  <div className="text-xs opacity-70 mt-1">Draft alone, see optimal lineup</div>
                </button>
              </div>

              {gameSettings.gameMode !== "solo" && (
                <>
                  <label className="block text-sm font-semibold mb-2">Lobby Type</label>
                  <div className="grid grid-cols-2 gap-3 mb-4">
                    <button
                      onClick={() => setGameSettings((p) => ({ ...p, lobbyMode: "fixed", maxPlayers: 2 }))}
                      className={`p-3 rounded-lg text-sm font-medium transition ${
                        gameSettings.lobbyMode === "fixed"
                          ? "bg-blue-600 text-white"
                          : "bg-slate-700 text-slate-300 hover:bg-slate-600"
                      }`}
                    >
                      Fixed Size
                      <div className="text-xs opacity-70 mt-1">Wait for exact count</div>
                    </button>
                    <button
                      onClick={() => setGameSettings((p) => ({ ...p, lobbyMode: "open", maxPlayers: 8 }))}
                      className={`p-3 rounded-lg text-sm font-medium transition ${
                        gameSettings.lobbyMode === "open"
                          ? "bg-blue-600 text-white"
                          : "bg-slate-700 text-slate-300 hover:bg-slate-600"
                      }`}
                    >
                      Open Lobby
                      <div className="text-xs opacity-70 mt-1">Start with 2-8 players</div>
                    </button>
                  </div>
                </>
              )}

              {gameSettings.gameMode !== "solo" && gameSettings.lobbyMode === "fixed" && (
                <>
                  <label className="block text-sm font-semibold mb-2">Player Count</label>
                  <div className="grid grid-cols-3 gap-3 mb-4">
                    {sizeBtn(2)}
                    {sizeBtn(3)}
                    {sizeBtn(4)}
                  </div>
                </>
              )}

              <label className="block text-sm font-semibold mb-2">Roster Construction</label>
              <div className="grid grid-cols-2 gap-3">
                {rosterControl("qbSlots", "QB")}
                {rosterControl("rbSlots", "RB")}
                {rosterControl("wrSlots", "WR")}
                {rosterControl("teSlots", "TE")}
                {rosterControl("flexSlots", "FLEX")}
                {rosterControl("kSlots", "K")}
                {rosterControl("dstSlots", "DST")}
              </div>

              {gameSettings.gameMode !== "solo" && (
                <div className="mt-3 flex items-center justify-between bg-slate-900/40 border border-slate-700 rounded-xl px-3 py-2">
                  <div className="text-sm font-semibold text-slate-200">Snake draft</div>

                  {snakeAllowed ? (
                    <label className="flex items-center gap-2 text-xs text-slate-300">
                      <input
                        type="checkbox"
                        checked={snakeChecked}
                        onChange={(e) => setGameSettings((p) => ({ ...p, snakeDraft: e.target.checked }))}
                      />
                      {snakeChecked ? "On" : "Off"} (3+ players)
                    </label>
                  ) : (
                    <div className="text-xs text-slate-400">Off for 2 players</div>
                  )}
                </div>
              )}

              <div className="text-xs text-slate-400 mt-2">
                Total roster size: <span className="font-semibold">{rosterSize}</span>
              </div>

              <div className="grid grid-cols-2 gap-3 mt-5">
                <div>
                  <label className="block text-sm font-semibold mb-2">Pick Timer (sec)</label>
                  <input
                    type="number"
                    min="10"
                    max="120"
                    step="5"
                    value={gameSettings.pickTime}
                    onChange={(e) => setGameSettings((p) => ({ ...p, pickTime: parseInt(e.target.value, 10) || 30 }))}
                    className="w-full bg-slate-900/60 border border-slate-700 rounded-lg px-3 py-2"
                  />
                </div>
                <div>
                  <label className="block text-sm font-semibold mb-2">Passing TD Points</label>
                  <div className="grid grid-cols-2 gap-3">
                    {[4, 6].map((v) => (
                      <button
                        key={v}
                        onClick={() => setGameSettings((p) => ({ ...p, passTdPoints: v }))}
                        className={`py-2 rounded-lg font-bold transition ${
                          gameSettings.passTdPoints === v ? "bg-blue-600 text-white" : "bg-slate-700/70 text-slate-200 hover:bg-slate-600"
                        }`}
                      >
                        {v} pts
                      </button>
                    ))}
                  </div>
                </div>
              </div>

              <div className="mt-5">
                <label className="block text-sm font-semibold mb-2">Scoring</label>
                <div className="grid grid-cols-3 gap-3">
                  {["standard", "half-ppr", "ppr"].map((sc) => (
                    <button
                      key={sc}
                      onClick={() => setGameSettings((p) => ({ ...p, scoring: sc }))}
                      className={`py-2 rounded-lg font-bold transition ${
                        gameSettings.scoring === sc ? "bg-blue-600 text-white" : "bg-slate-700/70 text-slate-200 hover:bg-slate-600"
                      }`}
                    >
                      {sc === "half-ppr" ? "Half PPR" : sc.toUpperCase()}
                    </button>
                  ))}
                </div>
              </div>

              <div className="mt-5">
                <label className="block text-sm font-semibold mb-2">Season Range</label>
                <div className="flex gap-3 items-center">
                  <input
                    type="number"
                    min="2010"
                    max="2025"
                    value={gameSettings.yearStart}
                    onChange={(e) => setGameSettings((p) => ({ ...p, yearStart: parseInt(e.target.value, 10) || 2010 }))}
                    className="flex-1 bg-slate-900/60 border border-slate-700 rounded-lg px-3 py-2"
                  />
                  <span className="text-slate-400">to</span>
                  <input
                    type="number"
                    min="2010"
                    max="2025"
                    value={gameSettings.yearEnd}
                    onChange={(e) => setGameSettings((p) => ({ ...p, yearEnd: parseInt(e.target.value, 10) || 2025 }))}
                    className="flex-1 bg-slate-900/60 border border-slate-700 rounded-lg px-3 py-2"
                  />
                </div>
              </div>
            </div>

            <div className="bg-slate-800/60 border border-slate-700 rounded-2xl p-6">
              <h2 className="text-xl font-bold mb-4">Play</h2>

              <input
                type="text"
                placeholder="Display name"
                value={playerName}
                onChange={(e) => setPlayerName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    if (gameSettings.joinMode === "global") startGlobalMatchmaking().catch(() => {});
                    else if (roomCode.trim().length >= 4) joinRoom().catch(() => {});
                  }
                }}
                className="w-full bg-slate-900/60 border border-slate-700 rounded-lg px-4 py-3 text-white placeholder-slate-400 mb-4"
              />

              {gameSettings.gameMode === "solo" ? (
                /* Solo Mode - Start immediately */
                <div className="space-y-3">
                  <button
                    onClick={startSoloGame}
                    disabled={busy || !playerName.trim()}
                    className="w-full bg-gradient-to-r from-purple-600 to-purple-700 hover:from-purple-500 hover:to-purple-600 disabled:from-slate-700 disabled:to-slate-700 py-4 rounded-lg font-bold transition text-lg"
                  >
                    {busy ? "Starting…" : "Start Solo Draft"}
                  </button>

                  <div className="mt-4 bg-slate-900/40 border border-slate-700 rounded-xl p-4 text-xs text-slate-300">
                    <div className="font-semibold text-purple-300 mb-2">Solo Practice Mode</div>
                    <ul className="space-y-1 list-disc list-inside">
                      <li>Draft your full lineup at your own pace</li>
                      <li>See your score and compare to the optimal lineup</li>
                      <li>Earn 10 FP base + bonus if you beat 80% of optimal</li>
                      <li>No multiplayer bonuses apply</li>
                    </ul>
                  </div>
                </div>
              ) : (
                /* Multiplayer Mode */
                <>
                  <div className="grid grid-cols-2 gap-3 mb-4">
                    <button
                      onClick={() => setGameSettings((p) => ({ ...p, joinMode: "code" }))}
                      className={`py-3 rounded font-bold transition ${
                        gameSettings.joinMode === "code" ? "bg-blue-600 text-white" : "bg-slate-700/70 text-slate-200 hover:bg-slate-600"
                      }`}
                    >
                      Code / Private
                    </button>
                    <button
                      onClick={() => setGameSettings((p) => ({ ...p, joinMode: "global" }))}
                      className={`py-3 rounded font-bold transition ${
                        gameSettings.joinMode === "global" ? "bg-blue-600 text-white" : "bg-slate-700/70 text-slate-200 hover:bg-slate-600"
                      }`}
                    >
                      Global Match
                    </button>
                  </div>

                  {gameSettings.joinMode === "code" ? (
                    <div className="space-y-3">
                      <button
                        onClick={createRoom}
                        disabled={busy || !playerName.trim()}
                        className="w-full bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-500 hover:to-blue-600 disabled:from-slate-700 disabled:to-slate-700 py-3 rounded-lg font-bold transition"
                      >
                        {busy ? "Creating…" : `Create Room (${effectiveMaxPlayers} Players)`}
                      </button>

                      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                        <input
                          type="text"
                          placeholder="Room Code"
                          value={roomCode}
                          onChange={(e) => setRoomCode(e.target.value.toUpperCase())}
                          className="w-full bg-slate-900/60 border border-slate-700 rounded-lg px-4 py-3 text-white placeholder-slate-400 uppercase"
                        />
                        <button
                          onClick={() => joinRoom().catch(() => {})}
                          disabled={busy || !playerName.trim() || roomCode.trim().length < 4}
                          className="w-full bg-gradient-to-r from-purple-600 to-purple-700 hover:from-purple-500 hover:to-purple-600 disabled:from-slate-700 disabled:to-slate-700 py-3 rounded-lg font-bold transition"
                        >
                          {busy ? "Joining…" : "Join Room"}
                        </button>
                      </div>
                    </div>
                  ) : (
                    <div className="space-y-3">
                      <button
                        onClick={() => startGlobalMatchmaking().catch(() => {})}
                        disabled={busy || !playerName.trim()}
                        className="w-full bg-gradient-to-r from-emerald-600 to-emerald-700 hover:from-emerald-500 hover:to-emerald-600 disabled:from-slate-700 disabled:to-slate-700 py-3 rounded-lg font-bold transition"
                      >
                        {busy ? "Searching…" : `Find Match (${effectiveMaxPlayers}p)`}
                      </button>

                      {matchmakingStatus ? <div className="text-xs text-slate-300">{matchmakingStatus}</div> : null}

                      <label className="flex items-center gap-2 text-xs text-slate-300">
                        <input
                          type="checkbox"
                          checked={!!gameSettings.autoStartWhenFull}
                          onChange={(e) => setGameSettings((p) => ({ ...p, autoStartWhenFull: e.target.checked }))}
                        />
                        Auto-start when lobby is full
                      </label>
                    </div>
                  )}

                  <div className="mt-4 bg-slate-900/40 border border-slate-700 rounded-xl p-4 text-xs text-slate-300">
                    Draft order randomizes at start. For 2 players, the draft alternates. For 3+ players, snake draft is optional.
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      </div>
    );
  }

  if (screen === "lobby") {
    const maxP = effectiveMaxPlayers;
    const isOpenLobby = gameSettings.lobbyMode === "open";
    const minPlayers = isOpenLobby ? 2 : maxP;
    const canStart = (players?.length || 0) >= minPlayers;
    const isFull = (players?.length || 0) >= maxP;

    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 text-white p-4">
        <div className="max-w-2xl mx-auto py-8">
          {notice ? (
            <div className="mb-4 rounded-xl border border-amber-500/30 bg-amber-900/15 px-4 py-3 text-sm text-amber-100">
              {notice}
            </div>
          ) : null}

          <div className="bg-slate-800 rounded-lg p-8 border border-slate-700">
            <h2 className="text-2xl font-bold mb-6 text-center">Lobby</h2>

            <div className="bg-slate-900 rounded-lg p-6 mb-4">
              <div className="flex items-center justify-between mb-2">
                <span className="text-slate-400">Room Code:</span>
                <span className="text-2xl font-mono font-bold tracking-wider">{roomCode}</span>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <button
                  onClick={copyRoomCodeOnly}
                  className="flex items-center justify-center gap-2 p-3 bg-slate-700 hover:bg-slate-600 rounded transition"
                >
                  {copied ? <Check size={16} /> : <Copy size={16} />}
                  Copy Code
                </button>

                <button
                  onClick={copyInviteLink}
                  className="flex items-center justify-center gap-2 p-3 bg-slate-700 hover:bg-slate-600 rounded transition"
                >
                  {copied ? <Check size={16} /> : (isNative || navigator.share) ? <Share2 size={16} /> : <LinkIcon size={16} />}
                  {(isNative || navigator.share) ? "Share Invite" : "Copy Invite Link"}
                </button>
              </div>

              <p className="text-xs text-slate-400 text-center mt-3">
                {isOpenLobby
                  ? `${players.length} player${players.length !== 1 ? "s" : ""} joined (2-${maxP} can play)`
                  : `${players.length}/${maxP} players joined`}
                {" • "}Your seat: {mySeat || "—"}
              </p>
              <p className="text-xs text-slate-500 text-center mt-1">
                Draft order randomizes on start • Snake: {snakeAllowed ? (gameSettings.snakeDraft ? "ON" : "OFF") : "OFF (2 players)"}
              </p>
            </div>

            <div className="space-y-3 mb-6">
              {players.map((p) => {
                const effectiveActive = p.is_active !== false && !isStale(p.last_seen, 90000);
                return (
                  <div key={p.id} className="bg-slate-700 rounded-lg p-4 flex items-center justify-between">
                    <div className="flex items-center gap-3">
                      <Users size={20} className={effectiveActive ? "text-emerald-300" : "text-orange-300"} />
                      <span className="font-medium">
                        {p.display_name} {p.user_id === userId ? "(You)" : ""}{" "}
                        {!effectiveActive ? <span className="text-xs text-slate-300 ml-2">(inactive / disconnected)</span> : null}
                      </span>
                    </div>
                    <div className={`w-3 h-3 rounded-full ${p.ready ? "bg-green-500" : "bg-yellow-500"}`} />
                  </div>
                );
              })}

              {!isFull && (
                <div className="bg-slate-700 rounded-lg p-4 flex items-center justify-center text-slate-400">
                  {isOpenLobby && canStart ? "Waiting for more players (optional)…" : "Waiting for players…"}
                </div>
              )}
            </div>

            {mySeat === 1 ? (
              <button
                onClick={startDraft}
                disabled={busy || !canStart}
                className="w-full bg-gradient-to-r from-green-600 to-green-700 hover:from-green-500 hover:to-green-600 disabled:from-slate-700 disabled:to-slate-700 disabled:cursor-not-allowed py-4 rounded-lg font-bold text-lg transition"
              >
                {busy
                  ? "Starting..."
                  : canStart
                  ? `Start Draft (${players.length} player${players.length !== 1 ? "s" : ""})`
                  : `Need ${minPlayers - players.length} more player${minPlayers - players.length !== 1 ? "s" : ""}`}
              </button>
            ) : (
              <div className="text-center text-slate-400">Waiting for host to start…</div>
            )}
          </div>
        </div>
      </div>
    );
  }

  if (screen === "draft") {
    const footerText =
      searchTotal > searchResults.length
        ? `Showing ${searchResults.length} of ${searchTotal}.`
        : searchTotal > 0
        ? `Showing ${searchTotal} result${searchTotal === 1 ? "" : "s"}.`
        : "";

    const tab = (label, val) => (
      <button
        key={val}
        onClick={() => setPosFilter(val)}
        className={`px-3 py-2 rounded text-xs font-bold transition ${
          posFilter === val ? "bg-slate-600 text-white" : "bg-slate-700 text-slate-300 hover:bg-slate-600"
        }`}
      >
        {label}
      </button>
    );

    const pickBtnEnabled = (p) => isMyTurn && hasOpenForPos(p.position) && !draftBusy;

    const pinBucketForRow = (p) => {
      if (posFilter === "ALL") return p.position;
      if (posFilter === "FLEX") return p.position;
      return posFilter;
    };

    const lowTime = isMyTurn && timeRemaining <= 10;

    const panelGlow = lowTime
      ? "shadow-[0_0_0_1px_rgba(239,68,68,0.25),0_0_25px_rgba(239,68,68,0.08)]"
      : isMyTurn
        ? "shadow-[0_0_0_1px_rgba(16,185,129,0.25),0_0_25px_rgba(16,185,129,0.08)]"
        : "shadow-[0_0_0_1px_rgba(139,92,246,0.25),0_0_25px_rgba(139,92,246,0.08)]";

    const mobileTabBtn = (id, label) => (
      <button
        onClick={() => setDraftView(id)}
        className={`flex-1 py-2 rounded font-bold text-xs ${draftView === id ? "bg-slate-600 text-white" : "bg-slate-700 text-slate-300"}`}
      >
        {label}
      </button>
    );

    const leaguePanel = (
      <div className="bg-slate-800 rounded-lg p-4 border border-slate-700">
        <div className="flex items-center justify-between mb-3">
          <h3 className="font-bold">League</h3>
          <span className="text-xs text-slate-400">
            {players.length}/{effectiveMaxPlayers}
          </span>
        </div>

        <div className="space-y-2">
          {players
            .slice()
            .sort((a, b) => Number(a.seat) - Number(b.seat))
            .map((p) => {
              const teamArr = teamsByUser?.[p.user_id] || Array(rosterSize).fill(null);
              const filled = teamArr.filter(Boolean).length;
              const effectiveActive = p.is_active !== false && !isStale(p.last_seen, 90000);
              const isTurn = p.user_id === turnUserId;

              return (
                <details key={p.user_id} className="bg-slate-700 rounded p-3">
                  <summary className="cursor-pointer flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <Users size={16} className={effectiveActive ? "text-emerald-300" : "text-orange-300"} />
                      <span className="text-sm font-semibold">
                        {p.display_name} {p.user_id === userId ? "(You)" : ""}
                      </span>
                      {isTurn ? <span className="text-[10px] px-2 py-0.5 rounded bg-emerald-600/70 font-bold">ON CLOCK</span> : null}
                      {!effectiveActive ? <span className="text-[10px] px-2 py-0.5 rounded bg-orange-600/50 font-bold">AUTO</span> : null}
                    </div>
                    <span className="text-xs text-slate-300">
                      {filled}/{rosterSize}
                    </span>
                  </summary>

                  <div className="mt-3 space-y-1">
                    {rosterSlots.map((slot, idx) => {
                      const pl = teamArr[idx];
                      return (
                        <div
                          key={`${p.user_id}-${idx}`}
                          className={`border rounded px-2 py-1 flex items-center justify-between ${
                            POSITION_COLORS[slot]?.bg || "bg-slate-900/20"
                          } ${pl ? (POSITION_COLORS[slot]?.border || "border-slate-600") : "border-slate-600"}`}
                        >
                          <span className={`text-[10px] font-bold ${POSITION_COLORS[slot]?.text || "text-white"}`}>{slot}</span>
                          <span className="text-xs text-slate-200 ml-2 truncate flex-1 text-right">{pl ? pl.name : "—"}</span>
                        </div>
                      );
                    })}
                  </div>
                </details>
              );
            })}
        </div>
      </div>
    );

    const myTeamPanel = (
      <div className={`bg-slate-800 rounded-lg p-4 border-2 ${lowTime ? "border-red-500" : isMyTurn ? "border-emerald-500" : "border-slate-700"}`}>
        <h3 className="font-bold mb-3 flex items-center gap-2">
          <Users size={18} className={lowTime ? "text-red-300" : isMyTurn ? "text-emerald-300" : "text-slate-300"} />
          Your Team
        </h3>
        <div className="space-y-2">
          {rosterSlots.map((slot, i) => (
            <div
              key={i}
              className={`border-2 rounded-lg p-3 ${POSITION_COLORS[slot]?.bg || "bg-slate-700"} ${
                myTeam[i] ? (POSITION_COLORS[slot]?.border || "border-slate-600") : "border-slate-600"
              }`}
            >
              <div className="flex items-center gap-2">
                <span className={`text-xs font-bold px-2 py-1 rounded ${POSITION_COLORS[slot]?.text || "text-white"} bg-slate-900/40`}>
                  {slot}
                </span>
                {myTeam[i] ? (
                  <>
                    <TeamColorBadge team={myTeam[i].team} />
                    <span className="text-sm font-medium truncate">{myTeam[i].name}</span>
                  </>
                ) : (
                  <span className="text-sm text-slate-400">Empty</span>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
    );

    const searchPanel = (
      <div className={`bg-slate-800 rounded-lg p-4 border ${lowTime ? "border-red-500/50" : isMyTurn ? "border-emerald-500/50" : "border-violet-500/50"} ${panelGlow}`}>
        <div className="flex items-center justify-between mb-3">
          <h3 className="font-bold">Player Search</h3>
          {isMyTurn ? (
            <span className={`text-xs px-2 py-1 rounded font-bold ${lowTime ? "bg-red-600" : "bg-emerald-600"}`}>Draft enabled</span>
          ) : (
            <span className="text-xs bg-violet-600 px-2 py-1 rounded font-bold">Pin mode</span>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-2 mb-3">
          {tab("All", "ALL")}
          {tab("QB", "QB")}
          {tab("RB", "RB")}
          {tab("WR", "WR")}
          {tab("TE", "TE")}
          {tab("FLEX", "FLEX")}
          {tab("K", "K")}
          {tab("DST", "DST")}
          <div className="border-l border-slate-600 h-6 mx-1" />
          <TeamFilterDropdown />
        </div>

        <div className="relative mb-3">
          <Search className="absolute left-3 top-3 text-slate-400" size={20} />
          <input
            type="text"
            placeholder="Search by name or team…"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full bg-slate-700 rounded pl-10 pr-10 py-3 text-white placeholder-slate-400"
          />
          {searchQuery && (
            <button onClick={() => setSearchQuery("")} className="absolute right-3 top-3 text-slate-400 hover:text-white">
              <X size={20} />
            </button>
          )}
        </div>

        {searchResults.length > 0 ? (
          <>
            <div className="space-y-1 max-h-[32rem] overflow-y-auto">
              {searchResults.map((p) => {
                const bucket = pinBucketForRow(p);
                const pinned = pinsFor(bucket).includes(p.id);

                return (
                  <div key={p.id} className="w-full bg-slate-700 rounded p-3 flex items-center justify-between gap-3">
                    <div className="flex items-center gap-2 min-w-0">
                      <button
                        onClick={() => togglePinned(bucket, p.id)}
                        className="p-3 bg-slate-600 hover:bg-slate-500 rounded min-w-11 min-h-11 flex items-center justify-center"
                        title={pinned ? "Unpin" : "Pin"}
                        disabled={draftBusy}
                      >
                        <Star size={18} className={pinned ? "text-yellow-300" : "text-slate-300"} />
                      </button>

                      <span className={`text-xs font-bold px-2 py-1 rounded ${POSITION_COLORS[p.position]?.text || "text-white"} bg-slate-600`}>
                        {p.position}
                      </span>

                      <div className="min-w-0">
                        <div className="text-sm font-medium truncate">{p.name}</div>
                        <div className="flex items-center gap-2">
                          <TeamColorBadge team={p.team} />
                          {p.matchup && <span className="flex items-center gap-1 opacity-50 text-[10px] text-slate-500">{p.matchup.is_home ? "vs" : "@"} <TeamColorBadge team={p.matchup.opponent} /></span>}
                          {p.number > 0 && <span className="text-xs text-slate-400">#{p.number}</span>}
                        </div>
                      </div>
                    </div>

                    <button
                      onClick={() => manualDraft(p)}
                      disabled={!pickBtnEnabled(p)}
                      className={`px-4 py-3 rounded font-bold transition text-sm min-h-11 ${
                        pickBtnEnabled(p) ? "bg-emerald-600 hover:bg-emerald-500 text-white" : "bg-slate-600 text-slate-400 cursor-not-allowed"
                      }`}
                    >
                      Draft
                    </button>
                  </div>
                );
              })}
            </div>

            <div className="mt-3 text-xs text-slate-400">
              {footerText}
            </div>
            {searchTotal > searchResults.length && (
              <button
                onClick={showMoreResults}
                className="mt-3 w-full py-3 px-4 bg-slate-700 hover:bg-slate-600 text-slate-200 rounded-lg font-medium text-sm transition-colors disabled:opacity-50"
                disabled={searchingMore || draftBusy}
              >
                {searchingMore ? "Loading more players..." : `Show more players (${searchResults.length} of ${searchTotal})`}
              </button>
            )}
          </>
        ) : (
          <div className="text-center py-8 text-slate-400">
            <AlertCircle className="mx-auto mb-2" size={32} />
            <p className="text-sm">No players found.</p>
          </div>
        )}
      </div>
    );

    return (
      <div
        className={`min-h-screen text-white p-4 transition-colors ${
          lowTime
            ? "bg-gradient-to-br from-red-950 via-slate-900 to-slate-900"
            : isMyTurn
              ? "bg-gradient-to-br from-emerald-950 via-slate-900 to-slate-900"
              : "bg-gradient-to-br from-violet-950 via-slate-900 to-slate-900"
        }`}
      >
        <div className="max-w-7xl mx-auto py-4">
          {notice ? (
            <div className="mb-4 rounded-xl border border-amber-500/30 bg-amber-900/15 px-4 py-3 text-sm text-amber-100">
              {notice}
            </div>
          ) : null}

          {inactivePlayers.length > 0 && (
            <div className="mb-4 rounded-lg border border-orange-400/50 bg-orange-900/20 px-4 py-3 text-sm text-orange-100">
              Inactive players will be auto-drafted on their turns:{" "}
              <span className="font-semibold">{inactivePlayers.slice().sort((a, b) => Number(a.seat) - Number(b.seat)).map((p) => p.display_name).join(", ")}</span>
            </div>
          )}

          {gameWeek && (
            <div
              className={`mb-4 rounded-lg border px-4 py-3 transition-all ${panelGlow} ${
                lowTime
                  ? "border-red-500/60 bg-red-900/15"
                  : isMyTurn
                    ? "border-emerald-500/60 bg-emerald-900/15"
                    : "border-violet-500/60 bg-violet-900/15"
              }`}
            >
              <div className="flex items-center justify-between gap-3">
                <div className="flex items-center gap-3">
                  <h2 className="text-2xl font-bold">
                    Week {gameWeek.week}, {gameWeek.season}
                  </h2>
                  <div className={`text-xs font-bold px-2 py-1 rounded ${lowTime ? "bg-red-600/80" : isMyTurn ? "bg-emerald-600/80" : "bg-violet-600/80"}`}>
                    {isMyTurn ? "DRAFT" : "PIN"}
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <Clock className={lowTime ? "text-red-400 animate-pulse" : isMyTurn ? "text-emerald-300" : "text-violet-300"} size={20} />
                  <span className={`text-2xl font-bold tabular-nums ${lowTime ? "text-red-400" : isMyTurn ? "text-emerald-300" : "text-violet-300"}`}>
                    {Math.floor(timeRemaining / 60)}:{String(timeRemaining % 60).padStart(2, "0")}
                  </span>
                </div>
              </div>
              <div className="mt-2 flex items-center gap-2 text-xs text-slate-400">
                <span>Pick {pickDisplay}</span>
                <span>•</span>
                <span>{gameSettings.scoring === "half-ppr" ? "Half PPR" : gameSettings.scoring.toUpperCase()}</span>
                <span>•</span>
                <span>{players.length} players</span>
              </div>
              {!weeklyRoster.length && <div className="text-xs text-slate-300 mt-2">Loading roster…</div>}
              {draftBusy && <div className="text-xs text-slate-300 mt-1">Submitting…</div>}
            </div>
          )}

          <div className="lg:hidden mb-3 flex gap-2">
            {mobileTabBtn("SEARCH", "Search")}
            {mobileTabBtn("MYTEAM", "My Team")}
            {mobileTabBtn("LEAGUE", "League")}
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
            <div className={`lg:block ${draftView === "MYTEAM" ? "block" : "hidden"} lg:col-span-1`}>{myTeamPanel}</div>
            <div className={`lg:block ${draftView === "SEARCH" ? "block" : "hidden"} lg:col-span-1`}>{searchPanel}</div>
            <div className={`lg:block ${draftView === "LEAGUE" ? "block" : "hidden"} lg:col-span-1`}>{leaguePanel}</div>
          </div>
        </div>
      </div>
    );
  }

  if (screen === "results") {
    const isSoloGame = gameSettings.gameMode === "solo" || players.length === 1;

    const scoreboard = Object.entries(resultsByUser || {})
      .map(([uid, v]) => ({
        user_id: uid,
        total: Number(v?.total || 0),
        name: players.find((p) => p.user_id === uid)?.display_name || "Player",
        seat: Number(players.find((p) => p.user_id === uid)?.seat || 999),
      }))
      .sort((a, b) => b.total - a.total || a.seat - b.seat);

    const top = scoreboard.length ? scoreboard[0].total : 0;
    const winners = scoreboard.filter((x) => Math.abs(x.total - top) < 1e-9);

    // Solo mode stats (computed directly, not with useMemo, since we're inside a conditional)
    const myResults = resultsByUser?.[userId] || { rows: [], total: 0 };
    const soloStats = (() => {
      if (!isSoloGame) return null;
      const rows = myResults.rows || [];
      let top10Count = 0;
      let top1Count = 0;
      const playerDetails = rows.map((player) => {
        const rk = weeklyRankInfoById?.[player.id] || null;
        const rank = rk?.rank || 999;
        const isTop10 = rank <= 10;
        const isTop1 = rank === 1;
        if (isTop10) top10Count++;
        if (isTop1) top1Count++;
        return { ...player, rank, isTop10, isTop1, rankInfo: rk };
      });
      return { top10Count, top1Count, total: rows.length, playerDetails };
    })();

    const headerText =
      winners.length === 0 ? "Results" : winners.length === 1 ? `Winner: ${winners[0].name}` : `Tie: ${winners.map((w) => w.name).join(", ")}`;

    const renderTeamPanel = (uid, ptsColorClass) => {
      const pack = resultsByUser?.[uid] || { rows: [], total: 0 };
      const title = players.find((p) => p.user_id === uid)?.display_name || "Player";

      return (
        <div className="bg-slate-800 rounded-lg p-6 border-2 border-slate-700">
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-xl font-bold">{title}</h3>
            <div className={`text-3xl font-bold ${ptsColorClass}`}>{Number(pack.total || 0).toFixed(1)} pts</div>
          </div>

          <div className="space-y-2">
            {(pack.rows || []).map((player, i) => {
              const keyStats = getKeyStats(player);
              const rk = weeklyRankInfoById?.[player.id] || null;

              return (
                <details key={i} className="bg-slate-700 rounded p-3">
                  <summary className="flex items-center justify-between cursor-pointer">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className={`text-xs font-bold px-2 py-1 rounded ${POSITION_COLORS[player.position]?.text || "text-white"} bg-slate-600`}>
                        {player.position}
                      </span>
                      <TeamColorBadge team={player.team} />
                      <span className="font-medium">{player.name}</span>
                      <MatchupLine matchup={player.matchup} />
                      {rk ? (
                        <span className="text-xs text-slate-400 ml-1">
                          {rk.tied ? "T-" : "#"}
                          {rk.rank}/{rk.total} {rk.pos}
                        </span>
                      ) : null}
                      <span className="text-xs text-slate-400 ml-2">(tap to learn more)</span>
                    </div>
                    <span className={`font-bold ${ptsColorClass}`}>{(player.points ?? 0).toFixed(1)} pts</span>
                  </summary>

                  <div className="mt-3 pt-3 border-t border-slate-600">
                    <div className="text-xs text-slate-300 mb-2 font-semibold">Key stats</div>
                    <div className="grid grid-cols-2 gap-2 text-sm text-slate-200">
                      {keyStats.map((kv) => (
                        <div key={kv.label} className="flex justify-between bg-slate-900/30 rounded px-2 py-1">
                          <span className="text-slate-400">{kv.label}</span>
                          <span className="font-medium">{kv.value}</span>
                        </div>
                      ))}
                    </div>

                    {player.breakdown && Object.keys(player.breakdown).length > 0 && (
                      <>
                        <div className="text-xs text-slate-300 mt-4 mb-2 font-semibold">Fantasy scoring breakdown</div>
                        <div className="grid grid-cols-2 gap-2 text-sm text-slate-200">
                          {Object.entries(player.breakdown).map(([k, v]) => (
                            <div key={k} className="flex justify-between bg-slate-900/30 rounded px-2 py-1">
                              <span className="text-slate-400">{String(k).toUpperCase()}</span>
                              <span className="font-medium">{String(v)}</span>
                            </div>
                          ))}
                        </div>
                      </>
                    )}
                  </div>
                </details>
              );
            })}
          </div>
        </div>
      );
    };

    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 text-white p-4">
        <div className="max-w-5xl mx-auto py-8">
          {notice && (
            <div className="mb-4 rounded-xl border border-amber-500/30 bg-amber-900/15 px-4 py-3 text-sm text-amber-100">
              {notice}
            </div>
          )}
          {loadingStats ? (
            <div className="text-center">
              <div className="animate-spin rounded-full h-16 w-16 border-4 border-blue-500 border-t-transparent mx-auto mb-4"></div>
              <h2 className="text-2xl font-bold mb-2">Calculating Scores…</h2>
            </div>
          ) : isSoloGame && soloStats ? (
            /* ==================== SOLO MODE RESULTS ==================== */
            <>
              <div className="text-center mb-6">
                <div className="text-6xl mb-4">🎯</div>
                <h1 className="text-3xl md:text-4xl font-bold mb-2">Solo Draft Complete!</h1>
                {gameWeek && (
                  <p className="text-slate-400">
                    Week {gameWeek.week}, {gameWeek.season} • {gameSettings.scoring === "half-ppr" ? "Half PPR" : gameSettings.scoring.toUpperCase()}
                  </p>
                )}
              </div>

              {/* Top 10 Summary Card */}
              <div className="bg-gradient-to-r from-purple-900/40 to-indigo-900/40 border border-purple-500/30 rounded-xl p-6 mb-6">
                <div className="text-center">
                  <div className="text-5xl font-bold text-purple-300 mb-2">
                    {soloStats.top10Count} / {soloStats.total}
                  </div>
                  <div className="text-lg text-purple-200 font-semibold">Players in Top 10 at Position</div>
                  {soloStats.top1Count > 0 && (
                    <div className="mt-3 inline-flex items-center gap-2 bg-yellow-500/20 border border-yellow-500/40 rounded-full px-4 py-2">
                      <span className="text-2xl">👑</span>
                      <span className="text-yellow-300 font-bold">
                        {soloStats.top1Count} #1 Overall Pick{soloStats.top1Count > 1 ? "s" : ""}!
                      </span>
                    </div>
                  )}
                </div>
              </div>

              {/* Your Picks with Rankings */}
              <div className="bg-slate-800 rounded-lg p-6 border border-slate-700 mb-6">
                <h3 className="text-xl font-bold mb-4">Your Picks</h3>
                <div className="space-y-2">
                  {soloStats.playerDetails.map((player, i) => {
                    const keyStats = getKeyStats(player);
                    return (
                      <details key={i} className={`rounded p-3 ${
                        player.isTop1 ? "bg-yellow-900/30 border border-yellow-500/50" :
                        player.isTop10 ? "bg-emerald-900/30 border border-emerald-500/30" :
                        "bg-slate-700"
                      }`}>
                        <summary className="flex items-center justify-between cursor-pointer">
                          <div className="flex items-center gap-2 flex-wrap">
                            {player.isTop1 && <span className="text-lg">👑</span>}
                            <span className={`text-xs font-bold px-2 py-1 rounded ${POSITION_COLORS[player.position]?.text || "text-white"} bg-slate-600`}>
                              {player.position}
                            </span>
                            <TeamColorBadge team={player.team} />
                            <span className="font-medium">{player.name}</span>
                            <MatchupLine matchup={player.matchup} />
                          </div>
                          <div className="flex items-center gap-3">
                            <span className={`text-sm font-bold px-2 py-1 rounded ${
                              player.isTop1 ? "bg-yellow-500 text-yellow-900" :
                              player.isTop10 ? "bg-emerald-500/80 text-white" :
                              "bg-slate-600 text-slate-300"
                            }`}>
                              #{player.rank} {player.rankInfo?.pos || player.position}
                            </span>
                            <span className="font-bold text-slate-200">{(player.points ?? 0).toFixed(1)} pts</span>
                          </div>
                        </summary>

                        <div className="mt-3 pt-3 border-t border-slate-600">
                          <div className="text-xs text-slate-300 mb-2 font-semibold">Key stats</div>
                          <div className="grid grid-cols-2 gap-2 text-sm text-slate-200">
                            {keyStats.map((kv) => (
                              <div key={kv.label} className="flex justify-between bg-slate-900/30 rounded px-2 py-1">
                                <span className="text-slate-400">{kv.label}</span>
                                <span className="font-medium">{kv.value}</span>
                              </div>
                            ))}
                          </div>
                        </div>
                      </details>
                    );
                  })}
                </div>

                <div className="mt-4 pt-4 border-t border-slate-600 flex justify-between items-center">
                  <span className="text-slate-400">Total Score</span>
                  <span className="text-2xl font-bold text-emerald-300">{Number(myResults.total || 0).toFixed(1)} pts</span>
                </div>
              </div>

              <div className="flex justify-center gap-3 mb-6">
                <button
                  onClick={handleShareResults}
                  className="bg-slate-700 hover:bg-slate-600 px-5 py-3 rounded-lg font-bold transition flex items-center gap-2"
                >
                  <Share2 size={18} />
                  {shareCopied ? "Copied" : "Share Results"}
                </button>
              </div>

              {/* Solo FP Earned Card */}
              {(() => {
                const baseFp = 10;
                const optimalPercent = globalBestLineup?.total > 0
                  ? (Number(myResults.total || 0) / globalBestLineup.total) * 100
                  : 0;
                const winBonus = optimalPercent >= 80 ? 5 : 0;
                const streakMult = engagementStats?.streak_multiplier || 1;
                const actualFp = lastGameFpEarned;
                const estimatedFp = Math.round((baseFp + winBonus) * streakMult);
                const displayFp = actualFp !== null ? actualFp : null;

                if (displayFp === null && !engagementStats) return null;

                return (
                  <div className="bg-gradient-to-r from-purple-900/30 to-indigo-900/30 border border-purple-500/30 rounded-xl p-4 mb-6">
                    <div className="flex items-center justify-between mb-3">
                      <div className="flex items-center gap-3">
                        <div className="w-10 h-10 rounded-full bg-purple-500/20 flex items-center justify-center">
                          <Zap className="w-5 h-5 text-purple-400" />
                        </div>
                        <div>
                          <div className="text-sm font-semibold text-purple-200">Solo Practice FP</div>
                          {engagementStats && (
                            <div className="text-xs text-slate-400">
                              <span className="capitalize">{engagementStats.tier_name || "Rookie"}</span>
                              {(engagementStats.current_streak || 0) > 0 && (
                                <span className="text-orange-400 ml-2">
                                  🔥 {engagementStats.current_streak} day streak
                                </span>
                              )}
                            </div>
                          )}
                        </div>
                      </div>
                      <div className="text-right">
                        {displayFp !== null && (
                          <div className="text-2xl font-bold text-purple-300">+{displayFp} FP</div>
                        )}
                      </div>
                    </div>

                    {/* Solo FP Breakdown */}
                    <div className="bg-slate-800/50 rounded-lg p-2 text-sm">
                      <div className="flex justify-between text-xs mb-1">
                        <span className="text-slate-400">Base (Solo)</span>
                        <span className="text-slate-300">+{baseFp}</span>
                      </div>
                      {winBonus > 0 && (
                        <div className="flex justify-between text-xs mb-1">
                          <span className="text-slate-400">Beat 80% Optimal</span>
                          <span className="text-emerald-400">+{winBonus}</span>
                        </div>
                      )}
                      {streakMult > 1 && (
                        <div className="flex justify-between text-xs">
                          <span className="text-slate-400">Streak Bonus</span>
                          <span className="text-orange-400">×{streakMult}</span>
                        </div>
                      )}
                      {optimalPercent < 80 && globalBestLineup && (
                        <div className="text-[10px] text-slate-500 mt-1 text-center">
                          Beat 80% of optimal ({Math.round(globalBestLineup.total * 0.8)} pts) for +5 bonus FP!
                        </div>
                      )}
                    </div>

                    {/* Tier Progress */}
                    {engagementStats && engagementStats.tier !== "goat" && (
                      <div className="mt-3">
                        <div className="flex justify-between text-[10px] text-slate-400 mb-1">
                          <span className="capitalize">{engagementStats.tier_name}</span>
                          <span>{(engagementStats.flashback_points || 0).toLocaleString()} FP total</span>
                        </div>
                        <div className="h-1.5 bg-slate-700 rounded-full overflow-hidden">
                          <div
                            className="h-full bg-gradient-to-r from-purple-500 to-indigo-500"
                            style={{ width: `${Math.min(engagementStats.tier_progress_percent || 0, 100)}%` }}
                          />
                        </div>
                      </div>
                    )}
                  </div>
                );
              })()}

              {/* Global Best Lineup for Solo */}
              {globalBestLineup && (
                <div className="bg-slate-800 rounded-lg p-6 border border-slate-700 mb-6">
                  <div className="flex items-center justify-between">
                    <div>
                      <div className="text-sm font-semibold text-slate-200">Optimal Lineup This Week</div>
                      <div className="text-xs text-slate-400">The best possible draft you could have made</div>
                    </div>
                    <div className="text-3xl font-bold text-emerald-300">{globalBestLineup.total.toFixed(1)} pts</div>
                  </div>

                  <div className="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-2">
                    {globalBestLineup.slots.map((s, idx) => (
                      <div key={idx} className="bg-slate-700 rounded p-3 flex items-center justify-between gap-3">
                        <div className="flex items-center gap-2 min-w-0">
                          <span className={`text-xs font-bold px-2 py-1 rounded ${POSITION_COLORS[s.slot]?.text || "text-white"} bg-slate-600`}>
                            {s.slot}
                          </span>
                          <TeamColorBadge team={s.player.team} />
                          <span className="text-sm font-medium truncate">{s.player.name}</span>
                        </div>
                        <div className="text-sm font-bold text-emerald-200">{(s.player.points ?? 0).toFixed(1)}</div>
                      </div>
                    ))}
                  </div>

                  {/* Comparison to your score */}
                  {globalBestLineup.total > 0 && (
                    <div className="mt-4 pt-4 border-t border-slate-600 text-center">
                      <div className="text-sm text-slate-400">
                        You scored <span className="font-bold text-white">{((Number(myResults.total || 0) / globalBestLineup.total) * 100).toFixed(0)}%</span> of the optimal lineup
                      </div>
                    </div>
                  )}
                </div>
              )}

              {/* Solo Action Buttons */}
              <div className="flex flex-col items-center gap-4">
                <div className="flex gap-3">
                  <button
                    onClick={() => {
                      rosterLoadedRef.current = false;
                      resultsComputedRef.current = false;
                      autoPickInFlightRef.current = false;
                      lastAutoPickTryRef.current = { gameId: null, pickNumber: null };

                      setGameId(null);
                      setMySeat(null);
                      setPlayers([]);
                      setWeeklyRoster([]);
                      setDraftedPlayerIds(new Set());
                      setPinnedByPos({});
                      setTeamsByUser({});
                      setResultsByUser({});
                      setWeeklyRankInfoById({});
                      setGlobalBestLineup(null);
                      setGameWeek(null);
                      setPosFilter("ALL");
                      setTeamFilter("ALL");
                      setSearchQuery("");
                      setSearchResults([]);
                      setTurnDeadlineAtMs(null);
                      setTimeRemaining(gameSettings.pickTime || 30);
                      setDraftBusy(false);
                      setMatchmakingStatus("");
                      setDraftView("SEARCH");
                      setInviteRoom(null);
                      inviteAutoJoinRef.current = false;
                      setRematchRequested(false);
                      setRematchStatus({ ready: 0, total: 0 });
                      setLastGameFpEarned(null);
                      flashNotice("");

                      // Start another solo game
                      setTimeout(() => {
                        startSoloGame().catch?.(() => {});
                      }, 0);
                    }}
                    disabled={busy || !playerName.trim()}
                    className="bg-gradient-to-r from-purple-600 to-purple-700 hover:from-purple-500 hover:to-purple-600 disabled:opacity-50 px-6 py-3 rounded-lg font-bold transition"
                  >
                    Play Again (Solo)
                  </button>

                  <button
                    onClick={() => {
                      markLeft();

                      rosterLoadedRef.current = false;
                      resultsComputedRef.current = false;
                      autoPickInFlightRef.current = false;
                      lastAutoPickTryRef.current = { gameId: null, pickNumber: null };

                      setScreen("setup");
                      setGameId(null);
                      setMySeat(null);
                      setPlayers([]);
                      setWeeklyRoster([]);
                      setDraftedPlayerIds(new Set());
                      setPinnedByPos({});
                      setTeamsByUser({});
                      setResultsByUser({});
                      setWeeklyRankInfoById({});
                      setGlobalBestLineup(null);
                      setGameWeek(null);
                      setPosFilter("ALL");
                      setTeamFilter("ALL");
                      setSearchQuery("");
                      setSearchResults([]);
                      setTurnDeadlineAtMs(null);
                      setTimeRemaining(gameSettings.pickTime || 30);
                      setDraftBusy(false);
                      setMatchmakingStatus("");
                      setDraftView("SEARCH");
                      setInviteRoom(null);
                      inviteAutoJoinRef.current = false;
                      setRematchRequested(false);
                      setRematchStatus({ ready: 0, total: 0 });
                      setLastGameFpEarned(null);
                      flashNotice("");
                    }}
                    className="bg-slate-700 hover:bg-slate-600 px-6 py-3 rounded-lg font-bold transition"
                  >
                    Back to Menu
                  </button>
                </div>
              </div>
            </>
          ) : (
            /* ==================== MULTIPLAYER RESULTS ==================== */
            <>
              <div className="text-center mb-6">
                <Trophy size={64} className="mx-auto mb-4 text-yellow-400" />
                <h1 className="text-3xl md:text-4xl font-bold mb-2">{headerText}</h1>
                {gameWeek && (
                  <p className="text-slate-400">
                    Week {gameWeek.week}, {gameWeek.season} • {gameSettings.scoring === "half-ppr" ? "Half PPR" : gameSettings.scoring.toUpperCase()}
                  </p>
                )}
              </div>

              <div className="flex justify-center gap-3 mb-6">
                <button
                  onClick={handleShareResults}
                  className="bg-slate-700 hover:bg-slate-600 px-5 py-3 rounded-lg font-bold transition flex items-center gap-2"
                >
                  <Share2 size={18} />
                  {shareCopied ? "Copied" : "Share Results"}
                </button>
              </div>

              {/* Flashback Points Earned Card */}
              {(() => {
                // Calculate FP breakdown for display
                const playerCount = players.length;
                const isWinner = winners.some(w => w.user_id === userId);
                const streakMult = engagementStats?.streak_multiplier || 1;

                // Determine multipliers based on game type
                const isSolo = isSoloGame;
                const baseFp = isSolo ? 10 : (playerCount >= 3 ? 40 : 25);
                const winBonus = isWinner ? (isSolo ? 5 : (playerCount >= 3 ? 25 : 15)) : 0;
                const partyMult = isSolo ? 1 : (playerCount >= 7 ? 3 : playerCount >= 5 ? 2.5 : playerCount >= 3 ? 2 : 1.5);

                // Use actual FP if available
                const actualFp = lastGameFpEarned;
                const displayFp = actualFp !== null ? actualFp : null;

                // Only show if we have FP data or engagement stats
                if (displayFp === null && !engagementStats) return null;

                return (
                  <div className="bg-gradient-to-r from-amber-900/30 to-orange-900/30 border border-amber-500/30 rounded-xl p-4 mb-6">
                    {/* Header with total FP earned */}
                    <div className="flex items-center justify-between mb-4">
                      <div className="flex items-center gap-3">
                        <div className="w-12 h-12 rounded-full bg-amber-500/20 flex items-center justify-center">
                          <Zap className="w-6 h-6 text-amber-400" />
                        </div>
                        <div>
                          <div className="text-sm font-semibold text-amber-200">Flashback Points Earned</div>
                          {engagementStats && (
                            <div className="text-xs text-slate-400 flex items-center gap-2">
                              <span className="capitalize">{engagementStats.tier_name || "Rookie"}</span>
                              {(engagementStats.current_streak || 0) > 0 && (
                                <span className="flex items-center gap-1 text-orange-400">
                                  <Flame className="w-3 h-3" />
                                  {engagementStats.current_streak} day streak
                                </span>
                              )}
                            </div>
                          )}
                        </div>
                      </div>
                      <div className="text-right">
                        {displayFp !== null && (
                          <div className="text-3xl font-bold text-amber-400">+{displayFp} FP</div>
                        )}
                        {engagementStats && (
                          <div className="text-xs text-slate-400">
                            Total: {(engagementStats.flashback_points || 0).toLocaleString()} FP
                          </div>
                        )}
                      </div>
                    </div>

                    {/* FP Breakdown */}
                    {displayFp !== null && (
                      <div className="bg-slate-800/50 rounded-lg p-3 mb-3">
                        <div className="text-xs font-semibold text-slate-400 mb-2">Breakdown</div>
                        <div className="grid grid-cols-2 gap-2 text-sm">
                          <div className="flex justify-between">
                            <span className="text-slate-400">Base ({isSolo ? "Solo" : `${playerCount}P`})</span>
                            <span className="text-slate-200">+{baseFp}</span>
                          </div>
                          {isWinner && (
                            <div className="flex justify-between">
                              <span className="text-slate-400">Win Bonus</span>
                              <span className="text-emerald-400">+{winBonus}</span>
                            </div>
                          )}
                          {!isSolo && partyMult > 1 && (
                            <div className="flex justify-between">
                              <span className="text-slate-400">Party Size</span>
                              <span className="text-blue-400">×{partyMult}</span>
                            </div>
                          )}
                          {streakMult > 1 && (
                            <div className="flex justify-between">
                              <span className="text-slate-400">Streak Bonus</span>
                              <span className="text-orange-400">×{streakMult}</span>
                            </div>
                          )}
                        </div>
                      </div>
                    )}

                    {/* Tier Progress Bar */}
                    {engagementStats && engagementStats.tier !== "goat" && (
                      <div>
                        <div className="flex justify-between text-xs text-slate-400 mb-1">
                          <span className="capitalize">{engagementStats.tier_name}</span>
                          <span className="capitalize">{(engagementStats.next_tier || "").replace("_", " ")}</span>
                        </div>
                        <div className="h-2 bg-slate-700 rounded-full overflow-hidden">
                          <div
                            className="h-full bg-gradient-to-r from-amber-500 to-orange-500 transition-all duration-500"
                            style={{ width: `${Math.min(engagementStats.tier_progress_percent || 0, 100)}%` }}
                          />
                        </div>
                        <div className="text-xs text-slate-500 mt-1 text-center">
                          {(engagementStats.fp_to_next_tier || 0).toLocaleString()} FP to next tier
                        </div>
                      </div>
                    )}
                  </div>
                );
              })()}

              {globalBestLineup && (
                <div className="bg-slate-800 rounded-lg p-6 border border-slate-700 mb-6">
                  <div className="flex items-center justify-between">
                    <div>
                      <div className="text-sm font-semibold text-slate-200">Global best possible lineup</div>
                      <div className="text-xs text-slate-400">Best possible total using your roster settings (not limited to drafted players)</div>
                    </div>
                    <div className="text-3xl font-bold text-emerald-300">{globalBestLineup.total.toFixed(1)} pts</div>
                  </div>

                  <div className="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-2">
                    {globalBestLineup.slots.map((s, idx) => (
                      <div key={idx} className="bg-slate-700 rounded p-3 flex items-center justify-between gap-3">
                        <div className="flex items-center gap-2 min-w-0">
                          <span className={`text-xs font-bold px-2 py-1 rounded ${POSITION_COLORS[s.slot]?.text || "text-white"} bg-slate-600`}>
                            {s.slot}
                          </span>
                          <TeamColorBadge team={s.player.team} />
                          <span className="text-sm font-medium truncate">{s.player.name}</span>
                        </div>
                        <div className="text-sm font-bold text-emerald-200">{(s.player.points ?? 0).toFixed(1)}</div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              <div className="bg-slate-800 rounded-lg p-4 border border-slate-700 mb-6">
                <div className="text-sm font-semibold mb-2">Scoreboard</div>
                <div className="space-y-2">
                  {scoreboard.map((s, idx) => (
                    <div key={s.user_id} className="bg-slate-700 rounded px-3 py-2 flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <span className="text-xs text-slate-300 w-6">#{idx + 1}</span>
                        <span className="font-semibold">{s.name}</span>
                      </div>
                      <span className="font-bold text-emerald-200">{s.total.toFixed(1)}</span>
                    </div>
                  ))}
                </div>
              </div>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
                {scoreboard.slice(0, 4).map((s, idx) => renderTeamPanel(s.user_id, idx === 0 ? "text-emerald-300" : "text-slate-200"))}
              </div>


              <div className="flex flex-col items-center gap-4">
                {/* Rematch Section */}
                <div className="bg-slate-800 rounded-lg p-4 border border-slate-700 w-full max-w-md">
                  <div className="text-center mb-3">
                    <h3 className="font-semibold text-lg">Play Again Together</h3>
                    <p className="text-sm text-slate-400">Same players, same settings, new week</p>
                  </div>

                  {rematchStatus.total >= 2 && (
                    <div className="mb-3">
                      <div className="flex justify-between text-sm mb-1">
                        <span>Players Ready</span>
                        <span className="font-bold">
                          {rematchStatus.ready} / {rematchStatus.total}
                        </span>
                      </div>
                      <div className="h-2 bg-slate-700 rounded-full overflow-hidden">
                        <div
                          className="h-full bg-emerald-500 transition-all duration-300"
                          style={{ width: `${(rematchStatus.ready / rematchStatus.total) * 100}%` }}
                        />
                      </div>
                      {rematchStatus.ready > 0 && rematchStatus.ready < rematchStatus.total && (
                        <p className="text-xs text-slate-400 mt-1 text-center">
                          Waiting for {rematchStatus.total - rematchStatus.ready} more player
                          {rematchStatus.total - rematchStatus.ready > 1 ? "s" : ""}...
                        </p>
                      )}
                    </div>
                  )}

                  <button
                    onClick={requestRematch}
                    disabled={rematchPending || rematchRequested || busy || rematchStatus.total < 2}
                    className={`w-full py-3 rounded-lg font-bold transition flex items-center justify-center gap-2 min-h-11
                      ${rematchRequested ? "bg-emerald-600 cursor-default" : "bg-gradient-to-r from-emerald-600 to-emerald-700 hover:from-emerald-500 hover:to-emerald-600"}
                      disabled:opacity-50 disabled:cursor-not-allowed`}
                  >
                    {rematchPending ? (
                      <>
                        <span className="animate-spin rounded-full h-4 w-4 border-2 border-white border-t-transparent" />
                        Starting Rematch...
                      </>
                    ) : rematchRequested ? (
                      <>
                        <Check size={18} />
                        Ready for Rematch
                      </>
                    ) : rematchStatus.total < 2 ? (
                      "Need 2+ players for rematch"
                    ) : (
                      <>
                        <Users size={18} />
                        Rematch
                      </>
                    )}
                  </button>
                </div>

                {/* Divider */}
                <div className="flex items-center gap-3 w-full max-w-md">
                  <div className="flex-1 h-px bg-slate-700" />
                  <span className="text-slate-500 text-sm">or</span>
                  <div className="flex-1 h-px bg-slate-700" />
                </div>

                {/* Other Options */}
                <div className="flex gap-3">
                  <button
                    onClick={async () => {
                      try {
                        await markLeft();
                      } catch (_) {}

                      rosterLoadedRef.current = false;
                      resultsComputedRef.current = false;
                      autoPickInFlightRef.current = false;
                      lastAutoPickTryRef.current = { gameId: null, pickNumber: null };

                      setGameId(null);
                      setMySeat(null);
                      setPlayers([]);
                      setWeeklyRoster([]);
                      setDraftedPlayerIds(new Set());
                      setPinnedByPos({});
                      setTeamsByUser({});
                      setResultsByUser({});
                      setWeeklyRankInfoById({});
                      setGlobalBestLineup(null);
                      setGameWeek(null);
                      setPosFilter("ALL");
                      setTeamFilter("ALL");
                      setSearchQuery("");
                      setSearchResults([]);
                      setTurnDeadlineAtMs(null);
                      setTimeRemaining(gameSettings.pickTime || 30);
                      setDraftBusy(false);
                      setMatchmakingStatus("");
                      setDraftView("SEARCH");
                      setInviteRoom(null);
                      inviteAutoJoinRef.current = false;
                      setRematchRequested(false);
                      setRematchStatus({ ready: 0, total: 0 });
                      setLastGameFpEarned(null);
                      flashNotice("");

                      setGameSettings((p) => ({ ...p, joinMode: "code" }));

                      setTimeout(() => {
                        createRoom().catch?.(() => {});
                      }, 0);
                    }}
                    disabled={busy || !playerName.trim()}
                    className="bg-slate-700 hover:bg-slate-600 disabled:opacity-50 px-6 py-3 rounded-lg font-bold transition"
                  >
                    New Game
                  </button>

                  <button
                    onClick={() => {
                      markLeft();

                      rosterLoadedRef.current = false;
                      resultsComputedRef.current = false;
                      autoPickInFlightRef.current = false;
                      lastAutoPickTryRef.current = { gameId: null, pickNumber: null };

                      setScreen("setup");
                      setGameId(null);
                      setMySeat(null);
                      setPlayers([]);
                      setWeeklyRoster([]);
                      setDraftedPlayerIds(new Set());
                      setPinnedByPos({});
                      setTeamsByUser({});
                      setResultsByUser({});
                      setWeeklyRankInfoById({});
                      setGlobalBestLineup(null);
                      setGameWeek(null);
                      setPosFilter("ALL");
                      setTeamFilter("ALL");
                      setSearchQuery("");
                      setSearchResults([]);
                      setTurnDeadlineAtMs(null);
                      setTimeRemaining(gameSettings.pickTime || 30);
                      setDraftBusy(false);
                      setMatchmakingStatus("");
                      setDraftView("SEARCH");
                      setInviteRoom(null);
                      inviteAutoJoinRef.current = false;
                      setRematchRequested(false);
                      setRematchStatus({ ready: 0, total: 0 });
                      setLastGameFpEarned(null);
                      flashNotice("");
                    }}
                    className="bg-slate-700 hover:bg-slate-600 px-6 py-3 rounded-lg font-bold transition"
                  >
                    Back to Menu
                  </button>
                </div>
              </div>
            </>
          )}
        </div>
      </div>
    );
  }

  return null;
}