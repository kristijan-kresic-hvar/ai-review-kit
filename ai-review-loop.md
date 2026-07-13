
# AI Review Loop — canonical playbook (any coding agent)

The single source of truth for driving this repo's AI reviews to convergence. Claude
Code loads it via the project-local skill shim; other agents are pointed here by
AGENTS.md or told "read .github/ai-review-loop.md and follow it". The reviewers
(Claude + Codex) run in CI regardless of which agent you code with.

**Autonomy contract.** The loop runs without asking permission. The human does exactly
two things: the merge click, and answering a **critical escalation** (defined below).
Everything else — including behavior-changing and security fixes — the loop decides,
applies, verifies, and reports. When multiple defensible options exist, pick the safer
one and say so in the reply; never park the loop on a question a competent engineer
could settle.

## Ground rules (non-negotiable)
- **Never merge. Never commit to the default branch.** Fixes go to the PR's own branch.
- **Every thread gets a reply AND gets resolved — with ONE exception.** Fixed,
  rejected, out-of-scope, or not-worth-it: the reply states the disposition with its
  evidence, then the thread is resolved. The exception: a thread **escalated to the
  human stays UNRESOLVED** — it is the machine-visible merge blocker that keeps the
  gate red until the human answers. Any other open thread after a round means the loop
  hasn't processed it yet.
- **A human comment on the PR is a directive, not a finding.** Do exactly what it says;
  never auto-resolve or argue with it.
- **Abort any PR that is not OPEN and non-draft** — re-check at the top of every round
  (`gh pr view <N> --json state,isDraft,headRefOid`); a human can merge/close mid-loop.

## Per-PR loop

**1. Gather.**
- **Discover which reviewers THIS repo has — the gate's own signals:** Claude leg =
  `.github/workflows/code-review.yml` exists (or claude[bot] already reviewed this PR);
  Codex leg = `AGENTS.md` contains a `## Code Review Rules` section **on the default
  branch OR the PR head** (or the Codex bot already touched this PR) — same dual probe
  as the gate, or a PR that removes the section deadlocks red with no trigger. Run the
  loop against exactly the legs that exist — never wait on, and never trigger, a
  reviewer that isn't configured (it can't "go silent"; it was never installed).
  **Claude-leg waiver:** when the PR touches `code-review.yml` itself AND every
  changed file is under `.github/workflows/`, the review action skips itself and the
  gate waives the Claude leg — treat it as not-applicable (no wait, no nudge). A
  workflow-only PR that does NOT touch `code-review.yml` is reviewed normally; the
  self-skip is specific to the review workflow changing.
- `gh pr view <N> --json state,isDraft,headRefName,headRefOid,body` — capture the head
  SHA; every "did it actually review?" check keys off it. Read the description's
  Scope / trade-offs sections as author context.
- **Threads via GraphQL** (this is what makes rounds and sweeps idempotent — REST
  comments carry no resolution state):
  ```
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){totalCount nodes{id isResolved isOutdated path line originalLine root: comments(first:1){nodes{databaseId body author{login}}} latest: comments(last:10){nodes{databaseId body author{login} createdAt}}}}}}}' -F o=<o> -F r=<r> -F n=<N>
  ```
  (`root` identifies the finding; `latest` is what the rebuttal/escalation rules below
  read — a `first:N` slice alone hides the newest replies on long threads, exactly
  where a human blocker sits.)
  **`totalCount` > 100 → stop: the page is not the PR.** Unresolved findings past the
  first page are invisible — never classify, resolve, or converge such a PR; surface
  "too many review threads to verify" instead (the gate fails closed at the same cap).
  Triage ONLY `isResolved == false` threads. A resolved thread is a processed finding —
  match any re-flag against resolved ones on (path, originalLine, gist), and a match is
  NOT a fresh finding to re-triage: it is the referee verdict on that disputed finding
  — apply step 4's re-flag rule to it (P0/P1 → escalate; below → cheap fix or final
  resolve). Never silently drop it.
  **Rebuttal exception:** a non-self reply NEWER than your last disposition reply in
  any thread (open or resolved) is live input — a human's is a directive; a reviewer's
  is a finding to re-triage. Never re-assert a prior disposition over a rebuttal.
  Escalated threads follow the same precedence: leave one alone ONLY while its latest
  reply is your own `escalated to human` marker — a HUMAN reply after the marker IS the
  answer the escalation was waiting for: obey it, then resolve the thread (which lifts
  the escalation's merge block).
- **Summary findings too:** `gh api --paginate repos/<o>/<r>/issues/<N>/comments` and
  the review bodies (`gh api --paginate repos/<o>/<r>/pulls/<N>/reviews`) — bot verdict
  bodies can carry findings with no inline thread; humans comment directives there.
  Always `--paginate`: a first-page-only read hides late findings and human directives
  on busy PRs. (gh rejects `--slurp` combined with `--jq` — pipe to `jq` instead.)
  **Current-head artifacts only:** triage a bot's body findings solely from its LATEST
  review / most recent head-relevant comment — findings in superseded-head artifacts
  are history (fixed or restated by the fresh review), and your own posted disposition
  comments are processed-markers, not findings. Human directives have no head: obey
  them whenever unanswered.
- Bot logins differ by API: REST returns `claude[bot]` / `chatgpt-codex-connector[bot]`,
  GraphQL returns them WITHOUT `[bot]`. Accept both forms or you'll match zero threads
  and read real findings as absent.
- Wait for every CONFIGURED reviewer to have posted on the current head before triaging
  (they finish at different times) — triaging a partial set converges early. Bound the
  wait: ~20 min past a confirmed ack/push, then treat the reviewer per its dead-leg
  rule (step 5) instead of waiting forever.

**2. Triage each finding against the actual code** — not the comment text. Verify
before agreeing; performative agreement ships other people's bugs. Classes:
- **VALID, worth fixing** — real, and fixing it improves the PR.
- **VALID, not worth it** — technically right but churn without payoff (style
  preference, speculative hardening, nit below the repo's bar). The smart-filter class:
  reviewers always find *something*; the loop converges on importance, not on silence.
- **FALSE-POSITIVE / DISAGREE** — reviewer misread, or the choice is defensible.
- **OUT-OF-SCOPE** — real, belongs in its own ticket.

**3. Apply the worth-it fixes autonomously — gated by verification, not permission.**
- Mechanical fixes: apply, no commentary.
- Behavior-changing fixes: apply, but they MUST pass the repo's verification
  (typecheck/lint/tests), and where tests are thin, exercise the changed behavior
  directly before pushing. The reviewers' re-run on the push is the safety net.
- Security / critical-path fixes: apply + verify, and note it in the round's PR comment
  — informing, not asking.
- Batch the round's fixes into ONE push (each push burns a review run per reviewer).
- **Fix rounds SHRINK the diff, never grow it.** A valid finding whose fix needs new
  functionality, new files, or a redesign gets the minimal in-PR remedy (or none) plus
  its own follow-up PR/ticket, stated in the reply. Growing a PR mid-review hands the
  next round fresh attack surface — that treadmill is how PRs never converge (observed
  live: a 3-line docs PR absorbed an evolving script and ate five review rounds).
  Escalation answers follow the same rule.

**4. Reply + resolve every non-escalated thread.** Match threads on
`(path, original_line)` — `line` goes null once a fix outdates the hunk. When one file
has several threads, confirm by root-comment body before resolving — a path-only match
can resolve the wrong finding.
- VALID fixed → `Fixed in <sha> — <one line>`, resolve.
- VALID not-worth-it → one line on why it doesn't clear the bar, resolve.
- FALSE-POSITIVE / DISAGREE → the pushback WITH evidence (what you checked), resolve.
  The fresh re-review is the referee: Codex reads the diff, not thread replies — it
  can't be lobbied. If the NEXT review re-flags the same finding (new thread, same
  path/gist): P0/P1 → escalate (trigger 1); below that → accept the cheap fix if one
  exists, else reply "second flag, still disputed — not re-looping" and resolve. One
  referee round per finding, ever — never re-roll shopping for a clean pass.
- OUT-OF-SCOPE → file the ticket, reply with its id, resolve.
- **Findings with no thread** (verdict-body / issue-comment findings): disposition via
  `gh pr comment` — there is nothing to resolve.
- Resolve via GraphQL `resolveReviewThread` (thread `id` from step 1's query). Resolves
  fire NO GitHub event — afterwards refresh the gate:
  `gh workflow run merge-gate.yml -R <o>/<r> -f pr_number=<N>` (skip if you're about to
  post `@codex review`, which re-runs it anyway).

**5. Re-trigger every configured reviewer and CONFIRM it actually ran.**
- **Order: push first, then trigger.** Any commit this round (fix batch or empty
  re-trigger) must land BEFORE `@codex review` fires, so the clean comment names the
  final head — a clean comment on a superseded head buys nothing.
- Claude re-runs on the push automatically. Codex runs ONLY on an `@codex review`
  comment, and the `gh` login posting it must be a **Codex-connected human account** —
  Codex silently rejects CI-bot triggers (tested live).
- Codex acks with a 👀 reaction within ~1 min (no 👀 = re-fire; cap 3 per head), review
  lands in ~5–15 min. One un-acked Codex trigger in flight at a time — simultaneous
  triggers drop silently. **At the re-fire cap with no ack (dead leg):** post ONE
  "Codex unresponsive — adversarial pass unverified, DO NOT merge" comment (dedupe per
  head) + notify, then leave the PR; a new push resets the cap.
- Codex completion shapes: findings = COMMENTED review + inline comments on head;
  clean = issue comment "Didn't find any major issues" naming the head commit;
  "nothing new" while old threads were open = an EMPTY COMMENTED review — resolve the
  remaining threads, then fire one more `@codex review` to get the head-named clean
  comment the gate verifies.
- A pushback-only round (no fixes to push) still needs fresh verdicts: push ONE empty
  commit (`ci: re-trigger review`) — without it the Claude leg deadlocks red.
- **Silence is not approval — and each leg has its own CLEAN artifact.** Verify per
  leg on the CURRENT head: **Claude clean** = the LATEST claude[bot] review with
  `commit_id` == head has state APPROVED (`gh api --paginate
  repos/<o>/<r>/pulls/<N>/reviews` — reviews are chronological, take the last; a
  COMMENTED or CHANGES_REQUESTED latest is not clean). **Codex clean** = the
  head-naming "didn't find any major issues" ISSUE comment AND zero unresolved Codex
  threads — a COMMENTED review is the FINDINGS artifact, never a clean signal, and a
  clean Codex pass posts NO review at all, so checking `pulls/<N>/reviews` for it reads
  clean as silent and re-triggers forever. Green job rows prove nothing — the review
  job exits 0 whether or not a review was posted; the `merge-gate` status is the truth.

**6. Loop.** Repeat only when a round yields new VALID-worth-it findings. **Round cap:
3 per PR, not per head** — count your own `Fixed in …` reply rounds across the whole
PR; a per-head count resets on every push and never binds. At the cap with an open
P0/P1, escalate (trigger 2) — never report clean while a blocker is open.
**Converged** = every configured reviewer clean on head AND no `escalated to human`
thread awaiting an answer → post one "All reviewers clean on <sha> — ready for human
merge" comment (skip if one exists for this head) and notify the human. An open
escalation always blocks the converged claim, whatever the reviewers say.

## Critical escalation — the ONLY reasons a human hears from the loop
Escalation = a threaded reply starting `escalated to human — <trigger>` + a PR comment
naming it + a notification. **The escalated thread stays UNRESOLVED** (the ground-rule
exception) so the gate stays red until the human answers — in-thread or by resolving
it. Later rounds and sweeps leave escalated threads alone. The rest of the round
continues without that finding.
1. **P0/P1 consensus conflict** — an evidence-backed pushback re-flagged by the fresh
   review, on a finding that would block the merge. Two independent AI judgments
   disagree on a critical; only a party with no stake settles it.
2. **Round cap with an open P0/P1** — non-convergence; post "DO NOT MERGE — unresolved
   P1 at <file:line>".
3. **Unverifiable P0/P1 fix** — no runnable check exists and the behavior can't be
   exercised. (An unverifiable nit is just not-worth-it: acknowledge, resolve.)

Not escalations: choosing between two workable fixes (pick the safer, note it),
nit-level disagreements (resolve with reasoning), security fixes that verify clean
(apply + FYI). The merge click is not an escalation; it is always human.

## Sweep mode ("babysit my PRs")
- Enumerate: `gh search prs --author "@me" --state open --json repository,number,title,updatedAt,isDraft --limit 30`.
  Default scope is your PRs across repos; when the caller supplies a narrower scope
  (the babysitter runs per-repo, optionally `--all` authors within it), honor that.
  Skip drafts and PRs idle >14 days. Skip repos with no configured AI reviewers.
  **Every follow-up command carries `-R <owner>/<repo>` from the search result's
  `repository` field** — a bare `gh pr view <N>` resolves N against the current
  working directory's repo and can act on the wrong PR entirely.
- Per PR, classify against the current head with the gate's own clean definitions:
  - **Unprocessed findings on head** (unresolved non-escalated threads, or un-replied
    body findings) → run the per-PR loop above.
  - **Reviewer in flight** (👀 ack, or <20 min since push) → leave it. Never act while
    any reviewer is mid-review on the head — triage the complete set once.
  - **Codex trigger needed** (>20 min since push, no ack) → fire it, respecting the
    caps and dead-leg rule above.
  - **Claude leg unmet with zero open findings** (no review on head, COMMENTED-only,
    or CHANGES_REQUESTED with every thread already dispositioned) → push ONE empty
    nudge commit `ci: nudge claude re-review`. **Stateless cap: before nudging, check
    the branch log for a prior own nudge commit — one exists → post one
    surfacing comment (dedupe per head) + notify and leave the PR instead.** (The
    nudge message is deliberately distinct from `ci: re-trigger review` so the two
    caps never confuse each other.)
  - **Escalation pending** (a thread whose latest self-reply starts
    `escalated to human`, unanswered) → leave the PR; it is the human's move.
  - **Converged** (per step 6's definition, including the no-open-escalation check) →
    post the one-time ready-for-merge comment + notify.
- **Re-read the head SHA immediately before every posting action** — if it moved since
  classification, drop the action; the next sweep reclassifies. Classification data
  expires (observed live: a stalled sweep posted "converged" on a superseded head).
- Sweep output: one line per touched PR; untouched PRs are silent. Reports, never
  questions — the loop parks on nothing except a critical escalation. **Unsure whether
  acting is appropriate** (odd repo state, apparent test fixtures, a PR outside every
  bucket): SKIP it with a one-line reason in the report and move on — never end a
  sweep with "say go" or any other question; an unattended run has no one to answer.

## Output
One line per touched PR: what was fixed/replied/triggered, and the resulting state
(awaiting review / converged / escalated).
