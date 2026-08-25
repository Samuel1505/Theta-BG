// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SearcherRegistry} from "../src/SearcherRegistry.sol";

contract SearcherRegistryTest is Test {
    SearcherRegistry registry;
    address hook = address(this); // test contract plays the hook role
    address searcher = makeAddr("searcher");
    uint256 constant MIN_BOND = 1 ether;

    function setUp() public {
        registry = new SearcherRegistry(MIN_BOND, hook);
        vm.deal(searcher, 100 ether);
    }

    function test_register_succeeds_withExactMinimumBond() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();

        assertTrue(registry.isActiveSearcher(searcher));
        (uint128 bond,,,bool registered) = registry.searchers(searcher);
        assertEq(bond, MIN_BOND);
        assertTrue(registered);
    }

    function test_register_reverts_belowMinimumBond() public {
        vm.prank(searcher);
        vm.expectRevert(SearcherRegistry.InsufficientBond.selector);
        registry.register{value: MIN_BOND - 1}();
    }

    function test_register_reverts_ifAlreadyRegistered() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        vm.expectRevert(SearcherRegistry.AlreadyRegistered.selector);
        registry.register{value: MIN_BOND}();
        vm.stopPrank();
    }

    function test_topUpBond_increasesBond() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.topUpBond{value: 0.5 ether}();
        vm.stopPrank();

        (uint128 bond,,,) = registry.searchers(searcher);
        assertEq(bond, MIN_BOND + 0.5 ether);
    }

    function test_withdraw_reverts_withoutRequest() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        vm.expectRevert(SearcherRegistry.WithdrawalNotRequested.selector);
        registry.withdraw();
        vm.stopPrank();
    }

    function test_withdraw_reverts_beforeCooldownElapses() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN() - 1);
        vm.expectRevert(SearcherRegistry.CooldownNotElapsed.selector);
        registry.withdraw();
        vm.stopPrank();
    }

    function test_withdraw_succeeds_afterCooldown() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN());

        uint256 balBefore = searcher.balance;
        registry.withdraw();
        vm.stopPrank();

        assertEq(searcher.balance, balBefore + MIN_BOND);
        assertFalse(registry.isActiveSearcher(searcher));
    }

    function test_cancelWithdrawal_clearsPendingRequest() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        registry.cancelWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN());
        vm.expectRevert(SearcherRegistry.WithdrawalNotRequested.selector);
        registry.withdraw();
        vm.stopPrank();
    }

    function test_slash_onlyHook() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();

        vm.prank(address(0xBEEF));
        vm.expectRevert(SearcherRegistry.NotHook.selector);
        registry.slash(searcher);
    }

    function test_slash_zeroesEntireBond() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();

        uint256 balBefore = address(this).balance;
        uint256 slashed = registry.slash(searcher); // called by `hook` == address(this)
        assertEq(slashed, MIN_BOND);
        assertEq(address(this).balance, balBefore + MIN_BOND); // forwarded to hook

        (uint128 bond, uint32 slashCount,,) = registry.searchers(searcher);
        assertEq(bond, 0);
        assertEq(slashCount, 1);
    }

    function test_slash_ofUnregisteredSearcher_isNoOp() public {
        uint256 slashed = registry.slash(address(0xDEAD));
        assertEq(slashed, 0);
    }

    function test_requiredBond_doublesAfterSlash() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();
        assertEq(registry.requiredBond(searcher), MIN_BOND);

        registry.slash(searcher);
        assertEq(registry.requiredBond(searcher), MIN_BOND * 2);
    }

    function test_isActiveSearcher_falseAfterSlash_untilReTopUp() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        vm.stopPrank();

        registry.slash(searcher);
        assertFalse(registry.isActiveSearcher(searcher));

        // Topping back up to only the *old* minimum is not enough post-slash.
        vm.prank(searcher);
        registry.topUpBond{value: MIN_BOND}();
        assertFalse(registry.isActiveSearcher(searcher));

        // Reaching the doubled requirement reactivates them.
        vm.prank(searcher);
        registry.topUpBond{value: MIN_BOND}();
        assertTrue(registry.isActiveSearcher(searcher));
    }

    // ════════════════════════════════════════════════════════════════════
    // Constructor validation
    // ════════════════════════════════════════════════════════════════════

    function test_constructor_reverts_zeroMinimumBond() public {
        vm.expectRevert(SearcherRegistry.ZeroValue.selector);
        new SearcherRegistry(0, hook);
    }

    function test_constructor_reverts_zeroHook() public {
        vm.expectRevert(SearcherRegistry.ZeroValue.selector);
        new SearcherRegistry(MIN_BOND, address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(registry.minimumBond(), MIN_BOND);
        assertEq(registry.hook(), hook);
    }

    // ════════════════════════════════════════════════════════════════════
    // topUpBond edge cases
    // ════════════════════════════════════════════════════════════════════

    function test_topUpBond_reverts_ifNotRegistered() public {
        vm.prank(searcher);
        vm.expectRevert(SearcherRegistry.NotRegistered.selector);
        registry.topUpBond{value: 1 ether}();
    }

    function test_topUpBond_reverts_onZeroValue() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        vm.expectRevert(SearcherRegistry.ZeroValue.selector);
        registry.topUpBond{value: 0}();
        vm.stopPrank();
    }

    function test_topUpBond_afterWithdrawalRequested_stillWorks() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        registry.topUpBond{value: 1 ether}();
        vm.stopPrank();

        (uint128 bond,,,) = registry.searchers(searcher);
        assertEq(bond, MIN_BOND + 1 ether);
    }

    // ════════════════════════════════════════════════════════════════════
    // requestWithdrawal / cancelWithdrawal edge cases
    // ════════════════════════════════════════════════════════════════════

    function test_requestWithdrawal_reverts_ifNotRegistered() public {
        vm.prank(searcher);
        vm.expectRevert(SearcherRegistry.NotRegistered.selector);
        registry.requestWithdrawal();
    }

    function test_cancelWithdrawal_reverts_ifNotRegistered() public {
        vm.prank(searcher);
        vm.expectRevert(SearcherRegistry.NotRegistered.selector);
        registry.cancelWithdrawal();
    }

    function test_cancelWithdrawal_withoutPendingRequest_isSafeNoOp() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.cancelWithdrawal(); // no request pending — must not revert
        vm.stopPrank();

        (,, uint64 unlockTime,) = registry.searchers(searcher);
        assertEq(unlockTime, 0);
    }

    function test_requestWithdrawal_canBeCalledRepeatedly_resettingTimer() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        uint64 firstUnlock = uint64(block.timestamp + registry.WITHDRAWAL_COOLDOWN());

        vm.warp(block.timestamp + 1 hours);
        registry.requestWithdrawal();
        (,, uint64 secondUnlock,) = registry.searchers(searcher);
        vm.stopPrank();

        assertGt(secondUnlock, firstUnlock);
    }

    function test_withdraw_reverts_ifNotRegistered() public {
        vm.prank(searcher);
        vm.expectRevert(SearcherRegistry.NotRegistered.selector);
        registry.withdraw();
    }

    function test_withdraw_reverts_ifAlreadyWithdrawn() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN());
        registry.withdraw();

        vm.expectRevert(SearcherRegistry.NotRegistered.selector);
        registry.withdraw();
        vm.stopPrank();
    }

    function test_withdraw_thenReRegister_startsFresh() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN());
        registry.withdraw();

        registry.register{value: MIN_BOND}();
        vm.stopPrank();

        assertTrue(registry.isActiveSearcher(searcher));
        (uint128 bond, uint32 slashCount,,) = registry.searchers(searcher);
        assertEq(bond, MIN_BOND);
        assertEq(slashCount, 0, "slash count should not survive a full withdraw/re-register cycle");
    }

    function test_withdraw_exactlyAtCooldownBoundary_succeeds() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN()); // exactly, not +1
        registry.withdraw(); // must not revert
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════
    // slash — deeper coverage
    // ════════════════════════════════════════════════════════════════════

    function test_slash_slashesFullBond_evenWhenToppedUpAboveMinimum() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.topUpBond{value: 5 ether}();
        vm.stopPrank();

        uint256 slashed = registry.slash(searcher);
        assertEq(slashed, MIN_BOND + 5 ether);
    }

    function test_slash_secondSlashOnZeroBond_isNoOp() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();

        registry.slash(searcher);
        uint256 secondSlash = registry.slash(searcher);
        assertEq(secondSlash, 0);

        // slashCount must not increment on a zero-value slash.
        (, uint32 slashCount,,) = registry.searchers(searcher);
        assertEq(slashCount, 1);
    }

    function test_slash_doesNotAffectOtherSearchers() public {
        address searcher2 = makeAddr("searcher2");
        vm.deal(searcher2, 10 ether);

        vm.prank(searcher);
        registry.register{value: MIN_BOND}();
        vm.prank(searcher2);
        registry.register{value: MIN_BOND}();

        registry.slash(searcher);

        (uint128 bond1,,,) = registry.searchers(searcher);
        (uint128 bond2,,,) = registry.searchers(searcher2);
        assertEq(bond1, 0);
        assertEq(bond2, MIN_BOND, "unrelated searcher's bond must be untouched");
        assertTrue(registry.isActiveSearcher(searcher2));
    }

    function test_slash_thenWithdraw_transfersZero() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.stopPrank();

        registry.slash(searcher);

        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN());
        uint256 balBefore = searcher.balance;
        vm.prank(searcher);
        registry.withdraw();
        assertEq(searcher.balance, balBefore, "nothing left to withdraw after a slash");
    }

    function test_requiredBond_staysFlatDouble_afterMultipleSlashes() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        vm.stopPrank();

        registry.slash(searcher);
        assertEq(registry.requiredBond(searcher), MIN_BOND * 2);

        vm.prank(searcher);
        registry.topUpBond{value: MIN_BOND * 2}();
        registry.slash(searcher);

        // Flat 2x penalty, not exponential (2x, not 4x) — see MECHANISM.md.
        assertEq(registry.requiredBond(searcher), MIN_BOND * 2);
    }

    function test_isActiveSearcher_falseForNeverRegistered() public view {
        assertFalse(registry.isActiveSearcher(address(0x1234)));
    }

    function test_isActiveSearcher_falseForZeroBondRegisteredThenSlashed() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();
        registry.slash(searcher);
        assertFalse(registry.isActiveSearcher(searcher));
    }

    // ════════════════════════════════════════════════════════════════════
    // Events
    // ════════════════════════════════════════════════════════════════════

    function test_register_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit SearcherRegistry.SearcherRegistered(searcher, MIN_BOND);
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();
    }

    function test_slash_emitsEvent() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();

        vm.expectEmit(true, false, false, true, address(registry));
        emit SearcherRegistry.SearcherSlashed(searcher, MIN_BOND, 1);
        registry.slash(searcher);
    }

    function test_withdraw_emitsEvent() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN());

        vm.expectEmit(true, false, false, true, address(registry));
        emit SearcherRegistry.Withdrawn(searcher, MIN_BOND);
        registry.withdraw();
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════
    // Fuzz
    // ════════════════════════════════════════════════════════════════════

    function testFuzz_register_succeedsForAnyValueAtOrAboveMinimum(uint96 extra) public {
        uint256 value = MIN_BOND + extra;
        vm.deal(searcher, value);
        vm.prank(searcher);
        registry.register{value: value}();

        (uint128 bond,,,) = registry.searchers(searcher);
        assertEq(bond, value);
        assertTrue(registry.isActiveSearcher(searcher));
    }

    function testFuzz_register_revertsForAnyValueBelowMinimum(uint96 shortfall) public {
        shortfall = uint96(bound(shortfall, 1, MIN_BOND));
        uint256 value = MIN_BOND - shortfall;
        vm.deal(searcher, value);
        vm.prank(searcher);
        vm.expectRevert(SearcherRegistry.InsufficientBond.selector);
        registry.register{value: value}();
    }

    function testFuzz_slash_neverExceedsPostedBond(uint96 topUp) public {
        vm.deal(searcher, uint256(MIN_BOND) + topUp);
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        if (topUp > 0) registry.topUpBond{value: topUp}();
        vm.stopPrank();

        uint256 totalBonded = uint256(MIN_BOND) + topUp;
        uint256 slashed = registry.slash(searcher);
        assertEq(slashed, totalBonded);

        (uint128 bondAfter,,,) = registry.searchers(searcher);
        assertEq(bondAfter, 0);
    }

    function testFuzz_multipleSearchers_bondsAreFullyIsolated(uint96 bondA, uint96 bondB) public {
        bondA = uint96(bound(bondA, MIN_BOND, MIN_BOND + 1000 ether));
        bondB = uint96(bound(bondB, MIN_BOND, MIN_BOND + 1000 ether));

        address searcherA = makeAddr("fuzzSearcherA");
        address searcherB = makeAddr("fuzzSearcherB");
        vm.deal(searcherA, bondA);
        vm.deal(searcherB, bondB);

        vm.prank(searcherA);
        registry.register{value: bondA}();
        vm.prank(searcherB);
        registry.register{value: bondB}();

        registry.slash(searcherA);

        (uint128 finalA,,,) = registry.searchers(searcherA);
        (uint128 finalB,,,) = registry.searchers(searcherB);
        assertEq(finalA, 0);
        assertEq(finalB, bondB, "searcher B's bond must be unaffected by searcher A's slash");
    }

    function testFuzz_topUpBond_accumulatesAcrossManyCalls(uint8 numTopUps, uint32 eachAmount) public {
        numTopUps = uint8(bound(numTopUps, 1, 20));
        eachAmount = uint32(bound(eachAmount, 1, 1000 ether / 20));

        vm.deal(searcher, uint256(numTopUps) * eachAmount + MIN_BOND);
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        for (uint256 i = 0; i < numTopUps; i++) {
            registry.topUpBond{value: eachAmount}();
        }
        vm.stopPrank();

        (uint128 bond,,,) = registry.searchers(searcher);
        assertEq(bond, MIN_BOND + uint256(numTopUps) * eachAmount);
    }

    function testFuzz_withdrawalCooldown_alwaysBlocksEarlyWithdrawal(uint32 tooEarlyBy) public {
        tooEarlyBy = uint32(bound(tooEarlyBy, 1, uint32(registry.WITHDRAWAL_COOLDOWN())));

        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + registry.WITHDRAWAL_COOLDOWN() - tooEarlyBy);
        vm.expectRevert(SearcherRegistry.CooldownNotElapsed.selector);
        registry.withdraw();
        vm.stopPrank();
    }

    function testFuzz_requiredBond_isMinimumOrDoubleNeverAnythingElse(address someSearcher) public view {
        uint256 req = registry.requiredBond(someSearcher);
        assertTrue(req == MIN_BOND || req == MIN_BOND * 2);
    }

    // ════════════════════════════════════════════════════════════════════
    // More coverage
    // ════════════════════════════════════════════════════════════════════

    function test_register_withExcessValue_bondsTheFullAmount() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND * 3}();
        (uint128 bond,,,) = registry.searchers(searcher);
        assertEq(bond, MIN_BOND * 3);
    }

    function test_multipleSlashes_withReRegistrationBetween_slashCountKeepsClimbing() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        vm.stopPrank();
        registry.slash(searcher); // slashCount = 1

        vm.deal(searcher, MIN_BOND * 2);
        vm.prank(searcher);
        registry.topUpBond{value: MIN_BOND * 2}();
        registry.slash(searcher); // slashCount = 2

        vm.deal(searcher, MIN_BOND * 2);
        vm.prank(searcher);
        registry.topUpBond{value: MIN_BOND * 2}();
        registry.slash(searcher); // slashCount = 3

        (, uint32 slashCount,,) = registry.searchers(searcher);
        assertEq(slashCount, 3);
        assertEq(registry.requiredBond(searcher), MIN_BOND * 2, "still flat 2x, not 2^3x");
    }

    function test_withdrawalUnlockTime_isExactlyCooldownAfterRequest() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        uint256 requestTime = block.timestamp;
        registry.requestWithdrawal();
        vm.stopPrank();

        (,, uint64 unlockTime,) = registry.searchers(searcher);
        assertEq(unlockTime, requestTime + registry.WITHDRAWAL_COOLDOWN());
    }

    function test_slash_immediatelyAfterRegister_sameBlock() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();
        uint256 slashed = registry.slash(searcher);
        assertEq(slashed, MIN_BOND);
    }

    function test_topUpBond_byDifferentCallerThanRegistrant_creditsTheCaller() public {
        // topUpBond always credits msg.sender's own position — there is no
        // "top up on behalf of someone else" path, by design (no ambiguity
        // about whose bond grew).
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();

        address stranger = makeAddr("stranger");
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        vm.expectRevert(SearcherRegistry.NotRegistered.selector);
        registry.topUpBond{value: 1 ether}();
    }

    function test_isActiveSearcher_immediatelyTrueAfterRegisterAtExactMinimum() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();
        assertTrue(registry.isActiveSearcher(searcher));
    }

    function test_isActiveSearcher_falseOneWeiBelowRequiredBond_afterSlash() public {
        vm.prank(searcher);
        registry.register{value: MIN_BOND}();
        registry.slash(searcher);

        vm.prank(searcher);
        registry.topUpBond{value: MIN_BOND * 2 - 1}();
        assertFalse(registry.isActiveSearcher(searcher));

        vm.prank(searcher);
        registry.topUpBond{value: 1}();
        assertTrue(registry.isActiveSearcher(searcher));
    }

    function testFuzz_slashCount_neverDecreases(uint8 numCycles) public {
        numCycles = uint8(bound(numCycles, 1, 10));
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        vm.stopPrank();

        uint32 lastCount = 0;
        for (uint256 i = 0; i < numCycles; i++) {
            registry.slash(searcher);
            (, uint32 count,,) = registry.searchers(searcher);
            assertGe(count, lastCount);
            lastCount = count;

            vm.deal(searcher, MIN_BOND * 2);
            vm.prank(searcher);
            registry.topUpBond{value: MIN_BOND * 2}();
        }
        assertEq(lastCount, numCycles);
    }

    // ════════════════════════════════════════════════════════════════════
    // A few more
    // ════════════════════════════════════════════════════════════════════

    function test_minimumBond_isImmutableAndCorrect() public view {
        assertEq(registry.minimumBond(), MIN_BOND);
    }

    function test_WITHDRAWAL_COOLDOWN_isTwentyFourHours() public view {
        assertEq(registry.WITHDRAWAL_COOLDOWN(), 24 hours);
    }

    function test_requestWithdrawal_emitsEvent() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();

        vm.expectEmit(true, false, false, true, address(registry));
        emit SearcherRegistry.WithdrawalRequested(searcher, uint64(block.timestamp + registry.WITHDRAWAL_COOLDOWN()));
        registry.requestWithdrawal();
        vm.stopPrank();
    }

    function test_cancelWithdrawal_emitsEvent() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        registry.requestWithdrawal();

        vm.expectEmit(true, false, false, true, address(registry));
        emit SearcherRegistry.WithdrawalCancelled(searcher);
        registry.cancelWithdrawal();
        vm.stopPrank();
    }

    function test_topUpBond_emitsEvent() public {
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();

        vm.expectEmit(true, false, false, true, address(registry));
        emit SearcherRegistry.BondToppedUp(searcher, 0.5 ether, MIN_BOND + 0.5 ether);
        registry.topUpBond{value: 0.5 ether}();
        vm.stopPrank();
    }

    function testFuzz_topUpThenSlash_slashesExactSum(uint96 initialTopUp, uint96 secondTopUp) public {
        vm.deal(searcher, uint256(MIN_BOND) + initialTopUp + secondTopUp);
        vm.startPrank(searcher);
        registry.register{value: MIN_BOND}();
        if (initialTopUp > 0) registry.topUpBond{value: initialTopUp}();
        if (secondTopUp > 0) registry.topUpBond{value: secondTopUp}();
        vm.stopPrank();

        uint256 expected = uint256(MIN_BOND) + initialTopUp + secondTopUp;
        uint256 slashed = registry.slash(searcher);
        assertEq(slashed, expected);
    }

    function testFuzz_withdraw_alwaysReturnsExactPostedBond(uint96 extra, uint32 warpBy) public {
        uint256 value = uint256(MIN_BOND) + extra;
        vm.deal(searcher, value);
        warpBy = uint32(bound(warpBy, uint32(registry.WITHDRAWAL_COOLDOWN()), type(uint32).max / 2));

        vm.startPrank(searcher);
        registry.register{value: value}();
        registry.requestWithdrawal();
        vm.warp(block.timestamp + warpBy);

        uint256 balBefore = searcher.balance;
        registry.withdraw();
        vm.stopPrank();

        assertEq(searcher.balance, balBefore + value);
    }

    receive() external payable {}
}
