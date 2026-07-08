# ai-review-kit

Two independent AI reviewers on every pull request, plus a merge-gate status that only
goes green when every reviewer **you actually have** is clean on the current head.

- **Claude** (craftsmanship): conventions, maintainability, a11y, quality — via
  [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).
- **Codex** (adversarial): assumes the change is wrong and tries to prove it — P0/P1
  logic bugs, edge cases, security — via the ChatGPT Codex GitHub app.
- **merge-gate**: a commit status stamped on the PR head. It detects which reviewers the
  repo has and gates on exactly those. One reviewer is fine. Zero reviewers = gate stays
  out of the way.

GitHub-only (Actions + GitHub apps). Bitbucket/GitLab repos cannot use this.

## Degradation matrix (the contract)

| Repo has | merge-gate goes green when |
|---|---|
| Claude + Codex | Claude's latest verdict on head is APPROVED **and** Codex is clean (no unresolved threads + a "didn't find any major issues" comment naming the head) |
| Claude only | Claude APPROVED on head |
| Codex only | Codex clean on head |
| Neither | Always ("no AI reviewers configured — gate not applicable") |

Detection is automatic, per repo, at gate runtime:

- **Claude leg** = `.github/workflows/code-review.yml` exists (or claude[bot] already reviewed the PR).
- **Codex leg** = `AGENTS.md` contains a `## Code Review Rules` section (or the Codex bot
  already touched the PR). Bare `AGENTS.md` presence is deliberately NOT the signal — a
  generic agent briefing without the Codex app must not red-line the gate.

Two reviewers are the recommended setup: they genuinely catch different things, and each
one reviews the other's blind spots.

## Setup

From your repo root (kit cloned as a sibling directory):

```bash
../ai-review-kit/setup.sh            # both legs
../ai-review-kit/setup.sh --claude   # Claude only
../ai-review-kit/setup.sh --codex    # Codex only
```

Or copy by hand — the script only copies files and prints the checklist below.

### Claude leg (per repo, once)

1. Copy `workflows/code-review.yml` to `.github/workflows/code-review.yml`.
2. Auth — either:
   - In Claude Code, run `/install-github-app` (guides app install + secret), **or**
   - `claude setup-token`, then `gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner>/<repo>`.
   One token per repo (the repo owner's Claude subscription). Reviewers need nothing.
3. Optional: tune the review prompt in the workflow for the repo's stack. If the repo
   also runs Codex, tell Claude so in the prompt (own craftsmanship, skip deep
   bug-hunting) — see the marked block in the file.

### Codex leg (per repo, once)

1. Install the Codex GitHub app and enable code review for the repo:
   ChatGPT → Settings → Codex → Code review (needs a ChatGPT plan with Codex).
2. Copy `AGENTS.md.example` to `AGENTS.md` at the repo root and adapt. **Keep the
   `## Code Review Rules` heading exactly** — it's both what Codex reads
   (openai/codex#25738) and what the merge-gate keys on.
3. Reviews run on PR-open / draft→ready if the account's Auto review toggle is on;
   otherwise trigger per PR with a comment: `@codex review`. The bot acks the trigger
   with a 👀 reaction within ~1 min; the review lands in ~5–15 min.

### Merge gate (per repo, once)

Copy `workflows/merge-gate.yml` to `.github/workflows/merge-gate.yml`. No secrets, no
config — it uses the built-in `github.token` and detects the legs itself.

**Promote it from advisory to enforced** (recommended wherever the plan allows —
private repos need Pro/Team; public repos free): repo Settings → Rulesets (or Branch
protection) → require status check **`merge-gate`** on the default branch. Without that,
the status is visual — don't merge on red.

## Gotchas (learned live, kept so you don't relearn them)

- **A green check is not a review.** The review job exits 0 even when nothing was
  posted; `code-review.yml` therefore ends with a verify step that fails unless a
  claude[bot] review exists on the head SHA. Trust the `merge-gate` status, not the row
  of green jobs.
- **A PR that edits `code-review.yml` is skipped by the action itself** (workflow-
  validation guard) — it runs "green" with no review, by design. The gate waives the
  Claude leg only when *every* changed file is under `.github/workflows/`; verify the
  workflow change on the next normal PR after merge.
- **Codex's clean signal is the head-naming comment** ("Didn't find any major issues" +
  the reviewed commit SHA). Its 👍 reaction is not trusted (no GitHub event fires for
  reactions, and it isn't head-scoped). Re-trigger with `@codex review` after a push.
- **merge-gate red + codex-review yellow = normal mid-review state.** The gate reports
  what is true *now*; the companion `codex-review` status shows in-flight. Red flips
  green by itself when the clean comment lands.
- Statuses are per-commit: every push resets both legs, and the gate dismisses Claude's
  stale approval from a superseded commit so the sidebar can't advertise an old ✓.

## Files

| File | What |
|---|---|
| `workflows/code-review.yml` | Claude reviewer + posted-review verification step |
| `workflows/merge-gate.yml` | Adaptive two-leg merge gate (commit status) |
| `AGENTS.md.example` | Codex adversarial briefing with the `## Code Review Rules` contract section |
| `setup.sh` | Copies the files for the legs you pick, prints the auth checklist |
