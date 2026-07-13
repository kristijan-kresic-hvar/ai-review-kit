#!/usr/bin/env bash
# ai-review-kit babysitter — one unattended sweep of this repo's open PRs.
# Runs the pr-review-loop skill headless: triage new findings, apply verified fixes,
# reply/resolve threads, re-trigger reviewers, announce converged PRs. Exits quietly
# when nothing is actionable.
#
# Run it manually, or schedule it (every ~30 min) with the built-in installer —
# always invoked FROM the target repo's root, running from the kit clone (scripts
# are never vendored into repos):
#   path/to/ai-review-kit/babysit.sh --install-cron
# That picks the right scheduler per OS — LaunchAgent on macOS (plain cron cannot
# reach the login Keychain where gh/claude keep credentials; observed live as HTTP
# 401 on every cron sweep), crontab on Linux. Scheduled runs are prompt-free by
# construction: permissions are decided at launch by the flags below (allowlist +
# hard deny-layer), and AI_CLI keeps the runner agent-agnostic. Works invoked as the
# repo-installed copy OR straight from the kit clone; either way run it FROM the
# target repo's root. (Don't ALSO run a Claude Code scheduled task for sweeping —
# it prompts under interactive permissions and doesn't take this script's lock.)
#
# Needs: `claude` CLI + `gh` CLI authenticated as you. Must run from the repo root,
# on a CLEAN checkout of the DEFAULT branch — the sweep refuses dirty trees and
# feature-branch checkouts (the policy/settings it loads come from the working
# tree). By default it handles PRs YOU authored;
# pass --all to babysit every open PR in the repo (e.g. one maintainer covering a team).
#
# Headless fix ceiling (deliberate): the allowlist carries no project build/test
# commands, so the sweep only pushes fixes it can verify with the tools it has —
# anything needing the project's own verification surfaces in the report for an
# interactive session instead (fail-closed, never push-unverified). Lock ceiling:
# a sweep running past 2h loses its lock to the stale-steal; at the 30-min cadence
# that long a run is treated as hung by definition.
#
# The allowlist scopes what the headless agent may do: read PR/review state, comment,
# resolve threads, commit and push fixes to PR branches. `gh pr merge` is NOT allowed,
# and the skill's hard rules forbid merging and pushing to the default branch either
# way; the merge-gate status stays the human's merge signal.
set -euo pipefail
# cron ships a bare PATH (/usr/bin:/bin) — claude/gh/jq live in homebrew paths.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
# Unknown flags fail hard BEFORE anything runs: a typo'd `--instal-cron` must not
# fall through and start a real write-capable sweep. The same loop detects
# --install-cron at ANY position — a positional-only check let
# `--all --all --install-cron` skip the installer and start a real sweep.
INSTALL_CRON=""
for arg in "$@"; do
  case "$arg" in
    --all) ;;
    --install-cron) INSTALL_CRON=1 ;;
    *) echo "usage: babysit.sh [--all] [--install-cron]  (unknown argument: $arg)"; exit 1 ;;
  esac
done
[ -f .github/ai-review-loop.md ] || { echo "run from a repo with ai-review-kit installed"; exit 1; }

# Desktop notifications — marker-file protocol, NO executable entry point for the
# agent: an allowlisted script inside the writable checkout would be a self-rewritable
# approved command (the agent has Write). Instead the agent writes its message to a
# marker file, and THIS launcher delivers it after the run — via a read-only snapshot
# of the helper taken BEFORE the agent ran, so mid-run tampering never executes.
NOTIFY="$(cd "$(dirname "$0")" && pwd)/ai-review-notify.sh"
[ -x "$NOTIFY" ] || NOTIFY=""
NOTIFY_SNAP=""
NOTIFY_MARKER=".claude/.babysit-notify"

# --install-cron: schedule THIS repo's sweep every 30 min, idempotently.
#   macOS  → LaunchAgent, NOT crontab: gh and claude store credentials in the login
#            Keychain, which plain cron's session cannot access (observed live: every
#            cron sweep died with HTTP 401). A user LaunchAgent runs inside the GUI
#            session where the Keychain is available. RunAtLoad fires one sweep
#            immediately so the install verifies itself.
#   Linux  → crontab (credentials are file-based there; cron works fine).
#   Windows→ WSL (then this is the Linux path), or Task Scheduler — see the kit
#            README § Portability: https://github.com/kristijan-kresic-hvar/ai-review-kit
# The job invokes this script by its resolved absolute path, so it works for the
# repo-installed copy and a shared kit clone alike.
if [ -n "$INSTALL_CRON" ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # Fail closed on quote-bearing paths/values: the generated bash -c / cron command
  # single-quotes them, and a value containing ' would break out of the quoting. Rare
  # enough that refusing beats shipping a shell-escaping library.
  case "$(pwd)$SELF${AI_CLI:-}" in *"'"*) echo "checkout, kit path, or AI_CLI contains a single quote — unsupported for scheduling; move/rename and retry"; exit 1 ;; esac
  SCHED_ARGS=""
  for arg in "$@"; do [ "$arg" = "--all" ] && SCHED_ARGS=" --all"; done
  # Persist a non-default AI_CLI into the scheduled command — without this,
  # `AI_CLI=codex babysit.sh --install-cron` installs a job that silently sweeps
  # with claude (the env var dies with the install shell).
  SCHED_ENV=""
  [ "${AI_CLI:-claude}" != "claude" ] && SCHED_ENV="AI_CLI='${AI_CLI}' "
  if [ "$(uname)" = "Darwin" ]; then
    # Label = basename + short path hash: two checkouts named alike (~/work/x and
    # ~/scratch/x) must not share a plist path and silently unload each other.
    PATH_HASH=$(printf %s "$(pwd)" | cksum | cut -d' ' -f1)
    LABEL="com.ai-review-kit.babysit.$(basename "$(pwd)").$PATH_HASH"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>-c</string>
    <string>cd '$(pwd)' || exit 1; ${SCHED_ENV}'$SELF'$SCHED_ARGS</string>
  </array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/.ai-review-kit-babysit.log</string>
  <key>StandardErrorPath</key><string>$HOME/.ai-review-kit-babysit.log</string>
</dict></plist>
PLIST_EOF
    # Strict-parse the generated plist: launchd's parser tolerates invalid XML
    # (verified live — plutil and xmllint both rejected a file launchd loaded), so
    # a lint here is the only honest install check.
    plutil -lint "$PLIST" >/dev/null || { echo "generated plist failed lint — not loading"; exit 1; }
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed LaunchAgent $LABEL (every 30 min + one run now)"
    echo "log: ~/.ai-review-kit-babysit.log · status: launchctl list | grep ai-review-kit"
    echo "NOTE: remove any old crontab line for this repo — cron cannot reach the Keychain."
  else
    # Paths single-quoted: a checkout under 'Client Projects/...' must not token-split
    # or execute as shell syntax inside cron. (Paths containing a single quote remain
    # unsupported — vanishingly rare; the installer is not a shell-escaping library.)
    # cron additionally treats % as end-of-command/newline — a %-bearing value would
    # silently truncate the job (AI_CLI is in scope: SCHED_ENV splices it into the
    # line). A backslash breaks the awk match keys below (awk -v escape-processes its
    # values), so re-installs would stack instead of replace. Same fail-closed posture.
    case "$(pwd)$SELF${AI_CLI:-}" in *"%"*|*"\\"*) echo "checkout, kit path, or AI_CLI contains % or \\ — unsupported for cron scheduling; move/rename and retry"; exit 1 ;; esac
    LINE="*/30 * * * * cd '$(pwd)' && ${SCHED_ENV}'$SELF'$SCHED_ARGS >> \"\$HOME/.ai-review-kit-babysit.log\" 2>&1"
    if ! command -v crontab >/dev/null 2>&1; then
      echo "no crontab on this system — schedule manually: kit README § Portability"; echo "  https://github.com/kristijan-kresic-hvar/ai-review-kit#portability--new-machine-any-os-any-teammate"; exit 1
    fi
    # Idempotency keys on the exact install fragment — script path alone breaks the
    # shared-kit-clone-many-repos case (same $SELF for every repo); checkout path
    # alone false-matches unrelated jobs that cd here. Both together are unambiguous.
    FRAG="cd '$(pwd)' && ${SCHED_ENV}'$SELF'$SCHED_ARGS"
    if crontab -l 2>/dev/null | grep -qF "$FRAG"; then
      echo "already scheduled — this repo's babysitter crontab entry exists:"
      crontab -l | grep -F "$FRAG"
    else
      # `crontab -l` exits non-zero when no crontab exists yet; under set -e that
      # aborted the subshell BEFORE echo — first-time installs silently did nothing.
      # REPLACE (never stack) any prior entry for this repo+script whose flags/env
      # differ: two live entries would race the lock on every tick and the loser's
      # "another sweep is running" noise would look like a fault. Match on BOTH the
      # checkout path and the script path (same keys as FRAG, minus the mutable bits).
      { crontab -l 2>/dev/null || true; } \
        | awk -v a="cd '$(pwd)' && " -v b="'$SELF'" 'index($0,a)==0 || index($0,b)==0' \
        | { cat; echo "$LINE"; } | crontab -
      echo "installed: $LINE"
      echo "log: ~/.ai-review-kit-babysit.log · view schedule: crontab -l"
    fi
  fi
  exit 0
fi

# Single-flight lock: a sweep can legitimately outlive the cron interval (the playbook
# bounds each reviewer wait at ~20 min and caps re-fires, but a multi-PR round chains
# several waits), so an unguarded cron overlaps two agents on the same PRs (double
# nudges, out-of-order resolves). mkdir is the portable atomic primitive (no flock on
# macOS). A lock older than 2h is stale: that exceeds every in-loop bound combined —
# a run past it is crashed or hung, not working. NOTE: the agent launches below run
# WITHOUT exec — exec would replace the shell and skip the EXIT trap, leaving the lock
# held after every successful sweep (caught in live review).
LOCK=".claude/.babysit.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    echo "stealing stale lock (>2h old)"; rm -rf "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || { echo "another sweep is running — exiting"; exit 0; }
  else
    echo "another sweep is running — exiting"; exit 0
  fi
fi
# Owner token: only the process that TOOK the lock may remove it. Without it, a hung
# sweep outliving the 2h stale-steal would, on eventually exiting, delete the stealing
# run's lock — letting a third sweep overlap the second on the same PRs.
echo "$$" > "$LOCK/owner"
trap '[ "$(cat "$LOCK/owner" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null; [ -n "$NOTIFY_SNAP" ] && rm -rf "$(dirname "$NOTIFY_SNAP")" 2>/dev/null; true' EXIT

# Stale-marker cleanup INSIDE the lock — done pre-lock, a second launch would wipe the
# still-running first sweep's queued notifications before bouncing off the lock.
rm -f "$NOTIFY_MARKER"

# Unattended agents never run over uncommitted human work: a write-capable sweep in a
# dirty checkout can sweep local changes into PR-branch commits. Fail quiet, fail closed.
# The explicit assignment matters: a FAILED `git status` yields an empty substitution,
# which the bare [ -n ... ] test read as "clean" — couldn't-check must never mean clean.
DIRTY=$(git status --porcelain) || { echo "git status failed — refusing unattended sweep"; exit 1; }
if [ -n "$DIRTY" ]; then
  echo "working tree dirty — refusing unattended sweep (commit/stash first)"; exit 0
fi

# Pin the sweep to the DEFAULT branch: the policy the agent loads (.github/
# ai-review-loop.md, .claude/ settings) comes from THIS working tree — a checkout left
# on a feature branch would feed the unattended run branch-authored policy. The gh call
# also resolves the repo slug + default branch for the prompt and the push deny below.
REPO_INFO=$(gh repo view --json nameWithOwner,defaultBranchRef --jq '.nameWithOwner + " " + .defaultBranchRef.name')
REPO_SLUG=${REPO_INFO%% *}
DEFAULT_BRANCH=${REPO_INFO##* }
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CUR_BRANCH" != "$DEFAULT_BRANCH" ]; then
  echo "checkout is on '$CUR_BRANCH', not default branch '$DEFAULT_BRANCH' — refusing unattended sweep"; exit 0
fi

# Snapshot the notify helper only now — every early-exit above leaks nothing, and the
# EXIT trap (armed with the lock) owns the cleanup from here on.
if [ -n "$NOTIFY" ]; then
  SNAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ai-review-notify.XXXXXX") \
    && cp "$NOTIFY" "$SNAP_DIR/notify.sh" && chmod 555 "$SNAP_DIR/notify.sh" \
    && NOTIFY_SNAP="$SNAP_DIR/notify.sh" || NOTIFY_SNAP=""
fi

SCOPE="authored by me (--author @me)"
for arg in "$@"; do [ "$arg" = "--all" ] && SCOPE="by ANY author"; done

# Hard repo scope: the playbook's enumerate is account-wide by default; a repo-local
# cron must not act on other repos (their own crons/sessions own them). Observed live:
# without the explicit slug, a sweep crossed repos. (REPO_SLUG resolved above,
# alongside the default-branch pin.)
PROMPT="Read .github/ai-review-loop.md fully and run its sweep mode restricted STRICTLY to the repository ${REPO_SLUG} — filter the enumerate to that repo, and ignore PRs in any other repository. Repo-scope every command: -R ${REPO_SLUG} on gh pr/gh search commands, fully-qualified repos/${REPO_SLUG}/... paths on gh api calls (gh api has no -R flag). Scope: OPEN, non-draft pull requests ${SCOPE} — never touch merged, closed, or draft PRs. Nothing actionable = exit with one quiet line."
if [ -n "$NOTIFY_SNAP" ]; then
  PROMPT="$PROMPT Where the playbook says to notify the human (converged PR, critical escalation, dead reviewer leg, security-fix FYI), APPEND one line per event to the file $NOTIFY_MARKER (Write tool) — the launcher delivers desktop notifications from it after the sweep; that is your only notification channel."
fi

# AI_CLI picks the agent. claude (default) is the supported, live-tested path.
# codex is wired but has less mileage — verify one sweep manually before cron.
# Any other value is executed verbatim with the prompt appended: unsupported, no promises.
AI_CLI="${AI_CLI:-claude}"
case "$AI_CLI" in
  claude)
    # disallowedTools = defense-in-depth (deny beats allow in Claude Code's
    # permission resolution). `gh api` must stay allowed (thread replies/resolves
    # have no higher-level gh command), so instead of enumerating dangerous
    # endpoints: every explicit-method call (-X / --method) is denied — the loop's
    # legitimate writes (thread replies, graphql resolves) are all default-POSTs
    # that never pass a method flag, while REST merges, ref moves, and deletes
    # require one. Method-less GraphQL write mutations are denied by name (merge,
    # createCommitOnBranch, create/update/deleteRef). Residual accepted risk:
    # plain POST endpoints (create comment/issue/ref-via-REST) — spammy at worst,
    # no history rewrite or default-branch move without a method flag. git push
    # denies cover bare pushes (branch inferred from a default-branch checkout)
    # and ANY refspec containing main/master OR this repo's actual default branch
    # (`origin HEAD:trunk` on a trunk-default repo slipped every static pattern);
    # branch names containing those words over-block — fail-closed, rename.
    # NOTE: allow/deny rules MERGE with any .claude/settings.json in the checkout
    # (allows are additive across sources; deny still always wins) — one more
    # reason the sweep only runs from a default-branch checkout (enforced above):
    # settings are the default branch's, not a PR branch's.
    ALLOWED="Skill,Read,Glob,Grep,Edit,Write,Bash(jq:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh pr checks:*),Bash(gh api:*),Bash(gh search:*),Bash(gh workflow run:*),Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git worktree:*),Bash(git checkout:*),Bash(git fetch:*)"
    claude -p "$PROMPT" \
      --allowedTools "$ALLOWED" \
      --disallowedTools "Bash(gh pr merge:*),Bash(gh api* -X *),Bash(gh api*--method*),Bash(gh api*/merge*),Bash(gh api*merges*),Bash(gh api*mergePullRequest*),Bash(gh api*createCommitOnBranch*),Bash(gh api*updateRef*),Bash(gh api*deleteRef*),Bash(gh api*createRef*),Bash(gh api*/git/*),Bash(git push),Bash(git push origin),Bash(git push origin HEAD),Bash(git push -u origin HEAD),Bash(git push*HEAD),Bash(git push*main*),Bash(git push*master*),Bash(git push*${DEFAULT_BRANCH}*)" || echo "[babysit] claude exited non-zero" ;;
  codex)
    # --full-auto: workspace-write + on-request network. Smoke-tested 2026-07-13: an
    # idle sweep works OUT OF THE BOX — the sandbox blocks gh's network, and Codex
    # degrades to its own GitHub connector (repo-scoped reads) and exits quietly.
    # ACTIVE rounds (pushing fixes, posting replies) still need your Codex config to
    # allow gh/git network in this repo, or the sweep stalls on approvals.
    # GUARDRAIL GAP (know what you're running): unlike the claude branch above, there
    # is no deny-list equivalent here — the playbook's never-merge/never-main rules are
    # prompt-level only, enforced by Codex's own sandbox/approval config, not by this
    # script. Verify one FIX round interactively before trusting it to cron.
    codex exec --full-auto "$PROMPT" || echo "[babysit] codex exited non-zero" ;;
  *)
    # Executed verbatim with the prompt appended: unsupported, no guardrails, no promises.
    $AI_CLI "$PROMPT" || echo "[babysit] $AI_CLI exited non-zero" ;;
esac

# Deliver queued notifications from the marker file — via the pre-run read-only
# snapshot, never the (agent-writable) checkout copy. Max 3, each line truncated;
# the agent controls only the TEXT (argv-passed, injection-safe), never code.
if [ -n "$NOTIFY_SNAP" ] && [ -f "$NOTIFY_MARKER" ]; then
  head -3 "$NOTIFY_MARKER" | cut -c1-200 | while IFS= read -r line; do
    [ -n "$line" ] && "$NOTIFY_SNAP" "$line"
  done
  rm -f "$NOTIFY_MARKER"
fi
