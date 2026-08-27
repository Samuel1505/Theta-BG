// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SearcherRegistry} from "../src/SearcherRegistry.sol";
import {DemoExecutor} from "./utils/DemoExecutor.sol";

/// @notice Bonds the demo searcher executor with SearcherRegistry, using
/// DemoExecutor.execute() so the registered identity (msg.sender as the
/// registry sees it) is the executor's own address — the same address that
/// will later call PoolManager.swap() directly in DemoSandwich.s.sol.
///
/// Usage:
///   forge script script/RegisterSearcher.s.sol --rpc-url unichain_sepolia --broadcast
contract RegisterSearcher is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        (address registryAddr, address searcherExecutorAddr) = _readDeployment();

        SearcherRegistry registry = SearcherRegistry(registryAddr);
        DemoExecutor searcher = DemoExecutor(payable(searcherExecutorAddr));

        uint256 bond = registry.requiredBond(searcherExecutorAddr);
        console2.log("Registering searcher executor:", searcherExecutorAddr);
        console2.log("Required bond:", bond);

        vm.startBroadcast(deployerKey);
        searcher.execute(registryAddr, bond, abi.encodeCall(SearcherRegistry.register, ()));
        vm.stopBroadcast();

        bool active = registry.isActiveSearcher(searcherExecutorAddr);
        console2.log("isActiveSearcher:", active);
        require(active, "registration did not activate the searcher");
    }

    function _readDeployment() private view returns (address registryAddr, address searcherExecutorAddr) {
        string memory json = vm.readFile("./deployments/unichain-sepolia.json");
        registryAddr = vm.parseJsonAddress(json, ".registry");
        searcherExecutorAddr = vm.parseJsonAddress(json, ".searcherExecutor");
    }
}
