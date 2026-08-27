# Security

Threat model, organized by actor. Each entry states the threat, the
mitigation actually implemented, and — where relevant — a disclosed residual
risk rather than a false "fully mitigated" claim.

## Searcher

**Fake registration / bond manipulation.** `SearcherRegistry.register()`
requires `msg.value >= requiredBond(msg.sender)`, checked before any state
change. Bond accounting uses checks-effects-interactions throughout
(`test_register_reverts_belowMinimumBond`, `test_slash_zeroesEntireBond`).

**Withdrawal race — searcher withdraws mid-attack.** The 24-hour cooldown
(`WITHDRAWAL_COOLDOWN`) means a bond posted before an attack cannot be
withdrawn before the attack's back-run leg executes, no matter how fast the
searcher acts. See `MECHANISM.md` §"withdrawal cooldown".

**Slash avoidance via proxy addresses.** A searcher could route their
front-run and back-run through two *different* contract addresses to defeat
condition 1 (`a.sender == c.sender`). This works — but only by *not*
bracketing as the same bonded identity, meaning neither leg is attributable
to their bond, so there is nothing to slash *and* nothing to gain from
bonding in the first place; an unbonded searcher gets no priority-fee
exemption and is just an ordinary trader from the hook's perspective. This
isn't a hole in the bonded-searcher deterrence — it's simply choosing not to
participate in the bonded lane, in which case there was never a bond at risk.

**Self-sandwich / intentional self-trigger.** A searcher's own bond can only
be slashed for a pattern involving *their own* address as both bracketing
legs plus a *different* victim address in the middle (condition 3). A
searcher cannot slash themselves for economic gain — the entire slashed bond
leaves their control (90% to LPs, 10% to protocol); there is no path back to
the searcher.

**Griefing via dust trades.** Mitigated by `minDisplacementBps` (condition
5a) — see `MECHANISM.md`. Verified by
`test_dustDisplacement_belowMinimum_notDetected`.

**Ring-buffer eviction — FIXED, originally a verified evasion technique.**
The original design used a 3-slot ring buffer (`build brief §14`) holding
only the *last three* swaps in the pool. Any fourth, unrelated swap landing
between the victim leg and the back-run leg evicted the front-run record
before the bracket completed — `a.sender` no longer matched the back-run's
sender, so condition 1 never fired. This was not a hypothetical: it was
executed and confirmed by a test that has since been renamed and flipped to
a regression check
(`test/ThetaBGAdversarial.t.sol::test_attack_decoySwapBetweenVictimAndBackRun_noLongerEvadesDetection`,
plus `test_attack_multipleDecoySwaps_stillDoesNotEvadeDetection` proving the
fix generalizes to any number of interleaved decoys).

The fix: detection state is now keyed per `(pool, searcher)` — `OpenLeg` in
`ThetaBGHook.sol` — instead of per pool-wide ring position. A searcher's
front-run record can only ever be consumed or overwritten by *that same
searcher's* own next swap; a third party's swap, decoy or not, in between
no longer touches it. "Who swapped in between" (the generalized condition 3)
is reconstructed from a single per-pool `lastSwapSender` value captured
before each swap overwrites it, which correctly reduces to "nobody" when the
searcher's own two swaps are back-to-back with nothing else in between. This
costs no more storage per swap than the ring buffer did (one open-leg slot
per active searcher who has traded a pool, comparable to how
`SearcherRegistry.searchers` already grows one slot per searcher) and isn't
a new unbounded-per-block growth vector — see build brief §72's constraint
against state a malicious actor can grow arbitrarily within one block, which
this design doesn't create: it's O(1) per swap, not O(swaps-in-block).

## Victim

**Malicious victim / victim-controlled router.** The predicate has no
concept of victim intent — it only requires the middle swap's sender to
differ from the bracketing sender (condition 3). A "victim" could in
principle be a colluding party trying to help a searcher avoid detection
(e.g. having the victim role played by an address that makes the pattern
*not* match) — but this only ever prevents a slash from firing, it can never
cause a wrongful one. There is no scenario where a malicious victim can get
an *innocent* searcher slashed, since the searcher must independently be a
registered, active, bonded address bracketing that victim.

## LP

**Flash liquidity at slash time.** Disclosed, not fully mitigated — see
`V4_ARCHITECTURE_VALIDATION.md §4` and `MECHANISM.md`. An LP who adds a
large position in the same block as, but strictly before, a slash-triggering
back-run, then removes it shortly after, can claim a share of that specific
slash despite near-zero holding duration, because
`StateLibrary.getLiquidity()` at slash time includes whatever liquidity is
currently in range regardless of when it arrived. A full fix needs
time-weighted or one-block-delayed eligibility (track a position's earliest
same-block deposit and exclude same-block liquidity from that slash's
divisor). Not implemented in this build — the accounting complexity and
gas cost of a second liquidity snapshot didn't clear the bar for the
hackathon scope, and the residual risk is bounded (it can only reduce
long-term LPs' share of an individual slash by dilution, never let anyone
claim more than the vault actually holds — see the invariant below).
Demonstrated concretely, not just described, by
`test/ThetaBGAdversarial.t.sol::test_attack_flashLiquidityAtSlash_capturesShareDespiteInstantExit`,
which shows a same-block flash-LP capturing an equal share to an honest,
persistent LP for that one slash.

**Reward-index staleness without checkpointing.** Solved, not just
disclosed — this is exactly why `afterAddLiquidity`/`afterRemoveLiquidity`
checkpointing exists (`MECHANISM.md` §"reward-per-liquidity accumulator").
Without it, an LP adding liquidity after a slash and claiming later would
wrongly capture pre-existing rewards. Not present in the original brief;
added as a correction — see `V4_ARCHITECTURE_VALIDATION.md §4`.

## Vault / ERC4626 strategy

**This is a real external trust boundary**, not "zero dependencies" — see
`V4_ARCHITECTURE_VALIDATION.md §6`. Specific risks:

- **Strategy insolvency / bad debt.** If the underlying lending protocol
  becomes insolvent, `strategy.previewRedeem()` reflects the loss and LPs'
  `availableBalance()` drops accordingly. Theta-BG has no mechanism to
  protect against this — the strategy is a configuration choice made at
  hook deployment, and its risk is inherited entirely by the pool's LPs.
  Pool operators should treat strategy selection as a first-class security
  decision, not an implementation detail.
- **ERC4626 inflation / donation attack.** Not applicable to
  `LPInsuranceVault` itself in the classic first-depositor sense, because
  `LPInsuranceVault` is not itself an ERC4626 vault with third-party
  depositors — it is a single depositor (itself) into the external
  strategy. The classic attack (front-run the first depositor, donate
  directly to inflate `pricePerShare`) targets a vault with *many*
  depositors sharing one share supply; here, only `LPInsuranceVault` ever
  calls `strategy.deposit()`. The residual exposure is entirely whatever
  inflation-attack resistance the *chosen* external strategy itself
  implements — again, a deployment-time choice, not something Theta-BG can
  fix from outside.
- **Strategy deposit/withdrawal failure must not block a slash.** Solved —
  see `V4_ARCHITECTURE_VALIDATION.md §7`. `receiveSlash()` wraps
  `strategy.deposit()` in try/catch; on failure, funds are held as
  `idleAssets`, still fully claimable by LPs. Verified end-to-end by
  `test_slash_succeedsEvenIfStrategyDepositFails` against a strategy with
  deposits deliberately paused mid-test.

## Hook

**Reentrancy through the slash call chain
(hook → registry → vault → ERC4626 → external strategy).** Mitigated by:
checks-effects-interactions in `SearcherRegistry.slash()` (bond zeroed
before the ETH transfer) and `LPInsuranceVault.receiveSlash()` (accumulator
updated before the strategy call); `ReentrancyGuard` on
`LPInsuranceVault.receiveSlash()` and `claimInsuranceYield()`.

**Nested/reentrant same-pool swaps corrupting the transient price bridge.**
Disclosed residual risk, flagged directly by the Solidity 0.8.24+ compiler's
own transient-storage composability warning (see the warning attached to
`ThetaBGHook._tstore`/`_tload` during `forge build`). If a swap for the same
pool were somehow nested inside another swap for that pool within one
transaction (Theta-BG's own hook never does this; it would require some
other hook attached to the same pool, or unusual router behavior, to
trigger it), the inner call's `tstore` could overwrite the outer call's
pending "before" price before the outer `afterSwap` reads it. **This can
only ever cause a missed detection (false negative) — an open-leg entry
recorded with a wrong `sqrtPriceX96Before` fails the predicate's price
conditions rather than passing them, since `sqrtPriceX96After` in that same
entry would then be inconsistent with a real price *movement* for that
specific swap.** It can never cause a wrongful slash. Not hardened against
in this build; a production version could add a per-call nesting counter if
this scope is ever relevant to a specific hook configuration.

**Pool isolation.** Every piece of detection and accumulator state
(`openLegs`, `lastSwapSender`, `vaults`, `accInsurancePerLiquidityX128`) is
keyed by `PoolId` throughout (`mapping(PoolId => ...)`), never a bare
global. Verified structurally (every such mapping in
`ThetaBGHook.sol`/`LPInsuranceVault.sol` is `PoolId`-keyed) and exercised
directly by `test_multiplePools_slashInPoolA_doesNotFundPoolBsVault` and
`test_attack_crossPoolState_doesNotLeakIntoUnrelatedPool`.

**Denial of service via unbounded state.** Per-swap storage writes are O(1):
one `OpenLeg` slot per active searcher who has traded a given pool (keyed by
`(poolId, searcher)`, overwritten in place — never appended to, never
iterated), plus one `lastSwapSender` value per pool. No array grows with the
number of swaps in a block, and nothing here scales with how many decoy or
unrelated swaps land in a block — a searcher's own open leg is touched only
by that searcher's own swaps. `SearcherRegistry` and `LPInsuranceVault` both
use direct mapping lookups keyed by address/position, never enumeration.

## Invariants

Exercised by two Foundry invariant suites
(`test/invariant/SearcherRegistryInvariant.t.sol`,
`test/invariant/LPInsuranceVaultInvariant.t.sol`), each run for 256 runs ×
500 calls (128,000 calls) against a handler that drives the contract through
every externally-callable action in random order and amounts — not just
asserted informally:

- `amountSlashed <= bond held immediately before the slash` — true by
  construction (`amountSlashed = s.bond` in `SearcherRegistry.slash`, not a
  separately-computed value that could exceed it); cross-checked by
  `invariant_neverPaysOutMoreThanWasBonded` and
  `invariant_sumOfIndividualBondsMatchesBalance`.
- `protocolCut + insuranceCut == amountSlashed` — true by construction
  (`insuranceCut = amountSlashed - protocolCut`, not two independently
  rounded quantities).
- `sum of all LP claims for a pool <= that pool's LPInsuranceVault.availableBalance() at any point in time` —
  proven directly by `invariant_outstandingClaimsNeverExceedHeldAssets` and
  `invariant_fundedCoversClaimedPlusOutstanding` against real
  `FullMath.mulDiv` rounding, not just asserted from the accumulator design.

Not yet covered by an invariant harness: `ThetaBGHook` itself under
randomized sequences of swaps, attacks, and liquidity changes together (the
two suites above test `SearcherRegistry` and `LPInsuranceVault` in
isolation) — see `LIMITATIONS.md`.
