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
  distributing insurance, which is a different, now-resolved problem — see
  "LP accounting" below).
- **Pattern detection, not intent proof.** See `MECHANISM.md` §"What this
  predicate is, and is not, proof of."

**Resolved since the first pass — not a current limitation, kept here for
the paper trail:** an earlier 3-slot pool-wide ring buffer design let a
single interstitial swap between the victim and back-run legs evict the
front-run record and defeat detection, verified by an adversarial test
before being fixed. Detection is now keyed per `(pool, searcher)` instead of
per ring-buffer position, which closes this entirely rather than just
narrowing it — see `SECURITY.md` §"Searcher" and
`V4_ARCHITECTURE_VALIDATION.md §2` for the design, and
`test/ThetaBGAdversarial.t.sol`'s
`test_attack_decoySwapBetweenVictimAndBackRun_noLongerEvadesDetection` /
`test_attack_multipleDecoySwaps_stillDoesNotEvadeDetection` for the
regression tests that now guard it.

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
- **No cross-pool LP test exists yet**, though the state is structurally
  isolated per `PoolId` throughout.

**Resolved since the first pass — not a current limitation, kept here for
the paper trail:** liquidity added in the same block as, but strictly
before, a slash-triggering back-run could previously be removed immediately
after and still capture a share of that slash despite near-zero holding
duration, verified by an adversarial test before being fixed. Liquidity now
requires `LIQUIDITY_MATURATION_BLOCKS` (1 block) of age before it counts
toward a slash's divisor *or* earns any share of one — tracked per-position
and pool-wide via an eligible/pending split, with an append-only
`slashHistory` checkpoint list letting a position's exact maturity boundary
be credited precisely even when multiple slashes land between two touches
of that position. See `SECURITY.md` §"LP" and `MECHANISM.md` for the design,
and `test/ThetaBGAdversarial.t.sol`'s
`test_attack_flashLiquidityAtSlash_noLongerCapturesShareDespiteInstantExit`
for the regression test that now guards it.

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

This build ships 252 passing tests across 8 suites:

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
- `ThetaBGAdversarial.t.sol` (13) — attacks modeled on build brief §71,
  including two *verified* findings confirmed by running the attack rather
  than assumed from reading the code, both since fixed: ring-buffer eviction
  and flash-liquidity capture at slash time (see "Scope of detection" and
  "LP accounting" above).
- `SearcherRegistryInvariant.t.sol` (5) + `LPInsuranceVaultInvariant.t.sol`
  (4) — Foundry invariant suites with dedicated handlers
  (`test/invariant/handlers/`), each run for 256 runs × 500 calls (128,000
  calls per invariant) covering bond-accounting solvency and vault
  reward-accounting solvency respectively.

This is real coverage, not padding to hit a number — every test asserts a
specific, named property, and genuine gaps were found and disclosed in the
process (see `SECURITY.md` above). Explicitly still not built:

- A third invariant suite over `ThetaBGHook` itself (combining swap-driven
  attacks, liquidity changes, and slashes through one randomized handler) —
  the two invariant suites that exist test `SearcherRegistry` and
  `LPInsuranceVault` in isolation, not the fully-wired hook under randomized
  adversarial sequences.
- Gas report (`GAS_REPORT.md` was not generated this pass).

(The ring-buffer eviction and flash-liquidity-at-slash findings have both
been fixed — see "Scope of detection" and "LP accounting" above.)

## Deployment

**Resolved — deployed and verified live on Unichain Sepolia.** See
`DEPLOYMENT.md` for addresses, verified contract links, and a real,
on-chain, production-threshold sandwich detection + slash (transaction
hashes included, not just log output) — the earlier "not yet deployed"
limitation no longer applies. What deployment did *not* cover: the live
`LPInsuranceVault` predates the flash-liquidity-at-slash fix and still runs
the old, unfixed bytecode (contracts are immutable once deployed) — any
remaining unresolved findings above are also still live on that instance,
since deploying a fix to this repo doesn't retroactively patch an
already-deployed contract. Redeploying to pick up the fix has not been done.

## Frontend

Not built in this pass.

## What would change first in a production hardening pass

In rough priority order: (1) exact-output priority fee support, (2) a third
invariant suite over `ThetaBGHook` itself (swap-driven attacks, liquidity
changes, and slashes through one randomized handler), (3) per-pool-fixed-
at-init economic parameters, (4) gas optimization pass with a checked-in
gas report, (5) redeploy to pick up the flash-liquidity-at-slash fix on the
live Unichain Sepolia instance, which still runs the pre-fix bytecode.
