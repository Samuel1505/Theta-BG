// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SearcherRegistry} from "../../src/SearcherRegistry.sol";
import {RegistryHandler} from "./handlers/RegistryHandler.sol";

/// @notice Invariant suite for SearcherRegistry's bond accounting. The
/// handler drives register/topUp/requestWithdrawal/withdraw/slash across a
/// fixed set of actors in random order and amounts; these invariants must
/// hold after every single call, no matter the sequence.
contract SearcherRegistryInvariantTest is Test {
    SearcherRegistry registry;
    RegistryHandler handler;

    uint256 constant NUM_ACTORS = 8;
    uint256 constant MIN_BOND = 1 ether;

    function setUp() public {
        // RegistryHandler needs `registry` at construction time, and
        // `registry` needs the handler's address (as `hook`) at ITS
        // construction time. Break the cycle by predicting the handler's
        // CREATE address before deploying the registry.
        address predictedHandler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SearcherRegistry(MIN_BOND, predictedHandler);
        handler = new RegistryHandler(registry, NUM_ACTORS);
        require(address(handler) == predictedHandler, "handler address prediction mismatch");

        targetContract(address(handler));
    }

    /// @notice The registry's own ETH balance must always exactly equal
    /// (total ever bonded in) minus (total ever withdrawn out) minus (total
    /// ever slashed out) — nothing else ever moves ETH through this
    /// contract.
    function invariant_balanceMatchesGhostAccounting() public view {
        assertEq(
            address(registry).balance,
            handler.ghost_totalBonded() - handler.ghost_totalWithdrawn() - handler.ghost_totalSlashedOut()
        );
    }

    /// @notice Independently, the sum of every tracked actor's individual
    /// `bond` field must equal the registry's actual ETH balance — no
    /// hidden drift between per-searcher accounting and the pooled balance.
    function invariant_sumOfIndividualBondsMatchesBalance() public view {
        uint256 sum;
        uint256 n = handler.actorsCount();
        for (uint256 i = 0; i < n; i++) {
            (uint128 bond,,,) = registry.searchers(handler.actors(i));
            sum += bond;
        }
        assertEq(sum, address(registry).balance);
    }

    /// @notice The registry can never pay out (via withdrawals + slashes)
    /// more than was ever bonded in — no phantom ETH creation.
    function invariant_neverPaysOutMoreThanWasBonded() public view {
        assertLe(handler.ghost_totalWithdrawn() + handler.ghost_totalSlashedOut(), handler.ghost_totalBonded());
    }

    /// @notice Every actor's required bond is always exactly the minimum or
    /// exactly double it — never anything else, no matter how many times
    /// they've been slashed (flat penalty, not exponential — see
    /// MECHANISM.md).
    function invariant_requiredBondIsAlwaysMinimumOrDouble() public view {
        uint256 n = handler.actorsCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 req = registry.requiredBond(handler.actors(i));
            assertTrue(req == MIN_BOND || req == MIN_BOND * 2);
        }
    }

    /// @notice A searcher can only be "active" if their current bond meets
    /// their current required bond — the two view functions must always
    /// agree with each other, for every actor, at every point.
    function invariant_isActiveSearcherAgreesWithBondVsRequirement() public view {
        uint256 n = handler.actorsCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            (uint128 bond,,, bool registered) = registry.searchers(actor);
            bool shouldBeActive = registered && bond >= registry.requiredBond(actor);
            assertEq(registry.isActiveSearcher(actor), shouldBeActive);
        }
    }
}
