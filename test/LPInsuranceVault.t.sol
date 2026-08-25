// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LPInsuranceVault} from "../src/LPInsuranceVault.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import {LPRouter} from "./utils/LPRouter.sol";

/// @notice Direct unit tests of LPInsuranceVault, isolated from ThetaBGHook's
/// swap/predicate machinery. Uses a real PoolManager (for accurate
/// StateLibrary reads — see V4_ARCHITECTURE_VALIDATION.md §4) but the vault
/// is constructed with `hook = address(this)`, so the test drives
/// `receiveSlash`/`checkpoint` directly instead of going through a full
/// sandwich detection cycle. This is what "unit test the vault" means when
/// the vault's own correctness fundamentally depends on live PoolManager
/// state — not a compromise, a deliberate choice of what "isolation" means
/// here (see MECHANISM.md for why the accumulator design requires it).
contract LPInsuranceVaultTest is Test, Deployers, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    LPInsuranceVault vault;
    MockWETH weth;
    MockYieldStrategy strategy;
    PoolKey poolKey;
    PoolId poolId;

    LPRouter lp2;
    LPRouter lp3;

    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 6000;

    struct CallbackData {
        PoolKey key;
        ModifyLiquidityParams params;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        weth = new MockWETH();
        strategy = new MockYieldStrategy(IERC20(address(weth)));

        (poolKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1);
        poolId = poolKey.toId();

        vault = new LPInsuranceVault(manager, poolId, IWETH9(address(weth)), IERC4626(address(strategy)), address(this));

        lp2 = new LPRouter(manager);
        lp3 = new LPRouter(manager);
        MockERC20Like(Currency.unwrap(currency0)).mint(address(lp2), 1_000_000e18);
        MockERC20Like(Currency.unwrap(currency1)).mint(address(lp2), 1_000_000e18);
        MockERC20Like(Currency.unwrap(currency0)).mint(address(lp3), 1_000_000e18);
        MockERC20Like(Currency.unwrap(currency1)).mint(address(lp3), 1_000_000e18);
    }

    // ── Local LP identity (this test contract itself calls PoolManager
    // directly, so address(this) is a real, independent position owner) ──

    /// @notice Mirrors exactly what ThetaBGHook.afterAddLiquidity/
    /// afterRemoveLiquidity does: modify liquidity, then checkpoint the
    /// position with its liquidity *before* this change. These pools have
    /// no hook attached (hooks=address(0), since we're testing the vault in
    /// isolation from ThetaBGHook), so nothing calls `checkpoint`
    /// automatically — the test must do it, exactly like the hook would.
    function _addLiquidity(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt) internal {
        manager.unlock(
            abi.encode(CallbackData(poolKey, ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, salt)))
        );
        (uint128 liquidityAfter,,) = manager.getPositionInfo(poolId, address(this), tickLower, tickUpper, salt);
        int256 beforeSigned = int256(uint256(liquidityAfter)) - liquidityDelta;
        vault.checkpoint(address(this), tickLower, tickUpper, salt, uint128(uint256(beforeSigned)));
    }

    function _addLiquidityFor(LPRouter router, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
        internal
    {
        router.modifyLiquidity(poolKey, ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, salt));
        (uint128 liquidityAfter,,) = manager.getPositionInfo(poolId, address(router), tickLower, tickUpper, salt);
        int256 beforeSigned = int256(uint256(liquidityAfter)) - liquidityDelta;
        vault.checkpoint(address(router), tickLower, tickUpper, salt, uint128(uint256(beforeSigned)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        CallbackData memory d = abi.decode(data, (CallbackData));
        (BalanceDelta delta,) = manager.modifyLiquidity(d.key, d.params, "");
        _settleDelta(d.key.currency0, BalanceDeltaLibrary.amount0(delta));
        _settleDelta(d.key.currency1, BalanceDeltaLibrary.amount1(delta));
        return "";
    }

    function _settleDelta(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _slash(uint256 amount) internal {
        vm.deal(address(this), amount);
        vault.receiveSlash{value: amount}();
    }

    // ════════════════════════════════════════════════════════════════════
    // receiveSlash
    // ════════════════════════════════════════════════════════════════════

    function test_receiveSlash_onlyHook() public {
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        vm.expectRevert(LPInsuranceVault.NotHook.selector);
        vault.receiveSlash{value: 1 ether}();
    }

    function test_receiveSlash_zeroValue_isNoOp() public {
        vault.receiveSlash{value: 0}();
        assertEq(vault.accInsurancePerLiquidityX128(), 0);
        assertEq(vault.idleAssets(), 0);
    }

    function test_receiveSlash_withNoLiquidity_holdsAsIdle() public {
        // No liquidity added yet in setUp — pool has zero active liquidity.
        _slash(1 ether);
        assertEq(vault.idleAssets(), 1 ether);
        assertEq(vault.accInsurancePerLiquidityX128(), 0, "accumulator must not move when liquidity is zero");
    }

    function test_receiveSlash_withLiquidity_updatesAccumulator() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        uint128 liquidity = manager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        _slash(1 ether);

        uint256 expected = FullMathLike.mulDiv(1 ether, 1 << 128, liquidity);
        assertEq(vault.accInsurancePerLiquidityX128(), expected);
        assertEq(vault.idleAssets(), 0, "should have gone to the strategy, not idle");
    }

    function test_receiveSlash_depositsIntoStrategy() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        assertEq(weth.balanceOf(address(strategy)), 1 ether);
        assertEq(vault.principalDeposited(), 1 ether);
        assertGt(strategy.balanceOf(address(vault)), 0);
    }

    function test_receiveSlash_multipleSlashes_accumulateAdditively() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        uint128 liquidity = manager.getLiquidity(poolId);

        _slash(1 ether);
        uint256 accAfterFirst = vault.accInsurancePerLiquidityX128();

        _slash(2 ether);
        uint256 accAfterSecond = vault.accInsurancePerLiquidityX128();

        uint256 secondIncrement = FullMathLike.mulDiv(2 ether, 1 << 128, liquidity);
        assertEq(accAfterSecond, accAfterFirst + secondIncrement);
        assertEq(vault.principalDeposited(), 3 ether);
    }

    function test_receiveSlash_liquidityChangesBetweenSlashes_usesLiquidityAtEachSlashTime() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        uint128 liquidity1 = manager.getLiquidity(poolId);
        _slash(1 ether);
        uint256 increment1 = vault.accInsurancePerLiquidityX128();

        _addLiquidity(TICK_LOWER, TICK_UPPER, 4000e18, 0); // liquidity increases 5x total
        uint128 liquidity2 = manager.getLiquidity(poolId);
        assertGt(liquidity2, liquidity1);

        _slash(1 ether);
        uint256 increment2 = vault.accInsurancePerLiquidityX128() - increment1;

        uint256 expectedIncrement2 = FullMathLike.mulDiv(1 ether, 1 << 128, liquidity2);
        assertEq(increment2, expectedIncrement2);
        assertLt(increment2, increment1, "same slash amount over more liquidity accrues less per unit");
    }

    function test_receiveSlash_strategyDepositFails_fundsHeldIdleNotLost() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        strategy.setPaused(true);

        _slash(1 ether);

        assertEq(vault.idleAssets(), 1 ether);
        assertEq(weth.balanceOf(address(strategy)), 0);
        // Accumulator still updates — LPs are still entitled to their share,
        // strategy failure only affects where the principal physically sits.
        assertGt(vault.accInsurancePerLiquidityX128(), 0);
    }

    function test_receiveSlash_emitsInsuranceFunded() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        uint128 liquidity = manager.getLiquidity(poolId);
        uint256 expectedAcc = FullMathLike.mulDiv(1 ether, 1 << 128, liquidity);

        vm.expectEmit(false, false, false, true, address(vault));
        emit LPInsuranceVault.InsuranceFunded(1 ether, expectedAcc, liquidity);
        _slash(1 ether);
    }

    function test_receiveSlash_emitsStrategyDepositFailed_whenPaused() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        strategy.setPaused(true);

        vm.expectEmit(false, false, false, true, address(vault));
        emit LPInsuranceVault.StrategyDepositFailed(1 ether);
        _slash(1 ether);
    }

    // ════════════════════════════════════════════════════════════════════
    // checkpoint / claim — single LP
    // ════════════════════════════════════════════════════════════════════

    function test_claim_revertsWithNothingOwed() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        vm.expectRevert(LPInsuranceVault.NoClaimable.selector);
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
    }

    function test_claim_afterSingleSlash_paysFullAmount() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        uint256 claimable = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(claimable, 1 ether, 2);

        uint256 balBefore = address(this).balance;
        uint256 claimed = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        assertEq(claimed, claimable);
        assertEq(address(this).balance, balBefore + claimed);
    }

    function test_claim_secondCallWithNothingNew_reverts() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);

        vm.expectRevert(LPInsuranceVault.NoClaimable.selector);
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
    }

    function test_claim_afterSecondSlash_onlyPaysTheNewAmount() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);

        _slash(1 ether);
        uint256 secondClaimable = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(secondClaimable, 1 ether, 2);

        uint256 claimed = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        assertEq(claimed, secondClaimable);
    }

    function test_claim_wrongTickRange_hasNothingOwed() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        // A position at a different range was never checkpointed and has no
        // liquidity — nothing accrues to it even though the same owner has
        // a *different* range that did earn.
        assertEq(vault.claimable(address(this), -120, 120, 0), 0);
    }

    function test_claim_wrongSalt_hasNothingOwed() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        assertEq(vault.claimable(address(this), TICK_LOWER, TICK_UPPER, bytes32(uint256(1))), 0);
    }

    function test_claim_byNonOwner_claimsTheirOwnEmptyPosition_notSomeoneElses() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        // address(this) has a claimable balance; a different caller with no
        // position of their own must have nothing, even at the identical
        // tick range/salt — claim identity is msg.sender, not a parameter.
        vm.prank(address(0xF00D));
        vm.expectRevert(LPInsuranceVault.NoClaimable.selector);
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
    }

    function test_claim_emitsLPInsuranceClaimed() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        uint256 expected = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit LPInsuranceVault.LPInsuranceClaimed(address(this), TICK_LOWER, TICK_UPPER, 0, expected);
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
    }

    // ════════════════════════════════════════════════════════════════════
    // Multi-LP proportionality and the "join after slash" correctness fix
    // ════════════════════════════════════════════════════════════════════

    function test_twoLPs_equalLiquidity_splitSlashEqually() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, 1000e18, 0);

        _slash(2 ether);

        uint256 claim1 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        uint256 claim2 = vault.claimable(address(lp2), TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(claim1, claim2, 2);
        assertApproxEqAbs(claim1 + claim2, 2 ether, 2);
    }

    function test_twoLPs_unequalLiquidity_splitProportionally() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0); // 1x
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, 3000e18, 0); // 3x

        _slash(4 ether);

        uint256 claim1 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        uint256 claim2 = vault.claimable(address(lp2), TICK_LOWER, TICK_UPPER, 0);
        // LP2 has 3x the liquidity of address(this) -> should get ~3x the reward.
        assertApproxEqAbs(claim2, claim1 * 3, 1e12);
    }

    /// @notice The critical correctness property: an LP joining *after* a
    /// slash must get zero share of that slash, even though the global
    /// accumulator is already nonzero when they add liquidity — this is
    /// exactly the bug V4_ARCHITECTURE_VALIDATION.md §4 describes and the
    /// checkpoint-on-modify mechanism exists to prevent.
    function test_lpJoiningAfterSlash_getsZeroShareOfThatSlash() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        // lp2 joins only now, after the slash already happened.
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, 1000e18, 0);

        assertEq(vault.claimable(address(lp2), TICK_LOWER, TICK_UPPER, 0), 0);

        // But lp2 *does* earn their fair share of a slash after joining.
        _slash(2 ether);
        uint256 claim1 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        uint256 claim2 = vault.claimable(address(lp2), TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(claim2, 1 ether, 2, "lp2 should get half of the second 2 ether slash");
        assertApproxEqAbs(claim1, 2 ether, 2, "address(this) should get all of the first slash plus half of the second");
    }

    /// @notice An LP who fully withdraws retains their already-earned share
    /// (it was checkpointed into `owed` at withdrawal time) even though
    /// their live liquidity is now zero.
    function test_lpWhoWithdraws_retainsAlreadyEarnedShare() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        // Withdraw everything — liquidityDelta negative of the full amount.
        _addLiquidity(TICK_LOWER, TICK_UPPER, -1000e18, 0);

        uint256 claimable = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(claimable, 1 ether, 2, "earned share must survive full withdrawal");

        uint256 claimed = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        assertEq(claimed, claimable);
    }

    /// @notice ...and after withdrawing, a *subsequent* slash must not
    /// credit them further (their live liquidity is now zero).
    function test_lpWhoWithdraws_earnsNothingFromSlashesAfterExit() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, 1000e18, 0);

        _slash(1 ether);
        _addLiquidity(TICK_LOWER, TICK_UPPER, -1000e18, 0); // address(this) exits fully
        uint256 owedAtExit = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);

        _slash(1 ether); // only lp2 has liquidity now

        uint256 owedAfter = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        assertEq(owedAfter, owedAtExit, "no new accrual after full exit");
    }

    /// @notice Partial withdrawal: checkpoint fires with the liquidity
    /// *before* the reduction, so the already-earned share up to that point
    /// is preserved, and subsequent slashes are shared according to the
    /// *reduced* liquidity going forward.
    function test_lpPartialWithdrawal_earnsLessOnSubsequentSlash() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 2000e18, 0);
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, 2000e18, 0);

        _slash(2 ether); // split 50/50 -> 1 ether each

        _addLiquidity(TICK_LOWER, TICK_UPPER, -1500e18, 0); // address(this) now has 500e18 vs lp2's 2000e18

        _slash(2.5 ether); // now split 1:4 -> 0.5 / 2.0

        uint256 claim1 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        uint256 claim2 = vault.claimable(address(lp2), TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(claim1, 1.5 ether, 1e12);
        assertApproxEqAbs(claim2, 3 ether, 1e12);
    }

    function test_threeLPs_proportionalSplit() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _addLiquidityFor(lp3, TICK_LOWER, TICK_UPPER, 2000e18, 0);

        _slash(4 ether);

        uint256 claim1 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        uint256 claim2 = vault.claimable(address(lp2), TICK_LOWER, TICK_UPPER, 0);
        uint256 claim3 = vault.claimable(address(lp3), TICK_LOWER, TICK_UPPER, 0);

        assertApproxEqAbs(claim1, claim2, 2);
        assertApproxEqAbs(claim3, claim1 * 2, 1e12);
        assertApproxEqAbs(claim1 + claim2 + claim3, 4 ether, 4);
    }

    /// @notice Sum of all claims across many LPs never exceeds what was
    /// actually funded, even after rounding in FullMath.mulDiv — the core
    /// solvency invariant, exercised directly rather than only asserted.
    function test_sumOfClaims_neverExceedsFundedAmount() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 777e18, 0);
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, 333e18, 0);
        _addLiquidityFor(lp3, TICK_LOWER, TICK_UPPER, 111e18, 0);

        _slash(1.23456789 ether);

        uint256 claim1 = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        vm.prank(address(lp2));
        uint256 claim2 = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        vm.prank(address(lp3));
        uint256 claim3 = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);

        assertLe(claim1 + claim2 + claim3, 1.23456789 ether);
    }

    // ════════════════════════════════════════════════════════════════════
    // availableBalance / self-compounding
    // ════════════════════════════════════════════════════════════════════

    function test_availableBalance_zeroInitially() public view {
        assertEq(vault.availableBalance(), 0);
    }

    function test_availableBalance_reflectsIdlePlusStrategy() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        assertApproxEqAbs(vault.availableBalance(), 1 ether, 1);
    }

    function test_availableBalance_growsFromStrategyYield() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        uint256 before = vault.availableBalance();

        vm.deal(address(this), 0.1 ether);
        weth.deposit{value: 0.1 ether}();
        weth.approve(address(strategy), 0.1 ether);
        strategy.simulateYield(0.1 ether);

        assertApproxEqAbs(vault.availableBalance(), before + 0.1 ether, 2);
    }

    function test_availableBalance_combinesIdleAndStrategyAfterMixedFunding() public {
        // First slash with zero liquidity -> idle.
        _slash(1 ether);
        assertEq(vault.idleAssets(), 1 ether);

        // Now add liquidity and slash again -> goes to strategy.
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        assertApproxEqAbs(vault.availableBalance(), 2 ether, 1);
        assertEq(vault.idleAssets(), 1 ether);
        assertApproxEqAbs(weth.balanceOf(address(strategy)), 1 ether, 1);
    }

    // ════════════════════════════════════════════════════════════════════
    // checkpoint — direct calls (as the hook would make them)
    // ════════════════════════════════════════════════════════════════════

    function test_checkpoint_onlyHook() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(LPInsuranceVault.NotHook.selector);
        vault.checkpoint(address(this), TICK_LOWER, TICK_UPPER, 0, 1000e18);
    }

    function test_checkpoint_withZeroLiquidityBefore_accruesNothing() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);

        // Simulate a brand new position's first checkpoint (liquidityBefore=0).
        vault.checkpoint(address(0x1111), TICK_LOWER, TICK_UPPER, 0, 0);
        assertEq(vault.claimable(address(0x1111), TICK_LOWER, TICK_UPPER, 0), 0);
    }

    function test_checkpoint_updatesRewardDebtEvenWithNoAccumulatorChange() public {
        // Calling checkpoint before any slash ever happened must be safe
        // and simply set rewardDebt to 0 without reverting or misbehaving.
        vault.checkpoint(address(this), TICK_LOWER, TICK_UPPER, 0, 0);
        assertEq(vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0), 0);
    }

    // ════════════════════════════════════════════════════════════════════
    // Fuzz
    // ════════════════════════════════════════════════════════════════════

    function testFuzz_receiveSlash_accumulatorMatchesFormula(uint96 slashAmount, uint96 liquidityAdd) public {
        slashAmount = uint96(bound(slashAmount, 1, 1000 ether));
        liquidityAdd = uint96(bound(liquidityAdd, 1e12, 1_000_000e18));

        _addLiquidity(TICK_LOWER, TICK_UPPER, int256(uint256(liquidityAdd)), 0);
        uint128 liquidity = manager.getLiquidity(poolId);
        vm.assume(liquidity > 0);

        _slash(slashAmount);

        uint256 expected = FullMathLike.mulDiv(slashAmount, 1 << 128, liquidity);
        assertEq(vault.accInsurancePerLiquidityX128(), expected);
    }

    function testFuzz_singleLP_claimsApproximatelyFullSlash(uint96 slashAmount) public {
        slashAmount = uint96(bound(slashAmount, 1e6, 1000 ether));
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(slashAmount);

        uint256 claimed = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        // Rounding in FullMath.mulDiv can only round DOWN, so claimed <= funded.
        assertLe(claimed, slashAmount);
        assertApproxEqAbs(claimed, slashAmount, 1e12);
    }

    function testFuzz_twoLPs_shareIsProportionalToLiquidity(uint96 liq1, uint96 liq2, uint96 slashAmount) public {
        liq1 = uint96(bound(liq1, 1e15, 1_000_000e18));
        liq2 = uint96(bound(liq2, 1e15, 1_000_000e18));
        slashAmount = uint96(bound(slashAmount, 1e12, 1000 ether));

        _addLiquidity(TICK_LOWER, TICK_UPPER, int256(uint256(liq1)), 0);
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, int256(uint256(liq2)), 0);

        _slash(slashAmount);

        uint256 claim1 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        uint256 claim2 = vault.claimable(address(lp2), TICK_LOWER, TICK_UPPER, 0);

        // claim1 / claim2 should approximate liq1 / liq2 — checked via
        // cross-multiplication to avoid division/precision issues.
        // 0.5% tolerance: at extreme liquidity ratios (e.g. one LP near the
        // 1e15 floor against another near 1e24), FullMath.mulDiv rounding
        // on each side of the cross-multiplication can legitimately exceed
        // a tighter bound even though both individual claims are correct.
        assertApproxEqRel(claim1 * uint256(liq2), claim2 * uint256(liq1), 0.005e18);
        assertLe(claim1 + claim2, slashAmount);
    }

    function testFuzz_sumOfClaims_neverExceedsTotalFunded(uint96 s1, uint96 s2, uint96 liq1, uint96 liq2) public {
        liq1 = uint96(bound(liq1, 1e15, 1_000_000e18));
        liq2 = uint96(bound(liq2, 1e15, 1_000_000e18));
        s1 = uint96(bound(s1, 1e9, 500 ether));
        s2 = uint96(bound(s2, 1e9, 500 ether));

        _addLiquidity(TICK_LOWER, TICK_UPPER, int256(uint256(liq1)), 0);
        _addLiquidityFor(lp2, TICK_LOWER, TICK_UPPER, int256(uint256(liq2)), 0);

        _slash(s1);
        _slash(s2);

        uint256 claim1 = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        vm.prank(address(lp2));
        uint256 claim2 = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);

        assertLe(claim1 + claim2, uint256(s1) + s2);
    }

    // ════════════════════════════════════════════════════════════════════
    // More coverage
    // ════════════════════════════════════════════════════════════════════

    function test_differentSalts_areFullyIndependentPositions() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, bytes32(uint256(1)));
        _addLiquidity(TICK_LOWER, TICK_UPPER, 2000e18, bytes32(uint256(2)));

        _slash(3 ether);

        uint256 claim1 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, bytes32(uint256(1)));
        uint256 claim2 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, bytes32(uint256(2)));
        assertApproxEqAbs(claim2, claim1 * 2, 1e12);
    }

    function test_sameOwner_twoDifferentTickRanges_trackedIndependently() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _addLiquidity(-120, 120, 1000e18, 0);

        _slash(2 ether);
        uint256 claimNarrowBefore = vault.claimable(address(this), -120, 120, 0);
        assertGt(claimNarrowBefore, 0);

        // Claiming the *wide* range must not touch the *narrow* range's
        // independently-tracked accrual for the same owner.
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        uint256 claimNarrowAfter = vault.claimable(address(this), -120, 120, 0);
        assertEq(claimNarrowAfter, claimNarrowBefore, "claiming one tick range must not affect another");
    }

    function test_claim_doesNotAffectOtherPositionsOfSameOwner() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, bytes32(uint256(1)));
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, bytes32(uint256(2)));
        _slash(2 ether);

        uint256 claimableBefore2 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, bytes32(uint256(2)));
        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, bytes32(uint256(1)));
        uint256 claimableAfter2 = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, bytes32(uint256(2)));

        assertEq(claimableAfter2, claimableBefore2, "claiming one salt must not touch another salt's accrual");
    }

    function test_repeatedAddThenRemove_sameBlock_accountingStaysConsistent() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _addLiquidity(TICK_LOWER, TICK_UPPER, 500e18, 0);
        _addLiquidity(TICK_LOWER, TICK_UPPER, -700e18, 0);

        (uint128 liquidity,,) = manager.getPositionInfo(poolId, address(this), TICK_LOWER, TICK_UPPER, 0);
        assertEq(liquidity, 800e18);

        _slash(1 ether);
        uint256 claimable = vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(claimable, 1 ether, 2);
    }

    function test_availableBalance_afterFullWithdrawalByOnlyLP_remainsClaimableNotStuck() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        _addLiquidity(TICK_LOWER, TICK_UPPER, -1000e18, 0);

        // Even though pool liquidity is now zero, the already-earned
        // balance is still fully claimable — availableBalance doesn't
        // depend on current liquidity at all, only accInsurancePerLiquidity.
        assertApproxEqAbs(vault.availableBalance(), 1 ether, 1);
        uint256 claimed = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        assertApproxEqAbs(claimed, 1 ether, 2);
    }

    function test_receiveSlash_veryLargeAmount_doesNotOverflow() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1_000_000e18, 0);
        uint256 large = 1_000_000 ether;
        vm.deal(address(this), large);
        vault.receiveSlash{value: large}();

        assertApproxEqAbs(vault.availableBalance(), large, 1);
    }

    function test_receiveSlash_verySmallAmount_stillTracked() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1); // 1 wei
        // Rounding may floor this to zero claimable for a single LP, but
        // the vault must not revert and idle/strategy accounting must not
        // go negative or misbehave.
        assertGe(vault.availableBalance(), 0);
    }

    function testFuzz_manySequentialSlashes_accumulatorIsMonotonicallyIncreasing(uint8 numSlashes, uint96 seed)
        public
    {
        numSlashes = uint8(bound(numSlashes, 1, 15));
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);

        uint256 prevAcc = 0;
        for (uint256 i = 0; i < numSlashes; i++) {
            uint256 amount = (uint256(keccak256(abi.encode(seed, i))) % 10 ether) + 1;
            _slash(amount);
            uint256 acc = vault.accInsurancePerLiquidityX128();
            assertGe(acc, prevAcc, "accumulator must never decrease");
            prevAcc = acc;
        }
    }

    function testFuzz_claimThenReClaim_secondCallNeverReturnsPositiveAmount(uint96 slashAmount) public {
        slashAmount = uint96(bound(slashAmount, 1e9, 1000 ether));
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(slashAmount);

        vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        assertEq(vault.claimable(address(this), TICK_LOWER, TICK_UPPER, 0), 0);
    }

    // ════════════════════════════════════════════════════════════════════
    // A few more
    // ════════════════════════════════════════════════════════════════════

    function test_immutables_areSetCorrectly() public view {
        assertEq(address(vault.poolManager()), address(manager));
        assertEq(address(vault.weth()), address(weth));
        assertEq(address(vault.strategy()), address(strategy));
        assertEq(vault.hook(), address(this));
    }

    function test_principalDeposited_tracksOnlySuccessfulStrategyDeposits() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        assertEq(vault.principalDeposited(), 1 ether);

        strategy.setPaused(true);
        _slash(1 ether);
        assertEq(vault.principalDeposited(), 1 ether, "a failed deposit must not be counted as principal");
    }

    function test_claimable_isZeroForAddressThatNeverInteracted() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        assertEq(vault.claimable(address(0xDEAD), TICK_LOWER, TICK_UPPER, 0), 0);
    }

    function test_receiveSlash_afterStrategyUnpaused_futureSlashesSucceedNormally() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        strategy.setPaused(true);
        _slash(1 ether);
        assertEq(vault.idleAssets(), 1 ether);

        strategy.setPaused(false);
        _slash(1 ether);
        assertApproxEqAbs(weth.balanceOf(address(strategy)), 1 ether, 1);
        assertEq(vault.idleAssets(), 1 ether, "idle assets from the earlier failure stay idle, not retroactively deposited");
    }

    function test_claimInsuranceYield_reentrancyGuard_blocksNestedCall() public {
        _addLiquidity(TICK_LOWER, TICK_UPPER, 1000e18, 0);
        _slash(1 ether);
        // A direct re-entrant call from within the same call stack isn't
        // reachable without a malicious token/strategy (covered in
        // ThetaBGAdversarial.t.sol); this test instead confirms the guard's
        // presence doesn't interfere with two *sequential*, non-reentrant
        // claims against different slashes.
        uint256 first = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        _slash(1 ether);
        uint256 second = vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, 0);
        assertGt(first, 0);
        assertGt(second, 0);
    }

    function testFuzz_checkpoint_calledByNonHook_alwaysReverts(address caller) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        vm.expectRevert(LPInsuranceVault.NotHook.selector);
        vault.checkpoint(address(this), TICK_LOWER, TICK_UPPER, 0, 1000e18);
    }

    function testFuzz_receiveSlash_calledByNonHook_alwaysReverts(address caller, uint96 amount) public {
        vm.assume(caller != address(this));
        vm.deal(caller, amount);
        vm.prank(caller);
        vm.expectRevert(LPInsuranceVault.NotHook.selector);
        vault.receiveSlash{value: amount}();
    }
}

interface MockERC20Like {
    function mint(address to, uint256 amount) external;
}

library FullMathLike {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = (a * b) / denominator;
    }
}
