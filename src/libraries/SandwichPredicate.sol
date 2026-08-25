// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Pure, formally-specified sandwich detection predicate.
/// @dev Deliberately free of storage access and external calls so it can be
/// unit- and fuzz-tested in complete isolation from PoolManager/hook wiring.
/// Terminology: this is a same-block, cross-transaction predicate — NOT a
/// same-transaction predicate. See V4_ARCHITECTURE_VALIDATION.md §2.
library SandwichPredicate {
    /// @notice A single recorded swap, as captured by the hook's ring buffer.
    struct SwapRecord {
        address sender; // the direct PoolManager caller for this swap (see V4_ARCHITECTURE_VALIDATION.md §1)
        uint64 blockNumber;
        bool zeroForOne;
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96After;
        bool occupied; // false = empty/stale ring-buffer slot
    }

    /// @notice Basis-points denominator for the price-restoration threshold.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Evaluate the five-condition sandwich predicate over three
    /// chronologically-ordered swap records (front-run candidate = a,
    /// victim candidate = b, back-run candidate = c).
    /// @param restorationThresholdBps Max allowed deviation between c's
    /// closing price and a's opening price, in basis points (brief's default: 10 = 0.1%).
    /// @param minDisplacementBps Minimum required price displacement caused by
    /// the front-run leg, in basis points — filters out dust swaps that
    /// can't have meaningfully impacted the victim (see MECHANISM.md §"minimum displacement").
    function isSandwich(
        SwapRecord memory a,
        SwapRecord memory b,
        SwapRecord memory c,
        uint256 restorationThresholdBps,
        uint256 minDisplacementBps
    ) internal pure returns (bool) {
        // All three slots must actually hold a recorded swap.
        if (!a.occupied || !b.occupied || !c.occupied) return false;

        // Condition 1: same searcher brackets the victim.
        if (a.sender != c.sender) return false;

        // Condition 2: all three swaps in the same block.
        if (a.blockNumber != b.blockNumber || b.blockNumber != c.blockNumber) return false;

        // Condition 3: middle swap is a different address (the victim).
        if (b.sender == a.sender) return false;

        // Condition 4: front-run and back-run are opposite directions.
        if (a.zeroForOne == c.zeroForOne) return false;

        // Condition 5a: front-run must have displaced price by at least the
        // configured minimum (excludes dust/no-op swaps).
        if (!_deviatesAtLeast(a.sqrtPriceX96Before, a.sqrtPriceX96After, minDisplacementBps)) {
            return false;
        }

        // Condition 5b: price is restored to within the threshold of where it
        // started before the front-run.
        if (!_withinDeviation(a.sqrtPriceX96Before, c.sqrtPriceX96After, restorationThresholdBps)) {
            return false;
        }

        return true;
    }

    /// @notice True if `after_` is within `thresholdBps` of `before` (both directions).
    /// @dev Compares sqrtPriceX96 directly (not price = sqrtPrice^2). Squaring
    /// a Q64.96 value overflows a uint256 well before real price ranges are
    /// reached is not the concern here — the concern is that comparing the
    /// *square roots* to a percentage threshold is not identical to comparing
    /// the underlying prices to that threshold, since price = sqrtPrice^2
    /// means a `t` bps deviation in sqrtPrice is approximately a `2t` bps
    /// deviation in price for small `t`. Theta-BG's configured threshold
    /// (default 10 bps) is deliberately interpreted as a sqrtPriceX96
    /// tolerance, and this approximation is documented explicitly in
    /// MECHANISM.md rather than silently mis-labeled as a price tolerance.
    function _withinDeviation(uint160 before, uint160 after_, uint256 thresholdBps) private pure returns (bool) {
        uint256 diff = before > after_ ? uint256(before) - after_ : uint256(after_) - before;
        return diff * BPS_DENOMINATOR <= uint256(before) * thresholdBps;
    }

    function _deviatesAtLeast(uint160 before, uint160 after_, uint256 thresholdBps) private pure returns (bool) {
        uint256 diff = before > after_ ? uint256(before) - after_ : uint256(after_) - before;
        return diff * BPS_DENOMINATOR >= uint256(before) * thresholdBps;
    }
}
