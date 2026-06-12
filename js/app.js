

const isLocal = location.hostname === "127.0.0.1" || location.hostname === "localhost";

const ANIMALCHAIN_CONFIG = isLocal ? {
  supabaseUrl: "http://127.0.0.1:54321",
  supabaseKey: "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
} : {
  supabaseUrl: "https://xbncxguszajafewaullp.supabase.co",
  supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhibmN4Z3VzemFqYWZld2F1bGxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc0OTMyMjIsImV4cCI6MjA5MzA2OTIyMn0.SmsP4udyYq9SSbVj-70_CyqlkPjyS2lzUM5jhFtRSPQ"
};

const LOCAL_ANIMALS_KEY = "animalchain_local_animals_v3_strict";
const LOBBY_SESSION_KEY = "animalchain_lobby_session_v1";
const GUEST_NAME_KEY = "animalchain_guest_name_v1";
const ACCOUNT_SESSION_KEY = "animalchain_account_session_v1";
const MOVES_VISIBLE_LIMIT = 5;

const AVATAR_EMOJIS = [
  "🦊","🐺","🦁","🐯","🐱","🐶","🐻","🐼","🐨","🦝",
  "🐰","🐹","🐭","🦔","🦄","🐴","🦓","🦒","🐘","🦏",
  "🦛","🐮","🐷","🐗","🐑","🐐","🦌","🦙","🦘","🐔",
  "🐧","🐦","🦅","🦆","🦢","🦉","🦩","🦚","🦜","🐤",
  "🦇","🐢","🐊","🦎","🐍","🐸","🦖","🦕","🐠","🐟",
  "🐬","🐳","🐋","🦈","🐙","🦑","🦐","🦞","🦀","🐚",
  "🐌","🦋","🐛","🐝","🐞","🪲","🕷️","🦂","🦗","🐜"
];

const supabaseClient = window.supabase
  ? window.supabase.createClient(ANIMALCHAIN_CONFIG.supabaseUrl, ANIMALCHAIN_CONFIG.supabaseKey, {
      realtime: { params: { eventsPerSecond: 10 } }
    })
  : null;

const page = document.body.dataset.page;
console.log("Animalchain app.js v16 (Collapse-Restore) geladen");

if (page === "practice") initPracticePage();
if (page === "online") initOnlinePage();
if (page === "local") initLocalPage();
if (page === "account") initAccountPage();

// Account-Pill in jeder Topbar einblenden, sobald angemeldet
window.addEventListener("DOMContentLoaded", () => {
  renderAccountPill();
});

async function loadApprovedAnimals() {
  ensureSupabase();
  let allAnimals = [];
  let from = 0;
  const pageSize = 1000;
  while (true) {
    const { data, error } = await supabaseClient
      .from("animals")
      .select("id, name, normalized_name, first_letter, last_letter, status")
      .eq("status", "approved")
      .order("name", { ascending: true })
      .range(from, from + pageSize - 1);
    if (error) throw new Error(`Tierdatenbank konnte nicht geladen werden: ${error.message}`);
    if (!data || data.length === 0) break;
    allAnimals = allAnimals.concat(data);
    if (data.length < pageSize) break;
    from += pageSize;
  }
  return mergeAnimals(allAnimals, loadLocalAnimals());
}

function generateLobbyCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const arr = new Uint8Array(6);
  crypto.getRandomValues(arr);
  let code = "";
  for (let i = 0; i < 6; i++) code += chars[arr[i] % chars.length];
  return code;
}

async function createGame({ code, guestName, timerEnabled, turnSeconds }) {
  ensureSupabase();
  const { data, error } = await supabaseClient.rpc("create_game", {
    p_code: code,
    p_guest_name: guestName,
    p_timer_enabled: timerEnabled,
    p_turn_seconds: turnSeconds,
    p_session_token: getActiveSessionToken()
  });
  if (error) throw new Error(`Lobby konnte nicht erstellt werden: ${error.message}`);
  return {
    game: data.game,
    player: data.player,
    hostSecret: data.host_secret,
    playerSecret: data.player_secret
  };
}

async function findGameByCode(code) {
  ensureSupabase();
  const { data, error } = await supabaseClient
    .from("games_public").select("*").eq("code", normalizeLobbyCode(code)).single();
  if (error) throw new Error("Lobby wurde nicht gefunden.");
  return data;
}

async function loadGameById(gameId) {
  ensureSupabase();
  const { data, error } = await supabaseClient
    .from("games_public").select("*").eq("id", gameId).single();
  if (error) throw new Error(`Lobby konnte nicht geladen werden: ${error.message}`);
  return data;
}

async function loadGamePlayers(gameId) {
  ensureSupabase();
  const { data, error } = await supabaseClient
    .from("game_players_public").select("*").eq("game_id", gameId).order("turn_order", { ascending: true });
  if (error) throw new Error(`Spieler konnten nicht geladen werden: ${error.message}`);
  return data || [];
}

async function loadGameMoves(gameId) {
  ensureSupabase();
  const { data, error } = await supabaseClient
    .from("moves").select("*").eq("game_id", gameId).order("move_number", { ascending: true });
  if (error) throw new Error(`Spielzüge konnten nicht geladen werden: ${error.message}`);
  return data || [];
}

async function joinGame(game, guestName) {
  const { data, error } = await supabaseClient.rpc("join_game", {
    p_code: game.code,
    p_guest_name: guestName,
    p_session_token: getActiveSessionToken()
  });
  if (error) throw new Error(`Beitritt fehlgeschlagen: ${error.message}`);
  return {
    player: data.player,
    playerSecret: data.player_secret
  };
}

async function rpcMakeMove(gameId, playerId, playerSecret, animalName) {
  const { data, error } = await supabaseClient.rpc("make_move", {
    p_game_id: gameId, p_player_id: playerId,
    p_player_secret: playerSecret, p_animal_name: animalName
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcStartGame(gameId, hostSecret, animalName) {
  const { data, error } = await supabaseClient.rpc("start_game", {
    p_game_id: gameId, p_host_secret: hostSecret, p_animal_name: animalName
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcKickPlayer(gameId, hostSecret, playerId) {
  const { data, error } = await supabaseClient.rpc("kick_player", {
    p_game_id: gameId, p_host_secret: hostSecret, p_player_id: playerId
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcSelfEliminate(gameId, playerId, playerSecret) {
  const { data, error } = await supabaseClient.rpc("self_eliminate", {
    p_game_id: gameId, p_player_id: playerId, p_player_secret: playerSecret
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcLeaveLobby(gameId, playerId, playerSecret) {
  const { data, error } = await supabaseClient.rpc("leave_lobby", {
    p_game_id: gameId, p_player_id: playerId, p_player_secret: playerSecret
  });
  if (error) throw new Error(error.message);
  return data;
}

// ============================================================
//  ACCOUNT-AUTH
// ============================================================
async function rpcRegister(username, pin, avatar) {
  ensureSupabase();
  const { data, error } = await supabaseClient.rpc("register_account", {
    p_username: username, p_pin: pin, p_avatar_emoji: avatar || null
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcLogin(username, pin) {
  ensureSupabase();
  const { data, error } = await supabaseClient.rpc("login_account", {
    p_username: username, p_pin: pin
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcValidateSession(token) {
  ensureSupabase();
  const { data, error } = await supabaseClient.rpc("validate_session", { p_token: token });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcLogout(token) {
  ensureSupabase();
  const { data, error } = await supabaseClient.rpc("logout_account", { p_token: token });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcUpdateAvatar(token, avatar) {
  ensureSupabase();
  const { data, error } = await supabaseClient.rpc("update_avatar", { p_token: token, p_avatar: avatar });
  if (error) throw new Error(error.message);
  return data;
}

// ============================================================
//  STATISTIK & TIERVORSCHLÄGE & ADMIN
// ============================================================
async function rpcGetMyStats() {
  ensureSupabase();
  const token = getActiveSessionToken();
  if (!token) throw new Error("Bitte anmelden.");
  const { data, error } = await supabaseClient.rpc("get_my_stats", { p_session_token: token });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcSubmitSuggestion(name, category, source) {
  ensureSupabase();
  const token = getActiveSessionToken();
  if (!token) throw new Error("Bitte anmelden, um Vorschläge zu machen.");
  const { data, error } = await supabaseClient.rpc("submit_animal_suggestion", {
    p_session_token: token, p_name: name, p_category: category, p_source: source || null
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcListMySuggestions() {
  ensureSupabase();
  const token = getActiveSessionToken();
  if (!token) throw new Error("Bitte anmelden.");
  const { data, error } = await supabaseClient.rpc("list_my_suggestions", { p_session_token: token });
  if (error) throw new Error(error.message);
  return data || [];
}

async function rpcAdminListSuggestions(status = "pending") {
  ensureSupabase();
  const token = getActiveSessionToken();
  if (!token) throw new Error("Bitte anmelden.");
  const { data, error } = await supabaseClient.rpc("admin_list_suggestions", {
    p_session_token: token, p_status: status
  });
  if (error) throw new Error(error.message);
  return data || [];
}

async function rpcApproveSuggestion(suggestionId) {
  ensureSupabase();
  const token = getActiveSessionToken();
  if (!token) throw new Error("Bitte anmelden.");
  const { data, error } = await supabaseClient.rpc("approve_animal_suggestion", {
    p_session_token: token, p_suggestion_id: suggestionId
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcRejectSuggestion(suggestionId, reason) {
  ensureSupabase();
  const token = getActiveSessionToken();
  if (!token) throw new Error("Bitte anmelden.");
  const { data, error } = await supabaseClient.rpc("reject_animal_suggestion", {
    p_session_token: token, p_suggestion_id: suggestionId, p_reason: reason
  });
  if (error) throw new Error(error.message);
  return data;
}

async function rpcRecordGameFinish(gameId) {
  ensureSupabase();
  const token = getActiveSessionToken();
  if (!token) return null; // Gast → kein XP
  const { data, error } = await supabaseClient.rpc("record_game_finish", {
    p_session_token: token, p_game_id: gameId
  });
  if (error) throw new Error(error.message);
  return data;
}

const XP_AWARDED_KEY = "animalchain_xp_awarded_v1";
function markXpAwarded(gameId) {
  try {
    const set = new Set(JSON.parse(localStorage.getItem(XP_AWARDED_KEY) || "[]"));
    set.add(gameId);
    // nur die letzten 50 behalten
    const arr = [...set].slice(-50);
    localStorage.setItem(XP_AWARDED_KEY, JSON.stringify(arr));
  } catch {}
}
function isXpAwarded(gameId) {
  try {
    const arr = JSON.parse(localStorage.getItem(XP_AWARDED_KEY) || "[]");
    return Array.isArray(arr) && arr.includes(gameId);
  } catch { return false; }
}

function saveAccountSession(session) {
  try { localStorage.setItem(ACCOUNT_SESSION_KEY, JSON.stringify(session)); } catch {}
}

function loadAccountSession() {
  try {
    const raw = localStorage.getItem(ACCOUNT_SESSION_KEY);
    if (!raw) return null;
    const s = JSON.parse(raw);
    if (!s?.session_token || !s?.account?.id) return null;
    if (s.expires_at && new Date(s.expires_at).getTime() < Date.now()) return null;
    return s;
  } catch { return null; }
}

function clearAccountSession() {
  try { localStorage.removeItem(ACCOUNT_SESSION_KEY); } catch {}
}

function getActiveAccount() {
  const s = loadAccountSession();
  return s?.account || null;
}

function getActiveSessionToken() {
  return loadAccountSession()?.session_token || null;
}

function renderAccountPill() {
  const account = getActiveAccount();
  // Existing pill aus Topbar holen oder neu bauen
  document.querySelectorAll(".topbar").forEach((topbar) => {
    let pill = topbar.querySelector(".account-pill");
    if (account) {
      if (!pill) {
        pill = document.createElement("a");
        pill.className = "account-pill";
        pill.href = "account.html";
        topbar.appendChild(pill);
      }
      pill.innerHTML = `<span class="ap-avatar">${escapeHtml(account.avatar_emoji || "🦊")}</span><span>${escapeHtml(account.username)}</span>`;
    } else {
      if (pill) pill.remove();
      // Statt Pill: kleiner "Anmelden"-Link in Nav-Links falls noch nicht da
      const navLinks = topbar.querySelector(".nav-links");
      if (navLinks && !navLinks.querySelector('a[href="account.html"]')) {
        const a = document.createElement("a");
        a.href = "account.html";
        a.textContent = "Account";
        navLinks.appendChild(a);
      }
    }
  });
}

function saveLobbySession(session) {
  try { localStorage.setItem(LOBBY_SESSION_KEY, JSON.stringify(session)); }
  catch { /* localStorage voll oder gesperrt */ }
}

function loadLobbySession() {
  try {
    const raw = localStorage.getItem(LOBBY_SESSION_KEY);
    if (!raw) return null;
    const session = JSON.parse(raw);
    if (!session || !session.gameId || !session.playerId || !session.playerSecret) return null;
    return session;
  } catch { return null; }
}

function clearLobbySession() {
  try { localStorage.removeItem(LOBBY_SESSION_KEY); } catch {}
}

function saveGuestName(name) {
  try { if (name) localStorage.setItem(GUEST_NAME_KEY, name); } catch {}
}

function loadGuestName() {
  try { return localStorage.getItem(GUEST_NAME_KEY) || ""; } catch { return ""; }
}

function buildLobbyShareUrl(code) {
  const url = new URL(location.href);
  url.searchParams.set("lobby", code);
  url.hash = "";
  return url.toString();
}

function readLobbyCodeFromUrl() {
  try {
    const url = new URL(location.href);
    const code = url.searchParams.get("lobby");
    return code ? normalizeLobbyCode(code) : "";
  } catch { return ""; }
}

// ============================================================
//  TIMELINE-RENDERING (für alle drei Spielmodi)
// ============================================================

function renderMovesTimeline(moves, startAnimal) {
  if (!moves || moves.length === 0) {
    if (startAnimal) {
      return `
        <li class="move-item move-latest">
          <div class="move-avatar">★<span class="move-number-badge">0</span></div>
          <div class="move-content">
            <div class="move-animal">${highlightFirstAndLast(startAnimal)}</div>
            <div class="move-player"><span class="move-player-icon">🎯</span>Starttier</div>
          </div>
          <div class="move-meta">
            <span class="move-latest-tag">Start</span>
          </div>
        </li>
      `;
    }
    return `
      <li class="moves-empty">
        <div class="moves-empty-icon">🦊</div>
        <div class="moves-empty-text">Noch keine Züge.<br>Das erste Tier wartet auf dich!</div>
      </li>
    `;
  }

  const total = moves.length;
  const reversed = [...moves].reverse();
  const hiddenCount = Math.max(0, total - MOVES_VISIBLE_LIMIT);

  const renderOne = (move, idx) => {
    const isLatest = idx === 0;
    const isHidden = idx >= MOVES_VISIBLE_LIMIT;
    const moveNumber = total - idx;
    const animal = move.animal || move.animal_name || "";
    const player = move.playerName || move.guest_name || "Unbekannt";
    const animalHtml = highlightFirstAndLast(animal);
    const playerName = escapeHtml(player);
    const initials = getInitials(player);
    const timeText = formatMoveTime(move);

    const classes = ["move-item"];
    if (isLatest) classes.push("move-latest");
    if (isHidden) classes.push("move-hidden");

    return `
      <li class="${classes.join(" ")}">
        <div class="move-avatar">${initials}<span class="move-number-badge">${moveNumber}</span></div>
        <div class="move-content">
          <div class="move-animal">${animalHtml}</div>
          <div class="move-player"><span class="move-player-icon">👤</span>${playerName}</div>
        </div>
        <div class="move-meta">
          ${isLatest ? `<span class="move-latest-tag">Neu</span>` : ""}
          ${timeText ? `<div class="move-time">${timeText}</div>` : ""}
        </div>
      </li>
    `;
  };

  if (hiddenCount > 0) {
    const visibleHtml = reversed.slice(0, MOVES_VISIBLE_LIMIT).map((m, i) => renderOne(m, i)).join("");
    const hiddenHtml = reversed.slice(MOVES_VISIBLE_LIMIT).map((m, i) => renderOne(m, i + MOVES_VISIBLE_LIMIT)).join("");

    return `
      ${visibleHtml}
      <li class="moves-toggle-wrap" style="list-style:none">
        <button type="button" class="moves-toggle" data-moves-toggle>
          <span class="toggle-label">Ältere Züge anzeigen</span>
          <span class="toggle-count">+${hiddenCount}</span>
          <span class="toggle-chevron">▼</span>
        </button>
      </li>
      ${hiddenHtml}
    `;
  }

  return reversed.map((m, i) => renderOne(m, i)).join("");
}

function highlightFirstAndLast(animalName) {
  const safe = escapeHtml(animalName || "");
  if (safe.length < 2) return safe;
  const first = safe[0];
  const last = safe[safe.length - 1];
  const middle = safe.slice(1, -1);
  return `<span class="letter-highlight">${first}</span>${middle}<span class="letter-highlight">${last}</span>`;
}

function formatMoveTime(move) {
  const ts = move.created_at || move.createdAt || move.timestamp || move.played_at;
  if (!ts) return "";
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
}

function getInitials(name) {
  const safe = String(name || "").trim();
  if (!safe) return "?";
  const parts = safe.split(/\s+/);
  if (parts.length === 1) return escapeHtml(parts[0].charAt(0).toUpperCase());
  return escapeHtml((parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase());
}

// ============================================================

function initPracticePage() {
  const state = { animals: [], lastAnimal: "Turmfalke", requiredLetter: "e", moves: [] };
  const el = mapElements({
    lastAnimal: "#practiceLastAnimal", requiredLetter: "#practiceRequiredLetter",
    moveCount: "#practiceMoveCount", animalForm: "#practiceAnimalForm",
    animalInput: "#practiceAnimalInput", message: "#practiceMessage",
    hintButton: "#practiceHintButton", newRoundButton: "#practiceNewRoundButton",
    movesList: "#practiceMovesList"
  });

  el.animalForm.addEventListener("submit", handleMove);
  el.hintButton.addEventListener("click", showHint);
  el.newRoundButton.addEventListener("click", () => startNewRound(true));
  start();

  async function start() {
    try {
      state.animals = await loadApprovedAnimals();
      if (!state.animals.length) { setMessage(el.message, "Keine Tiere in Supabase gefunden.", "warning"); render(); return; }
      startNewRound(false);
      setMessage(el.message, `${state.animals.length} Tiere geladen. Du bist dran.`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
    render();
  }

  function startNewRound(showMessage) {
    const animal = randomItem(state.animals) || { name: "Turmfalke" };
    state.lastAnimal = animal.name;
    state.requiredLetter = getLastLetter(animal.name);
    state.moves = [];
    render();
    if (showMessage) setMessage(el.message, `Neue Runde. Starttier: ${state.lastAnimal}`, "success");
  }

  async function handleMove(event) {
    event.preventDefault();
    const animalName = cleanAnimalName(el.animalInput.value);
    const validation = validatePracticeAnimal(animalName);
    if (!validation.ok) { setMessage(el.message, validation.message, validation.type); return; }
    addMove("Du", animalName);
    el.animalInput.value = "";
    render();
    await sleep(450);
    computerMove();
  }

  function computerMove() {
    const options = availableAnimals(state.animals, state.requiredLetter, state.moves.map((m) => m.animal));
    if (!options.length) {
      setMessage(el.message, `Der Computer findet kein Tier mit ${state.requiredLetter.toUpperCase()}. Du gewinnst!`, "success");
      return;
    }
    const animal = randomItem(options);
    addMove("Computer", animal.name);
    render();
    setMessage(el.message, `Computer spielt: ${animal.name}. Jetzt brauchst du ${state.requiredLetter.toUpperCase()}.`, "success");
  }

  function validatePracticeAnimal(animalName) {
    const normalized = normalizeAnimalName(animalName);
    if (!animalName) return { ok: false, type: "warning", message: "Bitte gib ein Tier ein." };
    if (getFirstLetter(normalized) !== state.requiredLetter)
      return { ok: false, type: "error", message: `Dein Tier muss mit ${state.requiredLetter.toUpperCase()} anfangen.` };
    if (!findAnimal(state.animals, animalName))
      return { ok: false, type: "error", message: `"${animalName}" ist nicht in deiner Tierliste.` };
    if (state.moves.some((m) => normalizeAnimalName(m.animal) === normalized))
      return { ok: false, type: "error", message: `"${animalName}" wurde schon gespielt.` };
    return { ok: true };
  }

  function addMove(playerName, animalName) {
    state.moves.push({ playerName, animal: toTitleCase(animalName), created_at: new Date().toISOString() });
    state.lastAnimal = toTitleCase(animalName);
    state.requiredLetter = getLastLetter(animalName);
  }

  function showHint() {
    const options = availableAnimals(state.animals, state.requiredLetter, state.moves.map((m) => m.animal));
    if (!options.length) { setMessage(el.message, `Kein Tipp für ${state.requiredLetter.toUpperCase()} gefunden.`, "warning"); return; }
    setMessage(el.message, `Tipp: ${randomItem(options).name}`, "success");
  }

  function render() {
    el.lastAnimal.textContent = state.lastAnimal || "---";
    el.requiredLetter.textContent = state.requiredLetter ? state.requiredLetter.toUpperCase() : "---";
    el.moveCount.textContent = String(state.moves.length);
    el.movesList.innerHTML = renderMovesTimeline(state.moves, state.lastAnimal);
  }
}

function initOnlinePage() {
  const state = {
    animals: [], guestName: "Gast",
    game: null, localPlayer: null,
    hostSecret: null, playerSecret: null,
    isHost: false,
    players: [], moves: [],
    countdownTimer: null, realtimeChannel: null, fallbackTimer: null,
    lastSeenTurnKey: null, localTurnStartedAt: null
  };

  const el = mapElements({
    nameForm: "#onlineNameForm", guestName: "#onlineGuestName",
    timerEnabled: "#onlineTimerEnabled", turnSeconds: "#onlineTurnSeconds",
    createLobbyButton: "#onlineCreateLobbyButton",
    lobbyTicket: "#onlineLobbyTicket", lobbyCode: "#onlineLobbyCode",
    copyCodeButton: "#onlineCopyCodeButton",
    joinForm: "#onlineJoinForm", joinCode: "#onlineJoinCode",
    message: "#onlineMessage",
    lastAnimal: "#onlineLastAnimal", requiredLetter: "#onlineRequiredLetter",
    timerDisplay: "#onlineTimerDisplay", turnBadge: "#onlineTurnBadge",
    moveForm: "#onlineMoveForm", animalInput: "#onlineAnimalInput",
    refreshButton: "#onlineRefreshButton", newRoundButton: "#onlineNewRoundButton",
    playersList: "#onlinePlayersList", movesList: "#onlineMovesList"
  });

  const startGameButton = optionalQs("#onlineStartGameButton");
  const shareLinkButton = optionalQs("#onlineShareLinkButton");
  const leaveLobbyButton = optionalQs("#onlineLeaveLobbyButton");
  const localAnimalForm = optionalQs("#onlineLocalAnimalForm");
  const localAnimalInput = optionalQs("#onlineLocalAnimalInput");
  const localAnimalMessage = optionalQs("#onlineLocalAnimalMessage");

  el.nameForm.addEventListener("submit", handleName);
  el.createLobbyButton.addEventListener("click", handleCreateLobby);
  el.copyCodeButton.addEventListener("click", copyLobbyCode);
  el.joinForm.addEventListener("submit", handleJoinLobby);
  el.moveForm.addEventListener("submit", handleMove);
  el.refreshButton.addEventListener("click", refreshLobby);
  el.newRoundButton.addEventListener("click", newRound);
  if (startGameButton) startGameButton.addEventListener("click", handleStartGame);
  if (shareLinkButton) shareLinkButton.addEventListener("click", handleShareLink);
  if (leaveLobbyButton) leaveLobbyButton.addEventListener("click", handleLeaveLobby);
  if (localAnimalForm && localAnimalInput && localAnimalMessage) {
    localAnimalForm.addEventListener("submit", handleAddLocalAnimal);
  }

  // Account-Username hat Vorrang vor Gastname
  const activeAccount = getActiveAccount();
  if (activeAccount) {
    state.guestName = activeAccount.username;
    // Gastname-Formular ausblenden, weil Username vom Account kommt
    if (el.nameForm) el.nameForm.hidden = true;
  } else {
    const savedName = loadGuestName();
    if (savedName) {
      state.guestName = savedName;
      el.guestName.value = savedName;
    }
  }

  // Lobby-Code aus URL `?lobby=XXX` ins Eingabefeld vorausfüllen
  const urlLobbyCode = readLobbyCodeFromUrl();
  if (urlLobbyCode) {
    el.joinCode.value = urlLobbyCode;
  }

  el.playersList.addEventListener("click", async (event) => {
    const kickButton = event.target.closest(".kick-button");
    if (!kickButton) return;
    const playerId = kickButton.dataset.playerId;
    const playerName = kickButton.dataset.playerName;
    if (!playerId) return;
    if (!confirm(`${playerName} wirklich aus der Lobby entfernen?`)) return;
    try {
      await rpcKickPlayer(state.game.id, state.hostSecret, playerId);
      setMessage(el.message, `${playerName} wurde aus der Lobby entfernt.`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
  });

  start();

  async function start() {
    try {
      state.animals = await loadApprovedAnimals();
      setMessage(el.message, `${state.animals.length} Tiere geladen. Erstelle eine Lobby oder tritt einer bei.`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
    render();
    // Falls eine alte Lobby in localStorage liegt → versuchen wieder beizutreten
    await tryReconnectLobby();
  }

  async function tryReconnectLobby() {
    const session = loadLobbySession();
    if (!session) return;
    try {
      const [game, players] = await Promise.all([
        loadGameById(session.gameId),
        loadGamePlayers(session.gameId)
      ]);
      const me = players.find((p) => p.id === session.playerId);
      if (!me) {
        // Wir wurden in der Zwischenzeit aus der Lobby entfernt
        clearLobbySession();
        return;
      }
      state.game = game;
      state.players = players;
      state.localPlayer = me;
      state.playerSecret = session.playerSecret;
      state.hostSecret = session.hostSecret || null;
      state.isHost = !!session.hostSecret;
      state.moves = await loadGameMoves(game.id);
      el.lobbyTicket.hidden = false;
      el.lobbyCode.textContent = game.code;
      subscribeToGame(game.id);
      startCountdownTimer();
      render();
      setMessage(el.message, `Wieder mit Lobby ${game.code} verbunden.`, "success");
    } catch (error) {
      // Session ist nicht mehr gültig (z. B. Lobby gelöscht) — verwerfen
      clearLobbySession();
      console.warn("Auto-Reconnect fehlgeschlagen:", error?.message || error);
    }
  }

  function handleName(event) {
    event.preventDefault();
    state.guestName = cleanPlayerName(el.guestName.value) || "Gast";
    saveGuestName(state.guestName);
    setMessage(el.message, `Name gesetzt: ${state.guestName}`, "success");
  }

  function persistCurrentSession() {
    if (!state.game?.id || !state.localPlayer?.id || !state.playerSecret) {
      clearLobbySession(); return;
    }
    saveLobbySession({
      gameId: state.game.id,
      playerId: state.localPlayer.id,
      playerSecret: state.playerSecret,
      hostSecret: state.hostSecret || null,
      code: state.game.code || null
    });
  }

  async function handleShareLink() {
    if (!state.game?.code) { setMessage(el.message, "Keine Lobby aktiv.", "warning"); return; }
    const url = buildLobbyShareUrl(state.game.code);
    // navigator.share auf Mobile, sonst Zwischenablage
    if (navigator.share) {
      try {
        await navigator.share({ title: "Animalchain Lobby", text: `Tritt meiner Lobby bei: ${state.game.code}`, url });
        setMessage(el.message, "Link geteilt.", "success");
        return;
      } catch { /* user cancelled → fallback */ }
    }
    try {
      await navigator.clipboard.writeText(url);
      setMessage(el.message, "Einladungslink in die Zwischenablage kopiert.", "success");
    } catch {
      setMessage(el.message, `Link: ${url}`, "warning");
    }
  }

  async function handleLeaveLobby() {
    if (!state.game?.id || !state.localPlayer?.id) {
      setMessage(el.message, "Keine Lobby aktiv.", "warning"); return;
    }
    if (!confirm("Lobby wirklich verlassen?")) return;
    try {
      await rpcLeaveLobby(state.game.id, state.localPlayer.id, state.playerSecret);
    } catch (error) {
      console.warn("Leave-Fehler (ignoriert):", error?.message || error);
    }
    clearLobbySession();
    if (state.realtimeChannel) { supabaseClient.removeChannel(state.realtimeChannel); state.realtimeChannel = null; }
    if (state.countdownTimer) { clearInterval(state.countdownTimer); state.countdownTimer = null; }
    if (state.fallbackTimer) { clearInterval(state.fallbackTimer); state.fallbackTimer = null; }
    state.game = null; state.localPlayer = null;
    state.hostSecret = null; state.playerSecret = null;
    state.isHost = false; state.players = []; state.moves = [];
    el.lobbyTicket.hidden = true;
    setMessage(el.message, "Du hast die Lobby verlassen.", "success");
    render();
  }

  function handleAddLocalAnimal(event) {
    event.preventDefault();
    try {
      const animalName = cleanAnimalName(localAnimalInput.value);
      const normalized = normalizeAnimalName(animalName);
      if (!animalName) { localAnimalMessage.textContent = "Bitte gib ein Tier ein."; return; }
      if (normalized.length < 3) { localAnimalMessage.textContent = "Der Tiername ist zu kurz."; return; }
      if (!/^[a-zäöüßA-ZÄÖÜ\s-]+$/.test(animalName)) {
        localAnimalMessage.textContent = "Bitte nur Buchstaben, Leerzeichen oder Bindestrich verwenden."; return;
      }
      const localAnimal = addLocalAnimal(animalName);
      state.animals = mergeAnimals(state.animals, [localAnimal]);
      localAnimalInput.value = "";
      localAnimalMessage.textContent = `"${toTitleCase(animalName)}" wurde lokal hinzugefügt.`;
      setMessage(el.message, `"${toTitleCase(animalName)}" ist jetzt lokal spielbar.`, "success");
    } catch (error) { localAnimalMessage.textContent = error.message; }
  }

  async function handleCreateLobby() {
    try {
      const code = generateLobbyCode();
      const { game, player, hostSecret, playerSecret } = await createGame({
        code, guestName: state.guestName,
        timerEnabled: el.timerEnabled.checked,
        turnSeconds: Number(el.turnSeconds.value || 60)
      });
      state.game = game;
      state.localPlayer = player;
      state.hostSecret = hostSecret;
      state.playerSecret = playerSecret;
      state.isHost = true;
      state.players = [player];
      state.moves = [];
      el.lobbyTicket.hidden = false;
      el.lobbyCode.textContent = code;
      subscribeToGame(game.id);
      startCountdownTimer();
      persistCurrentSession();
      render();
      setMessage(el.message, `Lobby ${code} erstellt. Du bist der Host. Teile den Code mit Freunden.`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
  }

  async function handleJoinLobby(event) {
    event.preventDefault();
    try {
      const game = await findGameByCode(el.joinCode.value);
      const { player, playerSecret } = await joinGame(game, state.guestName);
      state.game = game;
      state.localPlayer = player;
      state.playerSecret = playerSecret;
      state.hostSecret = null;
      state.isHost = false;
      el.lobbyTicket.hidden = false;
      el.lobbyCode.textContent = game.code;
      await refreshLobby();
      subscribeToGame(game.id);
      startCountdownTimer();
      persistCurrentSession();
      setMessage(el.message, `Du bist Lobby ${game.code} beigetreten. Warte bis der Host startet.`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
  }

  async function handleStartGame() {
    if (!state.game?.id) { setMessage(el.message, "Du bist in keiner Lobby.", "warning"); return; }
    if (!state.isHost || !state.hostSecret) { setMessage(el.message, "Nur der Host kann starten.", "warning"); return; }
    if (state.players.length < 2) { setMessage(el.message, "Du brauchst mindestens 2 Spieler.", "warning"); return; }
    try {
      const animal = randomItem(state.animals) || { name: "Turmfalke" };
      await rpcStartGame(state.game.id, state.hostSecret, animal.name);
      state.lastSeenTurnKey = null;
      state.localTurnStartedAt = null;
      await refreshLobby();
      setMessage(el.message, `Spiel gestartet! Starttier: ${animal.name}`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
  }

  async function copyLobbyCode() {
    if (!state.game?.code) return;
    try {
      await navigator.clipboard.writeText(state.game.code);
      setMessage(el.message, "Lobby-Code kopiert.", "success");
    } catch {
      setMessage(el.message, "Kopieren ging nicht. Markiere den Code manuell.", "warning");
    }
  }

  function subscribeToGame(gameId) {
    if (state.realtimeChannel) supabaseClient.removeChannel(state.realtimeChannel);
    state.realtimeChannel = supabaseClient
      .channel(`game-${gameId}`)
      .on("postgres_changes",
        { event: "*", schema: "public", table: "games", filter: `id=eq.${gameId}` },
        async () => { await refreshLobby(); })
      .on("postgres_changes",
        { event: "*", schema: "public", table: "game_players", filter: `game_id=eq.${gameId}` },
        async (payload) => {
          if (payload.eventType === "DELETE" && payload.old?.id === state.localPlayer?.id) {
            handleKickedOut(); return;
          }
          state.players = await loadGamePlayers(gameId);
          render();
        })
      .on("postgres_changes",
        { event: "*", schema: "public", table: "moves", filter: `game_id=eq.${gameId}` },
        async () => { state.moves = await loadGameMoves(gameId); render(); })
      .subscribe((status) => {
        if (status === "SUBSCRIBED" && state.fallbackTimer) {
          clearInterval(state.fallbackTimer); state.fallbackTimer = null;
        } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
          startFallbackPolling();
        }
      });
    setTimeout(() => { if (!state.fallbackTimer) startFallbackPolling(); }, 2000);
  }

  function handleKickedOut() {
    setMessage(el.message, "Du wurdest aus der Lobby entfernt.", "warning");
    if (state.realtimeChannel) { supabaseClient.removeChannel(state.realtimeChannel); state.realtimeChannel = null; }
    if (state.countdownTimer) clearInterval(state.countdownTimer);
    if (state.fallbackTimer) clearInterval(state.fallbackTimer);
    state.game = null; state.localPlayer = null;
    state.hostSecret = null; state.playerSecret = null;
    state.isHost = false; state.players = []; state.moves = [];
    el.lobbyTicket.hidden = true;
    clearLobbySession();
    render();
  }

  function startFallbackPolling() {
    if (state.fallbackTimer) return;
    state.fallbackTimer = setInterval(refreshLobby, 1500);
  }

  async function refreshLobby() {
    if (!state.game?.id) return;
    try {
      const [game, players, moves] = await Promise.all([
        loadGameById(state.game.id),
        loadGamePlayers(state.game.id),
        loadGameMoves(state.game.id)
      ]);
      if (state.localPlayer && !players.some(p => p.id === state.localPlayer.id)) {
        handleKickedOut(); return;
      }
      state.game = game; state.players = players; state.moves = moves;
      render();
    } catch (error) { console.error("Refresh-Fehler:", error); }
  }

  async function checkLocalTimerExpiration() {
    if (!state.game?.timer_enabled || state.game?.status !== "playing") return;
    const currentPlayer = getCurrentOnlinePlayer();
    if (!currentPlayer || currentPlayer.is_eliminated) return;
    if (state.localPlayer?.id !== currentPlayer.id) return;
    const remaining = getRemainingSeconds();
    if (remaining === null || remaining > 0) return;
    const activePlayers = state.players.filter((p) => !p.is_eliminated);
    if (activePlayers.length <= 1) return;
    try {
      await rpcSelfEliminate(state.game.id, state.localPlayer.id, state.playerSecret);
      setMessage(el.message, `Deine Zeit ist abgelaufen!`, "warning");
    } catch (err) { console.error(err); }
  }

  async function handleMove(event) {
    event.preventDefault();
    if (!state.game || !state.localPlayer) { setMessage(el.message, "Du bist in keiner Lobby.", "warning"); return; }
    if (state.game.status !== "playing") { setMessage(el.message, "Das Spiel hat noch nicht gestartet.", "warning"); return; }
    const currentPlayer = getCurrentOnlinePlayer();
    if (!currentPlayer || currentPlayer.id !== state.localPlayer.id) {
      setMessage(el.message, "Du bist gerade nicht dran.", "warning"); return;
    }
    if (currentPlayer.is_eliminated) {
      setMessage(el.message, "Du bist ausgeschieden und kannst nur noch zuschauen.", "warning"); return;
    }
    const animalName = cleanAnimalName(el.animalInput.value);
    if (!animalName) { setMessage(el.message, "Bitte gib ein Tier ein.", "warning"); return; }
    if (animalName.length > 60) { setMessage(el.message, "Tiername zu lang.", "warning"); return; }
    if (!/^[a-zäöüßA-ZÄÖÜ\s-]+$/.test(animalName)) {
      setMessage(el.message, "Bitte nur Buchstaben, Leerzeichen oder Bindestrich verwenden.", "warning"); return;
    }
    try {
      await rpcMakeMove(state.game.id, state.localPlayer.id, state.playerSecret, animalName);
      el.animalInput.value = "";
      await refreshLobby();
      setMessage(el.message, `${state.guestName} spielt: ${toTitleCase(animalName)}`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
  }

  async function newRound() {
    if (!state.game?.id) { setMessage(el.message, "Du bist in keiner Lobby.", "warning"); return; }
    if (!state.isHost || !state.hostSecret) { setMessage(el.message, "Nur der Host kann neue Runden starten.", "warning"); return; }
    if (state.players.length < 2) { setMessage(el.message, "Du brauchst mindestens 2 Spieler.", "warning"); return; }
    try {
      const animal = randomItem(state.animals) || { name: "Turmfalke" };
      await rpcStartGame(state.game.id, state.hostSecret, animal.name);
      state.lastSeenTurnKey = null;
      state.localTurnStartedAt = null;
      await refreshLobby();
      setMessage(el.message, `Neue Runde gestartet. Starttier: ${animal.name}`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
  }

  function startCountdownTimer() {
    if (state.countdownTimer) clearInterval(state.countdownTimer);
    state.countdownTimer = setInterval(() => {
      renderTimerOnly();
      checkLocalTimerExpiration();
    }, 250);
  }

  function getCurrentOnlinePlayer() {
    return state.players.find((p) => p.turn_order === state.game?.current_turn_order) || null;
  }

  function getRemainingSeconds() {
    if (!state.game?.timer_enabled || !state.game?.turn_started_at || state.game?.status !== "playing") return null;
    const turnKey = `${state.game.id}-${state.game.current_turn_order}-${state.game.turn_started_at}`;
    if (state.lastSeenTurnKey !== turnKey) {
      state.lastSeenTurnKey = turnKey;
      state.localTurnStartedAt = Date.now();
    }
    const elapsed = Math.floor((Date.now() - state.localTurnStartedAt) / 1000);
    return Math.max(0, Number(state.game.turn_seconds || 60) - elapsed);
  }

  function getTimerDisplayText() {
    if (!state.game) return "—";
    if (!state.game.timer_enabled) return "Aus";
    const status = state.game.status;
    if (status === "waiting") return "Wartend";
    if (status === "finished") return "Beendet";
    if (status === "playing") {
      const remaining = getRemainingSeconds();
      if (remaining === null) return "Wartend";
      return formatTimer(remaining);
    }
    return "—";
  }

  let lastTimerText = "";
  function renderTimerOnly() {
    if (!state.game) return;
    const newText = getTimerDisplayText();
    if (newText !== lastTimerText) {
      el.timerDisplay.textContent = newText;
      lastTimerText = newText;
    }
  }

  let lastMovesHash = "";
  let lastPlayersHash = "";
  function render() {
    const currentPlayer = getCurrentOnlinePlayer();
    const activePlayers = state.players.filter((p) => !p.is_eliminated);

    el.lastAnimal.textContent = state.game?.last_animal || "---";
    el.requiredLetter.textContent = state.game?.current_required_letter
      ? state.game.current_required_letter.toUpperCase() : "---";

    renderTimerOnly();

    if (!state.game) el.turnBadge.textContent = "Keine aktive Lobby";
    else if (state.game.status === "waiting")
      el.turnBadge.textContent = `Lobby wartet · ${state.players.length} Spieler${state.isHost ? " · Du bist Host" : ""}`;
    else if (state.game.status === "finished") el.turnBadge.textContent = "Spiel beendet";
    else if (currentPlayer)
      el.turnBadge.textContent = `${currentPlayer.guest_name} ist dran${currentPlayer.is_eliminated ? " · ausgeschieden" : ""}`;
    else el.turnBadge.textContent = "Warte...";

    if (startGameButton) {
      if (state.isHost && state.game?.status === "waiting" && state.players.length >= 2) {
        startGameButton.hidden = false; startGameButton.textContent = "Spiel starten";
      } else if (state.isHost && state.game?.status === "finished") {
        startGameButton.hidden = false; startGameButton.textContent = "Erneut spielen";
      } else { startGameButton.hidden = true; }
    }

    // Spielerliste: nur neu rendern wenn sich was geändert hat (verhindert Flackern)
    const playersHash = JSON.stringify(state.players.map(p => [p.id, p.guest_name, p.is_eliminated, p.turn_order])) + "_" + (state.game?.status || "") + "_" + (state.game?.current_turn_order || "");
    if (playersHash !== lastPlayersHash) {
      lastPlayersHash = playersHash;
      el.playersList.innerHTML = state.players.length
        ? state.players.map((p) => {
            const isMe = p.id === state.localPlayer?.id;
            const canKick = state.isHost && !isMe && state.game?.status === "waiting";
            return `
              <article class="player-row ${p.is_eliminated ? "eliminated" : ""}">
                <div>
                  <strong>${escapeHtml(p.guest_name)}</strong>
                  <div class="meta">Spieler ${p.turn_order}${isMe ? " · Du" : ""}${p.turn_order === 1 ? " · Host" : ""}</div>
                </div>
                <div style="display: flex; gap: 8px; align-items: center;">
                  ${ p.is_eliminated ? `<span class="pill danger">Raus</span>`
                    : state.game?.status === "waiting" ? `<span class="pill">Bereit</span>`
                    : p.turn_order === state.game?.current_turn_order ? `<span class="pill success">Dran</span>`
                    : `<span class="pill">Aktiv</span>` }
                  ${canKick ? `<button class="kick-button button ghost" data-player-id="${p.id}" data-player-name="${escapeHtml(p.guest_name)}" style="padding: 4px 10px; font-size: 13px;">Kick</button>` : ""}
                </div>
              </article>`;
          }).join("")
        : `<p class="hint">Noch keine Spieler.</p>`;
    }

    // Verlauf: nur neu rendern wenn sich Züge wirklich geändert haben (verhindert Flackern)
    const movesHash = JSON.stringify(state.moves.map(m => [m.animal_name || m.animal, m.guest_name || m.playerName])) + "_" + (state.game?.last_animal || "");
    if (movesHash !== lastMovesHash) {
      lastMovesHash = movesHash;
      el.movesList.innerHTML = renderMovesTimeline(state.moves, state.game?.last_animal);
    }

    // Lobby-Panels automatisch einklappen sobald Spiel läuft
    autoCollapseLobbyPanels(state.game?.status === "playing");

    if (state.game?.status === "playing" && activePlayers.length === 1 && state.players.length > 1) {
      setMessage(el.message, `${activePlayers[0].guest_name} gewinnt! Drücke "Neue Runde" um nochmal zu spielen.`, "success");
    }

    // XP-Vergabe nach Spielende (online, eingeloggter Spieler, idempotent serverseitig + localStorage-Cache)
    if (state.game?.status === "finished" && state.game?.id && !isXpAwarded(state.game.id)) {
      const account = getActiveAccount();
      const me = state.localPlayer;
      const hasAccountPlayer = !!(me && (me.account_id || me.account_username));
      if (account && hasAccountPlayer) {
        markXpAwarded(state.game.id); // sofort markieren um Doppelaufrufe zu vermeiden
        rpcRecordGameFinish(state.game.id).then((result) => {
          if (!result) return;
          if (result.awarded > 0) {
            const lvlInfo = result.level ? ` · Level ${result.level}` : "";
            const streakInfo = result.streak > 1 ? ` · Streak ${result.streak} 🔥` : "";
            setMessage(el.message, `+${result.awarded} XP${lvlInfo}${streakInfo} · Kette ${result.chain_length}`, "success");
          }
        }).catch((err) => {
          console.warn("XP-Vergabe fehlgeschlagen:", err.message);
        });
      }
    }
  }

  function autoCollapseLobbyPanels(shouldCollapse) {
    if (!shouldCollapse) return;
    let changed = false;
    document.querySelectorAll('[data-collapsible="lobby"]').forEach(panel => {
      if (!panel.dataset.userToggled && !panel.classList.contains("is-collapsed")) {
        panel.classList.add("is-collapsed");
        changed = true;
      }
    });
    if (changed) {
      updateRestoreBar();
      updatePageLayout();
    }
  }
}

function initLocalPage() {
  const state = {
    animals: [], players: [], moves: [],
    lastAnimal: "Turmfalke", requiredLetter: "e",
    turnIndex: 0, started: false
  };

  const el = mapElements({
    playerForm: "#localPlayerForm", playerName: "#localPlayerName",
    startButton: "#localStartButton", playersList: "#localPlayersList",
    message: "#localMessage", lastAnimal: "#localLastAnimal",
    requiredLetter: "#localRequiredLetter", moveCount: "#localMoveCount",
    turnBadge: "#localTurnBadge", moveForm: "#localMoveForm",
    animalInput: "#localAnimalInput", movesList: "#localMovesList"
  });

  const suggestForm = optionalQs("#localSuggestForm");
  const suggestInput = optionalQs("#localSuggestInput");
  const animalCountEl = optionalQs("#localAnimalCount");

  el.playerForm.addEventListener("submit", addPlayer);
  el.startButton.addEventListener("click", startRound);
  el.moveForm.addEventListener("submit", handleMove);
  if (suggestForm && suggestInput) {
    suggestForm.addEventListener("submit", handleSuggestAnimal);
  }
  start();

  function updateAnimalCount() {
    if (animalCountEl) animalCountEl.textContent = `${state.animals.length} Tiere geladen`;
  }

  function handleSuggestAnimal(event) {
    event.preventDefault();
    try {
      const animalName = cleanAnimalName(suggestInput.value);
      const normalized = normalizeAnimalName(animalName);
      if (!animalName) { setMessage(el.message, "Bitte gib ein Tier ein.", "warning"); return; }
      if (normalized.length < 3) { setMessage(el.message, "Der Tiername ist zu kurz.", "warning"); return; }
      if (!/^[a-zäöüßA-ZÄÖÜ\s-]+$/.test(animalName)) {
        setMessage(el.message, "Bitte nur Buchstaben, Leerzeichen oder Bindestrich verwenden.", "warning"); return;
      }
      const localAnimal = addLocalAnimal(animalName);
      state.animals = mergeAnimals(state.animals, [localAnimal]);
      suggestInput.value = "";
      updateAnimalCount();
      setMessage(el.message, `"${toTitleCase(animalName)}" wurde lokal hinzugefügt.`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
  }

  async function start() {
    try {
      state.animals = await loadApprovedAnimals();
      setMessage(el.message, `${state.animals.length} Tiere geladen. Füge Spieler hinzu.`, "success");
    } catch (error) { setMessage(el.message, error.message, "error"); }
    updateAnimalCount();
    render();
  }

  function addPlayer(event) {
    event.preventDefault();
    const name = cleanPlayerName(el.playerName.value);
    if (!name) { setMessage(el.message, "Bitte gib einen Spielernamen ein.", "warning"); return; }
    state.players.push({ id: crypto.randomUUID(), name });
    el.playerName.value = "";
    render();
  }

  function startRound() {
    if (state.players.length < 2) { setMessage(el.message, "Du brauchst mindestens 2 Spieler.", "warning"); return; }
    const animal = randomItem(state.animals) || { name: "Turmfalke" };
    state.lastAnimal = animal.name;
    state.requiredLetter = getLastLetter(animal.name);
    state.moves = []; state.turnIndex = 0; state.started = true;
    setMessage(el.message, `Runde gestartet. Starttier: ${animal.name}`, "success");
    render();
  }

  function handleMove(event) {
    event.preventDefault();
    if (!state.started) { setMessage(el.message, "Starte zuerst eine Runde.", "warning"); return; }
    const animalName = cleanAnimalName(el.animalInput.value);
    const validation = validateLocalAnimal(animalName);
    if (!validation.ok) { setMessage(el.message, validation.message, validation.type); return; }
    const player = state.players[state.turnIndex];
    state.moves.push({
      playerName: player.name,
      animal: toTitleCase(animalName),
      created_at: new Date().toISOString()
    });
    state.lastAnimal = toTitleCase(animalName);
    state.requiredLetter = getLastLetter(animalName);
    state.turnIndex = (state.turnIndex + 1) % state.players.length;
    el.animalInput.value = "";
    setMessage(el.message, `${player.name} spielt ${toTitleCase(animalName)}.`, "success");
    render();
  }

  function validateLocalAnimal(animalName) {
    const normalized = normalizeAnimalName(animalName);
    if (!animalName) return { ok: false, type: "warning", message: "Bitte gib ein Tier ein." };
    if (getFirstLetter(normalized) !== state.requiredLetter)
      return { ok: false, type: "error", message: `Das Tier muss mit ${state.requiredLetter.toUpperCase()} anfangen.` };
    if (!findAnimal(state.animals, animalName))
      return { ok: false, type: "error", message: `"${animalName}" ist nicht in deiner Tierliste.` };
    if (state.moves.some((m) => normalizeAnimalName(m.animal) === normalized))
      return { ok: false, type: "error", message: `"${animalName}" wurde schon gespielt.` };
    return { ok: true };
  }

  function render() {
    el.playersList.innerHTML = state.players.length
      ? state.players.map((p, i) => `
          <article class="player-row">
            <div><strong>${escapeHtml(p.name)}</strong><div class="meta">Spieler ${i + 1}</div></div>
            ${state.started && i === state.turnIndex ? `<span class="pill success">Dran</span>` : `<span class="pill">Dabei</span>`}
          </article>`).join("")
      : `<p class="hint">Noch keine Spieler.</p>`;

    el.lastAnimal.textContent = state.lastAnimal || "---";
    el.requiredLetter.textContent = state.requiredLetter ? state.requiredLetter.toUpperCase() : "---";
    el.moveCount.textContent = String(state.moves.length);
    el.turnBadge.textContent = state.started ? `${state.players[state.turnIndex].name} ist dran` : "Noch keine Runde";

    el.movesList.innerHTML = renderMovesTimeline(state.moves, state.lastAnimal);
  }
}

function loadLocalAnimals() {
  try { const animals = JSON.parse(localStorage.getItem(LOCAL_ANIMALS_KEY)); return Array.isArray(animals) ? animals : []; }
  catch { return []; }
}

function saveLocalAnimals(animals) { localStorage.setItem(LOCAL_ANIMALS_KEY, JSON.stringify(animals)); }

function createLocalAnimal(name) {
  const cleanName = cleanAnimalName(name);
  const normalizedName = normalizeAnimalName(cleanName);
  return {
    id: `local-${normalizedName}`, name: toTitleCase(cleanName),
    normalized_name: normalizedName,
    first_letter: getFirstLetter(normalizedName), last_letter: getLastLetter(normalizedName),
    status: "approved", local: true
  };
}

function addLocalAnimal(name) {
  const animal = createLocalAnimal(name);
  if (!animal.normalized_name || !animal.first_letter || !animal.last_letter) {
    throw new Error("Dieses Tier kann nicht lokal gespeichert werden.");
  }
  const localAnimals = loadLocalAnimals();
  if (!localAnimals.some((item) => item.normalized_name === animal.normalized_name)) {
    localAnimals.push(animal); saveLocalAnimals(localAnimals);
  }
  return animal;
}

function mergeAnimals(databaseAnimals, localAnimals) {
  const animalsByName = new Map();
  [...databaseAnimals, ...localAnimals].forEach((animal) => {
    if (!animal) return;
    const normalized = animal.normalized_name || normalizeAnimalName(animal.name);
    if (!normalized) return;
    animalsByName.set(normalized, {
      ...animal, normalized_name: normalized,
      first_letter: animal.first_letter || getFirstLetter(animal.name),
      last_letter: animal.last_letter || getLastLetter(animal.name)
    });
  });
  return [...animalsByName.values()].sort((a, b) => a.name.localeCompare(b.name, "de"));
}

function ensureSupabase() {
  if (!supabaseClient) throw new Error("Supabase konnte nicht geladen werden.");
  if (!ANIMALCHAIN_CONFIG.supabaseKey || ANIMALCHAIN_CONFIG.supabaseKey.includes("DEIN_PUBLIC")) {
    throw new Error("Bitte trage deinen Supabase Public/Publishable Key in js/app.js ein.");
  }
}

function mapElements(selectors) {
  return Object.fromEntries(Object.entries(selectors).map(([key, selector]) => [key, qs(selector)]));
}

function qs(selector) {
  const element = document.querySelector(selector);
  if (!element) throw new Error(`Element fehlt: ${selector}`);
  return element;
}

function optionalQs(selector) { return document.querySelector(selector); }

function findAnimal(animals, animalName) {
  const normalized = normalizeAnimalName(animalName);
  return animals.some((animal) => {
    if (!animal) return false;
    const animalNormalized = animal.normalized_name || normalizeAnimalName(animal.name);
    return animalNormalized === normalized;
  });
}

function availableAnimals(animals, firstLetter, usedNames = []) {
  const used = new Set(usedNames.map(normalizeAnimalName));
  const letter = String(firstLetter || "").toLowerCase();
  return animals.filter((animal) => {
    const animalFirst = animal.first_letter || getFirstLetter(animal.name);
    const animalNormalized = animal.normalized_name || normalizeAnimalName(animal.name);
    return animalFirst === letter && !used.has(animalNormalized);
  });
}

function cleanPlayerName(value) { return String(value || "").trim().replace(/\s+/g, " ").slice(0, 24); }
function cleanAnimalName(value) { return String(value || "").trim().replace(/\s+/g, " ").slice(0, 60); }

function normalizeAnimalName(value) {
  return String(value || "")
    .trim().toLowerCase()
    .replace(/ä/g, "a").replace(/ö/g, "o").replace(/ü/g, "u").replace(/ß/g, "ss")
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z\s-]/g, "").replace(/\s+/g, " ");
}

function getFirstLetter(value) { return normalizeAnimalName(value).replace(/[^a-z]/g, "").charAt(0) || ""; }

function getLastLetter(value) {
  const letters = normalizeAnimalName(value).replace(/[^a-z]/g, "");
  return letters.charAt(letters.length - 1) || "";
}

function normalizeLobbyCode(value) {
  return String(value || "").trim().toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8);
}

function formatTimer(seconds) {
  if (seconds === null || seconds === undefined) return "—";
  const safeSeconds = Math.max(0, Number(seconds) || 0);
  return `${Math.floor(safeSeconds / 60)}:${String(safeSeconds % 60).padStart(2, "0")}`;
}

function toTitleCase(value) {
  return String(value || "").trim().toLowerCase().split(" ")
    .map((p) => p ? p.charAt(0).toUpperCase() + p.slice(1) : "").join(" ");
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#039;"
  }[c]));
}

function randomItem(items) { return items[Math.floor(Math.random() * items.length)]; }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function setMessage(element, text, type = "") {
  element.textContent = text;
  element.className = `message ${type}`.trim();
}

// ============================================================
//  ACCOUNT-SEITE
// ============================================================
function initAccountPage() {
  const authPanel = document.getElementById("accountAuthPanel");
  const profilePanel = document.getElementById("accountProfilePanel");
  const message = document.getElementById("accountMessage");
  const profileMessage = document.getElementById("profileMessage");
  const usernameDisplay = document.getElementById("profileUsernameDisplay");
  const avatarDisplay = document.getElementById("profileAvatarDisplay");
  const profileAvatarPicker = document.getElementById("profileAvatarPicker");
  const regAvatarPicker = document.getElementById("regAvatarPicker");
  const logoutButton = document.getElementById("profileLogoutButton");

  let selectedRegAvatar = "🦊";

  // Avatar-Picker bauen
  function buildAvatarPicker(container, currentEmoji, onSelect) {
    container.innerHTML = AVATAR_EMOJIS.map((e) =>
      `<button type="button" class="avatar-option${e === currentEmoji ? " selected" : ""}" data-emoji="${e}">${e}</button>`
    ).join("");
    container.addEventListener("click", (event) => {
      const btn = event.target.closest(".avatar-option");
      if (!btn) return;
      container.querySelectorAll(".avatar-option").forEach((b) => b.classList.remove("selected"));
      btn.classList.add("selected");
      onSelect(btn.dataset.emoji);
    });
  }

  buildAvatarPicker(regAvatarPicker, selectedRegAvatar, (emoji) => { selectedRegAvatar = emoji; });

  // Tabs
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      const target = tab.dataset.tab;
      document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t === tab));
      document.querySelectorAll("[data-form]").forEach((f) => { f.hidden = f.dataset.form !== target; });
      setMessage(message, "Bereit.", "");
    });
  });

  // Login-Formular
  document.getElementById("accountLoginForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const username = document.getElementById("loginUsername").value.trim().toLowerCase();
    const pin = document.getElementById("loginPin").value.trim();
    if (!username || !pin) { setMessage(message, "Benutzername und PIN angeben.", "warning"); return; }
    try {
      const result = await rpcLogin(username, pin);
      saveAccountSession(result);
      setMessage(message, `Angemeldet als ${result.account.username}.`, "success");
      showProfile();
    } catch (e) { setMessage(message, e.message, "error"); }
  });

  // Register-Formular
  document.getElementById("accountRegisterForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const username = document.getElementById("regUsername").value.trim().toLowerCase();
    const pin = document.getElementById("regPin").value.trim();
    const pin2 = document.getElementById("regPin2").value.trim();
    if (!/^[a-z0-9_-]{3,20}$/.test(username)) {
      setMessage(message, "Benutzername: 3-20 Zeichen, nur a-z, 0-9, _ oder -.", "warning"); return;
    }
    if (!/^[0-9]{4,6}$/.test(pin)) {
      setMessage(message, "PIN muss 4-6 Ziffern sein.", "warning"); return;
    }
    if (pin !== pin2) {
      setMessage(message, "Die PINs stimmen nicht überein.", "warning"); return;
    }
    try {
      const result = await rpcRegister(username, pin, selectedRegAvatar);
      saveAccountSession(result);
      setMessage(message, `Account ${result.account.username} erstellt. Angemeldet.`, "success");
      showProfile();
    } catch (e) { setMessage(message, e.message, "error"); }
  });

  // Profil anzeigen
  function showProfile() {
    const account = getActiveAccount();
    if (!account) { authPanel.hidden = false; profilePanel.hidden = true; return; }
    authPanel.hidden = true; profilePanel.hidden = false;
    usernameDisplay.textContent = account.username;
    avatarDisplay.textContent = account.avatar_emoji || "🦊";
    buildAvatarPicker(profileAvatarPicker, account.avatar_emoji || "🦊", async (emoji) => {
      try {
        await rpcUpdateAvatar(getActiveSessionToken(), emoji);
        const session = loadAccountSession();
        session.account.avatar_emoji = emoji;
        saveAccountSession(session);
        avatarDisplay.textContent = emoji;
        setMessage(profileMessage, `Avatar geändert: ${emoji}`, "success");
        renderAccountPill();
      } catch (e) { setMessage(profileMessage, e.message, "error"); }
    });
    renderAccountPill();

    // Stats / Vorschläge / Admin laden
    refreshAccountWidgets();
  }

  // ============================================================
  //  WIDGETS: Stats, Tiervorschläge, Admin
  // ============================================================
  const statsPanel = document.getElementById("accountStatsPanel");
  const suggestPanel = document.getElementById("accountSuggestPanel");
  const adminPanel = document.getElementById("accountAdminPanel");

  async function refreshAccountWidgets() {
    try {
      const stats = await rpcGetMyStats();
      renderStats(stats);

      // Account-Daten ggf. mit is_admin aktualisieren
      const session = loadAccountSession();
      if (session && session.account) {
        session.account.is_admin = stats.is_admin;
        saveAccountSession(session);
      }

      const mine = await rpcListMySuggestions();
      renderMySuggestions(mine);

      if (stats.is_admin) {
        if (adminPanel) adminPanel.hidden = false;
        await refreshAdminList();
      } else {
        if (adminPanel) adminPanel.hidden = true;
      }
    } catch (e) {
      console.warn("Widgets laden fehlgeschlagen:", e.message);
    }
  }

  function renderStats(stats) {
    if (!statsPanel) return;
    statsPanel.hidden = false;
    const wr = Number(stats.win_rate || 0);
    const xpInLvl = stats.xp_in_level || 0;
    const xpForNext = stats.xp_for_next_level || 100;
    const pct = Math.min(100, Math.round((xpInLvl / xpForNext) * 100));

    statsPanel.querySelector("[data-stat='level']").textContent = stats.level || 1;
    statsPanel.querySelector("[data-stat='xp']").textContent = `${stats.total_xp || 0} XP`;
    statsPanel.querySelector("[data-stat='xp-progress']").style.width = pct + "%";
    statsPanel.querySelector("[data-stat='xp-progress-text']").textContent =
      `${xpInLvl} / ${xpForNext} XP bis Level ${(stats.level || 1) + 1}`;
    statsPanel.querySelector("[data-stat='games']").textContent = stats.games_played || 0;
    statsPanel.querySelector("[data-stat='wins']").textContent = stats.games_won || 0;
    statsPanel.querySelector("[data-stat='winrate']").textContent = `${wr}%`;
    statsPanel.querySelector("[data-stat='streak']").textContent = stats.current_streak || 0;
    statsPanel.querySelector("[data-stat='best-streak']").textContent = stats.best_streak || 0;
    statsPanel.querySelector("[data-stat='longest']").textContent = stats.longest_chain || 0;
    statsPanel.querySelector("[data-stat='daily']").textContent =
      `${stats.daily_xp_today || 0} / ${stats.daily_xp_cap || 300}`;

    const topList = statsPanel.querySelector("[data-stat='top-animals']");
    const top = Array.isArray(stats.top_animals) ? stats.top_animals : [];
    if (!top.length) {
      topList.innerHTML = `<p class="hint">Noch keine gespielten Tiere.</p>`;
    } else {
      const maxCount = Math.max(...top.map((t) => t.count));
      topList.innerHTML = top.map((t, i) => `
        <div class="stat-row">
          <div class="stat-rank">${i + 1}</div>
          <div class="stat-row-main">
            <div class="stat-row-name">${escapeHtml(t.name)}</div>
            <div class="stat-bar"><div class="stat-bar-fill" style="width:${Math.round((t.count / maxCount) * 100)}%"></div></div>
          </div>
          <div class="stat-row-count">${t.count} ×</div>
        </div>
      `).join("");
    }

    const recentList = statsPanel.querySelector("[data-stat='recent']");
    const recent = Array.isArray(stats.recent_games) ? stats.recent_games : [];
    if (!recent.length) {
      recentList.innerHTML = `<p class="hint">Noch keine abgeschlossenen Spiele.</p>`;
    } else {
      recentList.innerHTML = recent.map((g) => {
        const date = g.finished_at ? new Date(g.finished_at).toLocaleString("de-DE", {
          day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"
        }) : "";
        const pill = g.is_winner
          ? `<span class="pill success">Sieg</span>`
          : `<span class="pill danger">Niederlage</span>`;
        return `
          <div class="recent-row">
            <span class="recent-date">${escapeHtml(date)}</span>
            <div class="recent-detail">Kette: ${g.chain_length || 0} Tiere</div>
            ${pill}
            <span class="recent-xp">+${g.xp_awarded || 0} XP</span>
          </div>`;
      }).join("");
    }

    // Admin-Badge im Suggest-Panel (zeigt offene Anzahl)
    const adminTabBadge = document.querySelector("[data-admin-badge]");
    if (adminTabBadge) {
      adminTabBadge.textContent = stats.pending_admin_count || 0;
      adminTabBadge.hidden = !(stats.is_admin && stats.pending_admin_count > 0);
    }
  }

  function renderMySuggestions(list) {
    const cont = suggestPanel?.querySelector("[data-mine-list]");
    if (!cont) return;
    if (!list.length) {
      cont.innerHTML = `<p class="hint">Du hast noch nichts vorgeschlagen.</p>`;
      return;
    }
    const CAT = { saeugetier: "Säugetier", vogel: "Vogel", fisch: "Fisch",
      reptil: "Reptil", amphibie: "Amphibie", insekt: "Insekt", sonstiges: "Sonstiges" };
    const STATUS = {
      pending: { txt: "⏳ Wartet", cls: "" },
      approved: { txt: "✓ Genehmigt", cls: "success" },
      rejected: { txt: "✕ Abgelehnt", cls: "danger" }
    };
    cont.innerHTML = list.map((s) => {
      const st = STATUS[s.status] || STATUS.pending;
      return `
        <div class="suggestion-row">
          <div>
            <strong>${escapeHtml(s.name)}</strong>
            <span class="meta">${escapeHtml(CAT[s.category] || s.category || "")}</span>
            ${s.status === "rejected" && s.review_reason
              ? `<div class="meta" style="margin-top:4px">Grund: ${escapeHtml(s.review_reason)}</div>` : ""}
          </div>
          <span class="pill ${st.cls}">${st.txt}</span>
        </div>
      `;
    }).join("");
  }

  // Suggest-Form
  const suggestForm = document.getElementById("accountSuggestForm");
  if (suggestForm) {
    suggestForm.addEventListener("submit", async (event) => {
      event.preventDefault();
      const nameEl = document.getElementById("suggestAnimalName");
      const catEl = document.getElementById("suggestAnimalCategory");
      const srcEl = document.getElementById("suggestAnimalSource");
      const msg = document.getElementById("suggestMessage");
      const name = (nameEl?.value || "").trim();
      const category = catEl?.value || "";
      const source = (srcEl?.value || "").trim();
      if (!name) { setMessage(msg, "Bitte einen Tiernamen angeben.", "warning"); return; }
      if (!category) { setMessage(msg, "Bitte eine Kategorie wählen.", "warning"); return; }
      try {
        await rpcSubmitSuggestion(name, category, source);
        setMessage(msg, `Vorschlag „${name}" eingereicht ✓`, "success");
        if (nameEl) nameEl.value = "";
        if (srcEl) srcEl.value = "";
        if (catEl) catEl.value = "";
        const mine = await rpcListMySuggestions();
        renderMySuggestions(mine);
      } catch (e) { setMessage(msg, e.message, "error"); }
    });
  }

  // Admin: Liste laden
  let currentAdminFilter = "pending";
  async function refreshAdminList() {
    const list = adminPanel?.querySelector("[data-admin-list]");
    if (!list) return;
    list.innerHTML = `<p class="hint">Lade...</p>`;
    try {
      const items = await rpcAdminListSuggestions(currentAdminFilter);
      renderAdminItems(items);
    } catch (e) {
      list.innerHTML = `<p class="message error">${escapeHtml(e.message)}</p>`;
    }
  }

  function renderAdminItems(items) {
    const list = adminPanel?.querySelector("[data-admin-list]");
    if (!list) return;
    if (!items.length) {
      list.innerHTML = `<p class="hint">Keine Einträge in „${currentAdminFilter}".</p>`;
      return;
    }
    const CAT = { saeugetier: "Säugetier", vogel: "Vogel", fisch: "Fisch",
      reptil: "Reptil", amphibie: "Amphibie", insekt: "Insekt", sonstiges: "Sonstiges" };
    list.innerHTML = items.map((s) => {
      const date = s.created_at ? new Date(s.created_at).toLocaleString("de-DE", {
        day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"
      }) : "";
      const pendingActions = s.status === "pending" ? `
        <button class="button" data-approve="${s.id}" style="background:linear-gradient(135deg,var(--success),var(--accent2));color:#06281f">✓ Genehmigen</button>
        <button class="button" data-reject="${s.id}" data-reject-name="${escapeHtml(s.name)}" style="background:rgba(251,113,133,.18);color:#fecdd3;border:1px solid rgba(251,113,133,.45)">✕ Ablehnen</button>
      ` : `<span class="pill ${s.status === "approved" ? "success" : "danger"}">${s.status === "approved" ? "✓ Genehmigt" : "✕ Abgelehnt"}</span>`;
      return `
        <div class="admin-row">
          <div class="admin-main">
            <div class="admin-name"><strong>${escapeHtml(s.name)}</strong>
              <span class="meta">${escapeHtml(CAT[s.category] || s.category || "")}</span>
            </div>
            <div class="meta">
              ${escapeHtml(s.suggested_by_avatar || "🦊")} ${escapeHtml(s.suggested_by_username || "Unbekannt")}
              · ${escapeHtml(date)}
              ${s.source ? `<br>📎 ${escapeHtml(s.source)}` : ""}
              ${s.review_reason ? `<br>Grund: ${escapeHtml(s.review_reason)}` : ""}
            </div>
          </div>
          <div class="admin-actions">${pendingActions}</div>
        </div>
      `;
    }).join("");
  }

  if (adminPanel) {
    // Filter-Buttons
    adminPanel.querySelectorAll("[data-admin-filter]").forEach((b) => {
      b.addEventListener("click", () => {
        adminPanel.querySelectorAll("[data-admin-filter]").forEach((x) => x.classList.remove("active"));
        b.classList.add("active");
        currentAdminFilter = b.dataset.adminFilter;
        refreshAdminList();
      });
    });

    // Approve / Reject (Event Delegation)
    adminPanel.addEventListener("click", async (event) => {
      const ap = event.target.closest("[data-approve]");
      const rj = event.target.closest("[data-reject]");
      const msg = document.getElementById("adminMessage");
      if (ap) {
        const id = ap.dataset.approve;
        ap.disabled = true;
        try {
          const res = await rpcApproveSuggestion(id);
          setMessage(msg, `„${res.animal?.name || "Tier"}" der Datenbank hinzugefügt ✓`, "success");
          await refreshAdminList();
          await refreshAccountWidgets();
        } catch (e) { setMessage(msg, e.message, "error"); ap.disabled = false; }
      } else if (rj) {
        const id = rj.dataset.reject;
        const name = rj.dataset.rejectName || "Vorschlag";
        const reason = prompt(`Grund für die Ablehnung von „${name}":`, "");
        if (!reason || reason.trim().length < 3) {
          setMessage(msg, "Ablehnung abgebrochen (Grund fehlt).", "warning"); return;
        }
        try {
          await rpcRejectSuggestion(id, reason);
          setMessage(msg, `„${name}" abgelehnt.`, "success");
          await refreshAdminList();
          await refreshAccountWidgets();
        } catch (e) { setMessage(msg, e.message, "error"); }
      }
    });
  }

  // Logout
  logoutButton.addEventListener("click", async () => {
    const token = getActiveSessionToken();
    if (token) {
      try { await rpcLogout(token); } catch { /* ignorieren */ }
    }
    clearAccountSession();
    authPanel.hidden = false; profilePanel.hidden = true;
    setMessage(message, "Abgemeldet.", "success");
    renderAccountPill();
  });

  // Beim Laden: ist Session noch gültig?
  (async () => {
    const session = loadAccountSession();
    if (!session) return;
    try {
      const valid = await rpcValidateSession(session.session_token);
      if (!valid) { clearAccountSession(); return; }
      // Account-Daten aktualisieren (falls Server-seitig geändert)
      session.account = valid.account;
      session.expires_at = valid.expires_at;
      saveAccountSession(session);
      showProfile();
    } catch {
      clearAccountSession();
    }
  })();
}

// Toggle für "Ältere Züge anzeigen"
document.addEventListener("click", (event) => {
  const toggle = event.target.closest("[data-moves-toggle]");
  if (!toggle) return;
  event.preventDefault();

  const list = toggle.closest("ol, ul");
  if (!list) return;

  const hiddenItems = list.querySelectorAll(".move-hidden");
  const isOpen = toggle.classList.toggle("is-open");
  const label = toggle.querySelector(".toggle-label");

  if (isOpen) {
    hiddenItems.forEach((item, i) => {
      setTimeout(() => item.classList.add("move-revealed"), i * 40);
    });
    if (label) label.textContent = "Weniger anzeigen";
  } else {
    hiddenItems.forEach((item) => item.classList.remove("move-revealed"));
    if (label) label.textContent = "Ältere Züge anzeigen";
  }
});

// Collapsible Panels — komplett verstecken / wieder einblenden
document.addEventListener("click", (event) => {
  // Panel einklappen (Pfeil-Button im Panel)
  const toggle = event.target.closest("[data-collapsible-toggle]");
  if (toggle) {
    event.preventDefault();
    const panel = toggle.closest("[data-collapsible]");
    if (!panel) return;
    panel.classList.add("is-collapsed");
    panel.dataset.userToggled = "1";
    updateRestoreBar();
    updatePageLayout();
    return;
  }

  // Panel wieder einblenden (Pillen-Button oben)
  const restoreBtn = event.target.closest("[data-restore-panel]");
  if (restoreBtn) {
    event.preventDefault();
    const panelId = restoreBtn.dataset.restorePanel;
    const panel = document.getElementById(panelId);
    if (panel) {
      panel.classList.remove("is-collapsed");
      panel.dataset.userToggled = "1";
    }
    updateRestoreBar();
    updatePageLayout();
    return;
  }
});

function updateRestoreBar() {
  let bar = document.getElementById("restoreBar");
  const main = document.querySelector("main.page-grid");
  if (!main) return;
  if (!bar) {
    bar = document.createElement("div");
    bar.id = "restoreBar";
    bar.className = "restore-bar";
    main.parentNode.insertBefore(bar, main);
  }

  // Jedem eingeklappten Panel eine ID geben, falls noch keine da
  document.querySelectorAll(".collapsible").forEach(panel => {
    if (!panel.id) panel.id = "panel-" + Math.random().toString(36).slice(2, 9);
  });

  const hiddenPanels = document.querySelectorAll(".collapsible.is-collapsed");
  bar.innerHTML = Array.from(hiddenPanels).map(panel => {
    const heading = panel.querySelector(".panel-heading h1, .panel-heading h2");
    const eyebrow = panel.querySelector(".panel-heading .eyebrow");
    let title = heading ? heading.textContent.trim() : "Panel";
    if (eyebrow) title = eyebrow.textContent.trim() + ": " + title;
    return `<button type="button" class="restore-button" data-restore-panel="${panel.id}">${escapeHtml(title)} einblenden</button>`;
  }).join("");
}

function updatePageLayout() {
  const main = document.querySelector("main.page-grid");
  if (!main) return;
  // Wenn das erste (linke) Panel eingeklappt ist → Layout wird einspaltig (Spiel nutzt vollen Platz)
  const firstPanel = main.querySelector(".panel");
  if (firstPanel && firstPanel.classList.contains("is-collapsed")) {
    main.classList.add("no-sidebar");
  } else {
    main.classList.remove("no-sidebar");
  }
}

// Beim Laden der Seite Restore-Bar + Layout prüfen
window.addEventListener("DOMContentLoaded", () => {
  setTimeout(() => {
    updateRestoreBar();
    updatePageLayout();
  }, 100);
});
