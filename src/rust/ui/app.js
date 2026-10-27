// Two screens, one bundle. Setup mode: preflight and one Install action. Manager mode: the
// read-only status snapshot plus the action flows. Every engine string is rendered as text; the
// window never chooses a script or a path.

const LANGUAGES = ["en", "vi"];
const COMPONENTS = ["dnsproxy", "zapret", "nssm", "watchdog"];
const PHASES = new Set(["download", "stage", "elevation", "step"]);
const READINESS_LEVELS = { ready: "ok", degraded: "warn", failed: "block" };
const UNCHANGED_STATES = new Set(["notRequired", "unchanged", "unknown"]);

// v1's action list: the wire name, the form it needs, and whether it changes this PC.
// `admin` marks the actions that run in the elevated broker; the engine language and the read-only
// CDN test run in the current process and never raise UAC (v1's BrokerRouted = false).
const ACTIONS = [
  { id: "Install", key: "install", form: "install", destructive: true, admin: true, online: true },
  { id: "Update", key: "update", form: "none", destructive: true, admin: true, online: true },
  { id: "Pause", key: "pause", form: "none", destructive: false, admin: true },
  { id: "Resume", key: "resume", form: "none", destructive: false, admin: true },
  { id: "Restart", key: "restart", form: "none", destructive: true, admin: true },
  { id: "SetUpstream", key: "upstream", form: "upstream", destructive: true, admin: true },
  { id: "SetDns", key: "dns", form: "dns", destructive: true, admin: true },
  { id: "SetLanguage", key: "language", form: "language", destructive: false, admin: false },
  { id: "TestCdnOptimization", key: "cdn", form: "none", destructive: false, admin: false },
  { id: "Uninstall", key: "uninstall", form: "none", destructive: true, admin: true },
];

const EMPTY_ACTION = { key: null, stage: "review", error: "", result: null };
const THEMES = ["system", "light", "dark"];

const tauri = window.__TAURI__;
const state = {
  language: navigator.language.toLowerCase().startsWith("vi") ? "vi" : "en",
  strings: {},
  mode: "setup",
  preflight: null,
  snapshot: null,
  statusBusy: false,
  statusError: null,
  busy: false,
  startedAt: 0,
  timer: 0,
  // The manager's own choice, persisted by Rust in v1's settings.json.
  settings: { language: null, theme: "system" },
  operations: [],
  logDirectory: "",
  logBusy: false,
  logError: null,
  // Values survive a review that failed and a language switch, like v1's retained form.
  form: { clean: false, upstreamCustom: false, upstreamUrl: "", servers: "", language: "en" },
  action: { ...EMPTY_ACTION },
};

function t(key) {
  return state.strings[key] ?? key;
}

function node(id) {
  return document.getElementById(id);
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function setText(id, value) {
  const element = node(id);
  if (element) {
    element.textContent = value;
  }
}

function show(id, visible) {
  node(id)?.classList.toggle("hidden", !visible);
}

function clear(id) {
  const element = node(id);
  if (!element) {
    return null;
  }
  element.replaceChildren();
  return element;
}

// ---- Settings ---------------------------------------------------------------------------

// `system` removes the attribute so the CSS media query follows the OS live; an explicit choice
// pins one theme. The label always names the choice, never the resolved colour.
function applyTheme() {
  const theme = state.settings.theme;
  if (theme === "light" || theme === "dark") {
    document.documentElement.dataset.theme = theme;
  } else {
    delete document.documentElement.dataset.theme;
  }
  setText("theme", t(`theme.${theme}`));
}

async function loadSettings() {
  if (!tauri?.core?.invoke) {
    return;
  }
  try {
    const saved = await tauri.core.invoke("get_settings");
    state.settings = {
      language: LANGUAGES.includes(saved?.language) ? saved.language : null,
      theme: THEMES.includes(saved?.theme) ? saved.theme : "system",
    };
  } catch {
    // A missing or unreadable file means the defaults; the window still opens.
  }
  applyTheme();
}

async function persistSettings() {
  if (!tauri?.core?.invoke) {
    return;
  }
  try {
    await tauri.core.invoke("save_settings", { settings: state.settings });
  } catch {
    // The choice applies to this session even when it could not be saved.
  }
}

// ---- Setup ------------------------------------------------------------------------------

function renderComponents() {
  const list = clear("components");
  if (!list) {
    return;
  }

  for (const name of COMPONENTS) {
    const item = document.createElement("li");
    item.className = "component";
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.setAttribute("aria-hidden", "true");
    const label = document.createElement("span");
    label.textContent = t(`component.${name}`);
    item.append(dot, label);
    list.append(item);
  }

  setText(
    "components-tag",
    t("setup.componentsTag").replace("{count}", String(COMPONENTS.length)),
  );
}

function renderChecks() {
  const list = clear("checks");
  if (!list) {
    return;
  }

  for (const check of state.preflight?.checks ?? []) {
    const item = document.createElement("li");
    item.className = "check";

    const copy = document.createElement("span");
    copy.className = "check-text";
    const name = document.createElement("span");
    name.className = "check-name";
    name.textContent = t(`${check.code}.label`);
    copy.append(name);

    const detail = check.detail ?? (check.level === "warn" ? t(`${check.code}.warn`) : "");
    if (detail) {
      const line = document.createElement("span");
      line.className = "check-detail";
      line.textContent = detail;
      copy.append(line);
    }

    const level = ["ok", "warn", "block"].includes(check.level) ? check.level : "unknown";
    const pill = document.createElement("span");
    pill.className = `pill ${level}`;
    pill.textContent = t(`preflight.status.${level}`);

    item.append(copy, pill);
    list.append(item);
  }
}

function updateAction() {
  const bridged = Boolean(tauri?.core?.invoke);
  const canInstall = bridged && !state.busy && state.preflight?.canInstall === true;
  const button = node("install");
  if (button) {
    button.disabled = !canInstall;
  }

  let hint = t("setup.actionHint");
  if (!bridged) {
    hint = t("bridge.missing");
  } else if (state.busy) {
    hint = t("setup.busy");
  } else if (state.preflight && !state.preflight.canInstall) {
    hint = t("setup.blocked");
  }
  setText("action-hint", hint);
}

async function refreshPreflight() {
  if (!tauri?.core?.invoke) {
    return;
  }
  try {
    state.preflight = await tauri.core.invoke("preflight");
  } catch {
    state.preflight = null;
  }
  renderChecks();
  updateAction();
}

function log(message, id = "log") {
  const box = node(id);
  if (!box) {
    return;
  }
  const line = document.createElement("span");
  line.className = "line";
  const clock = new Date().toLocaleTimeString(state.language === "vi" ? "vi-VN" : "en-US", {
    hour12: false,
  });
  line.textContent = `${clock}  ${message}`;
  box.append(line);
  box.scrollTop = box.scrollHeight;
}

function startTimer(id) {
  stopTimer();
  state.startedAt = Date.now();
  setText(id, "0:00");
  state.timer = setInterval(() => {
    const seconds = Math.floor((Date.now() - state.startedAt) / 1000);
    setText(id, `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`);
  }, 1000);
}

function stopTimer() {
  if (state.timer) {
    clearInterval(state.timer);
  }
  state.timer = 0;
}

function phaseLabel(phase) {
  return PHASES.has(phase) ? t(`setup.phase.${phase}`) : phase;
}

function paintPhase(payload, id, emptyKey) {
  const phase = typeof payload?.phase === "string" ? payload.phase : "";
  const label = phaseLabel(phase) || t(emptyKey);
  const total = Number(payload?.bytesTotal ?? 0);
  const done = Number(payload?.bytesTransferred ?? 0);

  if (total > 0) {
    const percent = Math.min(100, Math.round((done / total) * 100));
    setText(id, `${label} ${percent}%`);
    return;
  }

  setText(id, label);
}

function onSetupEvent(payload) {
  const phase = typeof payload?.phase === "string" ? payload.phase : "";
  // A step keeps the header generic; its message is the useful part and it is
  // already in the log. `done` only logs so the header never flickers back.
  if (phase === "step") {
    setText("phase", t("setup.phase.step"));
  } else if (phase !== "done") {
    paintPhase(payload, "phase", "setup.phase.starting");
  }
  const message = typeof payload?.message === "string" ? payload.message : "";
  if (message) {
    log(message);
  }
}

function setProgressBusy(id, busy) {
  const card = node(id);
  if (!card) {
    return;
  }
  card.classList.toggle("settled", !busy);
  card.setAttribute("aria-busy", busy ? "true" : "false");
}

function onSetupResult(payload) {
  const ok = payload?.ok === true;
  stopTimer();
  state.busy = false;
  setProgressBusy("progress", false);

  const icon = node("result-icon");
  if (icon) {
    icon.textContent = ok ? "✓" : "✕";
    icon.className = `result-icon ${ok ? "ok" : "fail"}`;
  }

  setText("result-title", t(ok ? "setup.result.okTitle" : "setup.result.failTitle"));
  const message =
    String(payload?.message ?? "").trim() ||
    t(ok ? "setup.result.okMessage" : "setup.result.failMessage");
  setText("result-message", message);

  const next = String(payload?.nextStep ?? "").trim() || (ok ? t("setup.result.okHint") : "");
  setText("result-next", next);
  show("result-next", Boolean(next));

  const stderr = String(payload?.stderrTail ?? "").trim();
  if (!ok && stderr) {
    log(stderr);
  }

  setText("finish", t("setup.result.finish"));
  setText("retry", t("setup.result.retry"));
  show("finish", ok);
  show("retry", !ok);
  show("result", true);
  updateAction();
}

async function install() {
  if (state.busy || !tauri?.core?.invoke) {
    return;
  }

  state.busy = true;
  updateAction();
  clear("log");
  show("result", false);
  show("progress", true);
  setProgressBusy("progress", true);
  setText("phase", t("setup.phase.starting"));
  startTimer("elapsed");

  try {
    await tauri.core.invoke("run_action", { action: "Install", input: {} });
  } catch (error) {
    onSetupResult({ ok: false, message: String(error) });
  }
}

// ---- Manager: status --------------------------------------------------------------------

// One line per fact, same information v1's dashboard rendered, without inventing values.
function compact(value) {
  if (value === null || value === undefined) {
    return "";
  }
  if (typeof value === "string") {
    return value;
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  if (Array.isArray(value)) {
    return value.map(compact).filter(Boolean).join("; ");
  }
  if (isObject(value)) {
    return Object.entries(value)
      .map(([key, entry]) => `${key}=${isObject(entry) || Array.isArray(entry) ? "…" : compact(entry)}`)
      .join(", ");
  }
  return String(value);
}

function join(parts, separator = " · ") {
  return parts.filter((part) => typeof part === "string" && part.length > 0).join(separator);
}

function renderInstall(value) {
  if (!isObject(value)) {
    return [compact(value)];
  }
  return [
    value.installed === true ? t("dashboard.installed") : t("dashboard.notInstalled"),
    join([value.installPath, value.installUtc]),
  ];
}

function renderServices(value) {
  if (!Array.isArray(value)) {
    return [compact(value)];
  }
  return value.map((service) =>
    isObject(service)
      ? join([service.name, join([service.status, service.startType])], " — ")
      : compact(service),
  );
}

function renderWatchdog(value) {
  if (!isObject(value)) {
    return [compact(value)];
  }
  const details = [];
  if (typeof value.enabled === "boolean") {
    details.push(value.enabled ? t("dashboard.enabled") : t("dashboard.disabled"));
  }
  if (value.lastOutcome) {
    details.push(`${t("dashboard.lastOutcome")}: ${value.lastOutcome}`);
  }
  if (value.failClosed === true) {
    details.push("fail-closed");
  }
  if (value.lastRunUtc) {
    details.push(value.lastRunUtc);
  }
  if (value.lastFallbackUtc) {
    details.push(`fallback ${join([value.lastFallbackUtc, value.lastFallbackReason], " ") }`);
  }
  return [join([value.taskName, join(details)])];
}

function renderDns(value) {
  if (!Array.isArray(value)) {
    return [compact(value)];
  }
  return value.map((adapter) => {
    if (!isObject(adapter)) {
      return compact(adapter);
    }
    const servers = Array.isArray(adapter.servers) ? adapter.servers.join(", ") : "";
    const details = join([
      adapter.mode,
      servers,
      adapter.gatewayBypassed === true ? t("dashboard.bypassed") : "",
    ]);
    return join([adapter.adapterName, details], " — ");
  });
}

function renderUpstream(value) {
  if (!isObject(value)) {
    return [compact(value)];
  }
  return [
    join([
      value.host,
      join([value.scheme, value.source]),
      value.credentialsRedacted === true ? t("dashboard.redacted") : "",
    ]),
  ];
}

function renderVersions(value) {
  if (!Array.isArray(value)) {
    return [compact(value)];
  }
  return value.map((entry) => {
    if (!isObject(entry)) {
      return compact(entry);
    }
    return join([
      entry.component,
      join([
        entry.approved ? `approved ${entry.approved}` : "",
        entry.installed ? `installed ${entry.installed}` : "",
        entry.match ? `match ${entry.match}` : "",
      ]),
    ], " — ");
  });
}

function renderLastUpdate(value) {
  if (!isObject(value)) {
    return [compact(value)];
  }
  const transition = join([value.fromVersion, value.toVersion], " → ");
  return [join([value.utc, join([transition, value.outcome, value.reportedBy])], " — ")];
}

const DASHBOARD_ROWS = [
  ["installPresence", "dashboard.row.install", renderInstall],
  ["services", "dashboard.row.services", renderServices],
  ["watchdog", "dashboard.row.watchdog", renderWatchdog],
  ["dnsPerAdapter", "dashboard.row.dns", renderDns],
  ["upstream", "dashboard.row.upstream", renderUpstream],
  ["versions", "dashboard.row.versions", renderVersions],
  ["lastUpdate", "dashboard.row.lastUpdate", renderLastUpdate],
];

// A probe is `known` with a value, `unknown` with its own reason, or `notApplicable`. A missing
// or structurally wrong probe is unknown, never a guess.
function probe(snapshot, field) {
  if (!isObject(snapshot)) {
    return { state: "unknown", reason: t("dashboard.snapshotMissing") };
  }
  const value = snapshot[field];
  if (!isObject(value)) {
    return { state: "unknown", reason: t("dashboard.snapshotMissing") };
  }
  if (value.state === "known") {
    if (value.value === undefined || value.value === null) {
      return { state: "unknown", reason: t("dashboard.unknown") };
    }
    return { state: "known", value: value.value };
  }
  if (value.state === "unknown") {
    return { state: "unknown", reason: value.reason || t("dashboard.unknown") };
  }
  if (value.state === "notApplicable") {
    return { state: "notApplicable" };
  }
  return { state: "unknown", reason: t("dashboard.unknown") };
}

function renderReadiness() {
  const readiness = probe(state.snapshot, "readiness");

  if (readiness.state === "known" && isObject(readiness.value)) {
    const verdict = String(readiness.value.state ?? "");
    const reasons = Array.isArray(readiness.value.reasons) ? readiness.value.reasons : [];
    setText("readiness-title", verdict || t("dashboard.unknown"));
    setText("readiness-detail", reasons.join("; "));
    setPill(verdict || t("dashboard.unknown"), READINESS_LEVELS[verdict]);
    return;
  }

  if (readiness.state === "notApplicable") {
    setText("readiness-title", t("dashboard.notApplicable"));
    setText("readiness-detail", "");
    setPill(t("dashboard.notApplicable"), null);
    return;
  }

  if (readiness.state === "unknown") {
    setText("readiness-title", t("dashboard.unknown"));
    setText("readiness-detail", readiness.reason);
    setPill(t("dashboard.unknown"), null);
    return;
  }

  const loading = Boolean(state.statusBusy) && !state.statusError;
  setText("readiness-title", loading ? t("dashboard.loading") : t("dashboard.failed"));
  setText("readiness-detail", state.statusError ?? "");
  setPill(loading ? t("dashboard.loading") : t("dashboard.failed"), loading ? null : "block");
}

function setPill(text, level) {
  const pill = node("readiness-pill");
  if (!pill) {
    return;
  }
  pill.textContent = text;
  pill.className = level ? `pill ${level}` : "pill";
}

function renderDashboard() {
  setText("readiness-eyebrow", t("dashboard.row.readiness"));
  setText("refresh-status", state.statusBusy ? t("dashboard.refreshing") : t("dashboard.refresh"));
  const refresh = node("refresh-status");
  if (refresh) {
    refresh.disabled = state.statusBusy;
  }

  setText("status-error-title", t("dashboard.failed"));
  setText("status-error-detail", state.statusError ?? "");
  show("status-error", Boolean(state.statusError));

  renderReadiness();

  const grid = clear("dashboard-grid");
  if (!grid) {
    return;
  }

  for (const [field, titleKey, render] of DASHBOARD_ROWS) {
    const card = document.createElement("section");
    card.className = "card";

    const head = document.createElement("div");
    head.className = "card-head";
    const title = document.createElement("h2");
    title.textContent = t(titleKey);
    head.append(title);
    card.append(head);

    const value = probe(state.snapshot, field);
    if (value.state === "known") {
      const lines = render(value.value).filter((line) => line.length > 0);
      const list = document.createElement("ul");
      list.className = "rows";
      for (const line of lines.length > 0 ? lines : [t("dashboard.unknown")]) {
        const item = document.createElement("li");
        item.textContent = line;
        list.append(item);
      }
      card.append(list);
    } else {
      const note = document.createElement("p");
      note.className = "muted";
      note.textContent =
        value.state === "notApplicable" ? t("dashboard.notApplicable") : value.reason;
      card.append(note);
    }

    grid.append(card);
  }

  const observed = isObject(state.snapshot) ? state.snapshot.observedUtc : null;
  setText(
    "snapshot-at",
    observed ? t("dashboard.snapshotAt").replace("{time}", observed) : "",
  );
}

async function refreshStatus() {
  if (state.statusBusy || !tauri?.core?.invoke) {
    return;
  }

  state.statusBusy = true;
  state.statusError = null;
  renderDashboard();

  try {
    state.snapshot = await tauri.core.invoke("get_status");
  } catch (error) {
    state.snapshot = null;
    state.statusError = String(error);
  } finally {
    state.statusBusy = false;
    renderDashboard();
  }
}

// ---- Manager: actions -------------------------------------------------------------------

function currentAction() {
  return ACTIONS.find((action) => action.key === state.action.key) ?? null;
}

function renderActionGrid() {
  setText("actions-title", t("actions.title"));
  setText("actions-tag", t("actions.tag"));
  const grid = clear("action-grid");
  if (!grid) {
    return;
  }

  for (const action of ACTIONS) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = action.destructive ? "ghost danger" : "ghost";
    button.dataset.action = action.id;
    button.textContent = t(`action.${action.key}.title`);
    button.disabled = !tauri?.core?.invoke;
    button.addEventListener("click", () => openAction(action.key));
    grid.append(button);
  }
}

function openAction(key) {
  const action = ACTIONS.find((entry) => entry.key === key);
  if (!action || state.busy || !tauri?.core?.invoke) {
    return;
  }

  state.action = { ...EMPTY_ACTION, key };
  show("dashboard", false);
  show("action-view", true);
  renderAction();
}

// Both Back and Done leave the view; a finished action refreshes the dashboard that may now differ.
function closeAction() {
  state.action = { ...EMPTY_ACTION };
  state.busy = false;
  stopTimer();
  show("action-view", false);
  show("dashboard", true);
  void refreshStatus();
  // The terminal record was written before the result event arrived.
  void refreshOperations();
}

function renderAction() {
  const action = currentAction();
  if (!action) {
    return;
  }
  const stage = state.action.stage;

  setText("action-eyebrow", t(`action.${stage}Eyebrow`));
  setText("action-heading", t(`action.${action.key}.title`));
  setText("action-changes", t(`action.${action.key}.changes`));
  setText("action-footer", t("app.footer"));
  setText("action-back", t("action.back"));
  show("action-back", stage === "review");

  show("review-stage", stage === "review");
  // The log stays under the result so the steps that produced it remain readable.
  show("action-progress", stage === "progress" || stage === "result");
  show("action-result", stage === "result");

  if (stage === "review") {
    renderReview(action);
  } else if (stage === "result") {
    renderActionResult();
  }
}

function renderReview(action) {
  setText("review-scope-title", t("review.scopeTitle"));
  setText("review-preserved-title", t("review.preservedTitle"));
  setText("review-options-title", t("review.optionsTitle"));

  const scope = clear("review-scope");
  for (const key of ["installPath", "services", "watchdog", "dns"]) {
    const item = document.createElement("li");
    item.textContent = t(`review.scope.${key}`);
    scope?.append(item);
  }

  const preserved = clear("review-preserved");
  for (const key of ["files", "log"]) {
    const item = document.createElement("li");
    item.textContent = t(`review.preserved.${key}`);
    preserved?.append(item);
  }

  buildForm(action);
  show("review-form-card", action.form !== "none");

  const requirements = [];
  if (action.admin) {
    requirements.push(t("action.needsAdmin"));
  }
  if (action.online) {
    requirements.push(t("action.needsOnline"));
  }
  setText("review-preconditions", requirements.join(" ") || t("action.noRequirements"));
  setText("review-note", t("action.reversible"));
  show("review-note", !action.destructive);

  setText("review-error-text", state.action.error);
  show("review-error", Boolean(state.action.error));

  const back = node("review-back");
  if (back) {
    back.textContent = t("action.back");
  }
  const confirm = node("confirm");
  if (confirm) {
    confirm.textContent = t("action.confirm");
    confirm.disabled = !canConfirm(action);
  }
}

function choice(labelText, input, onChange) {
  const label = document.createElement("label");
  label.className = "choice";
  const text = document.createElement("span");
  text.textContent = labelText;
  input.addEventListener("change", onChange);
  label.append(input, text);
  return label;
}

function buildForm(action) {
  const form = clear("review-form");
  if (!form) {
    return;
  }

  if (action.form === "install") {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.id = "field-clean";
    box.checked = state.form.clean;
    form.append(
      choice(t("action.install.clean"), box, () => {
        state.form.clean = box.checked;
        updateConfirm(action);
      }),
    );
    const hint = document.createElement("p");
    hint.className = "muted";
    hint.textContent = t("action.install.cleanHint");
    form.append(hint);
    return;
  }

  if (action.form === "upstream") {
    for (const [value, key] of [
      [false, "action.upstream.reset"],
      [true, "action.upstream.custom"],
    ]) {
      const radio = document.createElement("input");
      radio.type = "radio";
      radio.name = "upstream-mode";
      radio.checked = state.form.upstreamCustom === value;
      form.append(
        choice(t(key), radio, () => {
          state.form.upstreamCustom = value;
          buildForm(action);
          updateConfirm(action);
        }),
      );
    }

    const label = document.createElement("label");
    label.className = "field";
    const caption = document.createElement("span");
    caption.textContent = t("action.upstream.url");
    const input = document.createElement("input");
    input.type = "url";
    input.id = "field-upstream-url";
    input.placeholder = "https://dns.example/dns-query";
    input.spellcheck = false;
    input.value = state.form.upstreamUrl;
    input.disabled = !state.form.upstreamCustom;
    input.addEventListener("input", () => {
      state.form.upstreamUrl = input.value;
      updateConfirm(action);
    });
    label.append(caption, input);
    form.append(label);
    return;
  }

  if (action.form === "dns") {
    const label = document.createElement("label");
    label.className = "field";
    const caption = document.createElement("span");
    caption.textContent = t("action.dns.servers");
    const input = document.createElement("input");
    input.type = "text";
    input.id = "field-servers";
    input.placeholder = "1.1.1.1, 8.8.8.8";
    input.spellcheck = false;
    input.value = state.form.servers;
    input.addEventListener("input", () => {
      state.form.servers = input.value;
      updateConfirm(action);
    });
    label.append(caption, input);
    label.addEventListener("click", () => input.focus());
    form.append(label);
    return;
  }

  if (action.form === "language") {
    for (const [value, key] of [
      ["en", "action.language.en"],
      ["vi", "action.language.vi"],
    ]) {
      const radio = document.createElement("input");
      radio.type = "radio";
      radio.name = "engine-language";
      radio.checked = state.form.language === value;
      form.append(
        choice(t(key), radio, () => {
          state.form.language = value;
          updateConfirm(action);
        }),
      );
    }
  }
}

// Only completeness is checked here. The values themselves are validated once, in Rust, so the
// wire rules never fork into a second copy in JavaScript.
function canConfirm(action) {
  if (!tauri?.core?.invoke || state.busy) {
    return false;
  }
  if (action.form === "dns") {
    return state.form.servers.trim().length > 0;
  }
  if (action.form === "upstream") {
    return !state.form.upstreamCustom || state.form.upstreamUrl.trim().length > 0;
  }
  return true;
}

function updateConfirm(action) {
  const button = node("confirm");
  if (button) {
    button.disabled = !canConfirm(action);
  }
}

function readInput(action) {
  switch (action.form) {
    case "install":
      return { clean: state.form.clean === true };
    case "upstream":
      return state.form.upstreamCustom
        ? { upstreamCustom: true, upstreamUrl: state.form.upstreamUrl.trim() }
        : { upstreamCustom: false };
    case "dns":
      return { servers: state.form.servers };
    case "language":
      return { language: state.form.language };
    default:
      return {};
  }
}

async function confirmAction() {
  const action = currentAction();
  if (!action || !canConfirm(action)) {
    return;
  }

  state.busy = true;
  state.action.error = "";
  state.action.result = null;
  state.action.stage = "progress";
  clear("action-log");
  setText("action-phase", t("action.progressNone"));
  setProgressBusy("action-progress", true);
  startTimer("action-elapsed");
  renderAction();

  try {
    await tauri.core.invoke("run_action", { action: action.id, input: readInput(action) });
  } catch (error) {
    // The app validates the input before it starts a worker: stay on review, show its message.
    stopTimer();
    state.busy = false;
    state.action.error = String(error);
    state.action.stage = "review";
    renderAction();
  }
}

function onActionEvent(payload) {
  if (state.action.stage !== "progress") {
    return;
  }
  const phase = typeof payload?.phase === "string" ? payload.phase : "";
  if (phase === "step") {
    setText("action-phase", t("setup.phase.step"));
  } else if (phase !== "done") {
    paintPhase(payload, "action-phase", "action.progressNone");
  }
  const message = typeof payload?.message === "string" ? payload.message : "";
  if (message) {
    log(message, "action-log");
  }
}

function onActionResult(payload) {
  if (!state.action.key) {
    return;
  }
  stopTimer();
  state.busy = false;
  setProgressBusy("action-progress", false);
  state.action.result = isObject(payload) ? payload : { ok: false, message: String(payload ?? "") };
  state.action.stage = "result";
  renderAction();
}

function renderActionResult() {
  const result = isObject(state.action.result) ? state.action.result : {};
  const ok = result.ok === true;

  const icon = node("action-icon");
  if (icon) {
    icon.textContent = ok ? "✓" : "✕";
    icon.className = `result-icon ${ok ? "ok" : "fail"}`;
  }

  setText("action-result-title", t(ok ? "result.success" : "result.failed"));
  setText(
    "action-result-message",
    String(result.message ?? "").trim() ||
      t(ok ? "result.successMessage" : "result.failedMessage"),
  );

  // A failure shows only the rows the engine filled in; a success shows only its log, like v1.
  const facts = clear("action-facts");
  let rows = 0;
  const fact = (label, value) => {
    const text = String(value ?? "").trim();
    if (!text) {
      return;
    }
    const row = document.createElement("div");
    const term = document.createElement("dt");
    term.textContent = label;
    const detail = document.createElement("dd");
    detail.textContent = text;
    row.append(term, detail);
    facts?.append(row);
    rows += 1;
  };
  if (!ok) {
    fact(t("result.code"), result.codeName);
    fact(t("result.currentState"), result.currentState);
    fact(t("result.restoredState"), result.restoredState);
    fact(t("result.nextStep"), result.nextStep);
  }
  fact(t("result.logPath"), result.transcriptPath);
  show("action-facts", rows > 0);

  const restored = String(result.restoredState ?? "").trim();
  const incomplete = !ok && restored.length > 0 && !UNCHANGED_STATES.has(restored);
  setText("action-incomplete", t("result.incomplete"));
  show("action-incomplete", incomplete);

  const stderr = String(result.stderrTail ?? "").trim();
  const tail = clear("action-result-log");
  if (stderr && tail) {
    const line = document.createElement("span");
    line.className = "line";
    line.textContent = stderr;
    tail.append(line);
  }
  show("action-result-log", Boolean(stderr));

  setText("action-open-log", t("result.openLog"));
  show("action-open-log", Boolean(String(result.transcriptPath ?? "").trim()));
  setText("action-copy", t("result.copyDetails"));
  setText("action-done", t("action.done"));
  setText("action-copied", t("result.copied"));
  show("action-copied", false);
}

async function openActionLog() {
  await openPath(String(state.action.result?.transcriptPath ?? "").trim());
}

async function openPath(path) {
  if (!path || !tauri?.core?.invoke) {
    return;
  }
  try {
    await tauri.core.invoke("open_log", { path });
  } catch {
    // v1 swallows an Explorer failure; the path stays visible in the text.
  }
}

function detailsText() {
  const action = currentAction();
  const result = isObject(state.action.result) ? state.action.result : {};
  const lines = [];
  if (action) {
    lines.push(t(`action.${action.key}.title`));
  }
  lines.push(
    `${t(result.ok === true ? "result.success" : "result.failed")}: ${String(
      result.message ?? "",
    ).trim()}`,
  );

  const field = (label, value) => {
    const text = String(value ?? "").trim();
    if (text) {
      lines.push(`${label}: ${text}`);
    }
  };
  if (result.ok !== true) {
    field(t("result.code"), result.codeName);
    field(t("result.currentState"), result.currentState);
    field(t("result.restoredState"), result.restoredState);
    field(t("result.nextStep"), result.nextStep);
  }
  field(t("result.logPath"), result.transcriptPath);
  const stderr = String(result.stderrTail ?? "").trim();
  if (stderr) {
    lines.push("", stderr);
  }
  return lines.join("\n");
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // The clipboard can be locked; the offscreen textarea is v1's fallback.
  }
  const buffer = node("copy-buffer");
  if (!buffer) {
    return false;
  }
  buffer.value = text;
  buffer.select();
  try {
    return document.execCommand("copy");
  } catch {
    return false;
  }
}

async function copyDetails() {
  show("action-copied", await copyText(detailsText()));
}

// ---- Manager: log surface ---------------------------------------------------------------

const ACTION_BY_ID = new Map(
  ACTIONS.map((action) => [action.id[0].toLowerCase() + action.id.slice(1), action]),
);
// `operations.jsonl` also carries v1's read-only `status` refreshes.
const LOG_ACTION_KEYS = new Map([["status", "action.status.title"]]);

function actionTitle(wire) {
  const key = LOG_ACTION_KEYS.get(wire);
  if (key) {
    return t(key);
  }
  const action = ACTION_BY_ID.get(wire);
  return action ? t(`action.${action.key}.title`) : wire;
}

function stamp(value) {
  const date = new Date(String(value ?? ""));
  if (Number.isNaN(date.getTime())) {
    return String(value ?? "");
  }
  return date.toLocaleString(state.language === "vi" ? "vi-VN" : "en-US", {
    dateStyle: "short",
    timeStyle: "short",
  });
}

// The last operations from operations.jsonl, one row each: what ran, how it ended, when, its
// message, and the two affordances v1 offered (open the transcript, copy the record).
function renderOperations() {
  setText("log-title", t("log.title"));
  setText("log-open-folder", t("log.openFolder"));
  setText("log-empty", t("log.empty"));
  setText("log-copied", t("result.copied"));
  setText("log-error", state.logError ?? "");
  show("log-error", Boolean(state.logError));

  const folder = node("log-open-folder");
  if (folder) {
    folder.disabled = !state.logDirectory;
  }

  const list = clear("operations");
  if (!list) {
    return;
  }

  const operations = Array.isArray(state.operations) ? state.operations : [];
  show("log-empty", operations.length === 0 && !state.logError);

  for (const operation of operations) {
    const item = document.createElement("li");
    item.className = "operation";

    const copy = document.createElement("div");
    copy.className = "operation-copy";

    const head = document.createElement("div");
    head.className = "operation-head";
    const name = document.createElement("span");
    name.className = "operation-name";
    name.textContent = actionTitle(String(operation?.action ?? ""));
    const pill = document.createElement("span");
    pill.className = `pill ${operation?.ok === true ? "ok" : "block"}`;
    pill.textContent = t(operation?.ok === true ? "result.success" : "result.failed");
    head.append(name, pill);
    copy.append(head);

    const detail = document.createElement("p");
    detail.className = "muted";
    detail.textContent = join([
      stamp(operation?.startedUtc),
      String(operation?.message ?? "").trim(),
    ]);
    copy.append(detail);

    const actions = document.createElement("div");
    actions.className = "operation-actions";
    const transcript = String(operation?.transcriptPath ?? "").trim();
    if (transcript) {
      const open = document.createElement("button");
      open.type = "button";
      open.className = "ghost small";
      open.textContent = t("log.openTranscript");
      open.addEventListener("click", () => {
        void openPath(transcript);
      });
      actions.append(open);
    }
    const copyButton = document.createElement("button");
    copyButton.type = "button";
    copyButton.className = "ghost small";
    copyButton.textContent = t("log.copy");
    copyButton.addEventListener("click", async () => {
      show("log-copied", await copyText(JSON.stringify(operation)));
    });
    actions.append(copyButton);

    item.append(copy, actions);
    list.append(item);
  }
}

async function refreshOperations() {
  if (state.logBusy || !tauri?.core?.invoke) {
    return;
  }

  state.logBusy = true;
  state.logError = null;

  try {
    const payload = await tauri.core.invoke("recent_operations");
    state.operations = Array.isArray(payload?.operations) ? payload.operations : [];
    state.logDirectory = String(payload?.directory ?? "");
  } catch (error) {
    state.operations = [];
    state.logError = String(error);
  } finally {
    state.logBusy = false;
    renderOperations();
  }
}

// ---- Shared -----------------------------------------------------------------------------

function apply() {
  document.documentElement.lang = state.language;
  document.title = t("app.title");
  setText("app-title", t("app.title"));
  setText("mode", t(state.mode === "setup" ? "mode.setup" : "mode.manager"));
  setText("elevation", t("elevation.none"));
  setText("language", t("language.switch"));
  setText("eyebrow", t("setup.eyebrow"));
  setText("title", t("setup.title"));
  setText("tagline", t("setup.tagline"));
  setText("components-title", t("setup.componentsTitle"));
  setText("checks-title", t("setup.checksTitle"));
  setText("refresh", t("setup.refresh"));
  setText("action-title", t("setup.actionTitle"));
  setText("install", t("setup.install"));
  setText("phase", t("setup.phase.starting"));
  setText("footer-note", t("app.footer"));
  renderComponents();
  renderChecks();
  updateAction();
  applyTheme();
  renderActionGrid();
  renderDashboard();
  renderOperations();
  if (state.action.key) {
    renderAction();
  }
}

async function load(language) {
  const response = await fetch(`locales/${language}.json`);
  if (!response.ok) {
    throw new Error(`locale ${language}: HTTP ${response.status}`);
  }
  state.language = language;
  state.strings = await response.json();
  apply();
}

function closeWindow() {
  try {
    tauri?.window?.getCurrentWindow?.()?.close?.();
  } catch {
    // The window is already going away.
  }
}

function onEvent(payload) {
  if (state.mode === "setup") {
    onSetupEvent(payload);
  } else {
    onActionEvent(payload);
  }
}

function onResult(payload) {
  if (state.mode === "setup") {
    onSetupResult(payload);
  } else {
    onActionResult(payload);
  }
}

async function attach() {
  if (!tauri?.event?.listen) {
    return;
  }
  await tauri.event.listen("engine://event", (event) => onEvent(event.payload));
  await tauri.event.listen("engine://result", (event) => onResult(event.payload));
}

node("language")?.addEventListener("click", () => {
  const next = LANGUAGES[(LANGUAGES.indexOf(state.language) + 1) % LANGUAGES.length];
  load(next)
    .then(() => {
      state.settings.language = next;
      void persistSettings();
    })
    .catch(() => {});
});
node("theme")?.addEventListener("click", () => {
  const next = THEMES[(THEMES.indexOf(state.settings.theme) + 1) % THEMES.length];
  state.settings.theme = next;
  applyTheme();
  void persistSettings();
});
node("install")?.addEventListener("click", () => {
  void install();
});
node("refresh")?.addEventListener("click", () => {
  void refreshPreflight();
});
node("refresh-status")?.addEventListener("click", () => {
  void refreshStatus();
  void refreshOperations();
});
node("log-open-folder")?.addEventListener("click", () => {
  void openPath(state.logDirectory);
});
node("finish")?.addEventListener("click", closeWindow);
node("retry")?.addEventListener("click", () => {
  show("result", false);
  void install();
});
node("action-back")?.addEventListener("click", closeAction);
node("review-back")?.addEventListener("click", closeAction);
node("confirm")?.addEventListener("click", () => {
  void confirmAction();
});
node("action-open-log")?.addEventListener("click", () => {
  void openActionLog();
});
node("action-copy")?.addEventListener("click", () => {
  void copyDetails();
});
node("action-done")?.addEventListener("click", closeAction);

(async () => {
  await loadSettings();
  await load(state.settings.language ?? state.language).catch(() => {});
  await attach();

  if (tauri?.core?.invoke) {
    try {
      state.mode = await tauri.core.invoke("app_mode");
    } catch {
      state.mode = "setup";
    }
  }

  show("setup-view", state.mode === "setup");
  show("dashboard", state.mode === "manager");
  show("action-view", false);
  apply();

  // First run: remember the language the OS implied, the same outcome as v1's first-run choice.
  if (!state.settings.language) {
    state.settings.language = state.language;
    void persistSettings();
  }

  if (state.mode === "setup") {
    await refreshPreflight();
  } else {
    await Promise.all([refreshStatus(), refreshOperations()]);
  }
})();
