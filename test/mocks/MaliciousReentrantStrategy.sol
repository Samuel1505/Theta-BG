// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPInsuranceVault} from "../../src/LPInsuranceVault.sol";

/// @notice An ERC4626 strategy that attempts to reenter the calling vault
/// during deposit()/withdraw() — used to prove LPInsuranceVault's
/// ReentrancyGuard actually blocks this rather than merely assuming it does
/// (SECURITY.md §"reentrancy through the slash call chain").
contract MaliciousReentrantStrategy is ERC4626 {
    LPInsuranceVault public target;
    bool public attackOnDeposit;
    bool public attackOnWithdraw;
    int24 public tickLower;
    int24 public tickUpper;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Malicious Strategy", "EVIL") {}

    function configure(LPInsuranceVault _target, bool _onDeposit, bool _onWithdraw, int24 _tickLower, int24 _tickUpper)
        external
    {
        target = _target;
        attackOnDeposit = _onDeposit;
        attackOnWithdraw = _onWithdraw;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (attackOnDeposit) {
            // Attempt to reenter receiveSlash via a second slash forwarded
            // through the vault while the first one is still executing.
            try target.receiveSlash{value: 0}() {} catch {}
            // Attempt to reenter claimInsuranceYield mid-slash.
            try target.claimInsuranceYield(tickLower, tickUpper, bytes32(0)) {} catch {}
        }
        return super.deposit(assets, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (attackOnWithdraw) {
            try target.claimInsuranceYield(tickLower, tickUpper, bytes32(0)) {} catch {}
        }
        return super.withdraw(assets, receiver, owner);
    }
}
