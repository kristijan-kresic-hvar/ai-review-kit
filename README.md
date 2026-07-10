# ai-review-kit

> **⚠️ GitHub only (for now).** Everything here runs on GitHub Actions + GitHub apps.
> Bitbucket and GitLab repos cannot use this kit — nothing in it will run there.

Two independent AI reviewers on every pull request, an autonomous fix loop that drives
their findings to convergence, and a merge-gate status that only goes green when every
reviewer **you actually have** is clean on the current head.

**The flow, once installed:** work on a feature, open a PR — reviewers fire, the loop
triages and fixes findings, resolves threads, re-reviews, and the gate flips green. The
human's entire job on a clean PR is the merge click. When the PR is opened from Claude
Code, even the loop starts unprompted (`setup.sh` wires the repo's CLAUDE.md for it).
Exceptions surface themselves; nothing else asks for attention.

- **Claude** (craftsmanship): conventions, maintainability, a11y, quality — via
  [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).
- **Codex** (adversarial): assumes the change is wrong and tries to prove it — P0/P1
  logic bugs, edge cases, security — via the ChatGPT Codex GitHub app.
- **merge-gate**: a commit status stamped on the PR head. It detects which reviewers the
  repo has and gates on exactly those. One reviewer is fine. Zero reviewers = gate stays
  out of the way.

## Prerequisites

- A **GitHub** repo (Actions enabled — the default).
- **Claude leg:** a Claude subscription with Claude Code access (the repo owner runs
  `claude setup-token` once per repo). Reviewers/teammates need nothing.
- **Codex leg:** a ChatGPT plan that includes Codex, with the Codex GitHub app
  installed on the repo.
- `gh` CLI locally only for the setup convenience steps — the workflows themselves
  need no local tooling.

Each leg is optional and independent — install what your repo's accounts support.
Cost: Claude reviews bill the repo owner's Claude subscription, Codex the ChatGPT plan;
budget roughly 2 runs per reviewer per fix round (the loop batches all of a round's
fixes into one push to keep it there).

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

From the **target repo's root**, pointing at wherever this kit lives on your disk:

```bash
path/to/ai-review-kit/setup.sh            # both legs
path/to/ai-review-kit/setup.sh --claude   # Claude only
path/to/ai-review-kit/setup.sh --codex    # Codex only
```

Or skip the script and copy by hand — it only copies files and prints the auth
checklist below. Eight pieces at most: two workflows into `.github/workflows/`,
`AGENTS.md` at the repo root, `pull_request_template.md` to
`.github/pull_request_template.md`, `ai-review-loop.md` to
`.github/ai-review-loop.md` (the canonical playbook), `skills/pr-review-loop.md` to
`.claude/skills/pr-review-loop/SKILL.md` (Claude shim), `babysit.sh` to
`.claude/ai-review-babysit.sh` (the unattended runner), and `CLAUDE.md.section`
appended to the repo's `CLAUDE.md` (Claude auto-run wiring; AGENTS.md carries the
same for other agents).

### Claude leg (per repo, once)

1. Copy `workflows/code-review.yml` to `.github/workflows/code-review.yml`.
2. Auth — either:
   - In Claude Code, run `/install-github-app` (guides app install + secret), **or**
   - `claude setup-token`, then `gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner>/<repo>`.
   One token per repo (the repo owner's Claude subscription). Reviewers need nothing.
3. No prompt tuning needed: the review prompt adapts itself — it reads the repo's
   CLAUDE.md/AGENTS.md conventions, and when AGENTS.md carries the `## Code Review
   Rules` section it automatically cedes deep bug-hunting to Codex and owns
   craftsmanship (with no Codex, it covers both roles).

#### Linear-aware review (optional)

If the repo tracks work in Linear, the Claude reviewer can also check the diff against
the **linked ticket's spec** — its Acceptance Criteria, Not-in-scope, and Verification
scenarios — so it catches "missed AC #3" and scope creep, not just code smells. One
step, zero code coupling:

    gh secret set LINEAR_API_KEY --repo <owner>/<repo>   # a Linear personal API key

The reviewer's Linear step then fetches the ticket named in the branch/PR-title/body
(any team prefix, e.g. `KKD-6`) via the Linear API and appends its spec to the review
prompt. Entirely self-gating: **no secret, or no issue id in the branch → silent no-op**,
and a Linear outage degrades to a normal review rather than failing CI. It reads issues
only (works on any Linear plan) and does *not* rely on the linkback PR comment — on
private teams that comment often carries only the bare issue key.

### Codex leg (per repo, once)

1. Install the Codex GitHub app and enable code review for the repo:
   ChatGPT → Settings → Codex → Code review (needs a ChatGPT plan with Codex).
2. Copy `AGENTS.md.example` to `AGENTS.md` at the repo root and adapt. **Keep the
   `## Code Review Rules` heading exactly** — it's both what Codex reads
   (openai/codex#25738) and what the merge-gate keys on.
3. **Leave the account's Auto review toggle OFF** (deliberate, learned live): with it
   ON, every Claude-Code-opened PR gets TWO reviews per head (the auto-run plus the
   loop's trigger), and an auto-review **clean** pass signals only a 👍 reaction — not
   the head-named comment the gate verifies — so even clean PRs need a second run to
   convert it. Trigger-only is one deterministic review per head: the loop (or the
   babysitter) posts `@codex review` for you. The bot acks triggers with a 👀 reaction
   within ~1 min; reviews land in ~5–15 min.

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
- **"Nothing new" re-review shape:** while old threads are still open, a re-review can
  land as an empty COMMENTED review — no clean comment, so the gate stays red. Resolve
  the threads per their dispositions, then fire one more `@codex review`; the clean pass
  then posts the head-naming comment the gate verifies.
- **merge-gate red + codex-review yellow = normal mid-review state.** The gate reports
  what is true *now*; the companion `codex-review` status shows in-flight. Red flips
  green by itself when the clean comment lands.
- Statuses are per-commit: every push resets both legs, and the gate dismisses Claude's
  stale approval from a superseded commit so the sidebar can't advertise an old ✓.

## The fix loop (ships with the kit — no separate install)

The CI side stops at "red until reviewed clean" — the **fix loop** drives the rest,
autonomously by design. `setup.sh` installs it into the target repo as a project-local
Claude Code skill (`.claude/skills/pr-review-loop/SKILL.md`), so anyone who opens the
repo with Claude Code has it immediately: say "run the review loop on PR <N>" or
"babysit my PRs".

What it does without asking: triages every finding against the actual code (pushing
back on wrong ones — the adversarial reviewer produces some false positives, and blind
agreement ships bugs), applies valid fixes gated by the repo's own verification —
including behavior-changing ones; the reviewers' re-run on the push is the safety net —
replies to and resolves every thread, re-triggers reviewers and confirms they actually
ran, and sweeps all your open PRs unattended. Disputed findings settle by a reviewer
consensus vote (the fresh re-review reads the diff, not the replies — it can't be
lobbied), not by a human.

A human hears from it in exactly three cases: reviewer-consensus disagreement, round
cap (3) with an open P0/P1, or a fix no runnable check can verify. Plus the merge
click — always human. **It never merges.**

### Which coding agent? Claude Code is the supported path

The reviewers are CI-side and fixed (Claude + Codex review your PR no matter what you
code with). On the developer's machine:

- **Claude Code — supported and battle-tested.** Everything in this kit ran live on
  real PRs from Claude Code. If you're on the company standard, stop reading here.
- **Codex CLI — wired, works via AGENTS.md.** The `## Pull request workflow (all
  agents)` section routes it to the same canonical playbook
  (`.github/ai-review-loop.md`), and `AI_CLI=codex` switches the babysitter runner.
  Functional but with less mileage than the Claude path.
- **Anything else — no promises.** The playbook is one plain-markdown file any capable
  agent can be pointed at (*"read .github/ai-review-loop.md and follow it"*), but
  nothing beyond Claude and Codex has been exercised. If you get another agent running
  the loop well, document it here.

One identity requirement regardless of agent: the `gh` login that posts `@codex
review` must belong to a Codex-connected human (Codex rejects CI-bot triggers —
tested live). A dev driving Codex CLI has that by definition.

### The babysitter — coverage for PRs opened ANY way

Claude's review fires on every PR regardless of origin (Actions). Codex is
trigger-only by design (Auto review stays OFF — see Codex leg setup), and a trigger
**must be authored by a Codex-connected human account** — tested live: a workflow-posted
`@codex review` from `github-actions[bot]` gets no review, only "To use Codex here,
create a Codex account and connect to github." CI therefore cannot fire Codex; the
loop and the babysitter (running under each developer's own `gh` identity) are the
trigger mechanism. (Escape hatch if a team wants true CI triggering: a dedicated
machine user with its own ChatGPT/Codex seat + a PAT secret — costs a seat, works.)

So the loop's kickoff is the only origin-dependent part:

| PR opened via | Who runs the loop | Latency |
|---|---|---|
| Claude Code | CLAUDE.md wiring — fires unprompted right after `gh pr create` | immediate |
| anything else (web UI, terminal) | the babysitter routine (below), or the next Claude Code session in the repo (session-start sweep) | up to the sweep interval |

**The routine (per developer, once):** `setup.sh` installs `.claude/ai-review-babysit.sh`
— a headless sweep runner (`claude -p` with a scoped allowlist: it can comment, resolve,
and push fixes to PR branches; it cannot merge). Wire it to cron:

    */30 * * * * cd /abs/path/to/repo && .claude/ai-review-babysit.sh >> "$HOME/.ai-review-kit-babysit.log" 2>&1

Claude Code users can skip cron and instead say once: *"schedule a recurring task:
babysit my PRs every 30 minutes"*. By default the babysitter handles PRs you authored;
`.claude/ai-review-babysit.sh --all` babysits every open PR in the repo — one
maintainer (or one always-on machine) can cover a whole team.

## Files

| File | What |
|---|---|
| `workflows/code-review.yml` | Claude reviewer + posted-review verification step |
| `workflows/merge-gate.yml` | Adaptive two-leg merge gate (commit status) |
| `AGENTS.md.example` | Codex adversarial briefing with the `## Code Review Rules` contract section |
| `ai-review-loop.md` | THE canonical fix-loop playbook — installed as `.github/ai-review-loop.md`, followed by any coding agent |
| `skills/pr-review-loop.md` | Thin Claude Code skill shim — routes Claude to the canonical playbook |
| `babysit.sh` | Installed as `.claude/ai-review-babysit.sh` — headless sweep runner for cron/manual use (`AI_CLI=claude\|codex\|<cmd>`, `--all` = whole team's PRs) |
| `pull_request_template.md` | Installed as `.github/pull_request_template.md` — review-optimized PR structure (Summary / Scope / Deliberate trade-offs / Verification), pre-filled by GitHub on every PR |
| `CLAUDE.md.section` | Appended to the target repo's CLAUDE.md — makes Claude Code fill the PR template with real content and run the loop unprompted after opening any PR |
| `setup.sh` | One-shot installer: workflows for the legs you pick + fix-loop skill + CLAUDE.md wiring, prints the auth checklist |
