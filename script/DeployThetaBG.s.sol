// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ThetaBGHook} from "../src/ThetaBGHook.sol";
import {DemoYieldStrategy} from "./utils/DemoYieldStrategy.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Deploys DemoYieldStrategy (wrapping the real WETH9 predeploy) and
/// ThetaBGHook to Unichain Sepolia. See DEPLOYMENT.md for the full
/// walkthrough and why a demo strategy is used (no verified real ERC4626
/// yield venue was found on this testnet — see LIMITATIONS.md).
///
/// Usage:
///   forge script script/DeployThetaBG.s.sol --rpc-url unichain_sepolia --broadcast --verify
///
/// Split into several small functions purely to keep each one's local
/// variable count under the legacy codegen's stack depth (the config +
/// deployment + JSON-writing logic together overflowed it in one function
/// — same issue and same fix as ThetaBGHook.afterSwap, see that file).
contract DeployThetaBG is Script {
    // Unichain Sepolia (chain id 1301). Verified against on-chain bytecode
    // before use, not copied from a single unverified source — see
    // DEPLOYMENT.md "Address verification".
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant WETH9 = 0x4200000000000000000000000000000000000006;

    // Foundry's deterministic CREATE2 deployer ("Nick's factory"), used
    // automatically by `new X{salt: salt}(...)` inside a broadcast — the
    // address a mined hook salt must be computed against.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Config {
        address protocolFeeRecipient;
        uint256 minimumBond;
        uint256 restorationThresholdBps;
        uint256 minDisplacementBps;
        uint256 priorityFeeBps;
        uint256 protocolShareBps;
    }

    function run() external returns (DemoYieldStrategy strategy, ThetaBGHook hook) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        Config memory cfg = _readConfig(vm.addr(deployerKey));

        console2.log("Deployer:", vm.addr(deployerKey));
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("WETH9:", WETH9);

        (strategy, hook) = _deploy(deployerKey, cfg);

        console2.log("DemoYieldStrategy deployed:", address(strategy));
        console2.log("ThetaBGHook deployed:", address(hook));
        console2.log("SearcherRegistry deployed:", address(hook.registry()));

        _writeDeployment(strategy, hook);
    }

    function _readConfig(address deployer) private view returns (Config memory cfg) {
        cfg.protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", deployer);
        cfg.minimumBond = vm.envOr("MINIMUM_BOND", uint256(0.01 ether));
        cfg.restorationThresholdBps = vm.envOr("RESTORATION_THRESHOLD_BPS", uint256(10));
        cfg.minDisplacementBps = vm.envOr("MIN_DISPLACEMENT_BPS", uint256(50));
        cfg.priorityFeeBps = vm.envOr("PRIORITY_FEE_BPS", uint256(5));
        cfg.protocolShareBps = vm.envOr("PROTOCOL_SHARE_BPS", uint256(1000));
    }

    function _deploy(uint256 deployerKey, Config memory cfg)
        private
        returns (DemoYieldStrategy strategy, ThetaBGHook hook)
    {
        vm.startBroadcast(deployerKey);

        strategy = new DemoYieldStrategy(IERC20(WETH9));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            cfg.minimumBond,
            IWETH9(WETH9),
            IERC4626(address(strategy)),
            cfg.protocolFeeRecipient,
            cfg.restorationThresholdBps,
            cfg.minDisplacementBps,
            cfg.priorityFeeBps,
            cfg.protocolShareBps
        );

        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ThetaBGHook).creationCode, constructorArgs);

        hook = new ThetaBGHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            cfg.minimumBond,
            IWETH9(WETH9),
            IERC4626(address(strategy)),
            cfg.protocolFeeRecipient,
            cfg.restorationThresholdBps,
            cfg.minDisplacementBps,
            cfg.priorityFeeBps,
            cfg.protocolShareBps
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        vm.stopBroadcast();
    }

    function _writeDeployment(DemoYieldStrategy strategy, ThetaBGHook hook) private {
        string memory json = "deployment";
        vm.serializeAddress(json, "poolManager", POOL_MANAGER);
        vm.serializeAddress(json, "weth", WETH9);
        vm.serializeAddress(json, "strategy", address(strategy));
        vm.serializeAddress(json, "hook", address(hook));
        vm.serializeAddress(json, "registry", address(hook.registry()));
        string memory finalJson = vm.serializeUint(json, "chainId", block.chainid);
        vm.writeJson(finalJson, "./deployments/unichain-sepolia.json");
        console2.log("Wrote ./deployments/unichain-sepolia.json");
    }
}
