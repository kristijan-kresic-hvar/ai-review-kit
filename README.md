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

- **7 real PRs driven end-to-end** on a production repo: findings → verified fixes →
  every thread replied + resolved → re-review → gate green → human merge. Two PRs went
  6 adversarial rounds each (~50 findings total triaged against the code — fixed or
  rebutted with evidence, none blindly accepted). One of those bought the playbook its
  shrink-only rule: fix rounds that ADD code hand the next round fresh attack surface.
- **Gate scenario matrix 6/6** on a throwaway repo: no-reviewers green, silent-reviewer
  red, workflow-only waiver + zero-reviewer guard, on-head Codex detection,
  `workflow_dispatch` re-eval (flipped a stale green after config changed under it),
  `issue_comment` re-eval.
- **Committed smoke test** (`test/smoke.sh`, no framework, no network): drives a real
  babysitter sweep with stubbed `gh`/agent in a throwaway repo — worktree isolation,
  checkout-stays-clean, single-flight lock, arg validation. Run it before trusting a
  kit change. (Dev-time-only checks that shipped earlier versions — setup variants,
  Linear degradation paths, injection attempts — were run by hand, not committed.)
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
| Claude + Codex | Claude clean (APPROVED on head + no unresolved Claude threads) **and** Codex clean (no unresolved Codex threads + a current "didn't find any major issues" comment naming the head) |
| Claude only | Claude APPROVED on head + no unresolved Claude-rooted threads |
| Codex only | Codex clean on head |
| Neither | Always ("gate not applicable") |

Detection is automatic, per repo, at gate runtime: Claude leg =
`.github/workflows/code-review.yml` exists on the PR's base branch or head (or
claude[bot] already reviewed the PR); Codex leg = `AGENTS.md` contains a
`## Code Review Rules` section on the base branch or head (or the Codex bot
already touched the PR). Bare AGENTS.md presence is deliberately NOT the signal.

Two blockers apply to every green, whatever the legs: review artifacts must postdate
the PR's last base retarget (retargeting keeps the head SHA while the effective diff
changes), and an unresolved thread carrying an `escalated to human` reply keeps the
gate red until the human answers.

**Fork PRs are unsupported for auto-review:** the review action can't read the token
secret on forks, so the gate goes red with a fork note — maintainer reviews manually
and merges via the web UI.

## Setup

Clone the kit once, then run the installer from each **target repo's root**:

```bash
git clone https://github.com/kristijan-kresic-hvar/ai-review-kit.git

cd <your-repo>
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
   **Multi-author repos:** the ticket id is author-controlled and the key fetches any
   ticket it can see — set the repo variable `LINEAR_TEAM_KEYS` (space-separated team
   prefixes, e.g. `"KKD OPS"`) to fence which tickets a PR can pull into review
   output, and prefer a least-privilege key over a personal one.
3. **Codex:** install the Codex GitHub app, enable code review for the repo
   (ChatGPT → Settings → Codex → Code review). **Keep Auto review OFF** — trigger-only
   is one deterministic review per head; the loop posts `@codex review` for you.
4. **Gate (recommended):** require status check **`merge-gate`** on the default branch
   (Settings → Rulesets; private repos need Pro/Team, public free). Without it the
   status is visual — don't merge on red. In the ruleset, pin the required check's
   **source to the GitHub Actions app**: a commit status is writable by any integration
   with statuses permission, and an unpinned context could be spoofed green by another
   app. Enable "require conversation resolution" too if the plan offers it. Also
   **block direct pushes to the default branch** in the same ruleset — that server-side
   rule, not the babysitter's deny list (string patterns, defense-in-depth only), is
   the real never-push-to-default boundary.
   **Multi-author honesty:** like any `pull_request` workflow, GitHub runs the gate
   from the PR branch's OWN copy of `merge-gate.yml` — so a same-repo PR can edit the
   gate and stamp its own green, and CODEOWNERS (which gates *merging*, not workflow
   *execution*) does not stop that. This is inherent to the `pull_request` trigger and
   the kit does not claim to close it. Solo, the "attacker" is whoever clicks merge —
   a non-issue. On a shared repo, treat `merge-gate` as a correctness aid, not a
   security boundary against a malicious collaborator: the real controls are branch
   protection requiring human review + not merging on red. A repo needing a
   tamper-proof gate wants a required check that runs from trusted (default-branch)
   code — outside this kit's scope.
5. **Babysitter (per developer, once) — cron is the recommended path:**
   ```bash
   cd <your-repo> && path/to/ai-review-kit/babysit.sh --install-cron   # idempotent
   ```
   That schedules a sweep every 30 min, running from your kit clone (scripts are
   deliberately not vendored into repos — one executable home, no drifting copies). Prompt-free by construction (permissions
   decided at launch: explicit allowlist + hard deny-layer, including this repo's
   actual default branch in the push denies), agent-agnostic via
   `AI_CLI`, single-flight locked, and desktop notifications via the bundled
   `ai-review-notify.sh` helper. Default sweep scope: PRs you authored; `--all`
   covers every open PR in the repo. The sweep never touches your checkout: it runs
   the agent inside a disposable worktree checked out from origin's default branch
   (policy/settings come from origin, not local state), and all runtime state (lock,
   notify marker, worktree) lives under `~/.cache/ai-review-kit/` — your tree can be
   dirty, mid-rebase, or on any branch; the sweep neither reads nor blocks on it.
   (Do NOT use a Claude Code scheduled task for this — it runs under interactive
   permission settings, prompts on anything not pre-allowed, and doesn't take the
   script's lock.)

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

## Portability — new machine, any OS, any teammate

Everything is plain bash + the `gh`/`claude` CLIs — nothing is tied to one machine.
Full bootstrap on a fresh box:

1. **Install the CLIs:** [`gh`](https://cli.github.com) (any OS),
   [`claude`](https://claude.com/claude-code) (macOS/Linux/Windows), `jq`, `git`, bash.
2. **Authenticate as yourself:** `gh auth login`, `claude` (login once interactively).
   Secrets (`CLAUDE_CODE_OAUTH_TOKEN`, `LINEAR_API_KEY`) live in the GitHub repo —
   nothing secret is stored on the machine beyond your own CLI logins.
3. **Clone the kit** and run `setup.sh` in each target repo (idempotent — re-running
   on an already-installed repo is safe and refreshes the copied files).

   > **Keeping installed repos in sync.** `merge-gate.yml` and `code-review.yml` are
   > GitHub **Actions workflows** — GitHub only runs a workflow that physically lives
   > in the repo's own `.github/workflows/`, so unlike `babysit.sh` (which runs from
   > the kit clone) they MUST be vendored copies. The canonical source is this kit's
   > `workflows/`; each installed repo holds a copy that goes stale when the kit
   > updates. **When the kit's workflows change, re-run `setup.sh` in every installed
   > repo to re-copy them** — don't hand-edit a repo's copy (that fork drifts and
   > re-introduces bugs already fixed upstream). `git diff --stat` after a re-run shows
   > what changed.
4. **Schedule the babysitter** — from the repo root, invoking YOUR KIT CLONE
   (the scripts are deliberately not vendored into repos — one executable home,
   no drifting copies): `path/to/ai-review-kit/babysit.sh --install-cron`
   (idempotent; add `--all` for team scope) — it picks the right scheduler per OS:
   - **macOS → LaunchAgent, deliberately NOT cron:** `gh` and `claude` keep their
     credentials in the login Keychain, which plain cron's session cannot access —
     a cron-scheduled sweep dies with HTTP 401 (observed live). The LaunchAgent runs
     inside your GUI session where the Keychain works, fires every 30 min plus once
     at install (self-verifying).
   - **Linux → crontab** (credentials are file-based; cron is fine).
   - **Windows:** run the whole flow under **WSL** (then it's the Linux path), or
     native Task Scheduler:
     `schtasks /Create /SC MINUTE /MO 30 /TN ai-review-babysit /TR "bash -lc 'cd /path/to/repo && /path/to/ai-review-kit/babysit.sh >> ~/.ai-review-kit-babysit.log 2>&1'"`
   - Schedulers only fire while the machine is awake; missed ticks are harmless —
     the sweep is stateless and the next tick reconciles from GitHub. Desktop
     notifications degrade per OS: macOS `osascript` → Linux `notify-send` → log line.

Per-teammate: each developer repeats steps 1–2 + 4 on their machine (the repo-side
install from step 3 is shared, committed once). One always-on machine running the
babysitter with `--all` can cover a whole team instead.

## Which coding agent do you develop with?

The CI side is agent-agnostic — Claude and Codex review your PRs no matter what you
code with. Only the fix loop's kickoff depends on your agent:

- **Claude Code — supported, battle-tested.** Everything in the Status section ran
  from Claude Code: CLAUDE.md wiring auto-runs the loop after every PR, the skill shim
  routes it to the playbook, and the babysitter's headless runs carry a hard
  deny-layer (no merge, no default-branch push, no method-flag API mutations).
- **Codex CLI — wired, lightly tested.** The `## Pull request workflow (all
  agents)` section of AGENTS.md routes it to the same playbook, and `AI_CLI=codex`
  switches the babysitter to `codex exec --full-auto`. Smoke-tested live: an idle
  sweep works out of the box (the sandbox blocks `gh`'s network; Codex degrades to
  its own GitHub connector, keeps the repo scope, exits quietly). Two honest
  caveats: ACTIVE fix rounds need your Codex config to allow gh/git network, and the
  never-merge/never-main rules are prompt-level there (no deny-list equivalent —
  Codex's sandbox is your guardrail). Verify one fix round interactively before cron.
- **Anything else** — the playbook is one plain-markdown file any capable agent can
  be pointed at (*"read `.github/ai-review-loop.md` and follow it"*). Unsupported,
  no promises; `AI_CLI=<cmd>` runs it verbatim.

## Gotchas (learned live)

- **A green check is not a review.** The review job exits 0 even when nothing posted;
  `code-review.yml` ends with a verify step that fails unless a claude[bot] review
  exists on the head SHA. Trust the `merge-gate` status, not green job rows.
- **A PR editing `code-review.yml` is skipped by the action itself** (workflow-
  validation guard). The gate waives the Claude leg only when that PR is ALSO
  workflow-only (every changed file under `.github/workflows/`) — a code+workflow
  bundle goes red ("split the PR"). Verify workflow changes on the next normal PR.
- **Codex's clean signal is the head-naming comment**, not its 👍 reaction (no GitHub
  event fires for reactions, and they aren't head-scoped).
- **merge-gate red + codex-review yellow = normal mid-review state.** Red flips green
  by itself when the clean comment lands.
- Statuses are per-commit: every push resets both legs, and the gate dismisses Claude's
  stale approval from a superseded commit.
- **launchd loads invalid XML.** A plist with a raw `&&` bootstrapped and ran for hours
  while `plutil` and `xmllint` both rejected it — parser leniency, not spec. The
  installer now lints before loading; never trust "it loaded" as "it's valid".
- **An allowlisted script inside a writable checkout is a self-rewritable approved
  command** — the headless agent has `Write`, so it could replace the script's content
  and invoke it via the approved path. That's why notifications use a marker FILE the
  launcher delivers via a pre-run read-only snapshot; the agent controls text, never code.
- **macOS cron cannot reach the login Keychain** where `gh`/`claude` keep credentials —
  every cron sweep died with HTTP 401 while the same command worked in a terminal.
  `--install-cron` uses a LaunchAgent on macOS for exactly this reason.
- **The gate evaluates on the PR HEAD commit, not the test-merge commit.** Two things
  follow. (1) Right after you retarget a PR, a review run that started pre-retarget can
  post within the cancellation grace and read as current until the fresh re-review
  lands — don't merge in those minutes (review objects carry no base identity, so this
  can't be closed artifact-side). (2) If the BASE branch advances while a PR sits
  approved, the effective merge changes without moving the head — the gate won't
  re-fire on its own — and no passive event re-reviews it (a comment or review only
  re-runs the gate, which re-greens the same reviews on the same head). Push an empty
  commit to force a fresh review before merging a long-open PR whose base has moved.
  A fully base-aware gate would evaluate on `refs/pull/N/merge` — a larger rework,
  outside this version.
- **Two open PRs sharing one head commit** (same branch, different bases) can't be
  told apart by the shared commit status — the gate detects the collision and forces
  both red; merge via the web UI after checking each PR's own reviews.
- **Title/body edits don't re-trigger review** (only base retargets do) — deliberate:
  the description is context, and the reviewers are told the diff is the truth when
  they conflict. Rewriting the description after approval changes prose, not the
  reviewed code.

## Files

| File | What |
|---|---|
| `workflows/code-review.yml` | Claude reviewer (+ optional Linear spec injection) + posted-review verification |
| `workflows/merge-gate.yml` | Adaptive two-leg merge gate (commit status) |
| `AGENTS.md.example` | Codex adversarial briefing with the `## Code Review Rules` contract section |
| `ai-review-loop.md` | THE canonical fix-loop playbook — installed as `.github/ai-review-loop.md` |
| `skills/pr-review-loop.md` | Thin Claude Code skill shim → the playbook |
| `babysit.sh` | Headless sweep runner — runs from the kit clone, never vendored (`--install-cron` schedules it; `--all` = whole team) |
| `pull_request_template.md` | Review-optimized PR structure (Summary / Scope / Trade-offs / Verification) |
| `CLAUDE.md.section` | Appended to the repo's CLAUDE.md — auto-runs the loop after Claude-opened PRs |
| `setup.sh` | One-shot installer + auth checklist |
| `test/smoke.sh` | Stubbed end-to-end babysitter smoke test (isolation, lock, arg handling) |

## License

MIT — see [LICENSE](LICENSE).
