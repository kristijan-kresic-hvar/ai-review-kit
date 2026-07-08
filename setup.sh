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

# The gate is always installed — it adapts to whichever legs exist.
cp "$KIT/workflows/merge-gate.yml" .github/workflows/merge-gate.yml
echo "installed .github/workflows/merge-gate.yml"

# The fix loop ships with the kit — installed as a project-local Claude Code skill, so
# anyone opening this repo with Claude Code has the loop with no separate install.
mkdir -p .claude/skills/pr-review-loop
cp "$KIT/skills/pr-review-loop.md" .claude/skills/pr-review-loop/SKILL.md
echo "installed .claude/skills/pr-review-loop/SKILL.md (autonomous fix loop)"

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
fi
if [ "$CODEX" = 1 ]; then
  echo "[codex]  install the Codex GitHub app + enable code review for this repo:"
  echo "         ChatGPT -> Settings -> Codex -> Code review"
  echo "         trigger per PR with a comment: @codex review (auto-review optional)"
fi
echo "[gate]   optional but recommended: require status check 'merge-gate' on the"
echo "         default branch (Settings -> Rulesets; private repos need Pro/Team)."
echo
echo "Commit the added files on a branch and open a PR — the reviewers review it."
