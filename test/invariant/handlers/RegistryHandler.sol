// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SearcherRegistry} from "../../../src/SearcherRegistry.sol";

/// @notice Drives SearcherRegistry through every externally-callable action
/// across a fixed set of actors, with a "hook" (this handler itself, given
/// the role at construction) able to slash any of them. Tracks ghost totals
/// the invariant test compares against actual contract state.
contract RegistryHandler is Test {
    SearcherRegistry public registry;
    address[] public actors;

    uint256 public ghost_totalBonded; // sum of ETH ever sent into the registry via register/topUp
    uint256 public ghost_totalWithdrawn; // sum of ETH ever paid out via withdraw
    uint256 public ghost_totalSlashedOut; // sum of ETH ever forwarded out via slash

    constructor(SearcherRegistry _registry, uint256 numActors) {
        registry = _registry;
        for (uint256 i = 0; i < numActors; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encode("registry-actor", i)))));
            actors.push(actor);
            vm.deal(actor, 1_000_000 ether);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function register(uint256 actorSeed, uint96 extraBond) public {
        address actor = _actor(actorSeed);
        (,,, bool registered) = registry.searchers(actor);
        if (registered) return;

        uint256 required = registry.requiredBond(actor);
        uint256 value = required + (uint256(extraBond) % 100 ether);
        vm.prank(actor);
        try registry.register{value: value}() {
            ghost_totalBonded += value;
        } catch {}
    }

    function topUpBond(uint256 actorSeed, uint96 amount) public {
        address actor = _actor(actorSeed);
        (,,, bool registered) = registry.searchers(actor);
        if (!registered) return;

        uint256 value = (uint256(amount) % 50 ether) + 1;
        vm.prank(actor);
        try registry.topUpBond{value: value}() {
            ghost_totalBonded += value;
        } catch {}
    }

    function requestWithdrawal(uint256 actorSeed) public {
        address actor = _actor(actorSeed);
        (,,, bool registered) = registry.searchers(actor);
        if (!registered) return;
        vm.prank(actor);
        try registry.requestWithdrawal() {} catch {}
    }

    function withdraw(uint256 actorSeed, uint32 warpSeconds) public {
        address actor = _actor(actorSeed);
        (uint128 bond,,, bool registered) = registry.searchers(actor);
        if (!registered || bond == 0) return;

        // Occasionally warp forward so the cooldown can actually elapse.
        vm.warp(block.timestamp + (uint256(warpSeconds) % 2 days));

        uint256 balBefore = actor.balance;
        vm.prank(actor);
        try registry.withdraw() {
            ghost_totalWithdrawn += (actor.balance - balBefore);
        } catch {}
    }

    /// @notice The handler itself plays the "hook" role (registry is
    /// constructed with hook = address(this handler)), so it can call
    /// slash() directly across any actor.
    function slash(uint256 actorSeed) public {
        address actor = _actor(actorSeed);
        uint256 balBefore = address(this).balance;
        uint256 slashed = registry.slash(actor);
        if (slashed > 0) {
            ghost_totalSlashedOut += (address(this).balance - balBefore);
        }
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    receive() external payable {}
}
