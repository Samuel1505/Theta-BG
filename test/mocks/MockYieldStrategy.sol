// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deterministic ERC4626 mock strategy standing in for Aave/Morpho in
/// tests. Supports a `simulateYield` hook to model strategy APY accruing
/// between slashes, and a `paused` switch to test the "strategy deposit
/// fails, vault must not revert the slash" path
/// (V4_ARCHITECTURE_VALIDATION.md §7).
contract MockYieldStrategy is ERC4626 {
    error DepositsPaused();

    bool public paused;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Strategy Share", "mSTRAT") {}

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    /// @notice Mints `yieldAmount` of the underlying directly to this vault,
    /// simulating accrued strategy yield without a share-price manipulation
    /// vector (mints the *underlying*, not shares) — same effect as real
    /// lending interest accruing to the strategy's holdings.
    function simulateYield(uint256 yieldAmount) external {
        IERC20(asset()).transferFrom(msg.sender, address(this), yieldAmount);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (paused) revert DepositsPaused();
        return super.deposit(assets, receiver);
    }
}
