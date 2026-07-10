#!/usr/bin/env bash
# ai-review-kit babysitter — one unattended sweep of this repo's open PRs.
# Runs the pr-review-loop skill headless: triage new findings, apply verified fixes,
# reply/resolve threads, re-trigger reviewers, announce converged PRs. Exits quietly
# when nothing is actionable.
#
# Run it manually, or on a schedule (every ~30 min):
#   crontab -e   →   */30 * * * * cd /abs/path/to/repo && .claude/ai-review-babysit.sh >> "$HOME/.ai-review-kit-babysit.log" 2>&1
# (Claude Code users can instead tell Claude once: "schedule a recurring task:
#  babysit my PRs every 30 minutes" — same effect, managed inside Claude Code.)
#
# Needs: `claude` CLI + `gh` CLI authenticated as you. Must run from the repo root
# (the pr-review-loop skill is project-local). By default it handles PRs YOU authored;
# pass --all to babysit every open PR in the repo (e.g. one maintainer covering a team).
#
# The allowlist scopes what the headless agent may do: read PR/review state, comment,
# resolve threads, commit and push fixes to PR branches. `gh pr merge` is NOT allowed,
# and the skill's hard rules forbid merging and pushing to the default branch either
# way; the merge-gate status stays the human's merge signal.
set -euo pipefail
[ -f .github/ai-review-loop.md ] || { echo "run from a repo with ai-review-kit installed"; exit 1; }

SCOPE="authored by me (--author @me)"
[ "${1:-}" = "--all" ] && SCOPE="by ANY author"

PROMPT="Read .github/ai-review-loop.md fully and run its sweep mode over this repository's OPEN, non-draft pull requests ${SCOPE} — never touch merged, closed, or draft PRs. Nothing actionable = exit with one quiet line."

# AI_CLI picks the agent. claude (default) is the supported, live-tested path.
# codex is wired but has less mileage — verify one sweep manually before cron.
# Any other value is executed verbatim with the prompt appended: unsupported, no promises.
AI_CLI="${AI_CLI:-claude}"
case "$AI_CLI" in
  claude)
    # disallowedTools = defense-in-depth against merge-by-API: `gh api` must stay
    # allowed (thread replies/resolves have no higher-level gh command), but the
    # REST merge endpoint (…/pulls/N/merge), the branch-merge endpoint (…/merges),
    # and the GraphQL mergePullRequest mutation are explicitly denied. Deny beats
    # allow in Claude Code's permission resolution.
    exec claude -p "$PROMPT" \
      --allowedTools "Skill,Read,Glob,Grep,Edit,Write,Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh pr checks:*),Bash(gh api:*),Bash(gh search:*),Bash(gh workflow run:*),Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git worktree:*),Bash(git checkout:*),Bash(git fetch:*)" \
      --disallowedTools "Bash(gh pr merge:*),Bash(gh api*/merge*),Bash(gh api*merges*),Bash(gh api*mergePullRequest*),Bash(git push*origin main*),Bash(git push*origin master*)" ;;
  codex)
    # --full-auto: workspace-write + on-request network; make sure your Codex config
    # allows gh/git in this repo or the sweep stalls on approvals.
    exec codex exec --full-auto "$PROMPT" ;;
  *)
    exec $AI_CLI "$PROMPT" ;;
esac
