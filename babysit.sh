#!/usr/bin/env bash
# ai-review-kit babysitter — one unattended sweep of this repo's open PRs.
# Runs the pr-review-loop skill headless: triage new findings, apply verified fixes,
# reply/resolve threads, re-trigger reviewers, announce converged PRs. Exits quietly
# when nothing is actionable.
#
# Run it manually, or on a schedule (every ~30 min) — CRON IS THE RECOMMENDED PATH:
# permissions are decided at launch by the flags below (allowlist + hard deny-layer),
# so an unattended run can never stall on a permission prompt, and AI_CLI keeps it
# agent-agnostic. Works invoked as the repo-installed copy OR straight from the kit
# clone; either way run it FROM the target repo's root:
#   crontab -e   →   */30 * * * * cd /abs/path/to/repo && .claude/ai-review-babysit.sh >> "$HOME/.ai-review-kit-babysit.log" 2>&1
# (A Claude Code scheduled task can do the same job, but it runs with your interactive
#  permission settings — expect prompts unless those are pre-allowed. Don't run both:
#  the scheduled task doesn't take this script's lock.)
#
# Needs: `claude` CLI + `gh` CLI authenticated as you. Must run from the repo root
# (the pr-review-loop skill is project-local). By default it handles PRs YOU authored;
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
[ -f .github/ai-review-loop.md ] || { echo "run from a repo with ai-review-kit installed"; exit 1; }

# Desktop-notification helper (sibling file): the ONLY notification capability the
# agent gets — a raw osascript allowlist entry would hand it all of AppleScript.
NOTIFY="$(cd "$(dirname "$0")" && pwd)/ai-review-notify.sh"
[ -x "$NOTIFY" ] || NOTIFY=""

# --install-cron: schedule THIS repo's sweep every 30 min, idempotently (macOS/Linux —
# anywhere with a cron daemon; Windows users: run under WSL, or see README for a Task
# Scheduler equivalent). The job invokes this script by its resolved absolute path, so
# it works for the repo-installed copy and a shared kit clone alike.
if [ "${1:-}" = "--install-cron" ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  LINE="*/30 * * * * cd $(pwd) && $SELF >> \"\$HOME/.ai-review-kit-babysit.log\" 2>&1"
  if ! command -v crontab >/dev/null 2>&1; then
    echo "no crontab on this system — schedule manually (README § Portability)"; exit 1
  fi
  if crontab -l 2>/dev/null | grep -qF "cd $(pwd) "; then
    echo "already scheduled — a crontab entry for $(pwd) exists:"
    crontab -l | grep -F "cd $(pwd) "
  else
    (crontab -l 2>/dev/null; echo "$LINE") | crontab -
    echo "installed: $LINE"
    echo "log: ~/.ai-review-kit-babysit.log · view schedule: crontab -l"
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
    echo "stealing stale lock (>2h old)"; rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || { echo "another sweep is running — exiting"; exit 0; }
  else
    echo "another sweep is running — exiting"; exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Unattended agents never run over uncommitted human work: a write-capable sweep in a
# dirty checkout can sweep local changes into PR-branch commits. Fail quiet, fail closed.
if [ -n "$(git status --porcelain)" ]; then
  echo "working tree dirty — refusing unattended sweep (commit/stash first)"; exit 0
fi

SCOPE="authored by me (--author @me)"
[ "${1:-}" = "--all" ] && SCOPE="by ANY author"

# Hard repo scope: the playbook's enumerate is account-wide by default; a repo-local
# cron must not act on other repos (their own crons/sessions own them). Observed live:
# without the explicit slug, a sweep crossed repos.
REPO_SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

PROMPT="Read .github/ai-review-loop.md fully and run its sweep mode restricted STRICTLY to the repository ${REPO_SLUG} — filter the enumerate to that repo, and ignore PRs in any other repository. Repo-scope every command: -R ${REPO_SLUG} on gh pr/gh search commands, fully-qualified repos/${REPO_SLUG}/... paths on gh api calls (gh api has no -R flag). Scope: OPEN, non-draft pull requests ${SCOPE} — never touch merged, closed, or draft PRs. Nothing actionable = exit with one quiet line."
if [ -n "$NOTIFY" ]; then
  PROMPT="$PROMPT Where the playbook says to notify the human (converged PR, critical escalation, dead reviewer leg, security-fix FYI), run: $NOTIFY '<one-line message>' — that is your only notification channel."
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
    # and ANY refspec containing main/master (`origin HEAD:main`); branch names
    # containing 'main'/'master' over-block — fail-closed, rename the branch.
    ALLOWED="Skill,Read,Glob,Grep,Edit,Write,Bash(jq:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh pr checks:*),Bash(gh api:*),Bash(gh search:*),Bash(gh workflow run:*),Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git worktree:*),Bash(git checkout:*),Bash(git fetch:*)"
    [ -n "$NOTIFY" ] && ALLOWED="$ALLOWED,Bash($NOTIFY:*)"
    claude -p "$PROMPT" \
      --allowedTools "$ALLOWED" \
      --disallowedTools "Bash(gh pr merge:*),Bash(gh api* -X *),Bash(gh api*--method*),Bash(gh api*/merge*),Bash(gh api*merges*),Bash(gh api*mergePullRequest*),Bash(gh api*createCommitOnBranch*),Bash(gh api*updateRef*),Bash(gh api*deleteRef*),Bash(gh api*createRef*),Bash(gh api*/git/*),Bash(git push),Bash(git push origin),Bash(git push origin HEAD),Bash(git push -u origin HEAD),Bash(git push*HEAD),Bash(git push*main*),Bash(git push*master*)" ;;
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
    codex exec --full-auto "$PROMPT" ;;
  *)
    # Executed verbatim with the prompt appended: unsupported, no guardrails, no promises.
    $AI_CLI "$PROMPT" ;;
esac
