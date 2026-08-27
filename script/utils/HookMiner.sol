// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Local copy of Uniswap's HookMiner test utility, duplicated from
/// test/utils/HookMiner.sol so script/ doesn't depend on test/. See that
/// file's header for why it's a local copy rather than an import across
/// periphery's own test/ tree.
library HookMiner {
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
    uint256 constant MAX_LOOP = 160_444;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address, bytes32)
    {
        flags = flags & FLAG_MASK;
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        address hookAddress;
        for (uint256 salt; salt < MAX_LOOP; salt++) {
            hookAddress = computeAddress(deployer, salt, creationCodeWithArgs);
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("HookMiner: could not find salt");
    }

    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
