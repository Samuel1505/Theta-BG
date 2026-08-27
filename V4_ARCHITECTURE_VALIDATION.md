# V4 Architecture Validation — Phase 1

Source inspected: `lib/v4-core` (Uniswap/v4-core @ `main`, cloned 2026-08-25),
`lib/v4-periphery` (Uniswap/v4-periphery @ `main`, commit `dce236d`),
`lib/openzeppelin-contracts` (OpenZeppelin/openzeppelin-contracts @ `master`).

Format per mechanism: **what v4 actually does → what Theta-BG requires →
compatible? → what implementation follows.**

---

## 1. Hook identity: `sender` is the direct caller of `PoolManager`, not `tx.origin`

**What v4 does.** `IHooks.beforeSwap`/`afterSwap`
(`lib/v4-core/src/interfaces/IHooks.sol:96,108`) receive `address sender`,
documented as *"The initial msg.sender for the swap call"*. Tracing into
`Hooks.beforeSwap`/`afterSwap` (`lib/v4-core/src/libraries/Hooks.sol:248,285`),
this value is `msg.sender` **at the point `PoolManager.swap()` is invoked**
— i.e. whichever contract or EOA directly called the PoolManager. If a
router (Universal Router, a custom aggregator, `PoolSwapTest`, etc.) sits
between the end user and the PoolManager, the hook sees the router's
address, not the end user's.

**What Theta-BG requires.** The bonded searcher's identity must be
attributable per swap, with no way for an attacker to launder identity
through an intermediary contract, and no way for an unrelated address to be
mistakenly attributed as a searcher.

**Compatible?** Only under a restriction. Trusting `hookData`-supplied
identity (e.g., "swapper claims to be address X in the calldata") is
spoofable — anyone can pass any address in `hookData`. The only
non-spoofable identity available to the hook is `sender` itself.

**Implementation decision.** Theta-BG defines **searcher identity =
`sender`, the direct caller of `PoolManager.swap()`.** Bonded searchers
must call swap directly (or through a contract they control end-to-end,
which is their own risk) — they are not routed through a shared aggregator
for the purposes of the bonded lane. A swap arriving through an
unrecognized intermediary is simply treated as an ordinary (non-searcher)
swap: it pays no priority fee, is not subject to the searcher predicate, and
cannot be slashed as a searcher. This is a deliberate scope restriction, not
a workaround — it trades "supports every router" for "identity cannot be
spoofed." Documented in `LIMITATIONS.md`.

---

## 2. EIP-1153 transient storage is transaction-scoped — confirmed from v4-core's own usage

**What v4 does.** `PoolManager`'s own flash-accounting state —
`Lock.IS_UNLOCKED_SLOT`, `CurrencyReserves`, `NonzeroDeltaCount`, and every
per-caller `currencyDelta` — all live in transient storage
(`lib/v4-core/src/libraries/TransientStateLibrary.sol`, using `tload`/
`tstore` via `exttload`). The `unlock()` pattern requires every currency
delta to net to zero **before the same transaction's top-level call
returns** (`NonzeroDeltaCount` must be zero to re-lock). This is only
possible because EIP-1153 storage is wiped at the end of the transaction —
v4-core's own core accounting depends on this exact property.

**What Theta-BG requires (per brief).** A mechanism that remembers a
searcher's front-run and pairs it back up with their own back-run —
front-run, victim, back-run — where those three swaps are ordinarily
**three separate transactions** that happen to land in the same block.

**Compatible?** **No, not as described in the brief.** Transient storage
cannot carry data from transaction 1 to transaction 2 — it is gone the
instant transaction 1 ends. The brief's own data-flow example ("TX 1 —
tstore(...)", "TX 2 — tstore(...)", "TX 3 — tstore(...) ... _checkAndSlash()")
is internally inconsistent: it labels three separate transactions while
using `tstore`, which cannot survive between them. This is the single most
important correction to the brief's mechanism.

**Implementation decision.** Split state by actual scope:
- **Persistent storage** (regular `SSTORE`) for a per-`(poolId, searcher)`
  "open leg" — `(blockNumber, zeroForOne, sqrtPriceX96Before, sqrtPriceX96After)`
  for that searcher's most recent unclosed swap in the current block, plus a
  single per-pool "last swap sender" value used to reconstruct who (if
  anyone) swapped between a searcher's open leg and its close. A read
  compares the stored `blockNumber` to `block.number`; a stale entry
  (different block) is treated as empty rather than physically cleared —
  cheaper, and avoids a race where a same-block "reset" could be reordered.
  (An earlier version of this design used a fixed 3-slot ring buffer keyed
  by pool position rather than by searcher — abandoned after
  `test/ThetaBGAdversarial.t.sol` proved it had a real eviction gap: any
  unrelated swap landing between the victim and back-run legs could evict
  the front-run record before the bracket completed, since the buffer held
  "the last 3 swaps in the pool" rather than "this searcher's own last
  swap." Keying per searcher instead means only that searcher's own next
  swap can ever consume or overwrite their open leg — see `ThetaBGHook.sol`'s
  `OpenLeg` struct and `_tryDetectAndSlash`.)
- **Transient storage** is still used, but only for its legitimate scope:
  passing `sqrtPriceX96` captured in `beforeSwap` to the same call's
  `afterSwap` (both invoked within the *same* `PoolManager.swap()`
  transaction), avoiding an extra persistent `SSTORE`/`SLOAD` round trip for
  data that only needs to survive one transaction. This is the correct,
  narrow use of EIP-1153 — not the cross-transaction use the brief implied.

**Terminology correction.** The brief calls this "same-block" detection in
some places and implies "same-transaction" (via `tstore`) in others.
Theta-BG's actual predicate is **same-block, cross-transaction** detection
using persistent storage. Docs and code use "same-block" consistently going
forward; "same-transaction" is never claimed.

---

## 3. `BeforeSwapDelta` / priority fee collection

**What v4 does.** `Hooks.beforeSwap` (`Hooks.sol:248`) lets a hook return a
`BeforeSwapDelta` only if the hook has the `BEFORE_SWAP_RETURNS_DELTA_FLAG`
permission. The returned delta's *specified*-currency component adjusts
`amountToSwap` directly (`Hooks.sol:270-279`) — this is how a hook can take
a cut of the swap's specified currency atomically, before the swap executes
against the pool. The *unspecified* component (and any `afterSwap` return)
is settled by `PoolManager` reducing/increasing the swapper's final
`BalanceDelta` (`Hooks.sol:305-313`). Every such delta the hook claims must
be backed by the hook actually holding/settling that currency inside the
same `unlock()` callback (via `IPoolManager.take()`/`sync()`/`settle()`) —
the flash-accounting invariant (`NonzeroDeltaCount == 0` at unlock) reverts
the whole transaction otherwise. There is no separate `transfer()` call and
no reentrancy surface from this path — the accounting is enforced by
`PoolManager` itself, not by hook-side bookkeeping.

**What Theta-BG requires.** Collect a priority fee from bonded searchers,
atomically, without a second token transfer.

**Compatible?** Yes — this is exactly the idiomatic v4 pattern. Confirmed
correct.

**Implementation decision.** `ThetaBGHook` sets
`beforeSwapReturnDelta: true`. In `beforeSwap`, if `sender` is a registered
searcher, the hook returns a `BeforeSwapDelta` that debits the searcher's
specified-currency amount by the configured priority fee, and calls
`poolManager.take(currency, address(this), fee)` within the same unlocked
callback to actually pull the settled amount to the hook's own balance,
which the hook then forwards to LPs (see §7). Non-searcher swaps are
untouched (delta = 0).

---

## 4. LP position accounting — no enumeration, use v4's own accounting primitive

**What v4 does.** `StateLibrary.getLiquidity(manager, poolId)`
(`lib/v4-core/src/libraries/StateLibrary.sol:183`) reads `pools[poolId].liquidity`
directly via `extsload` — this is the pool's current **active (in-range)**
liquidity, the same number used in the pool's own swap math. It is O(1),
requires no enumeration, and needs no per-position knowledge.
`StateLibrary.getPositionInfo(manager, poolId, owner, tickLower, tickUpper, salt)`
(`StateLibrary.sol:230`) reads a single position's liquidity, keyed exactly
as `Position.calculatePositionKey(owner, tickLower, tickUpper, salt)` — but
there is **no enumerable list of positions or owners** anywhere in
`PoolManager`. A hook cannot iterate "all LPs."

**What Theta-BG requires.** Distribute slashed-bond insurance pro-rata to
LPs, weighted by their liquidity at the time of each slash, without
iterating an unbounded LP set (brief §32 in the build prompt explicitly
rules this out, correctly).

**Compatible?** Yes, using the same accounting pattern Uniswap itself uses
for swap fees: a **global reward-per-liquidity accumulator**, updated at
each slash using `StateLibrary.getLiquidity()` as the divisor (the
in-range liquidity actually exposed to that swap's price impact), with
**per-position checkpoints** settled whenever a position's liquidity
changes.

**Implementation decision.**
- `accInsurancePerLiquidityX128` (per pool) increases on every slash by
  `insuranceShare * Q128 / activeLiquidityAtSlash`. If
  `activeLiquidityAtSlash == 0` (no in-range liquidity), the insurance share
  is still deposited into the vault as principal but is not distributed via
  the accumulator — see `LIMITATIONS.md` for this edge case.
- `ThetaBGHook` adds `afterAddLiquidity: true` and `afterRemoveLiquidity: true`
  permissions **not present in the brief's permission list** — required to
  checkpoint a position's `rewardDebt` and settle its accrued-but-unclaimed
  insurance *before* its liquidity changes (standard MasterChef/Synthetix
  reward-accounting pattern; without this checkpoint, an LP who adds
  liquidity after a slash and claims later would wrongly capture rewards
  accrued before they had any liquidity in the pool — this is a real
  accounting bug the brief's design left unaddressed, see §30-31 of the
  build brief).
- `claimInsuranceYield(poolKey, tickLower, tickUpper, salt)` settles and
  pays out a specific position's accrued share. No LP array, no iteration.
- **Known residual risk** (documented, not silently mitigated): an LP who
  adds a large position in the same block as — but strictly before — a
  slash-triggering back-run transaction, then removes it shortly after, can
  claim a share of that one slash despite near-zero holding duration
  ("flash-LP at slash" — brief §53). A full fix needs time-weighted or
  one-block-delayed eligibility; the hackathon build documents this in
  `SECURITY.md`/`LIMITATIONS.md` rather than shipping a partially-verified
  snapshot system.

---

## 5. Reentrancy surface: hook → registry → vault → ERC4626 → external strategy

**What v4 does.** `PoolManager` is reentrancy-guarded at the `unlock()`
level (only one unlocked call context at a time — `Lock.sol`), but that
guard protects `PoolManager` itself, not `ThetaBGHook`, `SearcherRegistry`,
or `LPInsuranceVault`. Once `afterSwap` starts calling out to
`SearcherRegistry.slash()` → `LPInsuranceVault.receiveSlash()` →
`IERC4626.deposit()` → an external lending protocol, every one of those is
an ordinary external call with no PoolManager-level protection.

**What Theta-BG requires.** The slash path must not be reenterable in a way
that double-slashes a bond, double-credits the vault, or lets a malicious
ERC4626 strategy / token reenter and drain state.

**Compatible?** Yes, with explicit guards — not "atomicity implies safety."

**Implementation decision.**
- `SearcherRegistry.slash()` follows checks-effects-interactions: bond
  balance is decremented (effects) before any external token transfer.
- `LPInsuranceVault.receiveSlash()` updates `accInsurancePerLiquidityX128`
  and vault-share accounting (effects) before calling into the external
  ERC4626 strategy (interaction).
- `LPInsuranceVault` uses OpenZeppelin `ReentrancyGuard` on
  `claimInsuranceYield()` and `receiveSlash()`.
- A failed/reverting external strategy deposit must **not** revert the
  slash itself (see §7 below) — the hook's core guarantee (bond gets
  slashed, searcher is punished) must not depend on an external protocol's
  liveness.

---

## 6. ERC4626 integration is a real external dependency, not "zero dependencies"

**What v4 does / what's actually external.** `PoolManager`, `Hooks`, and
the EVM are the only trust-free components. An ERC4626 strategy (Aave v3,
Morpho Blue, or any vault) is a **separate protocol** with its own
liveness, insolvency, and share-price-manipulation risk (see
`SECURITY.md` §"ERC4626 / strategy risk" for the inflation-attack and
donation-attack analysis).

**Correction applied.** The brief's claim "zero external dependencies
beyond Uniswap v4 + ERC4626 vault" is retained nowhere as "zero
dependencies" — it is restated everywhere as: *no oracle, no keeper, no
AVS, no off-chain component are required for detection or slashing; the
yield strategy is an explicit, documented external trust boundary,
isolated behind an `IYieldStrategy` adapter so it can be swapped, disabled,
or mocked without touching slash/detection logic.*

---

## 7. Strategy-deposit failure must not block a slash

**What v4 does.** N/A — this is a Theta-BG design requirement, but it
follows directly from §5: an `afterSwap` hook call that reverts causes the
**entire swap transaction to revert** (`Hooks.callHook` bubbles up any
failure). If slashing were implemented as "slash bond → must succeed in
depositing to Aave or the whole slash reverts," then a temporarily paused
or reverting external strategy would let a searcher's *sandwich itself*
revert along with the slash — worse, the victim's own swap transaction
(transaction 2) is unaffected since the predicate only fires on the
back-run (transaction 3), but transaction 3 reverting means the searcher
keeps their bond and the "attack" technically didn't complete as
back-run — this needs care.

**Implementation decision.** `LPInsuranceVault.receiveSlash()` **always**
succeeds at the accounting layer (bond moves from registry to vault,
`accInsurancePerLiquidityX128` updates) regardless of whether the
downstream ERC4626 strategy deposit succeeds. The strategy deposit is
wrapped in a try/catch; on failure, funds are simply held as idle assets in
the vault (still claimable by LPs, just not earning strategy yield until a
retry/harvest call succeeds). This guarantees the core deterrence property
(bond is always slashed when the predicate fires) never depends on
external protocol liveness.

---

## Dependency versions

| Package | Repo | Ref installed |
|---|---|---|
| forge-std | foundry-rs/forge-std | latest (`forge init` default) |
| v4-core | Uniswap/v4-core | `main` @ time of clone (2026-08-25) |
| v4-periphery | Uniswap/v4-periphery | `main` @ `dce236d` (2026-08-20) |
| openzeppelin-contracts | OpenZeppelin/openzeppelin-contracts | `master` @ time of clone |

Note: `v4-periphery`'s `BaseHook.sol` convenience base contract is **not
present** in the currently-installed `main` branch (its `src/` was
restructured; no `abstract contract BaseHook` exists under
`src/base` or `src/hooks` at this ref). `ThetaBGHook` therefore implements
`IHooks` directly against `v4-core`, using `Hooks.validateHookPermissions`
in its constructor rather than inheriting a periphery base contract. This
avoids depending on periphery internals that are mid-restructure, and is a
one-file, auditable amount of boilerplate on top of `IHooks`.
