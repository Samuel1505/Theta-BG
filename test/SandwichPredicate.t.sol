// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SandwichPredicate} from "../src/libraries/SandwichPredicate.sol";

/// @notice Pure unit + fuzz tests for the five-condition predicate, isolated
/// from PoolManager entirely. This is where the brief's false-positive
/// demands (build prompt §17, §51) are exercised precisely, since every
/// input here is hand-constructed rather than derived from real swap math.
contract SandwichPredicateTest is Test {
    uint256 constant RESTORATION_BPS = 10; // 0.1%
    uint256 constant MIN_DISPLACEMENT_BPS = 50; // 0.5%

    address constant SEARCHER = address(0xAAAA);
    address constant SEARCHER_2 = address(0xBBBB);
    address constant VICTIM = address(0xCCCC);
    address constant VICTIM_2 = address(0xDDDD);

    function _record(address sender, uint64 blockNum, bool zeroForOne, uint160 before, uint160 after_)
        internal
        pure
        returns (SandwichPredicate.SwapRecord memory)
    {
        return SandwichPredicate.SwapRecord({
            sender: sender,
            blockNumber: blockNum,
            zeroForOne: zeroForOne,
            sqrtPriceX96Before: before,
            sqrtPriceX96After: after_,
            occupied: true
        });
    }

    // ════════════════════════════════════════════════════════════════════
    // Positive cases
    // ════════════════════════════════════════════════════════════════════

    /// @notice The canonical positive case: searcher brackets victim, same
    /// block, opposite directions, price restored — must slash.
    function test_classicSandwich_isDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1001);

        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Direction of the front-run doesn't matter — a sandwich can
    /// push price down first (sell into victim) just as validly as up.
    function test_classicSandwich_reverseDirection_isDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, false, 1000, 900);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, false, 900, 850);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, true, 850, 999);

        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice The victim's own recorded direction is irrelevant to the
    /// predicate — only conditions on a/c's directions and b's identity
    /// matter. A victim trading in either direction between the two
    /// searcher legs still counts as bracketed.
    function test_victimDirection_doesNotAffectDetection_sameDirectionAsFrontRun() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    function test_victimDirection_doesNotAffectDetection_oppositeOfFrontRun() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, false, 1100, 1050);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1050, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice The victim's recorded prices are entirely irrelevant to the
    /// predicate (only a's and c's prices are examined) — extreme or
    /// nonsensical values in b's price fields must not change the outcome.
    function test_victimPrices_areIgnored_evenWhenExtreme() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1, type(uint160).max);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice address(0) is a structurally valid sender at this pure layer
    /// — real-world gating on "not a zero/burn address" happens at the
    /// SearcherRegistry/hook layer (isActiveSearcher), not here.
    function test_zeroAddressSender_structurallyValid() public pure {
        SandwichPredicate.SwapRecord memory a = _record(address(0), 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(address(0), 100, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Block number 0 is a valid block like any other.
    function test_blockZero_isValid() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 0, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 0, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 0, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Maximum uint64 block number does not overflow the equality checks.
    function test_maxBlockNumber_isValid() public pure {
        uint64 maxBlock = type(uint64).max;
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, maxBlock, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, maxBlock, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, maxBlock, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Large sqrtPriceX96 values near the practical top of the type
    /// don't overflow the internal diff/bps arithmetic.
    function test_largePrices_nearUint160Max_noOverflow() public pure {
        uint160 big = type(uint160).max / 2;
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, big, big - (big / 100));
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, big - (big / 100), big - (big / 90));
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, big - (big / 90), big - (big / 5000));
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice restorationThresholdBps == 10_000 (100%) makes restoration
    /// trivially satisfied by any price, no matter how far off.
    function test_restorationThreshold_100Percent_alwaysRestores() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, 10_000, MIN_DISPLACEMENT_BPS));
    }

    /// @notice minDisplacementBps == 0 makes even a one-unit price change
    /// satisfy the displacement floor.
    function test_minDisplacement_zero_anyNonZeroMoveQualifies() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1_000_000, 999_999);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 999_999, 999_998);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 999_998, 1_000_000);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, 0));
    }

    /// @notice Boundary: displacement exactly equal to the minimum must
    /// count (condition uses >=, not >).
    function test_displacement_exactlyAtThreshold_isDetected() public pure {
        // before=10_000, after must differ by exactly 0.5% (50 bps) = 50.
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 10_000, 9_950);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 9_950, 9_900);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 9_900, 10_000);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, 50));
    }

    /// @notice Boundary: restoration exactly at the threshold must count
    /// (condition uses <=, not <).
    function test_restoration_exactlyAtThreshold_isDetected() public pure {
        // before=10_000, restorationThresholdBps=10 (0.1%) => max diff = 10.
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 10_000, 9_000);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 9_000, 8_500);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 8_500, 9_990);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, 10, MIN_DISPLACEMENT_BPS));
    }

    // ════════════════════════════════════════════════════════════════════
    // Negative cases — structural gating
    // ════════════════════════════════════════════════════════════════════

    /// @notice Directional arbitrage: single actor moves price and leaves it
    /// moved. There is no third leg restoring price, so any (a,b,c) window
    /// containing this swap fails because there's no matching back-run at
    /// all — modeled here as c's sender not matching a's sender.
    function test_directionalArb_doesNotBracketAVictim_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER_2, 100, false, 1150, 1002);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Legitimate round-trip arbitrage around another trader: same
    /// address opens and closes a position, but price is NOT restored to
    /// within the tight threshold.
    function test_looseRoundTrip_priceNotRestored_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1080);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Same address on both sides, but the middle "victim" swap is
    /// also from the same address — no distinct victim, must not slash.
    function test_selfSandwich_noDistinctVictim_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(SEARCHER, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1001);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Same three-address pattern, but the back-run lands in the
    /// next block (build prompt §45's cross-block edge case).
    function test_backRunInNextBlock_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 101, false, 1150, 1001);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice The victim's swap landing in a different block than the
    /// bracketing legs must also fail — condition 2 requires all three
    /// blocks equal, not just a and c.
    function test_victimInDifferentBlock_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 99, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1001);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Front-run and back-run in the *same* direction — never a
    /// sandwich shape.
    function test_sameDirectionFrontAndBack_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, true, 1150, 1200);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Dust front-run: displaces price by far less than the
    /// configured minimum (build prompt §71 Attack 15).
    function test_dustDisplacement_belowMinimum_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1001);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1001, 1002);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1002, 1000);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Boundary: displacement one unit below the minimum must fail
    /// (strictly less than, not equal).
    function test_displacement_oneUnitBelowThreshold_notDetected() public pure {
        // before=10_000, threshold 50 bps => need diff>=50. Use diff=49.
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 10_000, 9_951);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 9_951, 9_900);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 9_900, 10_000);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, 50));
    }

    /// @notice Boundary: restoration one unit beyond the threshold must fail.
    function test_restoration_oneUnitBeyondThreshold_notDetected() public pure {
        // before=10_000, threshold 10 bps => max diff=10. Use diff=11.
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 10_000, 9_000);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 9_000, 8_500);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 8_500, 9_989);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, 10, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Zero price displacement never clears a nonzero minimum.
    function test_zeroDisplacement_neverClearsNonzeroMinimum() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1000, 1000);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, 1));
    }

    /// @notice An empty ring-buffer slot (pool with fewer than 3 total
    /// swaps yet) must never match — "occupied" gates everything.
    function test_emptySlotA_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a; // occupied = false
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1001);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    function test_emptySlotB_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b;
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 100, false, 1150, 1001);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    function test_emptySlotC_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c;
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    function test_allSlotsEmpty_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a;
        SandwichPredicate.SwapRecord memory b;
        SandwichPredicate.SwapRecord memory c;
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Multiple pools / multiple independent sandwiches must not
    /// cross-contaminate (build prompt §47) — two unrelated bracketing
    /// patterns from different searchers evaluated independently must each
    /// resolve on their own.
    function test_multipleIndependentSearchers_eachEvaluatedOnOwnMerits() public pure {
        SandwichPredicate.SwapRecord memory a1 = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b1 = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c1 = _record(SEARCHER, 100, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a1, b1, c1, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));

        SandwichPredicate.SwapRecord memory a2 = _record(SEARCHER_2, 200, true, 500, 550);
        SandwichPredicate.SwapRecord memory b2 = _record(VICTIM, 200, true, 550, 560);
        SandwichPredicate.SwapRecord memory c2 = _record(VICTIM, 200, false, 560, 500);
        assertFalse(SandwichPredicate.isSandwich(a2, b2, c2, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Two different victims across two independent patterns don't
    /// interfere with each other's evaluation.
    function test_differentVictims_independentPatterns() public pure {
        SandwichPredicate.SwapRecord memory a1 = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b1 = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c1 = _record(SEARCHER, 100, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a1, b1, c1, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));

        SandwichPredicate.SwapRecord memory a2 = _record(SEARCHER, 300, true, 2000, 2200);
        SandwichPredicate.SwapRecord memory b2 = _record(VICTIM_2, 300, true, 2200, 2300);
        SandwichPredicate.SwapRecord memory c2 = _record(SEARCHER, 300, false, 2300, 2002);
        assertTrue(SandwichPredicate.isSandwich(a2, b2, c2, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice A router-style shared sender for victim and searcher (e.g.
    /// aggregator both parties happened to route through) — since identity
    /// is opaque to this pure layer, condition 3 correctly denies detection
    /// whenever b's sender literally equals a's, regardless of what "kind"
    /// of address it is.
    function test_sharedRouterSenderForVictimAndSearcher_notDetected() public pure {
        address sharedRouter = address(0xF00D);
        SandwichPredicate.SwapRecord memory a = _record(sharedRouter, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(sharedRouter, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(sharedRouter, 100, false, 1150, 1001);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    // ════════════════════════════════════════════════════════════════════
    // Fuzz: invariants that must hold no matter what values are fuzzed
    // ════════════════════════════════════════════════════════════════════

    /// @notice Invariant: if the front-run and back-run senders differ, the
    /// predicate must never detect a sandwich, no matter what the prices or
    /// blocks are.
    function testFuzz_mismatchedSenders_neverDetected(
        address searcherA,
        address searcherC,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        bool dir0,
        bool dir2,
        uint64 blockNum
    ) public pure {
        vm.assume(searcherA != searcherC);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);

        SandwichPredicate.SwapRecord memory a = _record(searcherA, blockNum, dir0, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, blockNum, dir0, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcherC, blockNum, dir2, p1, p2);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Invariant: if front-run and back-run are in the same
    /// direction, the predicate must never detect a sandwich.
    function testFuzz_sameDirection_neverDetected(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        bool dir,
        uint64 blockNum
    ) public pure {
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);

        SandwichPredicate.SwapRecord memory a = _record(searcher, blockNum, dir, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, blockNum, dir, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, blockNum, dir, p1, p2);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Invariant: if the victim's address equals the searcher's, the
    /// predicate must never detect a sandwich (no distinct victim).
    function testFuzz_victimEqualsSearcher_neverDetected(
        address searcher,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        bool dir0,
        bool dir2,
        uint64 blockNum
    ) public pure {
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);

        SandwichPredicate.SwapRecord memory a = _record(searcher, blockNum, dir0, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(searcher, blockNum, dir0, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, blockNum, dir2, p1, p2);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Invariant: differing block numbers anywhere among the three
    /// records defeats detection, regardless of every other field.
    function testFuzz_anyBlockMismatch_neverDetected(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        uint64 blockA,
        uint64 blockB,
        uint64 blockC
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);
        vm.assume(!(blockA == blockB && blockB == blockC));

        SandwichPredicate.SwapRecord memory a = _record(searcher, blockA, true, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, blockB, true, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, blockC, false, p1, p2);

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Invariant: any unoccupied slot forces a false result,
    /// regardless of the fuzzed values in the other fields.
    function testFuzz_anyUnoccupiedSlot_neverDetected(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        uint64 blockNum,
        uint8 whichEmpty
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);

        SandwichPredicate.SwapRecord memory a = _record(searcher, blockNum, true, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, blockNum, true, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, blockNum, false, p1, p2);

        if (whichEmpty % 3 == 0) a.occupied = false;
        else if (whichEmpty % 3 == 1) b.occupied = false;
        else c.occupied = false;

        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Invariant: whenever the predicate returns true, each of the
    /// five conditions independently and verifiably holds — a positive
    /// detection is never a coincidence of the specific arithmetic used.
    function testFuzz_wheneverDetected_allFiveConditionsIndependentlyHold(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        bool dir0,
        uint64 blockNum,
        uint256 restorationBps,
        uint256 displacementBps
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);
        restorationBps = bound(restorationBps, 0, 10_000);
        displacementBps = bound(displacementBps, 0, 10_000);

        SandwichPredicate.SwapRecord memory a = _record(searcher, blockNum, dir0, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, blockNum, !dir0, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, blockNum, !dir0, p1, p2);

        bool result = SandwichPredicate.isSandwich(a, b, c, restorationBps, displacementBps);

        if (result) {
            assertEq(a.sender, c.sender, "condition 1");
            assertTrue(a.blockNumber == b.blockNumber && b.blockNumber == c.blockNumber, "condition 2");
            assertTrue(b.sender != a.sender, "condition 3");
            assertTrue(a.zeroForOne != c.zeroForOne, "condition 4");

            uint256 dispDiff = p0 > p1 ? uint256(p0) - p1 : uint256(p1) - p0;
            assertTrue(dispDiff * 10_000 >= uint256(p0) * displacementBps, "condition 5a");

            uint256 restDiff = p0 > p2 ? uint256(p0) - p2 : uint256(p2) - p0;
            assertTrue(restDiff * 10_000 <= uint256(p0) * restorationBps, "condition 5b");
        }
    }

    /// @notice Invariant: raising the restoration threshold can only ever
    /// turn a non-detection into a detection, never the reverse (monotonic
    /// in the threshold, holding everything else fixed).
    function testFuzz_restorationThreshold_isMonotonic(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        uint256 lowerThreshold,
        uint256 higherThreshold
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);
        lowerThreshold = bound(lowerThreshold, 0, 5_000);
        higherThreshold = bound(higherThreshold, lowerThreshold, 10_000);

        SandwichPredicate.SwapRecord memory a = _record(searcher, 1, true, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, 1, true, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, 1, false, p1, p2);

        bool detectedAtLower = SandwichPredicate.isSandwich(a, b, c, lowerThreshold, 0);
        bool detectedAtHigher = SandwichPredicate.isSandwich(a, b, c, higherThreshold, 0);

        if (detectedAtLower) {
            assertTrue(detectedAtHigher, "loosening the restoration band must not lose a detection");
        }
    }

    /// @notice Invariant: raising the minimum-displacement floor can only
    /// ever turn a detection into a non-detection, never the reverse.
    function testFuzz_minDisplacement_isAntitonic(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        uint256 lowerFloor,
        uint256 higherFloor
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);
        lowerFloor = bound(lowerFloor, 0, 5_000);
        higherFloor = bound(higherFloor, lowerFloor, 10_000);

        SandwichPredicate.SwapRecord memory a = _record(searcher, 1, true, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, 1, true, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, 1, false, p1, p2);

        bool detectedAtHigherFloor = SandwichPredicate.isSandwich(a, b, c, 10_000, higherFloor);
        bool detectedAtLowerFloor = SandwichPredicate.isSandwich(a, b, c, 10_000, lowerFloor);

        if (detectedAtHigherFloor) {
            assertTrue(detectedAtLowerFloor, "raising the displacement floor must not gain a detection");
        }
    }

    /// @notice Invariant: swapping which of a/c is "front" vs "back" (by
    /// flipping both their directions) never changes whether the shape as a
    /// whole is internally consistent — restated concretely: detection
    /// depends only on the *magnitude* of displacement/restoration, not on
    /// which literal direction (true/false) the front-run happens to be.
    function testFuzz_directionLabelsAreSymmetric(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        uint64 blockNum
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);

        SandwichPredicate.SwapRecord memory aTrue = _record(searcher, blockNum, true, p0, p1);
        SandwichPredicate.SwapRecord memory bTrue = _record(victim, blockNum, true, p1, p1);
        SandwichPredicate.SwapRecord memory cTrue = _record(searcher, blockNum, false, p1, p2);

        SandwichPredicate.SwapRecord memory aFalse = _record(searcher, blockNum, false, p0, p1);
        SandwichPredicate.SwapRecord memory bFalse = _record(victim, blockNum, false, p1, p1);
        SandwichPredicate.SwapRecord memory cFalse = _record(searcher, blockNum, true, p1, p2);

        assertEq(
            SandwichPredicate.isSandwich(aTrue, bTrue, cTrue, RESTORATION_BPS, MIN_DISPLACEMENT_BPS),
            SandwichPredicate.isSandwich(aFalse, bFalse, cFalse, RESTORATION_BPS, MIN_DISPLACEMENT_BPS)
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // More boundary / structural cases
    // ════════════════════════════════════════════════════════════════════

    /// @notice A price that stays perfectly flat across all three legs
    /// (before == after for every record) satisfies restoration trivially
    /// (0 deviation) but fails the displacement floor whenever it's
    /// nonzero — the two conditions pull in opposite directions by design.
    function test_perfectlyFlatPrice_failsNonzeroDisplacementFloor() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 1, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, false, 1000, 1000);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, 1));
    }

    /// @notice The same flat-price case, but with a zero displacement
    /// floor, is a legitimate (if degenerate) detection — every condition
    /// is satisfied by definition.
    function test_perfectlyFlatPrice_withZeroFloor_isDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 1, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, false, 1000, 1000);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, 0));
    }

    /// @notice Price overshooting past the starting point on the back-run
    /// (searcher pushes it further than restoration, out the other side)
    /// still counts as "restored" as long as the *magnitude* of the
    /// overshoot is within the threshold — restoration is a two-sided band,
    /// not a one-sided "must not exceed" check.
    function test_overshootPastStartingPrice_stillWithinBand_isDetected() public pure {
        // before=10_000, threshold 10 bps (max diff 10). Overshoot to
        // 10_005 (5 above start) is still within the symmetric band.
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, true, 10_000, 9_000);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 1, true, 9_000, 8_500);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, false, 8_500, 10_005);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, 10, MIN_DISPLACEMENT_BPS));
    }

    /// @notice A minimal 1-wei price difference for both before/after
    /// values (the smallest nonzero sqrtPriceX96 representable near the
    /// bottom of the type's range) doesn't cause division-by-zero or
    /// underflow in the bps arithmetic.
    function test_minimalNonzeroPrices_noArithmeticIssues() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, true, 2, 1);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 1, true, 1, 1);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, false, 1, 2);
        // before=2, after=1 is a 50% displacement (5000 bps) — clears any
        // reasonable floor; restoration back to 2 is an exact match (0 bps).
        assertTrue(SandwichPredicate.isSandwich(a, b, c, 0, 5000));
    }

    /// @notice A victim address that happens to equal address(0) (e.g. a
    /// burn-address artifact) is still treated as a structurally valid,
    /// distinct sender — no special-casing of the zero address anywhere in
    /// the predicate.
    function test_victimIsZeroAddress_stillTreatedAsDistinct() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(address(0), 1, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Condition evaluation order doesn't matter for the final
    /// result — running the same inputs twice is deterministic (pure
    /// function, no hidden state).
    function test_isDeterministic_acrossRepeatedCalls() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 1, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, false, 1150, 1001);
        bool first = SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS);
        bool second = SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS);
        assertEq(first, second);
    }

    /// @notice Invariant: the predicate's result depends only on the six
    /// scalar fields actually read (sender/block/direction/prices) — two
    /// records with identical relevant fields but constructed independently
    /// (not aliased/copied) produce identical results.
    function testFuzz_identicalInputsFromDifferentConstructions_agree(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        uint64 blockNum,
        uint256 restorationBps,
        uint256 displacementBps
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0 && p2 > 0);
        restorationBps = bound(restorationBps, 0, 10_000);
        displacementBps = bound(displacementBps, 0, 10_000);

        SandwichPredicate.SwapRecord memory a1 = _record(searcher, blockNum, true, p0, p1);
        SandwichPredicate.SwapRecord memory b1 = _record(victim, blockNum, true, p1, p1);
        SandwichPredicate.SwapRecord memory c1 = _record(searcher, blockNum, false, p1, p2);

        SandwichPredicate.SwapRecord memory a2 = _record(searcher, blockNum, true, p0, p1);
        SandwichPredicate.SwapRecord memory b2 = _record(victim, blockNum, true, p1, p1);
        SandwichPredicate.SwapRecord memory c2 = _record(searcher, blockNum, false, p1, p2);

        assertEq(
            SandwichPredicate.isSandwich(a1, b1, c1, restorationBps, displacementBps),
            SandwichPredicate.isSandwich(a2, b2, c2, restorationBps, displacementBps)
        );
    }

    /// @notice Invariant: a restoration threshold of exactly 10_000 bps
    /// (100%) always satisfies condition 5b, for any prices — the band
    /// covers the entire possible deviation range once `before > 0`.
    function testFuzz_maxRestorationThreshold_alwaysSatisfiesRestoration(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p1,
        uint160 p2,
        uint64 blockNum
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0 && p1 > 0);
        // A 100% band means |after - before| <= before, i.e. after must
        // fall within [0, 2*before] — NOT "any value whatsoever". Bounding
        // p2 into that range here (rather than asserting the stronger, and
        // false, claim that literally any p2 clears a 100% band once
        // before is small and after is far more than double it).
        p2 = uint160(bound(uint256(p2), 0, uint256(p0) * 2));

        SandwichPredicate.SwapRecord memory a = _record(searcher, blockNum, true, p0, p1);
        SandwichPredicate.SwapRecord memory b = _record(victim, blockNum, true, p1, p1);
        SandwichPredicate.SwapRecord memory c = _record(searcher, blockNum, false, p1, p2);

        // With displacement floor at 0 and restoration at 100%, every
        // structurally-valid bracket with `after` inside [0, 2*before] must
        // be detected.
        assertTrue(SandwichPredicate.isSandwich(a, b, c, 10_000, 0));
    }

    // ════════════════════════════════════════════════════════════════════
    // A few more named boundary cases
    // ════════════════════════════════════════════════════════════════════

    function test_frontRunUpThenBackRunDown_isValidDirectionPair() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, false, 1000, 1200);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 1, false, 1200, 1300);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, true, 1300, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice A victim block-number field that overflows the uint64 range
    /// on its own doesn't matter — equality is what's checked, not range.
    function test_maxBlockNumber_allThreeMatching_stillDetected() public pure {
        uint64 maxBlock = type(uint64).max;
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, maxBlock, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, maxBlock, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, maxBlock, false, 1150, 1001);
        assertTrue(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice block number 1 apart (adjacent, but not equal) fails just as
    /// clearly as blocks far apart — condition 2 is strict equality, not "close enough".
    function test_blockNumbersOneApart_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 100, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 99, false, 1150, 1001);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    function test_allThreeInDifferentBlocks_notDetected() public pure {
        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 100, true, 1000, 1100);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 101, true, 1100, 1150);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 102, false, 1150, 1001);
        assertFalse(SandwichPredicate.isSandwich(a, b, c, RESTORATION_BPS, MIN_DISPLACEMENT_BPS));
    }

    /// @notice Both restoration and displacement thresholds at zero
    /// simultaneously only detects a *perfectly flat* round trip (any
    /// nonzero front-run displacement fails the zero floor).
    function test_bothThresholdsZero_onlyPerfectlyFlatRoundTripQualifies() public pure {
        SandwichPredicate.SwapRecord memory aFlat = _record(SEARCHER, 1, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory bFlat = _record(VICTIM, 1, true, 1000, 1000);
        SandwichPredicate.SwapRecord memory cFlat = _record(SEARCHER, 1, false, 1000, 1000);
        assertTrue(SandwichPredicate.isSandwich(aFlat, bFlat, cFlat, 0, 0));

        SandwichPredicate.SwapRecord memory a = _record(SEARCHER, 1, true, 1000, 999);
        SandwichPredicate.SwapRecord memory b = _record(VICTIM, 1, true, 999, 998);
        SandwichPredicate.SwapRecord memory c = _record(SEARCHER, 1, false, 998, 1001); // 1 unit off from a's starting 1000
        assertFalse(SandwichPredicate.isSandwich(a, b, c, 0, 0), "even a 1-unit restoration deviation fails a zero band");
    }

    /// @notice Fuzz: for any occupied triple with matching sender/block/
    /// opposite-direction structure, detection is entirely determined by
    /// the two price conditions — never by anything else varying.
    function testFuzz_structurallyValidTriple_detectionDependsOnlyOnPriceConditions(
        address searcher,
        address victim,
        uint160 p0,
        uint160 p2,
        uint64 blockNum,
        uint256 restorationBps
    ) public pure {
        vm.assume(searcher != victim);
        vm.assume(p0 > 0);
        restorationBps = bound(restorationBps, 0, 10_000);

        SandwichPredicate.SwapRecord memory a = _record(searcher, blockNum, true, p0, p0);
        SandwichPredicate.SwapRecord memory b = _record(victim, blockNum, true, p0, p0);
        SandwichPredicate.SwapRecord memory c = _record(searcher, blockNum, false, p0, p2);

        bool result = SandwichPredicate.isSandwich(a, b, c, restorationBps, 0);

        uint256 diff = p0 > p2 ? uint256(p0) - p2 : uint256(p2) - p0;
        bool expectedRestoration = diff * 10_000 <= uint256(p0) * restorationBps;
        assertEq(result, expectedRestoration);
    }
}
