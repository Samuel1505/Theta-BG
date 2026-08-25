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

**Ring-buffer eviction — a verified, disclosed evasion technique.** The
3-slot ring buffer (`build brief §14`) holds only the *last three* swaps in
the pool. If any fourth, unrelated swap lands between the victim leg and the
back-run leg, it evicts the front-run record before the bracket completes —
`a.sender` no longer matches the back-run's sender, so condition 1 never
fires. This is not a hypothetical: it is executed and confirmed in
`test/ThetaBGAdversarial.t.sol::test_attack_ringBufferEviction_decoySwapDefeatsDetection`,
with `test_attack_ringBufferEviction_controlWithoutDecoy_doesSlash` as the
control proving the decoy swap is the only variable that changed the
outcome. A searcher aware of this could pay an accomplice (or even
themselves, from a third address) a small amount to place one interstitial
swap and reliably defeat detection. **Not mitigated in this build** — see
`LIMITATIONS.md` for the production-hardening options (a wider buffer, or
detection over the full in-block swap history rather than a fixed 3-slot
window) and why they weren't implemented here (gas cost of unbounded
per-block history, and DoS risk of a *searcher-manipulable* buffer size —
see build brief §72's constraint against unbounded state that a malicious
actor can control the growth of).

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
only ever cause a missed detection (false negative) — a ring-buffer entry
recorded with a wrong `sqrtPriceX96Before` fails the predicate's price
conditions rather than passing them, since `sqrtPriceX96After` in that same
record would then be inconsistent with a real price *movement* for that
specific swap.** It can never cause a wrongful slash. Not hardened against
in this build; a production version could add a per-call nesting counter if
this scope is ever relevant to a specific hook configuration.

**Pool isolation.** Ring buffer and accumulator state are keyed by `PoolId`
throughout (`mapping(PoolId => ...)`), never a bare global. Verified
structurally (every mapping in `ThetaBGHook.sol`/`LPInsuranceVault.sol` is
`PoolId`-keyed) rather than by a dedicated cross-pool test — a two-pool
integration test is listed as follow-up work in `LIMITATIONS.md`.

**Denial of service via unbounded state.** The ring buffer is a fixed
3-slot array per pool (`SandwichPredicate.SwapRecord[3]`), overwritten
circularly — no growth, no per-address arrays, no iteration anywhere in the
hot path. `SearcherRegistry` and `LPInsuranceVault` both use direct mapping
lookups keyed by address/position, never enumeration.

## Invariants (informal — not yet exercised by a Foundry invariant-test
harness; see `LIMITATIONS.md` for that gap)

- `amountSlashed <= bond held immediately before the slash` — true by
  construction (`amountSlashed = s.bond` in `SearcherRegistry.slash`, not a
  separately-computed value that could exceed it).
- `protocolCut + insuranceCut == amountSlashed` — true by construction
  (`insuranceCut = amountSlashed - protocolCut`, not two independently
  rounded quantities).
- `sum of all LP claims for a pool <= that pool's LPInsuranceVault.availableBalance() at any point in time` —
  follows from the accumulator design (an LP can only ever claim
  `accInsurancePerLiquidityX128`-derived amounts that were funded by an
  actual `receiveSlash()` deposit), but is not yet fuzzed/invariant-tested
  directly against rounding edge cases in `FullMath.mulDiv`.
