#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}

# Orca relaunch is a receipt-proven endpoint replacement, NOT an agent-state
# classifier. Only the local 1.4.222 runtime was inspected for stopAndWait's
# incarnation-bound PTY-exit proof; older/other runtimes must not turn a mere
# kill dispatch into a stop claim. Keep that compatibility guard exact until
# refreshed (docs/verification/runtime-backends.md, "Orca").
#
# The task-local receipt preserves the status, authoritative worktree-scoped
# inventory and close response. An interrupted caller can reuse a confirmed
# receipt only on the same runtime and incarnation, with the old PTY absent or
# disconnected. Unknown, truncated, omitted-host, contradictory and peer-live
# inventories refuse. We never close a peer or remove a worktree.
fm_backend_orca_relaunch_check() {  # <terminal> <worktree-id> <path> <receipt> [prepare|replacement] [replacement-terminal]
  local terminal=$1 worktree_id=$2 path=$3 receipt=$4 mode=${5:-check} replacement=${6:-} status inventory
  fm_backend_orca_tool_check || return 1
  status=$(orca status --json) || return 1
  inventory=$(orca terminal list --worktree "id:$worktree_id" --limit 100 --json) || return 1
  node -e '
const fs = require("fs");
const [handle, wt, path, file, mode, replacement, statusRaw, inventoryRaw] = process.argv.slice(1);
function refuse(message) { throw new Error(message); }
function requireFact(value, message) { if (!value) refuse(message); }
function identity(t) {
  requireFact(t && t.worktreeId === wt && t.worktreePath === path &&
    t.executionHostId === "local" && typeof t.handle === "string" && t.handle &&
    typeof t.ptyId === "string" && t.ptyId && typeof t.incarnationId === "string" && t.incarnationId &&
    typeof t.connected === "boolean" && typeof t.writable === "boolean",
    "unattributed terminal in the recorded Orca worktree");
}
try {
  const status = JSON.parse(statusRaw), inventory = JSON.parse(inventoryRaw);
  const runtime = status.result?.runtime;
  requireFact(status.ok === true && status.result?.target?.kind === "local" &&
    runtime?.reachable === true && runtime.state === "ready" && runtime.appVersion === "1.4.222" &&
    typeof runtime.runtimeId === "string" && runtime.runtimeId && status._meta?.runtimeId === runtime.runtimeId,
    "Orca relaunch requires the verified local runtime 1.4.222 and its runtime identity");
  const r = inventory.result;
  requireFact(inventory.ok === true && inventory._meta?.runtimeId === runtime.runtimeId &&
    Array.isArray(r?.terminals) && r.truncated === false && r.totalCount === r.terminals.length &&
    Array.isArray(r.hostScope?.hostIds) && r.hostScope.hostIds.length === 1 && r.hostScope.hostIds[0] === "local" &&
    Array.isArray(r.hostScope.omittedHostIds) && r.hostScope.omittedHostIds.length === 0,
    "Orca worktree terminal inventory is incomplete or belongs to another runtime");
  const seen = new Set();
  for (const t of r.terminals) {
    identity(t);
    requireFact(!seen.has(t.handle), "duplicate terminal identity in Orca inventory"); seen.add(t.handle);
    if (t.handle !== handle && t.handle !== replacement) {
      requireFact(t.connected === false && t.writable === false,
        "another Orca endpoint may own the recorded worktree: " + t.handle);
    }
  }
  const current = r.terminals.find(t => t.handle === handle);
  let proof = null;
  if (fs.existsSync(file)) {
    requireFact(fs.lstatSync(file).isFile(), "Orca stop receipt is not a regular file");
    proof = JSON.parse(fs.readFileSync(file, "utf8"));
  }
  const prior = proof?.inventory?.result?.terminals?.find(t => t.handle === handle);
  const close = proof?.close?.result?.close;
  const confirmed = proof?.status?.result?.runtime?.appVersion === "1.4.222" &&
    proof.status.result.runtime.runtimeId === runtime.runtimeId && proof.status._meta?.runtimeId === runtime.runtimeId &&
    proof.inventory?.ok === true && proof.inventory._meta?.runtimeId === runtime.runtimeId &&
    prior?.worktreeId === wt && prior.worktreePath === path && prior.executionHostId === "local" &&
    typeof prior.ptyId === "string" && prior.ptyId && typeof prior.incarnationId === "string" && prior.incarnationId &&
    proof.close?.ok === true && proof.close._meta?.runtimeId === runtime.runtimeId &&
    close?.handle === handle && close.ptyKilled === true && close.pendingKillRecorded !== true &&
    close.ptyStopVerdict === undefined;
  if (confirmed) {
    requireFact(!current || (current.ptyId === prior.ptyId && current.incarnationId === prior.incarnationId &&
      current.connected === false && current.writable === false),
      "Orca stop receipt contradicts the current terminal incarnation or liveness");
    if (mode === "replacement") {
      const next = r.terminals.find(t => t.handle === replacement);
      requireFact(replacement !== handle && next?.connected === true && next.writable === true,
        "replacement Orca terminal is not bound to the preserved worktree");
    }
    process.stdout.write("stopped");
  } else {
    requireFact(mode !== "replacement", "no confirmed Orca stop receipt for the previous agent");
    requireFact(current?.connected === true && current.writable === true,
      "recorded Orca terminal is absent or disconnected without a confirmed stop receipt");
    if (mode === "prepare") {
      requireFact(!fs.existsSync(file) || fs.lstatSync(file).isFile(), "unsafe Orca stop receipt path");
      requireFact(!fs.existsSync(file + ".tmp"), "pending Orca stop receipt write must be reconciled");
      fs.writeFileSync(file + ".tmp", JSON.stringify({status, inventory, close: null}) + "\n", {flag: "wx", mode: 0o600});
      fs.renameSync(file + ".tmp", file);
    }
    process.stdout.write("ready");
  }
} catch (e) { console.error("error: " + e.message); process.exit(1); }
' "$terminal" "$worktree_id" "$path" "$receipt" "$mode" "$replacement" "$status" "$inventory"
}

fm_backend_orca_relaunch_stop() {  # <terminal> <worktree-id> <path> <receipt>
  local terminal=$1 worktree_id=$2 path=$3 receipt=$4 state out rc=0
  state=$(fm_backend_orca_relaunch_check "$terminal" "$worktree_id" "$path" "$receipt" prepare) || return 1
  [ "$state" != stopped ] || return 0
  # Capture even a failing close response: a committed surface close with an
  # unconfirmed process stop is evidence to retain, never permission to launch.
  out=$(orca terminal close --terminal "$terminal" --json) || rc=$?
  node -e '
const fs = require("fs"), [file, raw] = process.argv.slice(1);
try {
  const proof = JSON.parse(fs.readFileSync(file, "utf8"));
  try { proof.close = JSON.parse(raw); } catch { proof.close = null; proof.closeRaw = raw; }
  fs.writeFileSync(file + ".tmp", JSON.stringify(proof) + "\n", {flag: "wx", mode: 0o600});
  fs.renameSync(file + ".tmp", file);
} catch (e) { console.error("error: could not preserve Orca close evidence: " + e.message); process.exit(1); }
' "$receipt" "$out" || return 1
  [ "$rc" -eq 0 ] || { echo "error: Orca close did not confirm the recorded agent stopped; evidence retained at $receipt" >&2; return 1; }
  state=$(fm_backend_orca_relaunch_check "$terminal" "$worktree_id" "$path" "$receipt") || return 1
  [ "$state" = stopped ] || {
    echo "error: Orca close lacks a confirmed, matching PTY-stop receipt; preserving task metadata ($receipt)" >&2
    return 1
  }
}
