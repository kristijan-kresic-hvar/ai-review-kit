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
[ -f .claude/skills/pr-review-loop/SKILL.md ] || { echo "run from a repo with ai-review-kit installed"; exit 1; }

SCOPE="authored by me (--author @me)"
[ "${1:-}" = "--all" ] && SCOPE="by ANY author"

exec claude -p "Run the pr-review-loop skill in sweep mode over this repository's open pull requests ${SCOPE}. Nothing actionable = exit with one quiet line." \
  --allowedTools "Skill,Read,Glob,Grep,Edit,Write,Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh pr checks:*),Bash(gh api:*),Bash(gh search:*),Bash(gh workflow run:*),Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git worktree:*),Bash(git checkout:*),Bash(git fetch:*)"
