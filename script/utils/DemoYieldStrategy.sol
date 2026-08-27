// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The ERC4626 strategy LPInsuranceVault deposits slashed WETH into
/// for this Unichain Sepolia deployment. Named "Demo" deliberately: no
/// verified real ERC4626 yield venue (Aave v3, Morpho, or otherwise) was
/// found deployed on this testnet at the time of deployment — see
/// DEPLOYMENT.md and LIMITATIONS.md. This is the same deterministic-mock
/// pattern used throughout the test suite (test/mocks/MockYieldStrategy.sol),
/// duplicated here rather than imported so script/ doesn't depend on test/.
/// Swapping in a real strategy later requires no change to ThetaBGHook or
/// LPInsuranceVault — only a new `strategy` address at the next hook
/// deployment, since `strategy` is immutable per hook instance.
contract DemoYieldStrategy is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Theta-BG Demo Strategy Share", "tbgDEMO") {}
}
