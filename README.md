# ai-review-kit

> **GitHub only.** Everything runs on GitHub Actions + GitHub apps.

Two independent AI reviewers on every pull request, an autonomous fix loop that drives
their findings to convergence, and a merge-gate status that only goes green when every
reviewer you actually have is clean on the current head.

**The flow, once installed:** open a PR — reviewers fire, the loop triages findings
(fixing what's worth fixing, rejecting what isn't — every thread replied to AND
resolved either way), re-reviews until clean, and the gate flips green. The human does
exactly two things: the merge click, and answering the rare critical escalation.

- **Claude** (craftsmanship): conventions, maintainability, a11y, quality — via
  [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).
  Optionally **Linear-aware**: reviews the diff against the linked ticket's spec.
- **Codex** (adversarial): assumes the change is wrong and tries to prove it — P0/P1
  logic bugs, edge cases, security — via the ChatGPT Codex GitHub app.
- **merge-gate**: a commit status on the PR head. Detects which reviewers the repo has
  and gates on exactly those. One reviewer is fine; zero = gate stays out of the way.

## Status: battle-tested (solo, GitHub, 2026-07)

Everything here ran live before being called done — not simulated, not mocked:

- **4 real PRs driven end-to-end** on a production repo: findings → verified fixes →
  every thread replied + resolved → re-review → gate green → human merge. One PR took
  6 adversarial review rounds; all 24 of its P1 findings were triaged against the code
  (fixed or rebutted with evidence), none blindly accepted.
- **Gate scenario matrix 6/6** on a throwaway repo: no-reviewers green, silent-reviewer
  red, workflow-only waiver + zero-reviewer guard, on-head Codex detection,
  `workflow_dispatch` re-eval (flipped a stale green after config changed under it),
  `issue_comment` re-eval.
- **14/14 local tests**: every `setup.sh` variant (legs, idempotent re-run,
  preserve-existing), every Linear-step degradation path (no key / no id / API failure
  / timeout / issue-not-found), and a delimiter-injection attempt contained.
- **2 unattended headless sweeps** observed live, including the permission denies
  stopping a merge-by-API attempt and the single-flight lock rejecting a second run.
- **Ticket-aware review proven**: reviewer verdict explicitly checked the linked
  ticket's acceptance criteria ("all three KKD-11 acceptance criteria satisfied").

Scope honesty: tested by ONE person on solo repos. Multi-collaborator flows (fork PRs,
concurrent authors) are designed for but not exercised. The loop's fix rounds are
capped at 3 per PR; reviewers bill your Claude/ChatGPT subscriptions per round.

## Prerequisites

- A GitHub repo (Actions enabled).
- **Claude leg:** a Claude subscription with Claude Code (`claude setup-token`, once per repo).
- **Codex leg:** a ChatGPT plan with Codex + the Codex GitHub app installed on the repo.
- `gh` CLI locally for setup only. Each leg is optional and independent.

Budget roughly 2 runs per reviewer per fix round (the loop batches each round's fixes
into one push to keep it there).

## Degradation matrix (the contract)

| Repo has | merge-gate goes green when |
|---|---|
| Claude + Codex | Claude APPROVED on head **and** Codex clean (no unresolved threads + a "didn't find any major issues" comment naming the head) |
| Claude only | Claude APPROVED on head |
| Codex only | Codex clean on head |
| Neither | Always ("gate not applicable") |

Detection is automatic, per repo, at gate runtime: Claude leg =
`.github/workflows/code-review.yml` exists (or claude[bot] already reviewed the PR);
Codex leg = `AGENTS.md` contains a `## Code Review Rules` section (or the Codex bot
already touched the PR). Bare AGENTS.md presence is deliberately NOT the signal.

## Setup

From the **target repo's root**:

```bash
path/to/ai-review-kit/setup.sh            # both legs
path/to/ai-review-kit/setup.sh --claude   # Claude only
path/to/ai-review-kit/setup.sh --codex    # Codex only
```

Then the manual steps the script prints:

1. **Claude:** `claude setup-token`, then
   `gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner>/<repo>`
   (or `/install-github-app` inside Claude Code).
2. **Linear-aware review (optional):** `gh secret set LINEAR_API_KEY --repo <o>/<r>`
   (a personal API key, read-only issue access, any Linear plan). The reviewer then
   fetches the ticket named in the branch/title/body (any team prefix, e.g. `KKD-6`)
   and reviews the diff against its Acceptance Criteria / Not-in-scope / Verification
   scenarios — catching "missed AC #3" and scope creep, not just code smells.
   Self-gating: no secret or no issue id → silent no-op; a Linear outage degrades to a
   normal review rather than failing CI.
3. **Codex:** install the Codex GitHub app, enable code review for the repo
   (ChatGPT → Settings → Codex → Code review). **Keep Auto review OFF** — trigger-only
   is one deterministic review per head; the loop posts `@codex review` for you.
4. **Gate (recommended):** require status check **`merge-gate`** on the default branch
   (Settings → Rulesets; private repos need Pro/Team, public free). Without it the
   status is visual — don't merge on red.
5. **Babysitter (per developer, once):** either tell Claude Code
   *"schedule a recurring task: babysit my PRs every 30 minutes"*, or cron the
   installed runner:
   `*/30 * * * * cd /abs/path/to/repo && .claude/ai-review-babysit.sh >> "$HOME/.ai-review-kit-babysit.log" 2>&1`
   Default scope: PRs you authored; `--all` covers every open PR in the repo.

## The fix loop

`setup.sh` installs the canonical playbook as `.github/ai-review-loop.md` plus a thin
Claude Code skill shim. PRs opened from Claude Code start the loop unprompted
(CLAUDE.md wiring); PRs opened any other way get picked up by the babysitter sweep.

What it does without asking: triages every finding against the actual code, fixes what
clears the worth-it bar (verification-gated — typecheck/lint/tests, exercise the flow
where tests are thin), pushes one batch per round, **replies to and resolves every
thread** (fixes, evidence-backed rejections, and not-worth-it acknowledgements alike),
re-triggers reviewers and confirms they actually ran on the head SHA. Disputed findings
are refereed by the fresh re-review (Codex reads the diff, not the replies — it can't
be lobbied).

A human hears from it ONLY on a critical escalation: a P0/P1 consensus conflict, the
round cap (3) with an open P0/P1, or an unverifiable P0/P1 fix. **It never merges.**

One identity requirement: the `gh` login that posts `@codex review` must belong to a
Codex-connected human — Codex rejects CI-bot triggers (tested live), which is why CI
cannot fire Codex and the loop/babysitter (running as you) is the trigger mechanism.

## Gotchas (learned live)

- **A green check is not a review.** The review job exits 0 even when nothing posted;
  `code-review.yml` ends with a verify step that fails unless a claude[bot] review
  exists on the head SHA. Trust the `merge-gate` status, not green job rows.
- **A PR editing `code-review.yml` is skipped by the action itself** (workflow-
  validation guard). The gate waives the Claude leg only when every changed file is
  under `.github/workflows/`; verify workflow changes on the next normal PR.
- **Codex's clean signal is the head-naming comment**, not its 👍 reaction (no GitHub
  event fires for reactions, and they aren't head-scoped).
- **merge-gate red + codex-review yellow = normal mid-review state.** Red flips green
  by itself when the clean comment lands.
- Statuses are per-commit: every push resets both legs, and the gate dismisses Claude's
  stale approval from a superseded commit.

## Files

| File | What |
|---|---|
| `workflows/code-review.yml` | Claude reviewer (+ optional Linear spec injection) + posted-review verification |
| `workflows/merge-gate.yml` | Adaptive two-leg merge gate (commit status) |
| `AGENTS.md.example` | Codex adversarial briefing with the `## Code Review Rules` contract section |
| `ai-review-loop.md` | THE canonical fix-loop playbook — installed as `.github/ai-review-loop.md` |
| `skills/pr-review-loop.md` | Thin Claude Code skill shim → the playbook |
| `babysit.sh` | Installed as `.claude/ai-review-babysit.sh` — headless sweep runner for cron (`--all` = whole team) |
| `pull_request_template.md` | Review-optimized PR structure (Summary / Scope / Trade-offs / Verification) |
| `CLAUDE.md.section` | Appended to the repo's CLAUDE.md — auto-runs the loop after Claude-opened PRs |
| `setup.sh` | One-shot installer + auth checklist |
