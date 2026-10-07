#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# Relaunch uses an Orca stop-and-wait receipt rather than guessing agent state.
# Model the verified protocol, uncertain closes, competing PTYs and retries
# through the real spawn/control entry points; all endpoints are fake and all
# checkout fixtures are temporary. No live backend or shared home is touched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so spawn_worktree_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
printf '%s\n' "$*" >> "$DIR/calls"
case "$1 $2" in
  "status --json")
    if [ -e "$DIR/supports-stop" ]; then
      version=1.4.222
      [ ! -e "$DIR/unsupported" ] || version=1.4.221
      runtime=runtime-1
      [ ! -e "$DIR/closed" ] || [ ! -e "$DIR/runtime-change" ] || runtime=runtime-2
      printf '{"ok":true,"result":{"target":{"kind":"local"},"runtime":{"reachable":true,"state":"ready","appVersion":"%s","runtimeId":"%s"}},"_meta":{"runtimeId":"%s"}}\n' "$version" "$runtime" "$runtime"
      exit 0
    fi
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    if [ -e "$DIR/supports-stop" ]; then
      [ ! -e "$DIR/create-fails" ] || exit 1
      touch "$DIR/replacement-created"
      printf '{"ok":true,"result":{"terminal":{"handle":"term-2"}}}\n'
      exit 0
    fi
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal send")
    printf '{"ok":true}\n'
    exit 0
    ;;
  "terminal list")
    node <<'JS'
const fs = require("fs"), d = process.env.FM_TEST_ORCA_DIR;
const has = n => fs.existsSync(d + "/" + n);
const wt = d + "/wt", terminals = [];
function terminal(handle, connected = true) {
  return {handle, ptyId: handle + "-pty", incarnationId: handle + "-incarnation",
    worktreeId: "wt-1::" + wt, worktreePath: wt, executionHostId: "local", connected, writable: connected, orphaned: true};
}
if (!has("closed") || has("stays-live")) terminals.push(terminal("term-1"));
if (has("peer") || (has("peer-after-close") && has("closed"))) terminals.push(terminal("term-peer"));
if (has("replacement-created")) terminals.push(terminal("term-2"));
if (has("wrong-worktree") && terminals[0]) terminals[0].worktreePath = d + "/foreign";
const runtime = has("runtime-change") && has("closed") ? "runtime-2" : "runtime-1";
console.log(JSON.stringify({ok: true, result: {terminals, totalCount: terminals.length,
  truncated: has("truncated"), hostScope: {hostIds: ["local"], omittedHostIds: has("omitted-host") ? ["remote"] : []}}, _meta: {runtimeId: runtime}}));
JS
    exit 0
    ;;
  "terminal close")
    touch "$DIR/closed"
    node <<'JS'
const fs = require("fs"), d = process.env.FM_TEST_ORCA_DIR;
const has = n => fs.existsSync(d + "/" + n);
if (has("malformed-close")) {console.log("not JSON"); process.exit(0);}
const close = {handle: has("wrong-handle") ? "term-foreign" : "term-1", ptyKilled: !has("unconfirmed-close")};
if (has("legacy-close")) delete close.ptyKilled;
if (has("contradictory-close")) close.ptyStopVerdict = "live";
if (has("pending-close")) close.pendingKillRecorded = true;
console.log(JSON.stringify({ok: !has("error-close"), result: {close}, _meta: {runtimeId: "runtime-1"}}));
process.exit(has("transport-fails") ? 1 : 0);
JS
    exit $?
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run() {
  local case_dir home proj wt id=orca-relaunch-a2 out status fb
  case_dir="$TMP_ROOT/relaunch"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch attempt against a recorded Orca task.

## Firstmate spec
Confirm the relaunch is refused before any worktree re-entry logic runs.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$wt"
    echo "terminal=term-1"
  } > "$home/state/$id.meta"
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?

  expect_code 1 "$status" "a relaunch against a recorded Orca task should refuse"$'\n'"$out"
  assert_contains "$out" "verified local runtime 1.4.222" \
    "an unverified Orca runtime must refuse before endpoint replacement"
  pass "Orca relaunch refuses an unverified runtime before endpoint replacement"
}

orca_relaunch_case() {  # <name>
  local dir="$TMP_ROOT/$1" id=orca-recovery
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data/$id"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  fm_git_worktree "$dir/proj" "$dir/wt" "fm/$id"
  fm_write_meta "$dir/home/state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" \
    "backend=orca" "terminal=term-1" "orca_worktree_id=wt-1::$dir/wt" \
    "worktree=$dir/wt" "project=$dir/proj" "harness=claude" "kind=ship" "branch=fm/$id" \
    "release_head=approved-release" "mode=direct-PR" "yolo=off" "approval_key=release-go"
  printf 'preserve dirty work\n' > "$dir/wt/uncommitted"
  printf '# Task\n## Captain\x27s intent\nPreserve the release and real gates.\n## Firstmate spec\nDo not release without go.\n' > "$dir/home/data/$id/brief.md"
  printf 'release report\n' > "$dir/home/data/$id/report.md"
  cp "$dir/home/state/$id.meta" "$dir/meta-prior"
  cp "$dir/home/data/$id/brief.md" "$dir/brief-prior"
  touch "$dir/supports-stop"
  make_orca_fakebin "$dir" >/dev/null
  printf '%s\n' "$dir"
}

orca_run() {  # <case-dir> <control|spawn> [args...]
  local dir=$1 tool=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_SPAWN_NO_GUARD=1 \
    FM_TEST_ORCA_DIR="$dir" PATH="$dir/fakebin:$PATH" \
    bash "$ROOT/bin/fm-$tool.sh" orca-recovery "$@" 2>&1
}

test_orca_control_relaunch_proves_stop_and_preserves_release() {
  local dir out rc meta calls
  dir=$(orca_relaunch_case recovery-success)
  out=$(orca_run "$dir" control relaunch --harness codex --note 'Read the preserved release report; approval remains required'); rc=$?
  expect_code 0 "$rc" "receipt-proven Orca relaunch should deliver a replacement"$'\n'"$out"
  assert_contains "$out" 'prior-agent=stopped replacement=unconfirmed' 'delivery must not masquerade as an agent-liveness proof'
  meta=$(cat "$dir/home/state/orca-recovery.meta")
  assert_contains "$meta" 'harness=codex' 'record should switch to Codex'
  assert_contains "$meta" 'terminal=term-2' 'record should rebind the terminal'
  assert_contains "$meta" "worktree=$dir/wt" 'replacement must keep the preserved worktree'
  assert_contains "$meta" "orca_worktree_id=wt-1::$dir/wt" 'Orca worktree identity must survive'
  assert_contains "$meta" 'approval_key=release-go' 'release approval boundary must survive'
  assert_contains "$meta" 'release_head=approved-release' 'release state must survive'
  assert_contains "$meta" 'yolo=off' 'merge authority must survive'
  [ "$(cat "$dir/wt/uncommitted")" = 'preserve dirty work' ] || fail 'dirty work was lost'
  [ "$(cat "$dir/home/data/orca-recovery/report.md")" = 'release report' ] || fail 'report was lost'
  assert_contains "$(cat "$dir/home/data/orca-recovery/brief.md")" 'Read the preserved release report' 'replacement must inherit progress note'
  calls=$(cat "$dir/calls")
  assert_not_contains "$calls" 'worktree create' 'relaunch must not create another worktree'
  assert_not_contains "$calls" 'worktree rm' 'relaunch must never remove the worktree'
  assert_not_contains "$calls" 'send --terminal term-1' 'old quota prompt must receive no lifecycle text'
  node -e 'const c=require("fs").readFileSync(process.argv[1],"utf8"); if(c.indexOf("terminal close --terminal term-1") < 0 || c.indexOf("terminal close --terminal term-1") > c.indexOf("terminal create")) process.exit(1)' "$dir/calls" || fail 'replacement started before close'
  pass 'Orca control relaunch: confirmed stop precedes Codex delivery, preserving dirty work, report and approval'
}

test_orca_relaunch_refuses_uncertain_stop() {
  local marker dir out rc
  for marker in unconfirmed-close legacy-close contradictory-close pending-close error-close malformed-close wrong-handle transport-fails stays-live runtime-change; do
    dir=$(orca_relaunch_case "refuse-$marker")
    touch "$dir/$marker"
    out=$(orca_run "$dir" control relaunch --harness codex --note 'Never launch without stop proof'); rc=$?
    expect_code 1 "$rc" "Orca must refuse $marker"$'\n'"$out"
    cmp -s "$dir/meta-prior" "$dir/home/state/orca-recovery.meta" || fail "$marker changed prior metadata"
    cmp -s "$dir/brief-prior" "$dir/home/data/orca-recovery/brief.md" || fail "$marker changed the live brief"
    assert_present "$dir/wt/uncommitted" "$marker lost dirty work"
    assert_not_contains "$(cat "$dir/calls")" 'terminal create' "$marker created a second endpoint"
    assert_present "$dir/home/state/orca-recovery.orca-stop.json" "$marker lost close evidence"
  done
  pass 'Orca relaunch: uncertain, malformed, mismatched, contradictory and stale-runtime stop receipts retain state and refuse'
}

test_orca_relaunch_refuses_other_worktree_owners_and_incomplete_reads() {
  local marker dir out rc
  for marker in peer truncated omitted-host wrong-worktree unsupported; do
    dir=$(orca_relaunch_case "preflight-$marker")
    touch "$dir/$marker"
    out=$(orca_run "$dir" control relaunch --harness codex --note 'Keep all work'); rc=$?
    expect_code 1 "$rc" "Orca preflight must refuse $marker"$'\n'"$out"
    cmp -s "$dir/meta-prior" "$dir/home/state/orca-recovery.meta" || fail "$marker changed metadata"
    cmp -s "$dir/brief-prior" "$dir/home/data/orca-recovery/brief.md" || fail "$marker changed instructions"
    assert_not_contains "$(cat "$dir/calls")" 'terminal close' "$marker closed a live terminal"
    assert_not_contains "$(cat "$dir/calls")" 'terminal create' "$marker created another endpoint"
  done
  pass 'Orca relaunch: competing orphaned PTYs and incomplete or unverified inventories refuse before touching agents'
}

test_orca_relaunch_retry_reuses_confirmed_receipt() {
  local dir out rc
  dir=$(orca_relaunch_case retry-after-stop)
  touch "$dir/create-fails"
  out=$(orca_run "$dir" spawn --relaunch --harness codex); rc=$?
  expect_code 1 "$rc" "replacement creation failure must refuse"$'\n'"$out"
  cmp -s "$dir/meta-prior" "$dir/home/state/orca-recovery.meta" || fail 'failed creation changed prior metadata'
  mv "$dir/create-fails" "$dir/create-failure-handled"
  out=$(orca_run "$dir" spawn --relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "retry with confirmed stop evidence should succeed"$'\n'"$out"
  [ "$(grep -c '^terminal close ' "$dir/calls")" = 1 ] || fail 'retry repeated the old endpoint close'
  assert_contains "$(cat "$dir/home/state/orca-recovery.meta")" 'terminal=term-2' 'retry did not record replacement'
  pass 'Orca spawn relaunch: creation failure retains the record; retry reuses confirmed incarnation stop evidence'
}

test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run
test_orca_control_relaunch_proves_stop_and_preserves_release
test_orca_relaunch_refuses_uncertain_stop
test_orca_relaunch_refuses_other_worktree_owners_and_incomplete_reads
test_orca_relaunch_retry_reuses_confirmed_receipt

echo "# all fm-spawn-orca-worktree tests passed"
