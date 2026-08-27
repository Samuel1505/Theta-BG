// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DemoExecutor} from "./utils/DemoExecutor.sol";

/// @notice Deploys a demo ERC20, initializes a native-ETH/demo-token pool
/// through the already-deployed ThetaBGHook, and seeds it with liquidity.
/// Reads the hook/PoolManager addresses written by DeployThetaBG.s.sol.
///
/// Usage:
///   forge script script/ConfigurePool.s.sol --rpc-url unichain_sepolia --broadcast
contract ConfigurePool is Script {
    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 6000;
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // How much native ETH the seed liquidity position consumes — kept
    // modest since this is a demo deployment, not a real market.
    uint256 constant LP_ETH_AMOUNT = 0.02 ether;
    uint256 constant LP_TOKEN_AMOUNT = 1_000_000e18; // abundant; ETH side is the binding constraint

    function run()
        external
        returns (PoolKey memory poolKey, MockERC20 token, DemoExecutor searcher, DemoExecutor victim, DemoExecutor lp)
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        (address hookAddr, address poolManagerAddr) = _readDeployment();
        IPoolManager manager = IPoolManager(poolManagerAddr);

        console2.log("Hook:", hookAddr);
        console2.log("PoolManager:", poolManagerAddr);

        vm.startBroadcast(deployerKey);

        token = new MockERC20("Theta-BG Demo USD", "tbgUSD", 18);
        token.mint(vm.addr(deployerKey), 10_000_000e18);

        (searcher, victim, lp) = _deployExecutors(manager);
        _fundExecutors(token, searcher, victim, lp);

        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        console2.log("Pool initialized. Demo token:", address(token));

        _seedLiquidity(poolKey, lp);

        vm.stopBroadcast();

        _writeDeployment(address(token), address(searcher), address(victim), address(lp));
    }

    function _deployExecutors(IPoolManager manager)
        private
        returns (DemoExecutor searcher, DemoExecutor victim, DemoExecutor lp)
    {
        searcher = new DemoExecutor(manager);
        victim = new DemoExecutor(manager);
        lp = new DemoExecutor(manager);
        console2.log("Searcher executor:", address(searcher));
        console2.log("Victim executor:", address(victim));
        console2.log("LP executor:", address(lp));
    }

    function _fundExecutors(MockERC20 token, DemoExecutor searcher, DemoExecutor victim, DemoExecutor lp) private {
        token.transfer(address(searcher), 200_000e18);
        token.transfer(address(victim), 200_000e18);
        token.transfer(address(lp), LP_TOKEN_AMOUNT);

        (bool ok1,) = address(searcher).call{value: 0.02 ether}("");
        require(ok1, "fund searcher");
        (bool ok2,) = address(victim).call{value: 0.01 ether}("");
        require(ok2, "fund victim");
        (bool ok3,) = address(lp).call{value: LP_ETH_AMOUNT}("");
        require(ok3, "fund lp");
    }

    function _seedLiquidity(PoolKey memory poolKey, DemoExecutor lp) private {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, sqrtPriceLower, sqrtPriceUpper, LP_ETH_AMOUNT, LP_TOKEN_AMOUNT
        );

        lp.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: 0
            })
        );
        console2.log("Seeded liquidity:", uint256(liquidityDelta));
    }

    function _readDeployment() private view returns (address hookAddr, address poolManagerAddr) {
        string memory json = vm.readFile("./deployments/unichain-sepolia.json");
        hookAddr = vm.parseJsonAddress(json, ".hook");
        poolManagerAddr = vm.parseJsonAddress(json, ".poolManager");
    }

    function _writeDeployment(address token, address searcher, address victim, address lp) private {
        string memory existing = vm.readFile("./deployments/unichain-sepolia.json");
        string memory json = "deployment";
        vm.serializeAddress(json, "poolManager", vm.parseJsonAddress(existing, ".poolManager"));
        vm.serializeAddress(json, "weth", vm.parseJsonAddress(existing, ".weth"));
        vm.serializeAddress(json, "strategy", vm.parseJsonAddress(existing, ".strategy"));
        vm.serializeAddress(json, "hook", vm.parseJsonAddress(existing, ".hook"));
        vm.serializeAddress(json, "registry", vm.parseJsonAddress(existing, ".registry"));
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "demoToken", token);
        vm.serializeAddress(json, "searcherExecutor", searcher);
        vm.serializeAddress(json, "victimExecutor", victim);
        string memory finalJson = vm.serializeAddress(json, "lpExecutor", lp);
        vm.writeJson(finalJson, "./deployments/unichain-sepolia.json");
        console2.log("Updated ./deployments/unichain-sepolia.json");
    }
}
