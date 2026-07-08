---
name: pr-review-loop
description: Autonomous review-fix loop for ai-review-kit repos — triages AI review findings, applies verified fixes, replies/resolves threads, re-triggers reviewers, sweeps your open PRs. Use when review findings land on a PR, or when asked to "run the review loop on PR <N>" or "babysit my PRs".
---

# PR Review Loop (ai-review-kit companion)

Drive AI review findings on a PR to convergence: triage, fix, reply, resolve, re-trigger until merge-gate is green. Works on any repo using ai-review-kit (Claude + Codex reviewers, or either alone). Also runs as a sweep over all your open PRs ("babysit my PRs"). GitHub only; needs the `gh` CLI authenticated as you.

**Autonomous by design.** The loop runs without asking permission per finding — the human is an exception handler (three escalation triggers below) and the merge click, nothing else. Fixes are gated by verification and the reviewers' re-run, not by human pre-approval.

## Ground rules (non-negotiable)
- **Never merge. Never commit to the default branch.** Fixes go to the PR's own branch; the merge click stays human — it is the one control point that lets everything upstream be autonomous.
- **Every finding gets a threaded reply — no silent skips.** Fixed, disputed, or out-of-scope: the reply is the audit trail and the marker that stops the next round from re-triaging it.
- **A human comment on the PR is a directive, not a finding.** Do exactly what it says; never auto-resolve or argue with it.

## Per-PR loop

**1. Gather.**
- `gh pr view <N> --json headRefName,headRefOid,body` — capture the head SHA; every "did it actually review?" check keys off it. Read the PR description's Scope / trade-offs sections as author context.
- Inline findings, ROOT comments only (replies excluded, or later rounds re-triage your own "Fixed in…" replies as new findings):
  `gh api repos/<o>/<r>/pulls/<N>/comments --jq '[.[] | select(.in_reply_to_id == null)]'`
- Bot logins differ by API — REST returns `claude[bot]` / `chatgpt-codex-connector[bot]`, GraphQL returns them WITHOUT the `[bot]` suffix. A filter using the wrong form matches zero threads and reads real findings as absent. Accept both forms.

**2. Triage each finding against the actual code** — not the comment text. Classes: **VALID** (confirmed real), **FALSE-POSITIVE** (reviewer misread — expect some from the adversarial one), **OUT-OF-SCOPE** (real, separate ticket), **DISAGREE** (defensible choice — push back with reasoning). Verify before agreeing; performative agreement ships other people's bugs.

**3. Apply valid fixes autonomously — gated by verification, not by asking.**
- Mechanical fixes (typo, import path, config flag, a11y attribute): apply, no commentary.
- Behavior-changing fixes (logic, boundaries, contracts): apply too — but they MUST pass the repo's own verification (typecheck/lint/tests), and where tests are thin, **exercise the changed behavior directly** (run the flow, not just the compiler) before pushing. The push sends the fix back through both reviewers — that adversarial re-run is the safety net a human pre-read used to be.
- Security findings or the repo's critical paths (endpoints, auth, payments): apply + verify as above, and note it explicitly in the round's PR comment — **informing, not asking**; the loop does not stop.
- **The only fix that stops:** one you cannot verify — no runnable check exists and the behavior can't be exercised. That single finding escalates (trigger 3); the rest of the round proceeds.

**4. Reply + resolve.** Match threads on `(path, original_line)` — **`line` goes null once a fix outdates the hunk**, and matching on it silently no-ops:
- VALID → reply `Fixed in <sha> — <one line>`, resolve the thread.
- FALSE-POSITIVE / DISAGREE → reply with the pushback **and the evidence** (what you checked), leave the thread UNRESOLVED, and put it to the **reviewer consensus vote**: the fresh re-review this round is an independent second opinion (Codex reads the diff, not thread replies — it can't be lobbied). Not re-flagged next round → resolve ("pushback stood — fresh review did not re-flag"). Re-flagged → genuine disagreement between two independent AI judgments → escalate (trigger 1). **One vote per finding, ever** — a clean pass can be variance; never re-roll a re-flagged finding shopping for clean.
- OUT-OF-SCOPE → reply with the ticket reference, resolve.
- Resolve via GraphQL `resolveReviewThread`; when one file has several threads, confirm by root-comment body before resolving — a path-only match can resolve the wrong finding and hide a real one.

**5. Re-trigger and CONFIRM the reviewers actually ran.**
- Claude re-runs on the push automatically. Codex only runs when you comment `@codex review`.
- Codex acks the trigger with a 👀 reaction within ~1 min (no 👀 = re-fire); review lands in ~5–15 min. Completion shapes: findings = COMMENTED review + inline comments on the head; clean = an issue comment "Didn't find any major issues" naming the head commit; **"nothing new" while old threads are open = an empty COMMENTED review** — resolve the remaining threads per their dispositions, then fire one more `@codex review` to get the head-named clean comment the gate verifies.
- A pushback-only round (nothing fixed, nothing pushed) still needs Claude's fresh verdict for its side of a vote: push ONE empty commit (`ci: re-trigger review`) — without it the Claude leg deadlocks red.
- **Silence is not approval.** Before calling a PR clean, verify each reviewer posted on the CURRENT head SHA (`gh api repos/<o>/<r>/pulls/<N>/reviews`, check `commit_id` and the reviewer's own login). The review CI job exits 0 either way — green rows prove nothing; the `merge-gate` status is the truth.

**6. Loop.** Repeat only when a round yields new VALID findings. From round 3, only P0/P1 justifies another cycle — nits get an acknowledging reply and resolve, not a re-loop. **Round cap 3:** at the cap with an open P0/P1, escalate (trigger 2) — never report clean while a blocker is open.

## Escalation triggers — the ONLY reasons a human hears from the loop
Escalation = a threaded reply starting `escalated to human — <trigger>` (the marker later rounds key on) + a PR comment naming it; the rest of the round continues without that finding.
1. **Consensus disagreement** — a pushback'd finding re-flagged by the fresh review: two independent AI judgments conflict; only a party with no stake in closing the loop settles it.
2. **Round cap with an open P0/P1** — non-convergence; post "DO NOT MERGE — unresolved P1 at <file:line>".
3. **Unverifiable fix** — a valid finding with no runnable check and no way to exercise the behavior.

Everything else — including behavior-changing and security fixes — proceeds autonomously with the audit trail in the threads. The merge click is not an escalation; it is always human.

## Sweep mode ("babysit my PRs")
- Enumerate: `gh search prs --author "@me" --state open --json repository,number,title,isDraft --limit 30`. Skip drafts and PRs idle >14 days.
- Per PR, classify against the current head using the gate's own clean definitions, then act: unaddressed findings → run the loop above; a pushback'd thread with a completed fresh review on head → tally its consensus vote (resolve or escalate); reviewer in-flight → leave it; converged → post one "All reviewers clean on <sha> — ready for human merge" comment (skip if one already exists for this head).
- Sweep comments are **reports of what was done, never questions waiting for an answer** — the loop never parks on human input outside the three escalation triggers.
- Caps that keep an unattended sweep safe: **one un-acked Codex trigger in flight at a time** (simultaneous triggers drop silently — stagger), re-fire cap 3 per head, round cap 3 per PR, and **re-read the head SHA immediately before every posting action** — if it moved since you classified, drop the action; the next sweep reclassifies.
- Thread resolves fire no GitHub event: after resolving, refresh the gate with `gh workflow run merge-gate.yml -R <o>/<r> -f pr_number=<N>` (skip if you're about to post `@codex review` — that comment re-runs it).

## Output
One line per touched PR: what was fixed/replied/triggered, and the PR's resulting state (awaiting review / converged / escalated). Untouched PRs stay silent.
