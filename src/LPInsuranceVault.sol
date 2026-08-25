// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice One vault per pool. Receives a pool's share of every slash as
/// native ETH, wraps it to WETH, and deposits it into an external ERC4626
/// yield strategy. Distribution to LPs uses a fee-growth-style
/// reward-per-liquidity accumulator (StateLibrary.getLiquidity /
/// getPositionInfo) — never an enumerable LP list. See
/// V4_ARCHITECTURE_VALIDATION.md §4 for why this shape was chosen.
///
/// Naming note: "Insurance Vault" describes what LPs can claim — their
/// accrued share of past slashes plus strategy yield on it — not a promise
/// that principal is locked/reserved against future losses. See
/// MECHANISM.md §"insurance vs reward vault" for the explicit model
/// (Model A: fully claimable) and why that was chosen over locking
/// principal.
contract LPInsuranceVault is ReentrancyGuard {
    using StateLibrary for IPoolManager;

    error NotHook();
    error NoClaimable();
    error ZeroValue();

    event InsuranceFunded(uint256 assetsIn, uint256 accInsurancePerLiquidityX128, uint128 activeLiquidityAtSlash);
    event StrategyDepositFailed(uint256 amount);
    event StrategyWithdrawFailed(uint256 amount);
    event LPInsuranceClaimed(
        address indexed owner, int24 tickLower, int24 tickUpper, bytes32 salt, uint256 amount
    );

    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;
    IWETH9 public immutable weth;
    IERC4626 public immutable strategy; // strategy.asset() MUST equal address(weth)
    address public immutable hook;

    /// @notice Reward-per-unit-liquidity accumulator, Q128 fixed point.
    /// Increases only when a slash occurs while active (in-range) pool
    /// liquidity > 0.
    uint256 public accInsurancePerLiquidityX128;

    /// @notice WETH held directly by this vault, not currently deposited in
    /// the strategy (e.g. a slash landed when activeLiquidity == 0, or a
    /// strategy deposit failed and was not retried).
    uint256 public idleAssets;

    /// @notice Cumulative WETH ever handed to the strategy, for dashboards.
    uint256 public principalDeposited;

    struct PositionInfo {
        uint256 rewardDebtX128;
        uint256 owed;
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

        uint128 activeLiquidity = poolManager.getLiquidity(poolId);
        if (activeLiquidity == 0) {
            // No in-range liquidity was exposed to this swap's price impact.
            // Held as idle principal; see LIMITATIONS.md "zero in-range
            // liquidity at slash time" for why this is not distributed
            // retroactively once liquidity returns.
            idleAssets += amount;
            emit InsuranceFunded(amount, accInsurancePerLiquidityX128, 0);
            return;
        }

        accInsurancePerLiquidityX128 += FullMath.mulDiv(amount, FixedPoint128.Q128, activeLiquidity);
        _depositToStrategy(amount);
        emit InsuranceFunded(amount, accInsurancePerLiquidityX128, activeLiquidity);
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

    /// @notice Checkpoints a position's accrued-but-unclaimed insurance
    /// *before* its liquidity changes. Called by the hook from
    /// afterAddLiquidity/afterRemoveLiquidity with the position's liquidity
    /// as it was immediately before this change (new liquidity minus the
    /// signed delta). Without this, an LP who adds liquidity after a slash
    /// and claims later would wrongly capture rewards accrued before they
    /// held any liquidity — see V4_ARCHITECTURE_VALIDATION.md §4.
    function checkpoint(address owner, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidityBefore)
        external
        onlyHook
    {
        _settle(owner, tickLower, tickUpper, salt, liquidityBefore);
    }

    /// @notice Claims a specific position's accrued insurance share. No LP
    /// enumeration — the caller names their own position, and current
    /// liquidity is read live from PoolManager.
    function claimInsuranceYield(int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        nonReentrant
        returns (uint256 amount)
    {
        (uint128 liquidity,,) =
            poolManager.getPositionInfo(poolId, msg.sender, tickLower, tickUpper, salt);
        bytes32 key = _settle(msg.sender, tickLower, tickUpper, salt, liquidity);

        PositionInfo storage p = positions[key];
        amount = p.owed;
        if (amount == 0) revert NoClaimable();
        p.owed = 0;

        emit LPInsuranceClaimed(msg.sender, tickLower, tickUpper, salt, amount);
        _payOut(msg.sender, amount);
    }

    function claimable(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256)
    {
        (uint128 liquidity,,) = poolManager.getPositionInfo(poolId, owner, tickLower, tickUpper, salt);
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        PositionInfo storage p = positions[key];
        uint256 delta = accInsurancePerLiquidityX128 - p.rewardDebtX128;
        uint256 pending = delta == 0 || liquidity == 0 ? 0 : FullMath.mulDiv(delta, liquidity, FixedPoint128.Q128);
        return p.owed + pending;
    }

    function _settle(address owner, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidityAtCheckpoint)
        private
        returns (bytes32 key)
    {
        key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        PositionInfo storage p = positions[key];

        uint256 delta = accInsurancePerLiquidityX128 - p.rewardDebtX128;
        if (delta != 0 && liquidityAtCheckpoint != 0) {
            p.owed += FullMath.mulDiv(delta, liquidityAtCheckpoint, FixedPoint128.Q128);
        }
        p.rewardDebtX128 = accInsurancePerLiquidityX128;
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
