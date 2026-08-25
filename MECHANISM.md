# Mechanism

## Terminology, precisely

- **Same-block, cross-transaction.** The predicate matches three swaps in
  the same `block.number`, which are ordinarily three *separate*
  transactions (front-run tx, victim tx, back-run tx). This is never called
  "same-transaction" anywhere in this codebase — see
  `V4_ARCHITECTURE_VALIDATION.md §2` for why the brief's original
  transient-storage-across-three-transactions design was impossible.
- **Searcher identity = the direct caller of `PoolManager.swap()`.** Not
  `tx.origin`, not a `hookData`-supplied claim. See
  `V4_ARCHITECTURE_VALIDATION.md §1`.
- **"Priority lane."** Theta-BG does not and cannot control block-builder
  transaction ordering. "Priority lane" means: a registered, bonded
  searcher's swaps are the only ones subject to (and benefiting from) this
  hook's fee/detection machinery. It is not a promise about sequencing.

## The five-condition predicate

Implemented in `src/libraries/SandwichPredicate.sol`, evaluated over three
`SwapRecord`s `(a, b, c)` in chronological order:

1. `a.sender == c.sender` — same searcher brackets the victim.
2. `a.blockNumber == b.blockNumber == c.blockNumber` — same block.
3. `b.sender != a.sender` — the middle swap is a distinct address.
4. `a.zeroForOne != c.zeroForOne` — front-run and back-run are opposite
   directions.
5. Two sub-conditions on price, both required:
   - **5a — minimum displacement**: `a`'s own swap must have moved price by
     at least `minDisplacementBps`. Not in the original brief; added because
     without it, a searcher could grief the detector with a dust swap that
     technically satisfies conditions 1–4 (see build prompt §15, §71 Attack
     15) while displacing price by an amount too small to have meaningfully
     affected any victim. Covered by
     `test_dustDisplacement_belowMinimum_notDetected`.
   - **5b — restoration**: `c`'s closing price must be within
     `restorationThresholdBps` of `a`'s opening price.

All five must hold simultaneously; each is independently necessary and none
is independently sufficient — this is a conjunction, not a scored heuristic.

### What this predicate is, and is not, proof of

The predicate identifies **an observable round-trip price-displacement
pattern consistent with sandwich execution**. It is not, and cannot be, proof
of an address's *intent*. A sufficiently contrived sequence of unrelated
trades could in principle satisfy all five conditions without being an
intentional attack (see `SECURITY.md` §"self-triggering / griefing"). The
mitigation is that only *bonded, registered searchers* are ever evaluated —
`ThetaBGHook.afterSwap` short-circuits with
`registry.isActiveSearcher(a.sender)` before even calling the predicate — so
the worst case for an innocent pattern-match is that a searcher who chose to
bond loses that bond; an ordinary trader who never registered is never at
risk of being slashed no matter what pattern their trades happen to form.

### Price representation and the sqrtPrice-vs-price approximation

The predicate compares `sqrtPriceX96` values directly — never converts to
price via squaring, which would need a much wider intermediate type and
introduce rounding complexity for no benefit here. This means
`restorationThresholdBps` is a tolerance on the *square root* of price, not
on price itself. Since `price = sqrtPrice²`, a `t` bps deviation in
`sqrtPrice` corresponds to approximately `2t` bps deviation in the
underlying price for small `t`. This is stated explicitly (see the doc
comment in `SandwichPredicate._withinDeviation`) rather than silently
mislabeled — operators configuring `restorationThresholdBps` should budget
for roughly double that figure in real price terms.

### Minimum displacement / minimum victim size

Only a front-run displacement floor (`minDisplacementBps`) is implemented.
A separate `minimumVictimSize` (brief §50) was considered and deliberately
**not** added: the victim's trade size doesn't change whether the searcher's
bracketing pattern occurred, and gating on victim size would create a new
griefing vector (an attacker could split a large sandwich into many
just-under-the-floor victim trades). Filtering on the *searcher's own*
displacement, which the searcher cannot easily disguise without also
reducing their own extractable profit, is the more robust choice.

## Bond economics

- **`minimumBond`**: immutable, set at hook deployment.
- **`requiredBond(searcher)`**: `minimumBond` if never slashed, `2 ×
  minimumBond` after any slash — a flat penalty, not
  `minimumBond × 2^slashCount`. Exponential escalation was considered and
  rejected: it has no natural ceiling, and a searcher slashed a few times
  would face an economically meaningless re-entry bar rather than a
  proportionate one. A flat doubling still meaningfully raises the cost of
  repeat offense while remaining a bond a genuine searcher could reasonably
  post again.
- **Slash amount = the searcher's entire current bond**, always. There is no
  separate "slash amount" distinct from the bond, and therefore no "bond
  smaller than the required slash" edge case to handle (brief §9) — the
  slash is definitionally bounded by whatever the bond currently holds.
  This is also the maximum deterrence available: partial slashing would
  only ever be a weaker economic signal for the same complexity.
- **Split**: `protocolShareBps` (default 1000 = 10%) to the protocol,
  remainder to the pool's `LPInsuranceVault`. Both immutable.
- **Withdrawal cooldown**: 24 hours between `requestWithdrawal()` and
  `withdraw()` succeeding. This prevents a searcher from posting a bond,
  executing an attack, and withdrawing before... actually the cooldown's
  real purpose is different and more important: it prevents a searcher from
  *front-running their own imminent slash* by withdrawing their bond between
  the front-run and back-run legs of their own attack. Since `withdraw()`
  cannot execute inside the cooldown window regardless of when it was
  requested, a bond posted before an attack is guaranteed to still be present
  when the back-run's `afterSwap` evaluates the predicate.

### Bond sizing is a configuration choice, not a guarantee

If `minimumBond < expectedMEVprofit` for some trade, a rational searcher may
still attack — the expected value calculation is
`EV = P(profit) × MEVprofit − P(slash) × bond − priorityFee`, and Theta-BG
only pushes this negative for the *covered pattern* at a *given bond size*.
Pool operators choosing `minimumBond` should size it against the largest
single-block MEV exposure they're willing to leave unprotected — this is a
deployment-time risk parameter, not something the protocol enforces
automatically. Stated in `ECONOMICS.md`... folded into this file: no
separate `ECONOMICS.md` was written, since bond and insurance economics are
inseparable from the mechanism they secure — splitting them would mean
cross-referencing between two files for every claim.

## LP insurance vault: what "insurance" means here

**Model chosen: fully claimable at any time (build prompt §56 Model A)**,
not a locked reserve that only distributes yield (Model B), and not a
principal-plus-minimum-reserve hybrid (Model C).

Rationale: a vault that locks principal needs a governance-free rule for
*when* principal becomes claimable, which reintroduces exactly the kind of
discretionary parameter this design avoids elsewhere. "Insurance" here
describes the **source** of the funds (attacker bonds) and their
**growth mechanism** (ERC4626 strategy yield compounding between slashes),
not a promise that capital is reserved against some specific future claim.
An LP's `claimable()` balance is real, current, and theirs — same as
accrued swap fees.

### Self-compounding, precisely

`LPInsuranceVault.availableBalance() = idleAssets + strategy.previewRedeem(sharesHeld)`.
This number increases from two independent sources: new slashes (principal
in) and strategy APY (yield on existing principal, accruing continuously,
with no action required). `test_strategyYield_compoundsInsuranceBalance`
demonstrates this directly by simulating strategy yield between a slash and
a balance check.

### Distribution: reward-per-liquidity accumulator, not LP enumeration

See `V4_ARCHITECTURE_VALIDATION.md §4` for the full derivation. In one line:
`accInsurancePerLiquidityX128 += slashAmount * Q128 / activeLiquidityAtSlash`,
checkpointed per-position via `afterAddLiquidity`/`afterRemoveLiquidity`, so
that only liquidity actually in-range and present *before* a slash accrues
that slash's share.

### The zero-liquidity edge case

If a slash occurs while `StateLibrary.getLiquidity(poolId) == 0` (no
in-range liquidity — the entire pool's active liquidity has moved out of
range, unusual but possible), the accumulator cannot be updated (division
by zero is undefined economically, not just numerically — there is no LP to
attribute the reward to). The insurance share is held as `idleAssets`
instead. It is **not** retroactively distributed once liquidity returns —
doing so would require tracking which specific future LP "deserves" a past
slash, reintroducing the enumeration problem this design avoids everywhere
else. This is a real, disclosed limitation, not a silently swallowed edge
case — see `LIMITATIONS.md`.
