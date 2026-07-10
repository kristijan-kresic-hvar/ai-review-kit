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

# Hard repo scope: the playbook's enumerate is account-wide by default; a repo-local
# cron must not act on other repos (their own crons/sessions own them). Observed live:
# without the explicit slug, a sweep crossed repos.
REPO_SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

PROMPT="Read .github/ai-review-loop.md fully and run its sweep mode restricted STRICTLY to the repository ${REPO_SLUG} — filter the enumerate to that repo, pass -R ${REPO_SLUG} on every command, and ignore PRs in any other repository. Scope: OPEN, non-draft pull requests ${SCOPE} — never touch merged, closed, or draft PRs. Nothing actionable = exit with one quiet line."

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
    # that never pass a method flag, while merges, ref moves, and deletes require
    # one. The GraphQL merge mutation carries no method flag, so it stays denied
    # by name. git push denies match ANY refspec containing main/master (covers
    # `origin HEAD:main`); branch names containing 'main'/'master' over-block —
    # fail-closed, rename the branch.
    exec claude -p "$PROMPT" \
      --allowedTools "Skill,Read,Glob,Grep,Edit,Write,Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh pr checks:*),Bash(gh api:*),Bash(gh search:*),Bash(gh workflow run:*),Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git worktree:*),Bash(git checkout:*),Bash(git fetch:*)" \
      --disallowedTools "Bash(gh pr merge:*),Bash(gh api* -X *),Bash(gh api*--method*),Bash(gh api*/merge*),Bash(gh api*merges*),Bash(gh api*mergePullRequest*),Bash(git push*main*),Bash(git push*master*)" ;;
  codex)
    # --full-auto: workspace-write + on-request network; make sure your Codex config
    # allows gh/git in this repo or the sweep stalls on approvals.
    exec codex exec --full-auto "$PROMPT" ;;
  *)
    exec $AI_CLI "$PROMPT" ;;
esac
