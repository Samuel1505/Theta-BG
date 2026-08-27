# Theta-BG — UHI10 Hookathon Submission

## Name and Description

Theta-BG — MEV deterrence-and-recapture infrastructure built entirely inside a
Uniswap v4 hook. Registered searchers post an on-chain bond for a priority
swap lane; a pure five-condition predicate detects same-block sandwich
patterns from chain state alone; a detected sandwich slashes the searcher's
entire bond and routes it into a self-compounding, per-pool ERC4626 insurance
vault that pays out to liquidity providers pro-rata. No oracle, no keeper, no
AVS, no off-chain component anywhere in the decision path.

Theta-BG turns a sandwich attack from a pure extraction event into a funding
event for the pool it targeted: the attacker does not merely fail, their
forfeited capital becomes a compounding yield stream for the LPs whose depth
they were trading against.

---

## Problem

### Sandwich Extraction Is a Compounding Tax on Public AMM Liquidity

Public transaction ordering lets sophisticated searchers bracket a pending
swap and force the victim to execute at a price they manufactured:

- **Direct swapper losses:** peer-reviewed measurement across ~95,000 attacks
  (Nov 2024–Oct 2025) puts the direct cost to swappers at roughly **$60M/year**,
  on top of the hundreds of millions extracted across DEXs in prior years.
- **MEV concentration:** the extracted value is split between the searcher and
  the block builder — none of it returns to the pool, the LPs, or the victim.
- **Behavioral flight:** **37% of sandwich victims move to private routing
  within 60 days, rising to 54% after repeat attacks.** Order flow leaves the
  public pool permanently.
- **Depth erosion:** as flow leaves, pool depth thins, which makes the
  remaining flow *easier* to sandwich — a self-reinforcing loop.
- **No recapture:** every existing defense is external to the pool. Even a
  blocked sandwich just makes the value vanish; nobody in the pool is made
  whole or paid.

### Economic Impact

- The direct victim is the **swapper**, but LPs carry the second-order cost:
  lost fee revenue as burned users route privately, and positions sitting in a
  pool whose depth and reputation are decaying.
- Volatile pairs — exactly the pairs UHI10 targets — are where sandwich
  frequency is highest and where thinning depth hurts execution most.
- Liquidity on a sandwiched pool is structurally less attractive than the same
  liquidity on a protected one, with no on-chain mechanism today to close that
  gap.

---

## Solution

### On-Chain Deterrence, On-Chain Detection, On-Chain Recapture — One Hook

**Bonded Priority Lane**
Any address registers as a searcher by posting a bond in the pool's native
currency. Only bonded searchers are subject to — and benefit from — the hook's
fee and detection machinery. A slashed searcher must re-bond at **2× the
minimum** before re-entering.

**Five-Condition Sandwich Predicate**
A pure, storage-free library evaluates three chronologically-ordered swaps
against five simultaneous conditions. All five must hold; each is independently
necessary and none is independently sufficient. Detection reads only on-chain
price and sender state — there is nothing to bribe, stall, or take offline.

**Entire-Bond Slash**
On detection, the hook slashes the searcher's **full current bond** in the
same transaction that closed the sandwich. There is no partial-slash edge case
because the slash is definitionally bounded by the bond.

**Self-Compounding LP Insurance Vault**
Slashed capital is split **10% protocol / 90% vault**. The per-pool vault
immediately deposits its share into an ERC4626 yield strategy and holds
*shares, not tokens*, so its balance grows from two independent sources: new
slashes, and lending APY on existing principal between slashes.

**Reward-Per-Liquidity Distribution**
LPs claim their pro-rata share via a MasterChef/Synthetix-style accumulator
checkpointed on every liquidity change — no LP enumeration, no unbounded loops,
and only liquidity that was in-range and mature *before* a slash accrues it.

---

## Deep Technical Architecture

### Deterrence → Detection → Slash → Recapture

```
BONDED SWAP  →  5-CONDITION PREDICATE  →  ENTIRE-BOND SLASH  →  ERC4626 VAULT  →  LP YIELD
(SearcherRegistry)   (afterSwap, pure)      (same transaction)    (auto-compound)   (per-liquidity accrual)
```

### Core Predicate — `SandwichPredicate.sol`

```solidity
library SandwichPredicate {
    struct SwapRecord {
        address sender;             // direct PoolManager caller for this swap
        uint64  blockNumber;
        bool    zeroForOne;
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96After;
        bool    occupied;
    }

    /// a = front-run candidate, b = victim candidate, c = back-run candidate
    function isSandwich(
        SwapRecord memory a,
        SwapRecord memory b,
        SwapRecord memory c,
        uint256 restorationThresholdBps,   // default 10  (0.1%)
        uint256 minDisplacementBps         // default 50  (0.5%)
    ) internal pure returns (bool) {
        if (!a.occupied || !b.occupied || !c.occupied)          return false;
        if (a.sender != c.sender)                               return false; // 1: same searcher brackets victim
        if (a.blockNumber != b.blockNumber
            || b.blockNumber != c.blockNumber)                  return false; // 2: same block
        if (b.sender == a.sender)                               return false; // 3: distinct middle address
        if (a.zeroForOne == c.zeroForOne)                       return false; // 4: opposite directions
        if (!_deviatesAtLeast(a.sqrtPriceX96Before,
                              a.sqrtPriceX96After,
                              minDisplacementBps))              return false; // 5a: front-run displaced price
        if (!_withinDeviation(a.sqrtPriceX96Before,
                              c.sqrtPriceX96After,
                              restorationThresholdBps))         return false; // 5b: back-run restored price
        return true;
    }
}
```

### Hook Detection State — `ThetaBGHook.sol`

```solidity
contract ThetaBGHook is IHooks {
    SearcherRegistry public immutable registry;
    IERC4626        public immutable strategy;
    uint256 public immutable restorationThresholdBps;   // immutable — no owner, no governance
    uint256 public immutable minDisplacementBps;
    uint256 public immutable priorityFeeBps;
    uint256 public immutable protocolShareBps;

    /// Per-(pool, searcher) open front-run leg. A third party's swap — decoy
    /// or not — can never evict it, closing the ring-buffer-eviction attack.
    struct OpenLeg {
        uint64  blockNumber;
        bool    zeroForOne;
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96After;
        bool    occupied;
    }
    mapping(PoolId => mapping(address => OpenLeg)) private openLegs;
    mapping(PoolId => address)                     private lastSwapSender;

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        address priorSender = lastSwapSender[poolId];      // captured before overwrite
        lastSwapSender[poolId] = sender;

        if (registry.isActiveSearcher(sender)) {
            OpenLeg storage leg = openLegs[poolId][sender];
            _tryDetectAndSlash(poolId, sender, priorSender, leg, /* this swap = c */ ...);
            // this swap becomes the new open leg regardless of outcome
        }
        return (IHooks.afterSwap.selector, 0);
    }

    function _slashAndFund(PoolId poolId, address searcher, address victim) private {
        uint256 amount       = registry.slash(searcher);            // entire bond, zeroed
        uint256 protocolCut  = amount * protocolShareBps / 10_000;  // 10%
        uint256 insuranceCut = amount - protocolCut;                // 90%
        pendingProtocolFees += protocolCut;
        vaults[poolId].receiveSlash{value: insuranceCut}();
        emit SandwichSlashed(poolId, searcher, victim, amount);
    }
}
```

### Insurance Vault Accumulator — `LPInsuranceVault.sol`

```solidity
contract LPInsuranceVault {
    IERC4626 public immutable strategy;              // strategy.asset() == WETH
    uint256  public constant LIQUIDITY_MATURATION_BLOCKS = 1;
    uint256  public accInsurancePerLiquidityX128;

    struct SlashCheckpoint { uint64 blockNumber; uint256 accAfter; }
    SlashCheckpoint[] public slashHistory;           // append-only

    function receiveSlash() external payable onlyHook nonReentrant {
        uint256 amount   = msg.value;
        uint128 eligible = poolEligibleLiquidity;    // mature, in-range liquidity only
        if (eligible == 0) { idleAssets += amount; return; }          // disclosed edge case
        accInsurancePerLiquidityX128 += FullMath.mulDiv(amount, FixedPoint128.Q128, eligible);
        slashHistory.push(SlashCheckpoint(uint64(block.number), accInsurancePerLiquidityX128));
        _depositToStrategy(amount);                   // auto-compound
    }
}
```

---

## Tests and Coverage

**252 tests · 8 suites · all passing against real `v4-core`, `v4-periphery`, and OpenZeppelin.**

| Suite | Tests | Focus |
|---|---|---|
| `SandwichPredicate.t.sol` | 53 | Pure predicate: unit + fuzz, threshold monotonicity, "when detected, all 5 conditions independently hold" |
| `SearcherRegistry.t.sol` | 59 | Bond accounting: register, top-up, cooldown, slash, re-bond multiplier |
| `LPInsuranceVault.t.sol` | 53 | Accumulator math, join-after-slash, partial withdrawal, strategy yield compounding |
| `ThetaBGHook.t.sol` | 45 | Full end-to-end: slash → vault → claim, strategy-failure resilience, multi-pool isolation |
| `ThetaBGFalsePositive.t.sol` | 20 | Every "must NOT slash" scenario, named individually |
| `ThetaBGAdversarial.t.sol` | 13 | Attacks executed, not assumed — includes 2 verified findings, both fixed |
| `SearcherRegistryInvariant.t.sol` | 5 | Bond-accounting solvency, 128,000 randomized calls |
| `LPInsuranceVaultInvariant.t.sol` | 4 | Vault solvency + outstanding-claims ≤ held-assets, 128,000 randomized calls |

Every economic parameter is `immutable`. No owner, no governance, no upgrade key.

---

## Market Opportunity and Scalability

### Market Sizing

- **Total Addressable Market:** **~$60M/year** in directly measured sandwich
  extraction, plus the far larger pool of LP fee revenue at risk on volatile
  pairs as flow migrates to private venues.
- **Serviceable Addressable Market:** high-volume volatile pairs on Uniswap v4
  where sandwich frequency is concentrated and bonded-lane economics are
  attractive to searchers.
- **Serviceable Obtainable Market:** early-adopter v4 pools deploying with
  Theta-BG at initialization — new pools choosing MEV protection as a launch
  feature.

### Scalability Vectors

- **Technical:** one shared `SearcherRegistry` across every pool on a hook
  deployment; one lightweight `LPInsuranceVault` per pool, deployed in
  `afterInitialize`. Adding a pool is one `CREATE`.
- **Market:** any ERC4626 venue can back the vault — swapping in a real yield
  strategy needs only a different immutable address at the next deployment, no
  contract changes.
- **Product:** the bonded-searcher primitive extends to cross-block MEV, JIT
  liquidity, and priority-lane fee markets without redesigning the core.

### Growth Drivers

- Volatile-pair LPs seeking a second yield stream beyond swap fees.
- Pool deployers wanting MEV protection as a differentiator at launch.
- The migration-to-private-routing trend making public-pool protection a
  competitive necessity rather than a nice-to-have.

---

## Economic Model and Economics

### Revenue Streams

- **Protocol share:** 10% of every slashed bond, tracked separately in
  `pendingProtocolFees`, withdrawable only by the immutable
  `protocolFeeRecipient`.
- **Priority-lane fee:** `priorityFeeBps` (default 0.05%) charged on bonded
  searchers' exact-input swaps, donated straight into in-range LPs' fee growth.
- **LP insurance yield:** 90% of every slashed bond, compounding at strategy
  APY between slashes.

### Unit Economics

**Per 1 ETH of bond slashed:**

- **Slash trigger:** 0 additional cost — evaluated inside the swap's own
  `afterSwap`.
- **LP distribution (90%):** 0.90 ETH into the pool's insurance vault,
  distributed pro-rata to mature in-range liquidity.
- **Protocol revenue (10%):** 0.10 ETH.
- **Compounding:** the 0.90 ETH begins earning ERC4626 yield immediately and
  keeps earning until claimed.

**Live demo result (production thresholds, 0.01 ETH bond):** bond → 0 · vault
+0.009 ETH (exactly 90%) · protocol +0.001 ETH (exactly 10%).

### Value Creation Analysis

- **LP protection:** converts a sandwich from an uncompensated externality
  into a funding event for the targeted pool.
- **Compounding reserve:** the insurance fund grows the longer a pool runs
  safely — funded by attackers, compounded by yield, with no token or
  emissions.
- **Deterrence:** for the covered pattern at a chosen bond size, the expected
  value of attacking is pushed negative, so rational searchers stop.
- **Sustainability:** deeper, stickier liquidity structurally lowers sandwich
  profitability, reinforcing the protection over time.

---

## Technical Competitive Advantage

### Moats

- **Zero external dependencies:** no oracle, no AVS, no keeper, no relay. The
  entire system is deployable with nothing but Uniswap v4 and an ERC4626 vault.
- **Working-capital insurance:** prior bonding/slashing designs treat the
  insurance fund as dead collateral. Theta-BG deposits it into a yield strategy
  the instant it lands — the structural differentiator.
- **Formally-specified detection:** a conjunctive five-condition predicate,
  pure and independently fuzz-tested, not a scored heuristic a judge has to
  trust.
- **Adversarially proven:** two evasion/capture techniques were found by
  writing and running the exploit, then fixed and frozen as regression tests.

### Competitive Analysis

| | Defense | Recapture | Yield on protection fund | External deps | On-chain only |
|---|:---:|:---:|:---:|:---:|:---:|
| Flashbots Protect / MEV-Blocker | ✅ | ❌ | ❌ | High | ❌ |
| CoW Protocol | Partial | ❌ | ❌ | High | ❌ |
| Dynamic-fee hooks | Partial | ❌ | ❌ | Low | ✅ |
| Backstop (UHI10) | ✅ | ✅ | ❌ | None | ✅ |
| **Theta-BG** | ✅ | ✅ | ✅ | **None** | ✅ |

- **vs Flashbots / MEV-Blocker:** in-pool and always-on, not opt-in per user, and it returns value instead of routing flow away.
- **vs CoW:** works on every trade, not only when a counterparty match exists.
- **vs dynamic fees:** distinguishes a sandwich from an honest whale via the price-restoration condition instead of penalizing both.
- **vs Backstop:** same defense + recapture, plus the compounding ERC4626 vault Backstop's insurance pool lacks.

---

## Technical Components and Integrations

### Core Smart Contracts

- **`ThetaBGHook.sol`** — `IHooks` implementation. Identity resolution,
  per-`(pool, searcher)` open-leg tracking, predicate evaluation, slash
  triggering, priority-fee collection, LP liquidity checkpointing.
- **`SearcherRegistry.sol`** — pure bond accounting. One instance, shared by
  every pool on the hook deployment. Register, top-up, 24h withdrawal cooldown,
  slash, 2× re-bond multiplier.
- **`LPInsuranceVault.sol`** — one instance per pool, deployed from
  `afterInitialize`. Holds insurance principal, runs the ERC4626 strategy and
  the reward-per-liquidity accumulator with a 1-block liquidity maturation gate.
- **`SandwichPredicate.sol`** — pure, storage-free five-condition predicate,
  fully unit- and fuzz-testable in isolation.

### Key v4 Integrations

- **Uniswap v4 core:** `afterInitialize` (vault deployment), `beforeSwap` +
  `beforeSwapReturnDelta` (priority-fee collection via `BeforeSwapDelta`),
  `afterSwap` (detection + slash), `afterAddLiquidity` / `afterRemoveLiquidity`
  (LP checkpointing).
- **EIP-1153 transient storage:** `tstore` / `tload` for the pre-swap price
  snapshot — automatically cleared between transactions.
- **`StateLibrary` / `extsload`:** pool price read directly from the packed
  `Slot0`.
- **ERC4626:** the insurance yield venue, typed directly as OpenZeppelin's
  `IERC4626` — no bespoke adapter interface.

### Priority-Fee Mechanism

The fee is claimed inside `beforeSwap` via `BeforeSwapDelta`, then `donate()`d
into in-range LPs' `feeGrowth` — reusing Uniswap's own fee accounting rather
than building a second accumulator. Verified end-to-end: an active searcher's
swap grows `feeGrowthInside` strictly more than an identical ordinary swap.

---

## How the Hook Works

### Complete Deterrence-and-Recapture Execution Flow

**Step 1: Searcher Bonds In**

- An address calls `SearcherRegistry.register()` with `msg.value ≥ requiredBond`.
- `requiredBond` is `minimumBond` for a clean searcher, `2 × minimumBond` after any slash.
- A 24-hour withdrawal cooldown means a bond posted before an attack cannot be pulled out between the attack's legs.

**Step 2: Front-Run (TX 1)**

- The searcher swaps, pushing price up. `beforeSwap` snapshots the pre-swap `sqrtPriceX96` in transient storage; `afterSwap` writes `openLegs[pool][searcher]` with the before/after price and direction.
- The front-run must displace price by at least `minDisplacementBps` (0.5%) to be eligible — dust swaps can't grief the detector.

**Step 3: Victim Swap (TX 2, same block)**

- Any address that is not the searcher swaps at the worse price the front-run created.
- The victim is not a bonded searcher, so no open leg is written. `lastSwapSender[pool]` records their address for condition 3.

**Step 4: Back-Run (TX 3, same block)**

- The searcher swaps in the opposite direction, restoring price to within `restorationThresholdBps` (0.1%) of where TX 1 started.
- `afterSwap` reconstructs `(a = open leg, b = synthetic record with sender = priorSender, c = this swap)` and calls `SandwichPredicate.isSandwich(...)`.

**Step 5: Slash and Recapture**

- All five conditions hold **and** `registry.isActiveSearcher(searcher)` is true → `registry.slash(searcher)` zeroes the entire bond.
- Split: 10% → `pendingProtocolFees`, 90% → `vault.receiveSlash{value: insuranceCut}()`.
- The vault increments `accInsurancePerLiquidityX128` by `insuranceCut · Q128 / poolEligibleLiquidity`, pushes a `slashHistory` checkpoint, and deposits the WETH into its ERC4626 strategy.
- Every mature in-range LP's `claimable()` balance rises — in the same block — and keeps growing at strategy APY until claimed via `claimInsuranceYield(...)`.

**Result:** the searcher's forfeited bond becomes a compounding yield stream
for the LPs whose liquidity they were trading against, with no oracle, keeper,
or off-chain actor anywhere in the path.

---

## Schematic

### Theta-BG Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ SEARCHER LAYER                                                   │
│                                                                 │
│   register() msg.value ≥ requiredBond                            │
│   ┌───────────────────────────────────────────┐                  │
│   │ SearcherRegistry  (ONE, shared)          │                  │
│   │   - bond, slashCount, withdrawalUnlock    │                  │
│   │   - requiredBond = minimumBond × (slashed ? 2 : 1)           │
│   │   - 24h withdrawal cooldown               │                  │
│   └───────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────┘
      ↓ bonded searcher swaps
┌─────────────────────────────────────────────────────────────────┐
│ UNISWAP v4 HOOK LAYER  —  ThetaBGHook                            │
│                                                                 │
│   TX1 front-run  →  openLegs[pool][searcher] = {before, after}   │
│   TX2 victim     →  lastSwapSender[pool] = victim                │
│   TX3 back-run   →  a = openLeg, b = victim, c = this swap       │
│                                                                 │
│   ┌───────────────────────────────────────────┐                  │
│   │ SandwichPredicate.isSandwich(a, b, c)     │                  │
│   │   1 same searcher brackets victim         │                  │
│   │   2 same block                            │                  │
│   │   3 distinct middle address               │                  │
│   │   4 opposite directions                   │                  │
│   │   5 price displaced ≥0.5% then restored ≤0.1%                │
│   └───────────────────────────────────────────┘                  │
│               ↓ all 5 true AND isActiveSearcher                  │
│   registry.slash(searcher)  →  entire bond, zeroed               │
└─────────────────────────────────────────────────────────────────┘
      ↓ slashed bond                    ↓ 10%
┌──────────────────────────────────┐   ┌───────────────────────────┐
│ LPInsuranceVault  (ONE per pool) │   │ pendingProtocolFees       │
│   receiveSlash{value: 90%}()     │   │  (protocolFeeRecipient)   │
│   accInsurancePerLiquidityX128   │   └───────────────────────────┘
│     += 90% · Q128 / eligibleLiq  │
│   slashHistory.push(checkpoint)  │
│   strategy.deposit(90%)  ────────┼──►┌───────────────────────────┐
│                                  │   │ ERC4626 Yield Strategy    │
│   claimInsuranceYield(...)       │◄──┤  - holds shares not tokens │
└──────────────────┬───────────────┘   │  - compounds between slash │
                   ↓ pro-rata          └───────────────────────────┘
┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
│ LIQUIDITY PROVIDER │ │ LIQUIDITY PROVIDER │ │ LIQUIDITY PROVIDER │
│  mature in-range   │ │  mature in-range   │ │  mature in-range   │
│  claimable ↑       │ │  claimable ↑       │ │  claimable ↑       │
└───────────────────┘ └───────────────────┘ └───────────────────┘
```

---

## Adversarial Findings — Fixed and Frozen as Regression Tests

| Finding | The attack | The fix |
|---|---|---|
| **Ring-buffer eviction** | A single unrelated swap slipped between the victim and back-run legs evicted the front-run record from a 3-slot pool-wide buffer, so condition 1 never matched. | Detection re-keyed per `(pool, searcher)`. A searcher's open leg can only be consumed by that same searcher's next swap — no third-party swap can touch it. Regression tests cover any number of decoys. |
| **Flash liquidity at slash** | An LP added a large position in the same block as, just before, a slash-triggering back-run, then removed it immediately after — capturing a share for near-zero exposure. | Liquidity must mature `LIQUIDITY_MATURATION_BLOCKS` (1 block) before it counts toward a slash's divisor *or* earns from it. An append-only `slashHistory` + binary search credits each position at its exact maturity boundary. |

Both were confirmed by executing the exploit and watching it succeed, then
closed — not assumed safe from reading the code.

---

## Live On-Chain Proof

**Unichain Sepolia (chain 1301) — deployed, verified on Uniscan, production thresholds:**

| Contract | Address |
|---|---|
| `ThetaBGHook` | `0x9739F9f628e06B0F1Da21A8AB841067856Fa15c8` |
| `SearcherRegistry` | `0x19d73C0f5cceb36D08B1272E292d86275Fd4c808` |
| `LPInsuranceVault` (demo pool) | `0x7D881A58E9231EEEf17800cA8d3dF4a6eB6f966d` |

A real front-run → victim → back-run against the live pool: front-run
displaced price **372.9 bps**; back-run closed **1.72 bps** from the start —
inside the tight 0.1% production band, achieved by computing the exact input
with v4's own `SqrtPriceMath`. Searcher bond → **0**, vault **+0.009 ETH**,
protocol **+0.001 ETH**. Three transaction hashes in `DEPLOYMENT.md`.

---

Theta-BG transforms a sandwich attack from an uncompensated tax on public AMM
liquidity into a funding event for the pool it targeted. Registered searchers
post a bond for priority access; a pure on-chain predicate detects the
same-block bracketing pattern with no oracle or keeper; a detected attack
forfeits the entire bond into a self-compounding ERC4626 insurance vault that
pays LPs pro-rata — making the pool harder to attack and more rewarding to
provide liquidity to the longer it runs safely.

**Team:** Samuel1505
**GitHub:** https://github.com/Samuel1505/Theta-BG
**Track:** UHI10 Hookathon — Sustainable Liquidity & MEV Protection

---

### Sources for the figures cited

- ~$60M/year direct swapper cost across ~95,000 attacks (Nov 2024–Oct 2025);
  ~38% of attacks targeting stablecoin pools — 2025 Ethereum sandwich-MEV
  remeasurement / EigenPhi-derived reporting.
- 37% of victims migrating to private routing within 60 days, 54% after
  repeated attacks — *Sandwiched and Silent: Behavioral Adaptation and Private
  Channel Exploitation in Ethereum MEV*, arXiv:2512.17602.
- Sandwich mechanics and "low-liquidity pools are more vulnerable" — Uniswap's
  own MEV / swap-protection documentation.

Numbers vary by methodology and year; this submission deliberately uses the
conservative recent measurement rather than a larger historical headline.
