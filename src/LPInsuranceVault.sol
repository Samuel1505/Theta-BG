// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice One vault per pool. Receives a pool's share of every slash as
/// native ETH, wraps it to WETH, and deposits it into an external ERC4626
/// yield strategy. Distribution to LPs uses a fee-growth-style
/// reward-per-liquidity accumulator — never an enumerable LP list. See
/// V4_ARCHITECTURE_VALIDATION.md §4 for why this shape was chosen.
///
/// Naming note: "Insurance Vault" describes what LPs can claim — their
/// accrued share of past slashes plus strategy yield on it — not a promise
/// that principal is locked/reserved against future losses. See
/// MECHANISM.md §"insurance vs reward vault" for the explicit model
/// (Model A: fully claimable) and why that was chosen over locking
/// principal.
///
/// Liquidity eligibility: newly added liquidity does not count toward a
/// slash's divisor, and cannot accrue any share of a slash, until it has
/// been present for at least `LIQUIDITY_MATURATION_BLOCKS`. This closes the
/// flash-liquidity-at-slash gap documented in SECURITY.md/LIMITATIONS.md —
/// see `_syncPosition`/`_syncPool` and MECHANISM.md for the full design.
/// LP position liquidity itself is tracked entirely internally (via
/// `checkpoint`, called on every add/remove by ThetaBGHook) rather than
/// read live from PoolManager at claim time, since it must always equal
/// exactly what this vault has been told about — StateLibrary's live value
/// would include not-yet-eligible liquidity that must never be creditable.
contract LPInsuranceVault is ReentrancyGuard {
    error NotHook();
    error NoClaimable();
    error ZeroValue();

    event InsuranceFunded(uint256 assetsIn, uint256 accInsurancePerLiquidityX128, uint128 eligibleLiquidityAtSlash);
    event StrategyDepositFailed(uint256 amount);
    event StrategyWithdrawFailed(uint256 amount);
    event LPInsuranceClaimed(address indexed owner, int24 tickLower, int24 tickUpper, bytes32 salt, uint256 amount);

    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;
    IWETH9 public immutable weth;
    IERC4626 public immutable strategy; // strategy.asset() MUST equal address(weth)
    address public immutable hook;

    /// @notice How long newly added liquidity must sit before it can affect
    /// a slash's divisor or accrue any share of one. A same-block add is
    /// exactly the flash-liquidity attack this exists to close; one block
    /// is the minimum delay that defeats it, so that's what's used — see
    /// MECHANISM.md for why this isn't a configurable/larger parameter.
    uint256 public constant LIQUIDITY_MATURATION_BLOCKS = 1;

    /// @notice Reward-per-unit-*eligible*-liquidity accumulator, Q128 fixed
    /// point. Increases only when a slash occurs while eligible liquidity
    /// > 0.
    uint256 public accInsurancePerLiquidityX128;

    /// @notice WETH held directly by this vault, not currently deposited in
    /// the strategy (e.g. a slash landed when eligible liquidity == 0, or a
    /// strategy deposit failed and was not retried).
    uint256 public idleAssets;

    /// @notice Cumulative WETH ever handed to the strategy, for dashboards.
    uint256 public principalDeposited;

    /// @notice Pool-wide aggregate of eligible/pending liquidity, kept in
    /// sync with the sum of every position's own eligible/pending fields
    /// below via identical apply-delta logic on every `checkpoint` call.
    /// This is the divisor `receiveSlash` uses — never PoolManager's live
    /// total, which would include immature liquidity.
    uint128 public poolEligibleLiquidity;
    uint128 public poolPendingLiquidity;
    uint64 public poolPendingBlock;

    /// @notice One entry per slash that actually moved the accumulator
    /// (never for the idle-fallback case, which doesn't move it). Lets
    /// `_syncPosition`/`claimable` look up "what was the accumulator value
    /// immediately before block N" for any position's specific maturity
    /// block, so a position that matured *between* two slashes gets
    /// credited for the later one but never the earlier one it wasn't yet
    /// eligible for — see `_syncPosition` for the full reasoning.
    ///
    /// Growth here is bounded by the number of *successful attacks*
    /// against this pool, not by ordinary swap/liquidity activity — each
    /// entry requires a searcher's entire bond to have just been slashed,
    /// which is exactly the kind of economically-costly-to-grow state the
    /// "no unbounded per-block/per-swap state" principle is about, not a
    /// free griefing vector.
    struct SlashCheckpoint {
        uint64 blockNumber;
        uint256 accAfter;
    }

    SlashCheckpoint[] public slashHistory;

    function slashHistoryLength() external view returns (uint256) {
        return slashHistory.length;
    }

    struct PositionInfo {
        uint256 rewardDebtX128;
        uint256 owed;
        uint128 eligibleLiquidity;
        uint128 pendingLiquidity;
        uint64 pendingBlock;
    }

    mapping(bytes32 positionKey => PositionInfo) public positions;

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(IPoolManager _poolManager, PoolId _poolId, IWETH9 _weth, IERC4626 _strategy, address _hook) {
        poolManager = _poolManager;
        poolId = _poolId;
        weth = _weth;
        strategy = _strategy;
        hook = _hook;
    }

    receive() external payable {}

    /// @notice Total assets currently attributable to this pool's insurance
    /// reserve: idle WETH plus the redeemable value of strategy shares.
    /// This is the "self-compounding" number — it grows both from new
    /// slashes and from strategy yield accruing between them.
    function availableBalance() external view returns (uint256) {
        uint256 shares = strategy.balanceOf(address(this));
        uint256 strategyValue = shares == 0 ? 0 : strategy.previewRedeem(shares);
        return idleAssets + strategyValue;
    }

    /// @notice Called by the hook immediately after a slash, forwarding the
    /// pool's insurance share as native ETH. Always succeeds at the
    /// accounting layer even if the downstream strategy deposit fails
    /// (V4_ARCHITECTURE_VALIDATION.md §7) — the core deterrence guarantee
    /// (bond gets slashed) must never depend on an external protocol's
    /// liveness.
    function receiveSlash() external payable onlyHook nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) return;

        weth.deposit{value: amount}();
        _syncPool();

        uint128 eligible = poolEligibleLiquidity;
        if (eligible == 0) {
            // Either genuinely no liquidity, or every bit of current
            // liquidity was added this same block and hasn't matured yet
            // (the exact flash-liquidity case this design closes). Held as
            // idle principal either way; see LIMITATIONS.md "zero eligible
            // liquidity at slash time" for why this is not distributed
            // retroactively once liquidity matures.
            idleAssets += amount;
            emit InsuranceFunded(amount, accInsurancePerLiquidityX128, 0);
            return;
        }

        accInsurancePerLiquidityX128 += FullMath.mulDiv(amount, FixedPoint128.Q128, eligible);
        slashHistory.push(SlashCheckpoint({blockNumber: uint64(block.number), accAfter: accInsurancePerLiquidityX128}));
        _depositToStrategy(amount);
        emit InsuranceFunded(amount, accInsurancePerLiquidityX128, eligible);
    }

    function _depositToStrategy(uint256 amount) private {
        weth.approve(address(strategy), amount);
        try strategy.deposit(amount, address(this)) returns (uint256) {
            principalDeposited += amount;
        } catch {
            weth.approve(address(strategy), 0);
            idleAssets += amount;
            emit StrategyDepositFailed(amount);
        }
    }

    /// @notice Checkpoints a position on every liquidity change — called by
    /// the hook from afterAddLiquidity/afterRemoveLiquidity with the exact
    /// signed liquidity delta being applied. Settles accrued-but-unclaimed
    /// insurance at the position's *eligible* liquidity (never its raw
    /// live liquidity) before applying the change, then updates both the
    /// position's and the pool's eligible/pending tracking to match.
    function checkpoint(address owner, int24 tickLower, int24 tickUpper, bytes32 salt, int256 liquidityDelta)
        external
        onlyHook
    {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        PositionInfo storage p = positions[key];

        _syncPosition(p);
        _syncPool();
        _settleOwed(p);
        _applyPositionDelta(p, liquidityDelta);
        _applyPoolDelta(liquidityDelta);
    }

    /// @notice Claims a specific position's accrued insurance share. No LP
    /// enumeration — the caller names their own position. Liquidity is
    /// read from this vault's own tracking (kept exactly in sync with
    /// PoolManager by `checkpoint` being called on every change), not from
    /// a live StateLibrary read, since eligibility — not raw liquidity — is
    /// what must gate accrual here.
    function claimInsuranceYield(int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        nonReentrant
        returns (uint256 amount)
    {
        bytes32 key = keccak256(abi.encodePacked(msg.sender, tickLower, tickUpper, salt));
        PositionInfo storage p = positions[key];

        _syncPosition(p);
        _settleOwed(p);

        amount = p.owed;
        if (amount == 0) revert NoClaimable();
        p.owed = 0;

        emit LPInsuranceClaimed(msg.sender, tickLower, tickUpper, salt, amount);
        _payOut(msg.sender, amount);
    }

    /// @notice View-only mirror of `_syncPosition`'s exact logic (see its
    /// doc comment) — computed locally without mutating storage, so this
    /// always reports exactly what an actual `claimInsuranceYield()` call
    /// would pay out right now, never an optimistic estimate a real claim
    /// couldn't back up.
    function claimable(address owner, int24 tickLower, int24 tickUpper, bytes32 salt) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        PositionInfo storage p = positions[key];

        uint256 owed = p.owed;
        uint256 rewardDebt = p.rewardDebtX128;
        uint128 eligible = p.eligibleLiquidity;

        if (p.pendingBlock != 0 && block.number >= p.pendingBlock + LIQUIDITY_MATURATION_BLOCKS) {
            uint64 maturityBlock = p.pendingBlock + uint64(LIQUIDITY_MATURATION_BLOCKS);
            uint256 accBeforeMaturity = _accBeforeBlock(maturityBlock);

            uint256 oldDelta = accInsurancePerLiquidityX128 - rewardDebt;
            if (oldDelta != 0 && eligible != 0) {
                owed += FullMath.mulDiv(oldDelta, eligible, FixedPoint128.Q128);
            }
            uint256 newDelta = accInsurancePerLiquidityX128 - accBeforeMaturity;
            if (newDelta != 0 && p.pendingLiquidity != 0) {
                owed += FullMath.mulDiv(newDelta, p.pendingLiquidity, FixedPoint128.Q128);
            }

            eligible += p.pendingLiquidity;
            rewardDebt = accInsurancePerLiquidityX128;
        }

        uint256 delta = accInsurancePerLiquidityX128 - rewardDebt;
        uint256 pending = delta == 0 || eligible == 0 ? 0 : FullMath.mulDiv(delta, eligible, FixedPoint128.Q128);
        return owed + pending;
    }

    /// @notice This position's liquidity as this vault currently tracks it
    /// — eligible + still-pending — for dashboards/tests to cross-check
    /// against PoolManager's live value, which must always agree.
    function positionLiquidity(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 eligible, uint128 pending, uint64 pendingBlock)
    {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        PositionInfo storage p = positions[key];
        return (p.eligibleLiquidity, p.pendingLiquidity, p.pendingBlock);
    }

    /// @notice Promotes a position's matured pending liquidity into
    /// eligible, splitting credit for any unsynced accumulator delta
    /// exactly at the maturity boundary rather than crediting all (or
    /// none) of it to whichever amount happens to be current when this
    /// finally runs:
    ///
    /// - The pre-existing eligible amount earns the *entire* delta since
    ///   its own rewardDebt checkpoint, as always — it was eligible
    ///   throughout, unaffected by this position's pending liquidity.
    /// - The newly-matured (former pending) amount earns *only* the
    ///   accumulator growth since its own maturity block — found via
    ///   `_accBeforeBlock`, which looks up the accumulator value
    ///   immediately before that block from `slashHistory`. This is what
    ///   actually closes the flash-liquidity gap precisely: liquidity
    ///   added the same block as a slash gets `accBeforeMaturity ==
    ///   accAfter-that-slash`, so `newDelta` for that slash is zero: the
    ///   same-block slash correctly contributes nothing, while a slash
    ///   the *next* block or later correctly does.
    ///
    /// This is the maturity-precise version of the same idea `checkpoint`
    /// used to use (a single `liquidityBefore`/settle-then-apply step) —
    /// generalized to handle a maturity boundary landing anywhere between
    /// two slashes, not just immediately before or after one.
    function _syncPosition(PositionInfo storage p) private {
        if (p.pendingBlock == 0 || block.number < p.pendingBlock + LIQUIDITY_MATURATION_BLOCKS) return;

        uint64 maturityBlock = p.pendingBlock + uint64(LIQUIDITY_MATURATION_BLOCKS);
        uint256 accBeforeMaturity = _accBeforeBlock(maturityBlock);

        uint256 oldDelta = accInsurancePerLiquidityX128 - p.rewardDebtX128;
        if (oldDelta != 0 && p.eligibleLiquidity != 0) {
            p.owed += FullMath.mulDiv(oldDelta, p.eligibleLiquidity, FixedPoint128.Q128);
        }
        uint256 newDelta = accInsurancePerLiquidityX128 - accBeforeMaturity;
        if (newDelta != 0 && p.pendingLiquidity != 0) {
            p.owed += FullMath.mulDiv(newDelta, p.pendingLiquidity, FixedPoint128.Q128);
        }

        p.eligibleLiquidity += p.pendingLiquidity;
        p.pendingLiquidity = 0;
        p.pendingBlock = 0;
        p.rewardDebtX128 = accInsurancePerLiquidityX128;
    }

    /// @notice The accumulator's value immediately before `targetBlock` —
    /// i.e. the `accAfter` of the last slash strictly before it, or 0 if
    /// none. Binary search over `slashHistory`, which is append-only and
    /// sorted by block number by construction.
    function _accBeforeBlock(uint64 targetBlock) private view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = slashHistory.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (slashHistory[mid].blockNumber >= targetBlock) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo == 0 ? 0 : slashHistory[lo - 1].accAfter;
    }

    function _syncPool() private {
        if (poolPendingBlock != 0 && block.number >= poolPendingBlock + LIQUIDITY_MATURATION_BLOCKS) {
            poolEligibleLiquidity += poolPendingLiquidity;
            poolPendingLiquidity = 0;
            poolPendingBlock = 0;
        }
    }

    function _settleOwed(PositionInfo storage p) private {
        uint256 delta = accInsurancePerLiquidityX128 - p.rewardDebtX128;
        if (delta != 0 && p.eligibleLiquidity != 0) {
            p.owed += FullMath.mulDiv(delta, p.eligibleLiquidity, FixedPoint128.Q128);
        }
        p.rewardDebtX128 = accInsurancePerLiquidityX128;
    }

    /// @notice Applies a signed liquidity delta to a position's eligible/
    /// pending split. An increase always lands in `pending` (this block,
    /// immature); a decrease is drawn from `pending` first (undoing a
    /// same-block add before it ever matured costs nothing extra) and only
    /// then from `eligible` (reverts on underflow if the caller's delta is
    /// ever inconsistent with reality — fail loud, not silently wrap).
    function _applyPositionDelta(PositionInfo storage p, int256 liquidityDelta) private {
        if (liquidityDelta > 0) {
            p.pendingLiquidity += uint128(uint256(liquidityDelta));
            p.pendingBlock = uint64(block.number);
        } else if (liquidityDelta < 0) {
            uint128 removed = uint128(uint256(-liquidityDelta));
            uint128 fromPending = removed < p.pendingLiquidity ? removed : p.pendingLiquidity;
            p.pendingLiquidity -= fromPending;
            removed -= fromPending;
            if (removed > 0) p.eligibleLiquidity -= removed;
        }
    }

    function _applyPoolDelta(int256 liquidityDelta) private {
        if (liquidityDelta > 0) {
            poolPendingLiquidity += uint128(uint256(liquidityDelta));
            poolPendingBlock = uint64(block.number);
        } else if (liquidityDelta < 0) {
            uint128 removed = uint128(uint256(-liquidityDelta));
            uint128 fromPending = removed < poolPendingLiquidity ? removed : poolPendingLiquidity;
            poolPendingLiquidity -= fromPending;
            removed -= fromPending;
            if (removed > 0) poolEligibleLiquidity -= removed;
        }
    }

    function _payOut(address to, uint256 amount) private {
        if (idleAssets >= amount) {
            idleAssets -= amount;
        } else {
            uint256 fromStrategy = amount - idleAssets;
            idleAssets = 0;
            strategy.withdraw(fromStrategy, address(this), address(this));
        }
        weth.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }
}
