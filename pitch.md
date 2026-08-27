# Theta-BG

### Bonded Priority Lane · On-Chain Sandwich Detection · Self-Compounding LP Insurance

> **UHI10 Hookathon — Sustainable Liquidity & MEV Protection**
> Uniswap Hook Incubator · Cohort 10
> Uniswap v4 · Unichain Sepolia · Pure Solidity · Zero off-chain dependencies

> *"Sandwich me and lose your bond — and that bond becomes LP yield,
> automatically, on-chain, in the same block."*

---

## Why this matters — before the what

Every large swap on a volatile Uniswap pair is a standing invitation. A
searcher buys in front of it, lets the victim execute at the worse price
they created, and sells behind it in the same block. The spread the victim
paid becomes the searcher's profit. Peer-reviewed measurement across
~95,000 attacks (Nov 2024–Oct 2025) still puts the direct cost to swappers
at roughly **$60M/year**, on top of the hundreds of millions extracted
across DEXs in earlier years.

The uncomfortable part is not just the number — it is *where* the attack
happens versus where every defense lives:

- **Flashbots Protect / private routing** works only if the *user* opts in,
  off-chain, per trade. It also routes flow *away* from the public pool.
- **CoW / peer matching** only helps when a counterparty match exists.
- **Dynamic fees** cannot tell a sandwich bot from an honest large trade.

And it compounds: recent research finds **37% of sandwich victims move to
private routing within 60 days**, rising to **54% after repeated attacks**.
Toxic order flow doesn't just tax the trade — it drives volume off the
public AMM, thinning the very liquidity that made the pool safe to trade
against. Every mitigation today lives *outside* the pool, controlled by
*someone else*, and even when one works the extracted value simply
disappears — nobody in the pool is made whole.

**Theta-BG's thesis:** the defense belongs *in* the pool, it must need
nothing off-chain to work, and the penalty it collects from attackers
should become a yield stream for the LPs whose depth is the real defense —
turning security capital into working capital.

---

## What it is

Theta-BG is a single Uniswap v4 hook that makes a same-block sandwich
economically self-destructive. It has three cooperating layers:

| Layer | Mechanism | Effect |
|---|---|---|
| **Deter** | Searchers post an on-chain bond for the priority lane; the bond doubles after any slash | Attacking now has a capital cost and a rising re-entry cost |
| **Detect** | A pure five-condition predicate over three swaps, evaluated in `afterSwap` from on-chain state only | Same-block sandwiches are identified with no oracle, keeper, or AVS |
| **Recapture** | Slash → 90% to a per-pool ERC4626 insurance vault → claimable LP yield | The attacker's bond becomes LP revenue, and compounds at lending APY between slashes |

The pool gets *harder to attack* and *more rewarding to provide liquidity
to* the longer it runs. Every slash funds the vault. Every quiet day grows
it through yield. The attacker doesn't just fail — their forfeited bond
becomes yield for the LPs whose liquidity they were trading against.

---

## The problem, concretely

A sandwich is four steps: searcher front-runs (pushes price up), victim
executes (pays the spread), searcher back-runs (sells, pockets the
difference), price returns to roughly where it started. That round-trip —
**move the price and then restore it** — is the signature. A legitimate
directional trader moves the price *and leaves it moved*. That difference is
the entire basis for detection.

**Who actually loses, precisely.** The direct victim is the *swapper*, not
the LP — the swapper receives fewer tokens; the searcher and the block
builder split the difference. LPs are hit *indirectly*: they carry the
reputational cost of a pool known for toxic execution, they lose fee
revenue as burned users route privately, and their positions sit inside a
pool whose depth erodes as flow leaves. Theta-BG does not claim to refund
a specific victim's specific loss — quantifying that on-chain per trade
isn't tractable. It does two things that are: it makes the *covered
pattern* unprofitable at a chosen bond size, and it routes the forfeited
bond to the LPs, because deeper, stickier liquidity is what structurally
shrinks sandwich profitability in the first place.

The deeper problem is economic, not technical: today a blocked sandwich
recovers nothing for anyone in the pool. Theta-BG adds a return path.

---

## The solution

### Layer 1 — Bonded priority lane

Any address registers as a searcher by posting a bond (`minimumBond`,
immutable, set at deployment). Only registered searchers are subject to —
and eligible for — this hook's fee and detection machinery; unbonded flow is
treated as ordinary. A slashed searcher must re-bond at **2×** the minimum
(a flat penalty, not exponential — it has a natural ceiling and stays a bond
a real searcher could post again). A **24-hour withdrawal cooldown**
between `requestWithdrawal()` and `withdraw()` exists for one specific
reason: it makes it impossible for a searcher to pull their bond out
*between the front-run and back-run legs of their own attack*.

### Layer 2 — Five-condition on-chain predicate

Implemented as a pure, storage-free library
(`src/libraries/SandwichPredicate.sol`), evaluated over three swap records
`(a, b, c)` in chronological order. **All five must hold simultaneously** —
it is a conjunction, not a score:

1. `a.sender == c.sender` — the same searcher brackets the victim.
2. `a.block == b.block == c.block` — all three in one block.
3. `b.sender != a.sender` — the middle swap is a distinct address.
4. `a.zeroForOne != c.zeroForOne` — front-run and back-run are opposite
   directions.
5. **Displacement + restoration:** `a` moved price by at least
   `minDisplacementBps` (a dust swap can't grief the detector), *and* `c`'s
   closing price is within `restorationThresholdBps` of `a`'s opening price
   (the round-trip signature).

Each condition is independently necessary; none is independently sufficient.
A directional arb satisfies four and never the fifth. Because only *bonded,
registered* searchers are ever evaluated (`afterSwap` short-circuits on
`registry.isActiveSearcher` before the predicate runs), the worst case for
an unlucky pattern-match is that someone who *chose* to bond loses that bond
— an ordinary trader who never registered is never at risk, whatever shape
their trades happen to form.

### Layer 3 — Self-compounding LP insurance vault

On detection, the hook slashes the searcher's **entire current bond** in the
same transaction. Split: **10% protocol**, **90% to the pool's
`LPInsuranceVault`**. The vault immediately deposits into an external
ERC4626 yield strategy and holds *shares, not tokens* — so
`availableBalance()` is `idleAssets + strategy.previewRedeem(shares)`, a
number that rises from **two independent sources**: new slashes (principal
in) and strategy APY (yield on what's already there, continuously, with no
action needed).

LPs claim their pro-rata share any time. Distribution uses a
**reward-per-liquidity accumulator** —
`accInsurancePerLiquidityX128 += slashAmount · Q128 / poolEligibleLiquidity`,
checkpointed per position in `afterAddLiquidity`/`afterRemoveLiquidity` —
the same MasterChef/Synthetix pattern Uniswap itself uses for fee growth. No
LP enumeration, no unbounded loops.

---

## Technical implementation

### Contracts

```
src/ThetaBGHook.sol                   IHooks impl: identity resolution, per-searcher
                                      open-leg tracking, predicate eval, slash
                                      triggering, priority-fee collection, LP checkpointing
src/SearcherRegistry.sol              Pure bond accounting. ONE instance, shared across
                                      every pool on this hook deployment
src/LPInsuranceVault.sol              ONE instance per pool (deployed from afterInitialize).
                                      Holds principal, runs the ERC4626 strategy and the
                                      reward-per-liquidity accumulator
src/libraries/SandwichPredicate.sol   Pure five-condition predicate, fully unit + fuzz tested
```

**One registry, many vaults — deliberately.** A searcher's bond and slash
history should mean something across *every* pool this deployment serves
(fragmenting per-pool lets a searcher attack pool A with a bond pool B's
traffic never tested). But insurance principal must *never* leak between
pools — pool A's LPs should never be diluted or enriched by pool B's
sandwich activity — so each pool gets its own vault.

**Priority fee via `BeforeSwapDelta`.** Collected atomically inside
`beforeSwap` through v4 flash accounting, then `donate()`d straight into
in-range LPs' `feeGrowth` — reusing Uniswap's own accounting rather than
building a second accumulator. No separate transfer, no reentrancy surface.

**Every economic parameter is `immutable`.** `restorationThresholdBps`,
`minDisplacementBps`, `priorityFeeBps`, `protocolShareBps`, `minimumBond` —
all set once in the constructor. No owner, no governance, no function that
can change slashing behavior or redirect funds. The only privileged call is
`withdrawProtocolFees()`, which can only ever move fees the protocol is
already entitled to.

### Correctness — what the engineering review actually changed

This repo is a from-scratch, senior-reviewed build, **not a transcription of
the original pitch**. Several of that document's claims did not survive
contact with real v4 / EVM semantics and were corrected — this is a feature
of the submission, not an embarrassment:

- **"Same-transaction" detection was impossible.** A sandwich is three
  *separate* transactions; transient storage cannot span them. The
  predicate is precisely *same-block, cross-transaction*, and the codebase
  never claims otherwise.
- **The 3-slot ring buffer was an evasion vector — found by running the
  attack, then fixed.** A single decoy swap between the victim and back-run
  legs evicted the front-run record and defeated detection. Detection is
  now keyed per `(pool, searcher)`, which closes it entirely rather than
  narrowing it. Regression tests guard it against any number of decoys.
- **Flash liquidity at slash time was a capture vector — also found by
  running it, then fixed.** An LP could add a large position immediately
  before a slash and remove it immediately after, capturing a share for
  near-zero holding time. Liquidity now must mature one block
  (`LIQUIDITY_MATURATION_BLOCKS`) before it counts toward a slash's divisor
  *or* earns any share of one, tracked via an append-only `slashHistory`
  checkpoint list with binary search for the exact maturity boundary.

### Testing

**252 tests across 8 suites**, all passing against real `v4-core` /
`v4-periphery` / OpenZeppelin dependencies:

- Pure predicate unit + fuzz (53) — including monotonicity invariants on the
  thresholds and a "whenever detected, all five conditions independently
  hold" fuzz check
- Registry bond accounting (59), vault accounting (53)
- Full end-to-end integration against a real `PoolManager` and hook (45) —
  the slash → vault → claim pipeline, strategy-failure resilience, multi-pool
  isolation, re-bonding cycles
- False-positive checklist (20) — every named "this must NOT slash" scenario
  as a dedicated test
- Adversarial suite (13) — including the **two verified findings above**,
  confirmed by executing the attack, not assumed from reading code
- Two Foundry invariant suites — bond-accounting solvency and vault
  reward-accounting solvency, **128,000 randomized calls each**

### Live on Unichain Sepolia (chain 1301)

All contracts deployed and verified on Uniscan. `script/DemoSandwich.s.sol`
executed a **real front-run → victim → back-run against the deployed pool at
production thresholds** (0.5% displacement floor, 0.1% restoration band —
not the loosened bands the test suite uses to avoid hand-solving CPMM math).
The back-run input was computed exactly via v4's own `SqrtPriceMath`.

| Contract | Address |
|---|---|
| `ThetaBGHook` | `0x9739F9f628e06B0F1Da21A8AB841067856Fa15c8` |
| `SearcherRegistry` | `0x19d73C0f5cceb36D08B1272E292d86275Fd4c808` |
| `LPInsuranceVault` (demo pool) | `0x7D881A58E9231EEEf17800cA8d3dF4a6eB6f966d` |

Measured on-chain result: front-run displaced price 372.9 bps (cleared the
50 bps floor), back-run closed 1.72 bps from start (cleared the 10 bps
band), searcher bond went to **0**, slash count **1**, insurance vault
**+0.009 ETH** (exactly 90% of the 0.01 ETH bond), protocol **+0.001 ETH**.
Transaction hashes in `DEPLOYMENT.md`.

A live read-and-write console (`web/`, Vite + React + wagmi/viem +
RainbowKit) reads all state directly from chain — contract state via
multicall, pool price via `extsload` on the packed `Slot0`, history via
`eth_getLogs` — and drives the full searcher bond lifecycle and LP insurance
claims from a connected wallet.

---

## Core innovation

Prior bonding/slashing designs treat the insurance pool as **dead
collateral** — capital that sits, waiting, earning nothing. Theta-BG's
structural insight is that it should be **working capital**: the slashed
bond is deposited into an ERC4626 strategy the instant it arrives, so the
insurance fund compounds at lending APY *between* attacks, with no external
subsidy, no governance vote, and no protocol token.

That produces a property rare for any protection mechanism: **it gets
stronger the longer the pool runs safely.** A six-month-old pool has a
materially deeper insurance fund than a new one — funded by attackers,
grown by yield, compounding continuously.

Combined with fully on-chain, oracle-free, keeper-free, AVS-free same-block
detection as a native v4 hook, the unified primitive — bond + on-chain slash
+ self-compounding vault on the proceeds — has not appeared in any prior UHI
submission.

| | Defense | Recapture | Yield on the protection fund | External deps |
|---|:---:|:---:|:---:|:---:|
| Flashbots Protect | ✅ | ❌ | ❌ | High |
| CoW Protocol | Partial | ❌ | ❌ | High |
| Dynamic fees | Partial | ❌ | ❌ | Low |
| **Theta-BG** | ✅ | ✅ | ✅ | **None** |

---

## For the judges — what to verify, and how

Every claim here is checkable without trusting us:

1. **The predicate is real and pure** — read
   `src/libraries/SandwichPredicate.sol`; it has no storage and 53 tests.
2. **The slash pipeline is real** — `test_sandwichAttack_slashesBondAndFundsInsurance`
   runs it end to end against a real `PoolManager`.
3. **The attack is real on mainnet-equivalent testnet** — the three
   transaction hashes in `DEPLOYMENT.md` on Uniscan, at production
   thresholds, with the measured bond → vault transfer.
4. **The weaknesses are disclosed, not hidden** — `LIMITATIONS.md` states
   every boundary explicitly: same-block only, direct-caller identity only,
   exact-input priority fee only, and the fact that the *live* vault still
   runs pre-fix bytecode because contracts are immutable.

The false-positive question, answered up front: *a directional arb moves
price and leaves it moved; a sandwich moves price and restores it.
Condition 5 — restoration — is the discriminator, and 20 dedicated
false-positive tests plus a fuzz invariant back it.*

---

## What would change first in a production pass

In priority order: (1) exact-output priority-fee support, (2) a third
invariant suite over the fully-wired hook under randomized adversarial
sequences, (3) per-pool economic parameters fixed permanently at pool
initialization (no runtime mutability, no admin), (4) a gas optimization
pass with a checked-in report, (5) redeploy to pick up the
flash-liquidity-at-slash fix on the live instance.

---

## Sources for the figures cited

- ~$60M/year direct swapper cost across ~95,000 attacks (Nov 2024–Oct 2025)
  and 38% of attacks targeting stablecoin pools — 2025 remeasurement /
  EigenPhi-derived reporting on Ethereum sandwich MEV.
- 37% of victims migrating to private routing within 60 days (54% after
  repeated attacks) — *Sandwiched and Silent: Behavioral Adaptation and
  Private Channel Exploitation in Ethereum MEV*, arXiv:2512.17602.
- Sandwich mechanics and the "low-liquidity pools are more vulnerable"
  point — Uniswap's own documentation on MEV / swap protection.
- The March 2025 single-swap $215K USDC→USDT loss on Uniswap v3 — widely
  reported; illustrative of tail risk, not a typical case.

Numbers vary by methodology and year; the pitch deliberately uses the
conservative recent measurement rather than a larger historical headline.

---

*Built for UHI10 Hookathon — Sustainable Liquidity & MEV Protection*
