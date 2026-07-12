#!/usr/bin/env bash
# ai-review-kit installer — run from the TARGET repo's root.
# Usage: setup.sh [--claude] [--codex]   (no flags = both legs)
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE=0; CODEX=0
[ $# -eq 0 ] && { CLAUDE=1; CODEX=1; }
for a in "$@"; do
  case "$a" in
    --claude) CLAUDE=1 ;;
    --codex) CODEX=1 ;;
    *) echo "usage: setup.sh [--claude] [--codex]"; exit 1 ;;
  esac
done

[ -d .git ] || { echo "error: run from the target repo's root (no .git here)"; exit 1; }
mkdir -p .github/workflows

# Branch hygiene: merged PR branches auto-delete (GitHub repo setting). Best-effort —
# offline/no-gh setups just see the note instead.
if gh api -X PATCH "repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
     -f delete_branch_on_merge=true --silent 2>/dev/null; then
  echo "enabled delete_branch_on_merge (merged PR branches auto-delete)"
else
  echo "NOTE: could not set delete_branch_on_merge — enable it in repo Settings"
fi

# The gate is always installed — it adapts to whichever legs exist.
cp "$KIT/workflows/merge-gate.yml" .github/workflows/merge-gate.yml
echo "installed .github/workflows/merge-gate.yml"

# The fix loop ships with the kit. ONE canonical agent-neutral playbook, plus a thin
# Claude Code skill shim pointing at it — Codex CLI and other AGENTS.md-reading agents
# get routed by the 'Pull request workflow' section of AGENTS.md instead.
cp "$KIT/ai-review-loop.md" .github/ai-review-loop.md
echo "installed .github/ai-review-loop.md (canonical fix-loop playbook, any agent)"
mkdir -p .claude/skills/pr-review-loop
cp "$KIT/skills/pr-review-loop.md" .claude/skills/pr-review-loop/SKILL.md
echo "installed .claude/skills/pr-review-loop/SKILL.md (Claude Code shim -> playbook)"

# The babysitter — unattended sweep runner for cron/manual use, so PRs opened OUTSIDE
# Claude Code (web UI, plain terminal) still get the loop. The notify helper is its
# sibling: the only desktop-notification capability the headless agent gets.
cp "$KIT/babysit.sh" .claude/ai-review-babysit.sh
cp "$KIT/ai-review-notify.sh" .claude/ai-review-notify.sh
chmod +x .claude/ai-review-babysit.sh .claude/ai-review-notify.sh
echo "installed .claude/ai-review-babysit.sh + ai-review-notify.sh (unattended babysitter — see checklist)"

# Review-optimized PR structure for everyone — GitHub pre-fills it on every new PR.
if [ -f .github/pull_request_template.md ]; then
  echo ".github/pull_request_template.md exists — left as is"
else
  cp "$KIT/pull_request_template.md" .github/pull_request_template.md
  echo "installed .github/pull_request_template.md (review-optimized PR structure)"
fi

# Wire CLAUDE.md so Claude Code runs the loop UNPROMPTED after opening any PR —
# this is what makes the kit hands-off end to end, not a skill someone must invoke.
if [ -f CLAUDE.md ] && grep -qF '## AI review loop (ai-review-kit' CLAUDE.md; then
  echo "CLAUDE.md already wired for the review loop — left as is"
else
  cat "$KIT/CLAUDE.md.section" >> CLAUDE.md
  echo "wired CLAUDE.md — the loop auto-runs after every PR opened from Claude Code"
fi

if [ "$CLAUDE" = 1 ]; then
  cp "$KIT/workflows/code-review.yml" .github/workflows/code-review.yml
  echo "installed .github/workflows/code-review.yml"
fi

if [ "$CODEX" = 1 ]; then
  if [ -f AGENTS.md ]; then
    if grep -Eq '^##[[:space:]]+Code Review Rules' AGENTS.md; then
      echo "AGENTS.md already has '## Code Review Rules' — left as is"
    else
      echo "NOTE: AGENTS.md exists but lacks '## Code Review Rules' — the gate will NOT"
      echo "      treat this repo as Codex-enabled until you add that section."
      echo "      Template: $KIT/AGENTS.md.example"
    fi
    if ! grep -Eq '^##[[:space:]]+Pull request workflow' AGENTS.md; then
      echo "NOTE: AGENTS.md lacks the '## Pull request workflow (all agents)' section —"
      echo "      copy it from $KIT/AGENTS.md.example so non-Claude agents (Codex CLI"
      echo "      etc.) also auto-run the loop after opening PRs."
    fi
  else
    cp "$KIT/AGENTS.md.example" AGENTS.md
    echo "installed AGENTS.md (adapt the repo-specific parts)"
  fi
fi

echo
echo "== remaining manual steps =="
if [ "$CLAUDE" = 1 ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "<owner>/<repo>")
  if gh secret list 2>/dev/null | grep -q CLAUDE_CODE_OAUTH_TOKEN; then
    echo "[claude] CLAUDE_CODE_OAUTH_TOKEN secret: present"
  else
    echo "[claude] set the token secret:  claude setup-token   then"
    echo "         gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $REPO"
    echo "         (or run /install-github-app inside Claude Code)"
  fi
  echo "[linear] optional — review against linked Linear tickets (AC / scope / verification):"
  echo "         gh secret set LINEAR_API_KEY --repo $REPO   (a Linear personal API key)"
  echo "         no secret or no issue id in the branch => the step is a silent no-op"
fi
if [ "$CODEX" = 1 ]; then
  echo "[codex]  install the Codex GitHub app + enable code review for this repo:"
  echo "         ChatGPT -> Settings -> Codex -> Code review"
  echo "         keep the account's Auto review toggle OFF (trigger-only by design:"
  echo "         one deterministic review per head — the loop posts @codex review)"
fi
echo "[gate]   optional but recommended: require status check 'merge-gate' on the"
echo "         default branch (Settings -> Rulesets; private repos need Pro/Team)."
echo "[loop]   babysitter routine (per developer, once) — pick ONE:"
echo "         cron:        crontab -e   then add:"
echo "                      */30 * * * * cd $(pwd) && .claude/ai-review-babysit.sh >> \$HOME/.ai-review-kit-babysit.log 2>&1"
echo "         Claude Code: say \"schedule a recurring task: babysit my PRs every 30 minutes\""
echo "         (sessions in this repo also sweep on start via the CLAUDE.md wiring;"
echo "          the routine covers PRs opened outside Claude Code between sessions)"
echo
echo "Commit the added files on a branch and open a PR — the reviewers review it."
