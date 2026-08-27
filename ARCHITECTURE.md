# Architecture

## Contracts

```
src/
  ThetaBGHook.sol            IHooks implementation. Owns identity resolution,
                              the per-searcher open-leg tracking, predicate
                              evaluation, slash triggering, priority-fee
                              collection, and LP liquidity checkpointing.
  SearcherRegistry.sol        Pure bond accounting. One instance, deployed by
                              the hook's constructor, shared by every pool
                              that uses this hook deployment.
  LPInsuranceVault.sol         One instance per pool, deployed from
                              afterInitialize. Holds a pool's insurance
                              principal, deposits it into an external
                              ERC4626 strategy, and runs the reward-per-
                              liquidity accumulator LPs claim against.
  libraries/
    SandwichPredicate.sol      Pure, storage-free five-condition predicate.
                              Fully unit- and fuzz-testable in isolation
                              (test/SandwichPredicate.t.sol).
```

No `interfaces/IYieldStrategy.sol` exists — the strategy is typed directly as
OpenZeppelin's `IERC4626`, which already is the standard adapter interface;
wrapping it in a second Theta-BG-specific interface would be an abstraction
with no behavior behind it.

## Why one registry, many vaults

Section 36 of the build brief lists the options for where per-pool state
lives. Theta-BG splits it:

- **One global `SearcherRegistry`** (Option A). A searcher's bond and slash
  history are meaningful across every pool this hook deployment serves —
  fragmenting bonds per pool would let a searcher attack pool A with a bond
  that's never been tested by pool B's traffic, and would multiply the
  capital a legitimate multi-pool searcher needs to lock up for no security
  benefit.
- **One `LPInsuranceVault` per pool** (Option C), deployed via `new` inside
  `afterInitialize`. Insurance principal must never leak between pools —
  Pool A's LPs should never be diluted or enriched by Pool B's sandwich
  activity. A shared vault would need a second layer of per-pool share
  accounting on top of the ERC4626 strategy's own shares; a dedicated vault
  contract per pool needs none of that, at the cost of one extra `CREATE`
  per pool initialization (bounded, one-time, acceptable gas).

## Data flow — sandwich attack (see also `MECHANISM.md`)

```
TX 1 (searcher, front-run)
  beforeSwap:  tstore(sqrtPriceX96 before this swap)     [transient, this tx only]
  afterSwap:   priorSender = lastSwapSender[poolId]; lastSwapSender[poolId] = sender
               openLegs[poolId][searcher] = {block, dir, priceBefore, priceAfter}   // no prior open leg -> nothing to evaluate yet

TX 2 (victim, any address — not the searcher)
  afterSwap:   priorSender = lastSwapSender[poolId] (== searcher); lastSwapSender[poolId] = victim
               victim is not an active searcher -> no open-leg write, buffer untouched

TX 3 (searcher, back-run, same block)
  afterSwap:   priorSender = lastSwapSender[poolId] (== victim, or the *last* of any number
               of interleaved swaps since — see V4_ARCHITECTURE_VALIDATION.md §2 for why a
               decoy swap here no longer evades this); lastSwapSender[poolId] = searcher
               leg = openLegs[poolId][searcher]   // still this block -> potential close
               a = leg (front-run), b = synthetic record with sender=priorSender, c = this swap (back-run)
               if SandwichPredicate.isSandwich(a, b, c, ...) AND registry.isActiveSearcher(searcher):
                 amount = registry.slash(searcher)          // entire bond, zeroed
                 protocolCut = amount * protocolShareBps / 10000
                 insuranceCut = amount - protocolCut
                 pendingProtocolFees += protocolCut
                 vaults[poolId].receiveSlash{value: insuranceCut}()
                   -> wrap to WETH -> accInsurancePerLiquidityX128 += insuranceCut * Q128 / activeLiquidity
                   -> try strategy.deposit(insuranceCut) catch { hold idle }
                 emit SandwichSlashed(...)
               openLegs[poolId][searcher] = {block, dir, priceBefore, priceAfter}   // this swap becomes the new open leg regardless
```

Every step above is exercised by `test/ThetaBGHook.t.sol`'s
`test_sandwichAttack_slashesBondAndFundsInsurance`, against a real
`PoolManager`, real hook, and real (mock) ERC4626 strategy — not simulated.
The decoy-swap-in-between case specifically is exercised by
`test/ThetaBGAdversarial.t.sol`'s
`test_attack_decoySwapBetweenVictimAndBackRun_noLongerEvadesDetection` and
`test_attack_multipleDecoySwaps_stillDoesNotEvadeDetection`.

## Priority fee data flow

```
beforeSwap (active searcher, exact-input swap):
  fee = specifiedAmount * priorityFeeBps / 10000
  delta = toBeforeSwapDelta(+fee, 0)         // hook claims `fee` of specified currency
  poolManager.take(specifiedCurrency, hook, fee)
  poolManager.donate(key, fee-or-0, 0-or-fee, "")   // credited to in-range LPs' feeGrowth
  hook settles the donate's own delta back to the pool (sync+transfer+settle, or settle{value:})
```

This reuses Uniswap's own fee-growth accounting for LP-facing priority-fee
revenue rather than building a second bespoke accumulator — see
`V4_ARCHITECTURE_VALIDATION.md §3`. It is verified end-to-end by
`test_priorityFee_isCollectedFromActiveSearchers`, which checks that an
active searcher's swap grows `feeGrowthInside` strictly more than an
identically-sized ordinary swap.

## LP liquidity checkpointing

```
afterAddLiquidity / afterRemoveLiquidity:
  liquidityAfter  = StateLibrary.getPositionInfo(poolId, owner, tickLower, tickUpper, salt).liquidity
  liquidityBefore = liquidityAfter - params.liquidityDelta   // signed; reverts if this underflows/overflows uint128
  vault.checkpoint(owner, tickLower, tickUpper, salt, liquidityBefore)
    -> settles this position's accrued reward at its OLD liquidity
    -> resets rewardDebt to the current global accumulator
```

This is the standard MasterChef/Synthetix "sync before mutate" reward
pattern, necessary because `StateLibrary` gives no way to enumerate
positions or be notified retroactively — see
`V4_ARCHITECTURE_VALIDATION.md §4` for why this, and not a naive
"read current liquidity at claim time," is required.

## What is immutable vs. what nothing controls

Every economic parameter (`restorationThresholdBps`, `minDisplacementBps`,
`priorityFeeBps`, `protocolShareBps`, `minimumBond`) is set once in
`ThetaBGHook`'s constructor and is `immutable`. There is no owner, no
governance hook, no function that can alter slashing behavior, redirect
insurance funds, or change fee splits after deployment. The only
"privileged" function is `withdrawProtocolFees()`, callable exclusively by
`protocolFeeRecipient`, and it can only ever move `pendingProtocolFees` — an
amount the protocol is already economically entitled to, tracked
separately from LP/searcher funds.
