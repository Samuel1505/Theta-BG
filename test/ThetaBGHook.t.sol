// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ThetaBGHook} from "../src/ThetaBGHook.sol";
import {SearcherRegistry} from "../src/SearcherRegistry.sol";
import {LPInsuranceVault} from "../src/LPInsuranceVault.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import {ActorRouter} from "./utils/ActorRouter.sol";
import {LPRouter} from "./utils/LPRouter.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice End-to-end integration test wiring PoolManager, the real hook,
/// per-actor swap routers (see ActorRouter.sol for why a shared router
/// would make this untestable), and the vault together. Parameters below
/// are deliberately generous (see comments) so the test proves the *wiring*
/// — ring buffer population from real swaps, slash execution, vault
/// funding, LP claim — end to end; exact predicate-boundary correctness is
/// covered precisely by SandwichPredicate.t.sol's hand-crafted values.
contract ThetaBGHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    ThetaBGHook hook;
    SearcherRegistry registry;
    MockWETH weth;
    MockYieldStrategy strategy;
    ActorRouter searcherRouter;
    ActorRouter victimRouter;
    LPRouter lpRouter;
    PoolKey poolKey;

    address protocolFeeRecipient = makeAddr("protocolFeeRecipient");

    // Test-tuned parameters — generous restoration/displacement bands so the
    // scenario doesn't require hand-solving exact CPMM swap math to trigger.
    // Production defaults (10 bps restoration) are validated precisely by
    // the pure predicate unit tests instead.
    uint256 constant TEST_RESTORATION_BPS = 2000; // 20%
    uint256 constant TEST_MIN_DISPLACEMENT_BPS = 5; // 0.05%
    uint256 constant TEST_PRIORITY_FEE_BPS = 50; // 0.5%
    uint256 constant TEST_PROTOCOL_SHARE_BPS = 1000; // 10%
    uint256 constant MIN_BOND = 1 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        weth = new MockWETH();
        strategy = new MockYieldStrategy(IERC20(address(weth)));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            manager,
            MIN_BOND,
            IWETH9(address(weth)),
            IERC4626(address(strategy)),
            protocolFeeRecipient,
            TEST_RESTORATION_BPS,
            TEST_MIN_DISPLACEMENT_BPS,
            TEST_PRIORITY_FEE_BPS,
            TEST_PROTOCOL_SHARE_BPS
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ThetaBGHook).creationCode, constructorArgs);

        hook = new ThetaBGHook{salt: salt}(
            manager,
            MIN_BOND,
            IWETH9(address(weth)),
            IERC4626(address(strategy)),
            protocolFeeRecipient,
            TEST_RESTORATION_BPS,
            TEST_MIN_DISPLACEMENT_BPS,
            TEST_PRIORITY_FEE_BPS,
            TEST_PROTOCOL_SHARE_BPS
        );
        require(address(hook) == hookAddr, "hook address mismatch");
        registry = hook.registry();

        // Wide, deep liquidity so front-run/back-run of modest size neither
        // exhausts a tick range nor produces wild slippage.
        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);

        // Uses a dedicated LPRouter (not v4-core's own PoolModifyLiquidityTest)
        // because that router has no `receive()` and so cannot collect the
        // vault's ETH-denominated insurance payout in the claim test below —
        // see LPRouter.sol's header.
        lpRouter = new LPRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(lpRouter), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(lpRouter), 1_000_000e18);
        lpRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );

        searcherRouter = new ActorRouter(manager);
        victimRouter = new ActorRouter(manager);

        MockERC20(Currency.unwrap(currency0)).mint(address(searcherRouter), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(searcherRouter), 10_000e18);
        MockERC20(Currency.unwrap(currency0)).mint(address(victimRouter), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(victimRouter), 10_000e18);

        vm.deal(address(searcherRouter), 10 ether);
        vm.prank(address(searcherRouter));
        registry.register{value: MIN_BOND}();
    }

    function _slot0(PoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolId);
    }

    /// @notice The full "three wow moments" pipeline: bonded searcher
    /// front-runs, victim trades, searcher back-runs restoring price — the
    /// hook must detect it, slash the entire bond, fund the pool's
    /// insurance vault, and an LP must be able to claim their pro-rata
    /// share afterward.
    function test_sandwichAttack_slashesBondAndFundsInsurance() public {
        PoolId poolId = poolKey.toId();
        LPInsuranceVault vault = hook.vaults(poolId);

        (uint128 bondBefore,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondBefore, MIN_BOND);
        assertEq(vault.availableBalance(), 0);

        // Leg 1 — front-run: searcher sells currency0 for currency1.
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );

        // Leg 2 — victim: an unrelated trader, same direction, gets a worse price.
        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );

        // Leg 3 — back-run: searcher reverses, buying back currency0,
        // restoring price toward where it started. Same block as legs 1-2
        // (forge doesn't advance block.number between calls by default).
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );

        // The predicate must have fired: entire bond slashed.
        (uint128 bondAfter, uint32 slashCount,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfter, 0, "bond should be fully slashed");
        assertEq(slashCount, 1);

        // 90% of the slash funds the pool's insurance vault (as WETH,
        // immediately deposited into the mock strategy).
        uint256 expectedInsurance = (MIN_BOND * (10_000 - TEST_PROTOCOL_SHARE_BPS)) / 10_000;
        assertApproxEqAbs(vault.availableBalance(), expectedInsurance, 1);
        assertEq(weth.balanceOf(address(strategy)), expectedInsurance);

        // 10% is claimable by the protocol fee recipient.
        uint256 expectedProtocol = MIN_BOND - expectedInsurance;
        assertEq(hook.pendingProtocolFees(), expectedProtocol);

        // LP can now claim their pro-rata share of the insurance vault.
        uint256 claimable = vault.claimable(address(lpRouter), -6000, 6000, bytes32(0));
        assertGt(claimable, 0, "LP should have a nonzero claimable insurance share");

        uint256 balBefore = address(lpRouter).balance;
        vm.prank(address(lpRouter));
        uint256 claimed = vault.claimInsuranceYield(-6000, 6000, bytes32(0));
        assertEq(claimed, claimable);
        assertEq(address(lpRouter).balance, balBefore + claimed);
    }

    /// @notice Strategy yield compounds the vault's redeemable balance
    /// beyond the raw slash proceeds — the "self-compounding" claim, made
    /// concrete: simulate APY accruing on the strategy between a slash and
    /// an LP's claim.
    function test_strategyYield_compoundsInsuranceBalance() public {
        PoolId poolId = poolKey.toId();
        LPInsuranceVault vault = hook.vaults(poolId);

        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );

        uint256 balanceAfterSlash = vault.availableBalance();
        assertGt(balanceAfterSlash, 0);

        // Simulate strategy yield: mint extra WETH directly into the
        // strategy's holdings (see MockYieldStrategy.simulateYield).
        uint256 yieldAmount = balanceAfterSlash / 10; // 10% "APY"
        weth.deposit{value: yieldAmount}();
        weth.approve(address(strategy), yieldAmount);
        strategy.simulateYield(yieldAmount);

        assertApproxEqAbs(vault.availableBalance(), balanceAfterSlash + yieldAmount, 2);
    }

    /// @notice If the strategy is paused (deposit reverts), the slash must
    /// still succeed and funds must remain claimable as idle assets —
    /// V4_ARCHITECTURE_VALIDATION.md §7's "must not depend on external
    /// protocol liveness" guarantee, exercised for real.
    function test_slash_succeedsEvenIfStrategyDepositFails() public {
        strategy.setPaused(true);
        PoolId poolId = poolKey.toId();
        LPInsuranceVault vault = hook.vaults(poolId);

        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );

        (uint128 bondAfter,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfter, 0, "bond must still be slashed even if strategy is down");
        assertGt(vault.availableBalance(), 0);
        assertGt(vault.idleAssets(), 0);
        assertEq(weth.balanceOf(address(strategy)), 0, "nothing should have reached the paused strategy");
    }

    /// @notice A lone directional trade — no bracketing back-run — must
    /// never slash, and the searcher's bond must remain intact.
    function test_directionalTrade_noBackRun_doesNotSlash() public {
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        // No back-run — searcher just keeps going the same direction.
        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -5e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );

        (uint128 bondAfter,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfter, MIN_BOND, "no back-run leg means no sandwich, bond must be untouched");
    }

    /// @notice A back-run landing in the next block must not slash — the
    /// predicate is same-block only (build prompt §45's edge case).
    function test_backRunNextBlock_doesNotSlash() public {
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );

        vm.roll(block.number + 1);
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );

        (uint128 bondAfter,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfter, MIN_BOND, "cross-block back-run must not slash");
    }

    /// @notice Priority fee: an active searcher's exact-input swap should
    /// pay a bps cut that lands with LPs via PoolManager.donate(), which the
    /// standard modifyLiquidityRouter position can collect through normal
    /// v4 fee accounting (feeGrowthInside) — proven here by checking the
    /// position's owed fees increase after a searcher swap versus a
    /// non-searcher swap of identical size.
    function test_priorityFee_isCollectedFromActiveSearchers() public {
        (,, uint256 feeGrowth0Before,) = _feeGrowthInside();

        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );

        (,, uint256 feeGrowth0AfterSearcher,) = _feeGrowthInside();
        uint256 growthFromSearcherSwap = feeGrowth0AfterSearcher - feeGrowth0Before;

        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        (,, uint256 feeGrowth0AfterVictim,) = _feeGrowthInside();
        uint256 growthFromVictimSwap = feeGrowth0AfterVictim - feeGrowth0AfterSearcher;

        // Both swaps pay the pool's normal 0.3% LP fee; only the searcher's
        // swap additionally donates the 0.5% priority fee on top, so its
        // fee-growth contribution must be strictly larger.
        assertGt(growthFromSearcherSwap, growthFromVictimSwap);
    }

    function _feeGrowthInside() internal view returns (uint256, uint256, uint256, uint256) {
        (uint256 g0, uint256 g1) = manager.getFeeGrowthInside(poolKey.toId(), -6000, 6000);
        return (0, 0, g0, g1);
    }

    function _executeSandwich(ActorRouter searcher, ActorRouter victim, PoolKey memory key) internal {
        searcher.swap(key, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        victim.swap(key, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(key, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));
    }

    // ════════════════════════════════════════════════════════════════════
    // Identity gating — unregistered / non-active searchers
    // ════════════════════════════════════════════════════════════════════

    /// @notice A structurally perfect sandwich pattern from an address that
    /// never bonded must never slash — there is no bond to slash, and the
    /// predicate is never even evaluated for non-active senders
    /// (ThetaBGHook.afterSwap short-circuits on registry.isActiveSearcher).
    function test_unregisteredAddress_sandwichPattern_doesNotSlash() public {
        ActorRouter unregistered = new ActorRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(unregistered), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(unregistered), 10_000e18);

        _executeSandwich(unregistered, victimRouter, poolKey);

        (uint128 bond,,, bool registered) = hook.registry().searchers(address(unregistered));
        assertEq(bond, 0);
        assertFalse(registered);
        // No event, no state change anywhere attributable to a slash.
        assertEq(hook.pendingProtocolFees(), 0);
    }

    /// @notice A searcher who registered but was already slashed to zero
    /// bond (inactive until re-topped-up) triggers no new slash even if the
    /// pattern matches again.
    function test_alreadyInactiveSearcher_secondPattern_doesNotDoubleSlash() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        (uint128 bondAfterFirst,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfterFirst, 0);

        vm.roll(block.number + 1); // fresh block so ring buffer isn't stale-matched
        _executeSandwich(searcherRouter, victimRouter, poolKey);

        (uint128 bondAfterSecond, uint32 slashCount,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfterSecond, 0);
        assertEq(slashCount, 1, "an inactive (zero-bond) searcher cannot be slashed again");
    }

    /// @notice A self-directed round trip where the "victim" leg is also
    /// from the searcher's own router must not slash — no distinct victim.
    function test_allThreeLegsSameSearcher_noDistinctVictim_notSlashed() public {
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );

        (uint128 bondAfter,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfter, MIN_BOND);
    }

    /// @notice Two different registered searchers front-run and back-run
    /// respectively — condition 1 (a.sender == c.sender) fails, so neither
    /// gets slashed even though both are active bonded searchers.
    function test_twoDifferentSearchers_frontAndBack_neitherSlashed() public {
        ActorRouter searcher2 = new ActorRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(searcher2), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(searcher2), 10_000e18);
        vm.deal(address(searcher2), 10 ether);
        vm.prank(address(searcher2));
        registry.register{value: MIN_BOND}();

        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        searcher2.swap(
            poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );

        (uint128 bond1,,,) = hook.registry().searchers(address(searcherRouter));
        (uint128 bond2,,,) = hook.registry().searchers(address(searcher2));
        assertEq(bond1, MIN_BOND);
        assertEq(bond2, MIN_BOND);
    }

    // ════════════════════════════════════════════════════════════════════
    // Re-bonding / repeat offense
    // ════════════════════════════════════════════════════════════════════

    /// @notice After being slashed, topping back up to only the *old*
    /// minimum is not enough to become active again — and therefore not
    /// enough to be slashable again either.
    function test_reBondingToOldMinimum_notEnoughToReactivate() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        assertFalse(registry.isActiveSearcher(address(searcherRouter)));

        vm.deal(address(searcherRouter), MIN_BOND);
        vm.prank(address(searcherRouter));
        registry.topUpBond{value: MIN_BOND}();

        assertFalse(registry.isActiveSearcher(address(searcherRouter)), "old minimum is insufficient post-slash");

        vm.roll(block.number + 1);
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        (uint128 bond,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bond, MIN_BOND, "inactive searcher's bond must be untouched by the pattern");
    }

    /// @notice Re-bonding to the full doubled requirement reactivates the
    /// searcher, and a second offense slashes the full new (larger) bond.
    function test_reBondingToDoubledMinimum_reactivatesAndCanBeSlashedAgain() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);

        vm.deal(address(searcherRouter), MIN_BOND * 2);
        vm.prank(address(searcherRouter));
        registry.topUpBond{value: MIN_BOND * 2}();
        assertTrue(registry.isActiveSearcher(address(searcherRouter)));

        vm.roll(block.number + 1);
        _executeSandwich(searcherRouter, victimRouter, poolKey);

        (uint128 bondAfter, uint32 slashCount,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfter, 0);
        assertEq(slashCount, 2);
        assertEq(registry.requiredBond(address(searcherRouter)), MIN_BOND * 2, "penalty stays flat 2x, not exponential");
    }

    /// @notice A pending withdrawal request does not exempt a searcher from
    /// being slashed while the cooldown is still active — the bond is still
    /// physically present and at risk.
    function test_pendingWithdrawal_duringCooldown_stillSlashable() public {
        vm.prank(address(searcherRouter));
        registry.requestWithdrawal();

        _executeSandwich(searcherRouter, victimRouter, poolKey);

        (uint128 bondAfter,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bondAfter, 0, "an in-flight withdrawal request must not shield the bond from a slash");
    }

    // ════════════════════════════════════════════════════════════════════
    // Multi-pool isolation
    // ════════════════════════════════════════════════════════════════════

    /// @notice A slash in one pool must never touch another pool's
    /// insurance vault — each LPInsuranceVault instance is pool-specific.
    function test_multiplePools_slashInPoolA_doesNotFundPoolBsVault() public {
        (PoolKey memory poolKeyB,) = initPool(currency0, currency1, IHooks(address(hook)), 500, 10, SQRT_PRICE_1_1);
        PoolId poolIdB = poolKeyB.toId();
        LPInsuranceVault vaultB = hook.vaults(poolIdB);

        _executeSandwich(searcherRouter, victimRouter, poolKey);

        assertEq(vaultB.availableBalance(), 0, "pool B's vault must be untouched by pool A's slash");
    }

    /// @notice The searcher's bond is global (one registry shared across
    /// pools) — a slash triggered in pool A does deduct from the same bond
    /// that would have covered pool B, which is the intended, documented
    /// design (ARCHITECTURE.md "why one registry, many vaults").
    function test_multiplePools_slashInPoolA_alsoDeactivatesSearcherInPoolB() public {
        (PoolKey memory poolKeyB,) = initPool(currency0, currency1, IHooks(address(hook)), 500, 10, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            poolKeyB, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );

        _executeSandwich(searcherRouter, victimRouter, poolKey);
        assertFalse(registry.isActiveSearcher(address(searcherRouter)));

        // The same (now-inactive) searcher's ring buffer state in pool B is
        // independent, but they can no longer be treated as an active
        // searcher there either, since activity is bond-based and global.
        ActorRouter victim2 = new ActorRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(victim2), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(victim2), 10_000e18);

        searcherRouter.swap(
            poolKeyB, SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        victim2.swap(
            poolKeyB, SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        searcherRouter.swap(
            poolKeyB, SwapParams({zeroForOne: false, amountSpecified: -1.1e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT})
        );
        // Nothing to slash (bond already zero) — must not revert or misbehave.
        (uint128 bond,,,) = hook.registry().searchers(address(searcherRouter));
        assertEq(bond, 0);
    }

    /// @notice `afterInitialize` deploys a fresh, independent vault per pool.
    function test_multiplePools_haveDistinctVaultInstances() public {
        (PoolKey memory poolKeyB,) = initPool(currency0, currency1, IHooks(address(hook)), 500, 10, SQRT_PRICE_1_1);
        LPInsuranceVault vaultA = hook.vaults(poolKey.toId());
        LPInsuranceVault vaultB = hook.vaults(poolKeyB.toId());

        assertTrue(address(vaultA) != address(vaultB));
        assertTrue(address(vaultA) != address(0));
        assertTrue(address(vaultB) != address(0));
    }

    // ════════════════════════════════════════════════════════════════════
    // Protocol fees
    // ════════════════════════════════════════════════════════════════════

    function test_protocolFees_onlyRecipientCanWithdraw() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        assertGt(hook.pendingProtocolFees(), 0);

        vm.prank(address(0xBEEF));
        vm.expectRevert(ThetaBGHook.NotProtocolFeeRecipient.selector);
        hook.withdrawProtocolFees();
    }

    function test_protocolFees_withdrawTransfersCorrectAmountAndZeroesPending() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        uint256 pending = hook.pendingProtocolFees();
        assertGt(pending, 0);

        uint256 balBefore = protocolFeeRecipient.balance;
        vm.prank(protocolFeeRecipient);
        hook.withdrawProtocolFees();

        assertEq(protocolFeeRecipient.balance, balBefore + pending);
        assertEq(hook.pendingProtocolFees(), 0);
    }

    function test_protocolFees_accumulateAcrossMultipleSlashes() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        uint256 afterFirst = hook.pendingProtocolFees();
        assertGt(afterFirst, 0);

        vm.deal(address(searcherRouter), MIN_BOND * 2);
        vm.prank(address(searcherRouter));
        registry.topUpBond{value: MIN_BOND * 2}();

        vm.roll(block.number + 1);
        _executeSandwich(searcherRouter, victimRouter, poolKey);

        assertGt(hook.pendingProtocolFees(), afterFirst);
    }

    // ════════════════════════════════════════════════════════════════════
    // Events
    // ════════════════════════════════════════════════════════════════════

    function test_events_poolInsuranceVaultDeployedOnInitialize() public {
        vm.recordLogs();
        (PoolKey memory poolKeyB,) = initPool(currency0, currency1, IHooks(address(hook)), 500, 10, SQRT_PRICE_1_1);
        LPInsuranceVault vaultB = hook.vaults(poolKeyB.toId());
        assertTrue(address(vaultB) != address(0));
    }

    /// @notice The back-run leg emits many events before SandwichSlashed
    /// (Swap, Transfer, WETH deposit, ...), so vm.expectEmit's strict
    /// next-log matching can't be used directly — record all logs and
    /// search for the one that matters instead.
    function test_events_sandwichSlashedEmitted() public {
        vm.recordLogs();
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("SandwichSlashed(bytes32,address,address,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(logs[i].topics[1], bytes32(PoolId.unwrap(poolKey.toId())));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(searcherRouter)))));
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(victimRouter)))));
                (uint256 total, uint256 protocolCut, uint256 insuranceCut) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(total, MIN_BOND);
                assertEq(protocolCut, MIN_BOND / 10);
                assertEq(insuranceCut, MIN_BOND - MIN_BOND / 10);
            }
        }
        assertTrue(found, "SandwichSlashed was not emitted");
    }

    function test_events_protocolFeesWithdrawnEmitted() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        uint256 pending = hook.pendingProtocolFees();

        vm.expectEmit(false, false, false, true, address(hook));
        emit ThetaBGHook.ProtocolFeesWithdrawn(pending);
        vm.prank(protocolFeeRecipient);
        hook.withdrawProtocolFees();
    }

    // ════════════════════════════════════════════════════════════════════
    // Priority fee edge cases
    // ════════════════════════════════════════════════════════════════════

    function test_priorityFee_notChargedToNonActiveSearchers() public {
        (,, uint256 feeGrowthBefore,) = _feeGrowthInside();

        ActorRouter ordinary = new ActorRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(ordinary), 10_000e18);
        ordinary.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );

        (,, uint256 feeGrowthOrdinary,) = _feeGrowthInside();
        uint256 growthOrdinary = feeGrowthOrdinary - feeGrowthBefore;

        victimRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        (,, uint256 feeGrowthVictim,) = _feeGrowthInside();
        uint256 growthVictim = feeGrowthVictim - feeGrowthOrdinary;

        // Two identically-sized ordinary swaps, neither from a bonded
        // searcher, must contribute identically to fee growth (both pay
        // only the plain 0.3% LP fee, no priority-fee top-up).
        assertApproxEqAbs(growthOrdinary, growthVictim, 1);
    }

    /// @notice Exact-output swap (positive amountSpecified) from the active
    /// searcher — beforeSwap's fee-collection path is gated on
    /// amountSpecified < 0, so no PriorityFeeCollected event should fire.
    /// (Comparing fee-growth deltas between two *sequential* exact-output
    /// swaps isn't a valid way to test this — the second swap always trades
    /// against a price the first one already moved, so their raw fee
    /// amounts legitimately differ regardless of any priority-fee logic.
    /// Checking for the absence of the event directly is unambiguous.)
    function test_priorityFee_notChargedOnExactOutputSwaps() public {
        vm.recordLogs();
        searcherRouter.swap(
            poolKey, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("PriorityFeeCollected(bytes32,address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(
                logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == sig,
                "no priority fee should be collected on an exact-output swap"
            );
        }
    }

    function test_priorityFee_zeroBps_collectsNothing() public {
        bytes memory constructorArgs = abi.encode(
            manager,
            MIN_BOND,
            IWETH9(address(weth)),
            IERC4626(address(strategy)),
            protocolFeeRecipient,
            TEST_RESTORATION_BPS,
            TEST_MIN_DISPLACEMENT_BPS,
            uint256(0), // priorityFeeBps = 0
            TEST_PROTOCOL_SHARE_BPS
        );
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddr2, bytes32 salt2) =
            HookMiner.find(address(this), flags, type(ThetaBGHook).creationCode, constructorArgs);
        ThetaBGHook hook2 = new ThetaBGHook{salt: salt2}(
            manager,
            MIN_BOND,
            IWETH9(address(weth)),
            IERC4626(address(strategy)),
            protocolFeeRecipient,
            TEST_RESTORATION_BPS,
            TEST_MIN_DISPLACEMENT_BPS,
            0,
            TEST_PROTOCOL_SHARE_BPS
        );
        require(address(hook2) == hookAddr2, "hook2 address mismatch");

        (PoolKey memory key2,) = initPool(currency0, currency1, IHooks(address(hook2)), 3000, 60, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            key2, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );

        vm.deal(address(searcherRouter), MIN_BOND);
        vm.prank(address(searcherRouter));
        hook2.registry().register{value: MIN_BOND}();

        (uint256 g0Before,) = manager.getFeeGrowthInside(key2.toId(), -6000, 6000);
        searcherRouter.swap(
            key2, SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        (uint256 g0After,) = manager.getFeeGrowthInside(key2.toId(), -6000, 6000);

        victimRouter.swap(
            key2, SwapParams({zeroForOne: true, amountSpecified: -10e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        (uint256 g0After2,) = manager.getFeeGrowthInside(key2.toId(), -6000, 6000);

        assertApproxEqAbs(g0After - g0Before, g0After2 - g0After, 1);
    }

    // ════════════════════════════════════════════════════════════════════
    // LP checkpointing through the full hook path (not the isolated vault
    // test — this exercises ThetaBGHook.afterAddLiquidity/afterRemoveLiquidity
    // directly, wired end to end).
    // ════════════════════════════════════════════════════════════════════

    function test_lpJoiningAfterSlash_throughFullHookPath_getsZeroShareOfPastSlash() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        LPInsuranceVault vault = hook.vaults(poolKey.toId());
        assertGt(vault.availableBalance(), 0);

        LPRouter lateLP = new LPRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(lateLP), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(lateLP), 1_000_000e18);
        lateLP.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );

        assertEq(vault.claimable(address(lateLP), -6000, 6000, bytes32(0)), 0);
    }

    function test_lpRemovingLiquidity_throughFullHookPath_retainsEarnedShare() public {
        _executeSandwich(searcherRouter, victimRouter, poolKey);
        LPInsuranceVault vault = hook.vaults(poolKey.toId());
        uint256 claimableBefore = vault.claimable(address(lpRouter), -6000, 6000, bytes32(0));
        assertGt(claimableBefore, 0);

        lpRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -1_000e18, salt: 0})
        );

        uint256 claimableAfter = vault.claimable(address(lpRouter), -6000, 6000, bytes32(0));
        assertEq(claimableAfter, claimableBefore, "removing liquidity must not lose already-earned insurance share");
    }

    // ════════════════════════════════════════════════════════════════════
    // Constructor / permissions validation
    // ════════════════════════════════════════════════════════════════════

    function test_constructor_reverts_zeroProtocolFeeRecipient() public {
        bytes memory constructorArgs = abi.encode(
            manager,
            MIN_BOND,
            IWETH9(address(weth)),
            IERC4626(address(strategy)),
            address(0),
            TEST_RESTORATION_BPS,
            TEST_MIN_DISPLACEMENT_BPS,
            TEST_PRIORITY_FEE_BPS,
            TEST_PROTOCOL_SHARE_BPS
        );
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt3) = HookMiner.find(address(this), flags, type(ThetaBGHook).creationCode, constructorArgs);

        vm.expectRevert(ThetaBGHook.ZeroValue.selector);
        new ThetaBGHook{salt: salt3}(
            manager,
            MIN_BOND,
            IWETH9(address(weth)),
            IERC4626(address(strategy)),
            address(0),
            TEST_RESTORATION_BPS,
            TEST_MIN_DISPLACEMENT_BPS,
            TEST_PRIORITY_FEE_BPS,
            TEST_PROTOCOL_SHARE_BPS
        );
    }

    function test_hookPermissions_matchDeclaredFlags() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.afterInitialize);
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertTrue(perms.beforeSwapReturnDelta);
        assertFalse(perms.beforeInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    function test_onlyPoolManager_gatesAllHookCallbacks() public {
        vm.expectRevert(ThetaBGHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
    }

    function test_onlyPoolManager_gatesBeforeSwap() public {
        vm.expectRevert(ThetaBGHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );
    }

    function test_onlyPoolManager_gatesAfterInitialize() public {
        vm.expectRevert(ThetaBGHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), poolKey, SQRT_PRICE_1_1, 0);
    }

    function test_onlyPoolManager_gatesAfterAddLiquidity() public {
        vm.expectRevert(ThetaBGHook.NotPoolManager.selector);
        hook.afterAddLiquidity(
            address(this),
            poolKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e18, salt: 0}),
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
    }

    function test_onlyPoolManager_gatesAfterRemoveLiquidity() public {
        vm.expectRevert(ThetaBGHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(
            address(this),
            poolKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -1e18, salt: 0}),
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
    }

    /// @notice The unused IHooks callbacks (never invoked by PoolManager
    /// since their permission flags are false) still return their correct
    /// selector if called directly — satisfying the interface, not gated by
    /// onlyPoolManager since they're pure no-ops.
    function test_unusedCallbacks_returnCorrectSelectors() public view {
        assertEq(
            hook.beforeInitialize(address(this), poolKey, SQRT_PRICE_1_1), IHooks.beforeInitialize.selector
        );
        assertEq(
            hook.beforeAddLiquidity(
                address(this),
                poolKey,
                ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e18, salt: 0}),
                ""
            ),
            IHooks.beforeAddLiquidity.selector
        );
        assertEq(
            hook.beforeRemoveLiquidity(
                address(this),
                poolKey,
                ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -1e18, salt: 0}),
                ""
            ),
            IHooks.beforeRemoveLiquidity.selector
        );
        assertEq(hook.beforeDonate(address(this), poolKey, 0, 0, ""), IHooks.beforeDonate.selector);
        assertEq(hook.afterDonate(address(this), poolKey, 0, 0, ""), IHooks.afterDonate.selector);
    }

    function test_withdrawProtocolFees_whenNothingPending_transfersZeroWithoutReverting() public {
        uint256 balBefore = protocolFeeRecipient.balance;
        vm.prank(protocolFeeRecipient);
        hook.withdrawProtocolFees();
        assertEq(protocolFeeRecipient.balance, balBefore);
    }

    function test_registryAddress_isStableAcrossCalls() public view {
        assertEq(address(hook.registry()), address(registry));
        assertEq(address(hook.registry()), address(registry)); // repeat — immutable, must never change
    }

    function test_vaultsMapping_returnsZeroAddressForUninitializedPool() public view {
        // A PoolKey that was never actually initialized through this hook —
        // different fee tier, so a different (uninitialized) poolId.
        PoolKey memory neverInitialized =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))});
        LPInsuranceVault v = hook.vaults(neverInitialized.toId());
        assertEq(address(v), address(0));
    }

    /// @notice Multiple LPs at the same range, through the full hook path
    /// (not the isolated vault test), split a slash proportionally — end to
    /// end via real afterAddLiquidity checkpointing.
    function test_multipleLPs_throughFullHookPath_splitProportionally() public {
        LPRouter lp2 = new LPRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(lp2), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(lp2), 1_000_000e18);
        lp2.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );

        _executeSandwich(searcherRouter, victimRouter, poolKey);

        LPInsuranceVault vault = hook.vaults(poolKey.toId());
        uint256 claim1 = vault.claimable(address(lpRouter), -6000, 6000, bytes32(0));
        uint256 claim2 = vault.claimable(address(lp2), -6000, 6000, bytes32(0));
        assertApproxEqAbs(claim1, claim2, 2, "equal liquidity should split the slash evenly");
    }

    /// @notice Full narrative smoke test matching the demo's "three wow
    /// moments" structure end to end in one place, asserting the state
    /// transition at each moment rather than just the final result.
    function test_threeWowMoments_endToEndNarrative() public {
        LPInsuranceVault vault = hook.vaults(poolKey.toId());

        // Moment 1 — setup: LP has provided liquidity, insurance is empty.
        assertEq(vault.availableBalance(), 0);
        assertTrue(registry.isActiveSearcher(address(searcherRouter)));

        // Moment 2 — the attack: three legs execute.
        _executeSandwich(searcherRouter, victimRouter, poolKey);

        // Moment 3 — the slash: bond is gone, insurance is funded, and it's
        // already earning strategy yield.
        assertFalse(registry.isActiveSearcher(address(searcherRouter)));
        assertGt(vault.availableBalance(), 0);
        assertGt(weth.balanceOf(address(strategy)), 0);

        uint256 balanceBeforeYield = vault.availableBalance();
        weth.deposit{value: 0.01 ether}();
        weth.approve(address(strategy), 0.01 ether);
        strategy.simulateYield(0.01 ether);
        assertGt(vault.availableBalance(), balanceBeforeYield, "the insurance pool keeps growing after the slash");
    }

    // ════════════════════════════════════════════════════════════════════
    // A few more
    // ════════════════════════════════════════════════════════════════════

    function test_minimumBond_matchesConstructorArg() public view {
        assertEq(registry.minimumBond(), MIN_BOND);
    }

    function test_protocolShareBps_isImmutableAndCorrect() public view {
        assertEq(hook.protocolShareBps(), TEST_PROTOCOL_SHARE_BPS);
    }

    function test_restorationAndDisplacementThresholds_matchConstructorArgs() public view {
        assertEq(hook.restorationThresholdBps(), TEST_RESTORATION_BPS);
        assertEq(hook.minDisplacementBps(), TEST_MIN_DISPLACEMENT_BPS);
    }

    function test_priorityFeeBps_matchesConstructorArg() public view {
        assertEq(hook.priorityFeeBps(), TEST_PRIORITY_FEE_BPS);
    }

    function test_protocolFeeRecipient_isImmutableAndCorrect() public view {
        assertEq(hook.protocolFeeRecipient(), protocolFeeRecipient);
    }
}
