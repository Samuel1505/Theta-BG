# Limitations

Stated explicitly, per the build brief's own instruction not to hide
weaknesses. This is the honest boundary of what this codebase currently
does — see `V4_ARCHITECTURE_VALIDATION.md` and `SECURITY.md` for the
reasoning behind each.

## Scope of detection

- **Same-block only.** A back-run landing in the next block is never
  detected (`test_backRunNextBlock_doesNotSlash`,
  `SandwichPredicate.t.sol::test_backRunInNextBlock_notDetected`). Cross-block
  MEV is out of scope entirely.
- **Never "same-transaction."** Corrected from the original brief's
  transient-storage design — see `V4_ARCHITECTURE_VALIDATION.md §2`.
- **JIT liquidity attacks and LVR are out of scope.** The predicate looks at
  swap sequences only; it has no visibility into liquidity-provision timing
  as an attack vector in itself (only as an *accounting* concern for
  distributing insurance, which is a different problem — see "flash
  liquidity at slash time" below).
- **Pattern detection, not intent proof.** See `MECHANISM.md` §"What this
  predicate is, and is not, proof of."
- **Ring-buffer eviction defeats detection — verified, not hypothetical.**
  The 3-slot ring buffer only ever holds the *last three* swaps in a pool.
  One interstitial swap between the victim and back-run legs evicts the
  front-run record, so condition 1 (`a.sender == c.sender`) never matches.
  Confirmed by an actual passing/failing test pair in
  `test/ThetaBGAdversarial.t.sol`
  (`test_attack_ringBufferEviction_decoySwapDefeatsDetection` vs.
  `test_attack_ringBufferEviction_controlWithoutDecoy_doesSlash`), not just
  reasoned about. See `SECURITY.md` §"Searcher" for the write-up and why it
  isn't mitigated in this build (gas cost of unbounded per-block history vs.
  DoS risk of a buffer size an attacker could manipulate the growth of).

## Identity model

- **Searcher identity = direct `PoolManager.swap()` caller.** A searcher
  routed through an aggregator or shared router is invisible to the bonded
  lane entirely — their swap is just treated as ordinary flow. This is a
  deliberate restriction (`V4_ARCHITECTURE_VALIDATION.md §1`), not an
  oversight, but it does mean the bonded lane only ever covers searchers
  who call `PoolManager` (or their own dedicated contract) directly.

## LP accounting

- **Pool-wide, in-range-only weighting — not per-tick-range precision beyond
  what `StateLibrary.getLiquidity()` already gives.** LPs are rewarded in
  proportion to their liquidity units, matching exactly how Uniswap's own
  fee-growth accounting weights positions — this is the standard, not a
  simplification below it.
- **Zero-in-range-liquidity-at-slash-time is not retroactively distributed**
  once liquidity returns (`MECHANISM.md` §"the zero-liquidity edge case").
  Funds sit as `idleAssets`, fully claimable in principle but with no LP
  attribution mechanism for that specific slash.
- **Flash liquidity at slash time** can capture a disproportionate share of
  one specific slash (`SECURITY.md` §"LP" — disclosed, not mitigated in this
  build).
- **No cross-pool LP test exists yet**, though the state is structurally
  isolated per `PoolId` throughout.

## Economic parameters

- **Immutable, hook-wide, set once at deployment.** There is no per-pool
  override mechanism. A hook deployment serving many pools with very
  different volatility profiles uses the same
  `restorationThresholdBps`/`minDisplacementBps`/`priorityFeeBps` for all of
  them. Adding per-pool configuration was considered and rejected for this
  build because every mutable-parameter design introduces an
  owner/admin-controlled surface, which section 37/38 of the build brief
  explicitly asks to avoid — a future version could allow per-pool
  configuration *fixed permanently at that pool's initialization* (still no
  runtime mutability) without reintroducing admin trust.
- **Bond sizing is a deployment-time risk decision, not something the
  protocol enforces** — see `MECHANISM.md` §"Bond sizing is a configuration
  choice, not a guarantee."

## Priority fee

- **Exact-input swaps only.** Exact-output swaps pay no priority fee (the
  fee-collection code path in `ThetaBGHook.beforeSwap` is gated on
  `params.amountSpecified < 0`). Extending this to exact-output swaps is
  possible but requires careful handling of the specified-currency direction
  under `HookDeltaExceedsSwapAmount`'s sign constraints
  (`V4_ARCHITECTURE_VALIDATION.md §3`) and wasn't necessary for the core
  demonstration.

## Testing

This build ships 251 passing tests across 8 suites:

- `SandwichPredicate.t.sol` (53) — pure predicate unit + fuzz tests,
  including monotonicity/antitonicity invariants on the threshold
  parameters and a "whenever detected, all five conditions independently
  hold" fuzz check.
- `SearcherRegistry.t.sol` (59) — bond accounting unit + fuzz tests.
- `LPInsuranceVault.t.sol` (53) — direct vault unit + fuzz tests against a
  real `PoolManager`, including the join-after-slash and partial-withdrawal
  correctness properties.
- `ThetaBGHook.t.sol` (45) — full end-to-end integration against a real
  `PoolManager` and hook: the slash→vault→claim pipeline, strategy-failure
  resilience, multi-pool isolation, re-bonding cycles, events, and priority
  fee collection.
- `ThetaBGFalsePositive.t.sol` (20) — the build brief §51 checklist, all 16
  named scenarios plus 4 more in the same spirit, each a named, dedicated
  test.
- `ThetaBGAdversarial.t.sol` (12) — attacks modeled on build brief §71,
  including two *verified* findings (ring-buffer eviction, flash-liquidity
  capture — see `SECURITY.md`) that were confirmed by running the attack,
  not assumed from reading the code.
- `SearcherRegistryInvariant.t.sol` (5) + `LPInsuranceVaultInvariant.t.sol`
  (4) — Foundry invariant suites with dedicated handlers
  (`test/invariant/handlers/`), each run for 256 runs × 500 calls (128,000
  calls per invariant) covering bond-accounting solvency and vault
  reward-accounting solvency respectively.

This is real coverage, not padding to hit a number — every test asserts a
specific, named property, and two genuine gaps were found and disclosed in
the process (see `SECURITY.md`, `LIMITATIONS.md` above). Explicitly still
not built:

- A third invariant suite over `ThetaBGHook` itself (combining swap-driven
  attacks, liquidity changes, and slashes through one randomized handler) —
  the two invariant suites that exist test `SearcherRegistry` and
  `LPInsuranceVault` in isolation, not the fully-wired hook under randomized
  adversarial sequences.
- Gas report (`GAS_REPORT.md` was not generated this pass).
- A fix (or a chosen, documented mitigation) for the ring-buffer eviction
  and flash-liquidity-at-slash findings — currently disclosed, not resolved.

## Deployment

No Unichain Sepolia deployment has been executed. Deployment scripts
(`script/DeployThetaBG.s.sol` etc.) have not been written yet either — this
was an explicit scope decision for this pass (contracts and their test
coverage first, deployment once an RPC URL and deployer key are available).

## Frontend

Not built in this pass.

## What would change first in a production hardening pass

In rough priority order: (1) time-weighted/delayed liquidity eligibility to
close the flash-LP-at-slash gap, (2) exact-output priority fee support,
(3) a Foundry invariant-test harness, (4) per-pool-fixed-at-init economic
parameters, (5) gas optimization pass with a checked-in gas report.
