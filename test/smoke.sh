#!/usr/bin/env bash
# ai-review-kit smoke test — exercises babysit.sh's LAUNCHER path end-to-end with a
# stubbed `gh` and a stubbed agent (AI_CLI) in a throwaway repo. No network, no real
# agents, no scheduler writes. Run: test/smoke.sh   (exits non-zero on any failure)
#
# What it pins down (each was a live bug class):
#   1. a sweep leaves the human checkout byte-identical and `git status`-clean
#      (the lock's owner file inside .claude/ once made every sweep refuse itself)
#   2. the agent runs INSIDE a disposable worktree of origin's default branch,
#      never in the checkout, and the worktree is removed afterwards
#   3. a dirty human checkout does NOT block the sweep (isolation makes it moot)
#   4. the single-flight lock rejects a second concurrent run, and is released after
#      a successful sweep
#   5. unknown arguments refuse to start anything
#   6. the PRODUCTION claude) branch runs (stub is named `claude`, no AI_CLI): the
#      allow/deny flags are passed and the dynamic default-branch + force-push denies
#      are materialized in the deny list
set -euo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ark-smoke.XXXXXX")
TMP=$(cd "$TMP" && pwd)   # normalize (macOS TMPDIR ends in "/" → double-slash breaks path compares)
trap 'rm -rf "$TMP"' EXIT
FAILS=0
check() { # check <name> <cond...>
  local name="$1"; shift
  if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; FAILS=$((FAILS + 1)); fi
}

# Isolate all runtime state (RUNDIR is derived from XDG_CACHE_HOME).
export XDG_CACHE_HOME="$TMP/cache"
export HOME="$TMP/home"; mkdir -p "$HOME"

# --- stubs ---------------------------------------------------------------------
mkdir -p "$TMP/bin"
# gh stub: babysit.sh only calls `gh repo view --json nameWithOwner,defaultBranchRef`
# before launching the agent — answer with a fixed slug + trunk default.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "repo" ] && { echo "stub/repo trunk"; exit 0; }
exit 0
EOF
# claude stub — named `claude` (NOT routed via AI_CLI) so the sweep exercises the
# PRODUCTION claude) branch: subshell cd, allow/deny flags, dynamic default-branch
# deny. Records cwd + full argv + the prompt (the arg after -p), touches a file to
# prove Write access inside the worktree, exits clean.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
pwd > "$STUB_CWD_OUT"
printf '%s\n' "$@" > "$STUB_ARGS_OUT"
prev=""
for a in "$@"; do
  [ "$prev" = "-p" ] && printf %s "$a" > "$STUB_PROMPT_OUT"
  prev="$a"
done
touch agent-was-here
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"
export STUB_CWD_OUT="$TMP/stub-cwd" STUB_PROMPT_OUT="$TMP/stub-prompt" STUB_ARGS_OUT="$TMP/stub-args"

# --- throwaway repo with a real origin ------------------------------------------
git init -q --bare "$TMP/origin.git"
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/trunk
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
cd "$TMP/repo"
git config user.email smoke@test && git config user.name smoke
git checkout -q -b trunk
mkdir -p .github
cp "$KIT/ai-review-loop.md" .github/ai-review-loop.md
git add -A && git commit -qm init && git push -q origin trunk

# --- 5: unknown args refuse ------------------------------------------------------
if OUT=$("$KIT/babysit.sh" --oops 2>&1); then
  check "unknown arg exits non-zero" false
else
  check "unknown arg exits non-zero" true
fi
check "unknown arg never ran the agent" test ! -f "$STUB_CWD_OUT"

# --- 3: dirty checkout does not block (isolation makes it safe) ------------------
echo scratch > human-wip.txt

# --- run one sweep ---------------------------------------------------------------
"$KIT/babysit.sh" > "$TMP/sweep.log" 2>&1
check "sweep exits 0" true

# --- 2: agent ran inside the disposable worktree ---------------------------------
AGENT_CWD=$(cat "$STUB_CWD_OUT" 2>/dev/null || echo MISSING)
case "$AGENT_CWD" in
  "$XDG_CACHE_HOME"/ai-review-kit/*/tree) check "agent cwd is the RUNDIR worktree" true ;;
  *) echo "  (agent cwd was: $AGENT_CWD)"; check "agent cwd is the RUNDIR worktree" false ;;
esac
check "agent cwd is not the checkout" test "$AGENT_CWD" != "$TMP/repo"
RUNDIR=$(dirname "$AGENT_CWD")   # agent cwd is $RUNDIR/tree
check "worktree removed after sweep" test ! -e "$RUNDIR/tree"
grep -q "restricted STRICTLY to the repository stub/repo" "$STUB_PROMPT_OUT" \
  && check "prompt carries the repo scope" true || check "prompt carries the repo scope" false

# --- 1: checkout untouched and clean (the self-lock regression class) ------------
check "agent artifacts not in checkout" test ! -e agent-was-here
STATUS=$(git status --porcelain)
if [ "$STATUS" = "?? human-wip.txt" ]; then
  check "checkout clean after sweep (only the human's own file)" true
else
  echo "  (git status was: $STATUS)"; check "checkout clean after sweep (only the human's own file)" false
fi
check "lock released after sweep" test ! -e "$RUNDIR/lock"

# --- production claude) branch really ran, with its guardrails --------------------
grep -q -- "--allowedTools" "$STUB_ARGS_OUT" \
  && check "agent launched with an allowlist" true || check "agent launched with an allowlist" false
grep -q -- "--disallowedTools" "$STUB_ARGS_OUT" \
  && check "agent launched with a deny layer" true || check "agent launched with a deny layer" false
grep -q "git push\*trunk\*" "$STUB_ARGS_OUT" \
  && check "deny layer carries the dynamic default-branch push deny" true \
  || check "deny layer carries the dynamic default-branch push deny" false
grep -q "git push\*--force\*" "$STUB_ARGS_OUT" \
  && check "deny layer carries the force-push deny" true \
  || check "deny layer carries the force-push deny" false

# --- 4: single-flight lock -------------------------------------------------------
LOCKDIR="$RUNDIR/lock"
mkdir -p "$LOCKDIR"
rm -f "$STUB_CWD_OUT"
OUT=$("$KIT/babysit.sh" 2>&1) || true
echo "$OUT" | grep -q "another sweep is running" \
  && check "second run bounces off the lock" true || { echo "  (output: $OUT)"; check "second run bounces off the lock" false; }
check "locked run never ran the agent" test ! -f "$STUB_CWD_OUT"
rm -rf "$LOCKDIR"

echo
if [ "$FAILS" -gt 0 ]; then echo "SMOKE: $FAILS check(s) failed"; exit 1; fi
echo "SMOKE: all checks passed"
