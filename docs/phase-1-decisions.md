# Phase 1 decisions

This public record preserves the controller's phase-1 decisions before the temporary implementation ledger is removed. Rulings below retain their original wording and order; the applied preflight summary records the interpretation used by the implementation. Paths are repository-relative. Physical acceptance describes the earlier app snapshot, with the lifecycle limitation disclosed in [device acceptance](phase-1-acceptance.md).

## Controller rulings, in ledger order

Ruling: Work directly on main, no worktrees — explicit user instruction — commits remain on current branch.

Ruling: Initial documents committed before implementation because repository had no HEAD — preserves provided specs — initial commit fb0e725.

Ruling: Adopt preflight R1, R3–R6, R9, R11–R13, R15–R18 — resolves concrete interface conflicts — added validation/seams may need revision in review.

Ruling: R2 preserves Task 7 completed status when correctness passes; checker rejects bad end conditions per design — avoids inventing new status semantics — app file alone is not acceptance.

Ruling: R7 uses checked arithmetic for required allocations/counts, no arbitrary new limits — prevents traps without changing valid tunables — very large valid requests may exhaust resources.

Ruling: R8 retains specified two-entry smoke plans and adds separate acceptance plans for all four variants — keeps Task 10 tests exact while covering goal — extra acceptance runtime.

Ruling: R10 implement exact stripped executable hash first; investigate actual instability in Task 15, never silently normalize — specification mandates this hash — instability may require follow-up decision.

Ruling: R14 enforce deadlines/retry limits and budget required pending work, document any added budget allowances — maintains bounded sessions — conservative profile checks may refuse early.

Ruling: Golden chronology means event order and enclosing block intervals, not increasing every tick field in file order — block line precedes its batches by schema — no change to measured chronology.

Ruling: Track executor-slot written state separately from CPU -1 — nil denotes never written — small extra storage in same aligned region.

Ruling: Async final read may follow completion barrier before task teardown — all workers stopped state mutation and reviewer verified publication — incorrect barrier would invalidate checks.

Ruling: Calibration run entry repeats=1, tunables.repeats=200 — Task9 defines measurement samples and once-per-phone intent resolves flattened Task10 bullet — if wrong changes calibration session duration but not sample semantics.

Ruling: Calibration checker requires four calibration.samples checks indexed by block, not one run-level check — Experiment.run checks each block, spec requires all samples checked and Task9 emits this — changes Task11 cardinality contract, documented and tested; if wrong downstream consumers need schema adjustment.

Ruling: Original signed apps stored in ignored build/artifacts/<buildID>, not results — signed profiles inherently contain private identifiers forbidden in results — results metadata has repository-relative app path; moving/deleting local build artifact prevents install until rebuild. No sanitized broken app copies.

Ruling: Device availability live-probed for paired devices — list tunnelState/connectionState disconnected even while lockState succeeds — extra devicectl query, avoids false refusal.

Ruling: devicectl timeout minimum is 5 seconds; for shorter requested deadlines use CLI >=5 plus subprocess deadline — live command rejects 1 — timeout result handling must preserve overall budget.

Ruling: Rebuild ios26 targeting physical iphone15 for provisioning — iphone11 build profile rejected installation on iphone15 — separate signed artifacts retained, final acceptance checks matching build identity.

Ruling: Bounded crash-report publication grace30s — observed delayed reports missed by immediate collection — adds up to30s per crashed attempt and explicit missing-report outcome.

Ruling: Require actual active lifecycle plus two post-activation frames before one-shot launch — Task7 literal frame count raced activation in all18 physical smoke starts — changes launch timing; corrected physical non-smoke lifecycle remains unverified until later device run.

Ruling: Final reviewer declined scopes remain future work: performance/pilot statistics,matchedOS27,display/8B/other experiments,traces,multi-process sessions; no additional endpoint thermal rule — phase1 scope/spec supports these exclusions — future campaigns must verify them.

## Applied preflight decisions and costs if wrong

| ID | Applied decision | Cost if wrong |
| --- | --- | --- |
| R1 | Decode safely and validate path identifiers before constructing result paths. | Diagnostics may lose request attribution; unsafe IDs would expose path traversal. |
| R2 | Preserve completed status for correct work, record end conditions, and let the checker reject unsuitable endpoints. | Consumers treating completed as accepted would misclassify work. |
| R3 | Perform primitive operations unconditionally; assert only their stored return codes. | Release synchronization would disappear if calls moved into assertions. |
| R4 | Drain submitted async writes before visibility assertions. | Tests could fail nondeterministically or overlook pending work. |
| R5 | Treat block time as diagnostic; use post-setup batch intervals for measurements. | Deriving operation cost from blocks includes setup overhead. |
| R6 | Calibration has sample-only blocks, no batches, and checks per calibration block. | Downstream consumers expecting ordinary batch cardinality need adjustment. |
| R7 | Use checked arithmetic for counts and allocations without arbitrary tunable limits. | Very large valid requests can exhaust resources. |
| R8 | Keep two-variant smoke plans and add separate four-variant acceptance plans for both targets. | Additional acceptance runtime; missing variants would leave goal coverage incomplete. |
| R9 | Validate statuses, identities, grouping, counters, thread/CPU/sample layouts, and strictly positive batch intervals. | Overstrict rules could reject valid files; weak rules admit corrupt work. |
| R10 | Hash the exact executable after signature removal; investigate actual instability rather than normalize silently. | Nondeterministic binaries can require a new policy; stable evidence applies only to the recorded source snapshot. |
| R11 | Keep signed apps and original diagnostics private; publish scrubbed diagnostics and relative metadata paths. | Redaction can remove useful context; missed identities would leak private data. |
| R12 | Capture CLI fixtures first, recognize expected missing-file/timeouts, and retain crash modification times. | CLI variations may need new fixtures; wrong timestamps miss or misattribute crashes. |
| R13 | Inject device/doctor/process dependencies and always clean up caffeinate. | Fake tests could touch real tools if seams are bypassed; leaked processes waste power. |
| R14 | Use one monotonic deadline before launch through await/polling, preserve timeout precedence, bound retries, and budget pending work. | Conservative budgets may refuse early; resetting timeouts permits overruns. Cleanup and crash-publication grace add bounded time after the run deadline. |
| R15 | Require stable CPU observations and complete coverage before deriving a core map. | Sparse calibration may be refused instead of producing a misleading map. |
| R16 | Embed build identity through Info.plist settings before signing rather than generated source. | Tools expecting generated identity symbols would need adaptation. |
| R17 | Inspect all source specializations but allow explained compiler merging/removal; keep timed loops natural. | Missing optimization differences could escape inspection; forcing symbols would distort measurements. |
| R18 | Inject Release BuildInfo into the thermal-refusal test while keeping production configuration refusal. | A stale injected build could hide incorrect test setup; real build checks remain required. |

The final lifecycle correction replaces Task 7's literal second-display-callback launch with actual application and foreground-scene activation followed by two active display callbacks. An interrupted activation resets the delay; launching consumes the request once. The hard non-smoke preflight conditions remain authoritative. Simulator ordering coverage verifies this correction; physical non-smoke lifecycle verification is pending.

Build commands now reject a caller outside the repository root before executing any command or creating scratch files. This enforces the documented root-only workflow for git queries, project generation, build, and settings collection together. If that contract is too restrictive, callers must change directory before invoking build.

Cross-review corrections approved on 2026-11-05: synchronous read timing omits executor probes and pending-write drains; mutations retain timed completion and executor observations, and actor/MainActor reads retain required executor sampling. The original device smoke remains functional evidence, not unbiased read timing.

Thermal refusal allowance is per run within each session (initial attempt plus `maxThermalRetries`); all attempts remain recorded and numbered across sessions. A fresh session may retry a cooled phone, and doctor budgets that fresh allowance for each pending run. Ordinary `maxAttempts` remains unchanged.

Run state now separates clean and dev eligibility in addition to plan, phone, and code hash. Legacy state without an eligibility marker remains untouched but receives no progress credit because its eligibility is unknown. Fresh runs are required; guessing eligibility could silently finish a clean campaign using dev work.
