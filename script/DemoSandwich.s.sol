// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {ThetaBGHook} from "../src/ThetaBGHook.sol";
import {SearcherRegistry} from "../src/SearcherRegistry.sol";
import {LPInsuranceVault} from "../src/LPInsuranceVault.sol";
import {DemoExecutor} from "./utils/DemoExecutor.sol";

/// @notice Executes a real front-run / victim / back-run sequence against
/// the deployed pool and confirms the hook detects and slashes it on
/// Unichain Sepolia. The back-run's input amount is computed exactly via
/// v4's own SqrtPriceMath (not hand-tuned) so it reliably clears the
/// deployed hook's *production* thresholds (10 bps restoration, 50 bps
/// minimum displacement) rather than the loose test-only bands used in
/// the Foundry test suite.
///
/// Usage:
///   forge script script/DemoSandwich.s.sol --rpc-url unichain_sepolia --broadcast
contract DemoSandwich is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;

    struct Deployment {
        address poolManager;
        address hook;
        address registry;
        address demoToken;
        address searcherExecutor;
        address victimExecutor;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        Deployment memory d = _readDeployment();
        PoolKey memory key = _poolKey(d);
        PoolId poolId = key.toId();
        IPoolManager manager = IPoolManager(d.poolManager);

        (uint160 startingSqrtPrice,,,) = manager.getSlot0(poolId);
        console2.log("Starting sqrtPriceX96:", startingSqrtPrice);

        vm.startBroadcast(deployerKey);
        uint160 afterVictim = _frontRunAndVictim(manager, key, poolId, d);
        _backRun(manager, key, poolId, d, startingSqrtPrice, afterVictim);
        vm.stopBroadcast();

        _report(manager, poolId, d);
    }

    function _poolKey(Deployment memory d) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(d.demoToken),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(d.hook)
        });
    }

    function _frontRunAndVictim(IPoolManager manager, PoolKey memory key, PoolId poolId, Deployment memory d)
        private
        returns (uint160 afterVictim)
    {
        DemoExecutor searcher = DemoExecutor(payable(d.searcherExecutor));
        DemoExecutor victim = DemoExecutor(payable(d.victimExecutor));

        // Leg 1 — front-run: searcher sells a modest amount of ETH for the demo token.
        searcher.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.003 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
        (uint160 afterFrontRun,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96 after front-run:", afterFrontRun);

        // Leg 2 — victim: an unrelated trader, same direction, gets a worse price.
        victim.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
        (afterVictim,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96 after victim:", afterVictim);
    }

    function _backRun(
        IPoolManager manager,
        PoolKey memory key,
        PoolId poolId,
        Deployment memory d,
        uint160 startingSqrtPrice,
        uint160 afterVictim
    ) private {
        uint128 liquidity = manager.getLiquidity(poolId);
        // Exact demo-token input needed to move price from where it is now
        // back to the original starting price, via v4's own math.
        uint256 amount1Needed = SqrtPriceMath.getAmount1Delta(afterVictim, startingSqrtPrice, liquidity, true);
        console2.log("Computed back-run input (demo token):", amount1Needed);

        DemoExecutor searcher = DemoExecutor(payable(d.searcherExecutor));
        searcher.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount1Needed),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _report(IPoolManager manager, PoolId poolId, Deployment memory d) private {
        (uint160 finalSqrtPrice,,,) = manager.getSlot0(poolId);
        console2.log("Final sqrtPriceX96:", finalSqrtPrice);

        SearcherRegistry registry = SearcherRegistry(d.registry);
        (uint128 bondAfter, uint32 slashCount,,) = registry.searchers(d.searcherExecutor);
        console2.log("Searcher bond after:", bondAfter);
        console2.log("Searcher slash count:", slashCount);

        ThetaBGHook hook = ThetaBGHook(payable(d.hook));
        LPInsuranceVault vault = hook.vaults(poolId);
        console2.log("Insurance vault:", address(vault));
        console2.log("Insurance vault available balance:", vault.availableBalance());

        require(slashCount > 0, "sandwich was not detected -- see the price log above");
    }

    function _readDeployment() private view returns (Deployment memory d) {
        string memory json = vm.readFile("./deployments/unichain-sepolia.json");
        d.poolManager = vm.parseJsonAddress(json, ".poolManager");
        d.hook = vm.parseJsonAddress(json, ".hook");
        d.registry = vm.parseJsonAddress(json, ".registry");
        d.demoToken = vm.parseJsonAddress(json, ".demoToken");
        d.searcherExecutor = vm.parseJsonAddress(json, ".searcherExecutor");
        d.victimExecutor = vm.parseJsonAddress(json, ".victimExecutor");
    }
}
