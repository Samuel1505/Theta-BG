// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPInsuranceVault} from "../../../src/LPInsuranceVault.sol";
import {LPRouter} from "../../utils/LPRouter.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Drives LPInsuranceVault through liquidity changes (via a fixed
/// set of LPRouter actors, checkpointing exactly as ThetaBGHook would) and
/// slashes, tracking ghost totals for the solvency invariants.
contract VaultHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public manager;
    PoolKey public key;
    PoolId public poolId;
    LPInsuranceVault public vault;
    LPRouter[] public lps;

    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 6000;

    uint256 public ghost_totalFunded;
    uint256 public ghost_totalClaimed;

    constructor(
        IPoolManager _manager,
        PoolKey memory _key,
        LPInsuranceVault _vault,
        address currency0,
        address currency1,
        uint256 numLPs
    ) {
        manager = _manager;
        key = _key;
        poolId = _key.toId();
        vault = _vault;

        for (uint256 i = 0; i < numLPs; i++) {
            LPRouter r = new LPRouter(_manager);
            IMintable(currency0).mint(address(r), 10_000_000e18);
            IMintable(currency1).mint(address(r), 10_000_000e18);
            lps.push(r);
        }
    }

    function lpsCount() external view returns (uint256) {
        return lps.length;
    }

    function _lp(uint256 seed) internal view returns (LPRouter) {
        return lps[seed % lps.length];
    }

    function addLiquidity(uint256 seed, uint64 amount) public {
        LPRouter r = _lp(seed);
        uint256 delta = (uint256(amount) % 1000e18) + 1e15;

        (uint128 liquidityBefore,,) = manager.getPositionInfo(poolId, address(r), TICK_LOWER, TICK_UPPER, bytes32(0));
        r.modifyLiquidity(key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, int256(delta), bytes32(0)));
        vault.checkpoint(address(r), TICK_LOWER, TICK_UPPER, bytes32(0), liquidityBefore);
    }

    function removeLiquidity(uint256 seed, uint64 amount) public {
        LPRouter r = _lp(seed);
        (uint128 liquidity,,) = manager.getPositionInfo(poolId, address(r), TICK_LOWER, TICK_UPPER, bytes32(0));
        if (liquidity == 0) return;

        uint256 toRemove = (uint256(amount) % liquidity) + 1;
        r.modifyLiquidity(key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, -int256(toRemove), bytes32(0)));
        vault.checkpoint(address(r), TICK_LOWER, TICK_UPPER, bytes32(0), liquidity);
    }

    function slash(uint64 amount) public {
        uint256 value = (uint256(amount) % 10 ether) + 1;
        vm.deal(address(this), value);
        vault.receiveSlash{value: value}();
        ghost_totalFunded += value;
    }

    function claim(uint256 seed) public {
        LPRouter r = _lp(seed);
        uint256 claimable = vault.claimable(address(r), TICK_LOWER, TICK_UPPER, bytes32(0));
        if (claimable == 0) return;

        vm.prank(address(r));
        try vault.claimInsuranceYield(TICK_LOWER, TICK_UPPER, bytes32(0)) returns (uint256 amt) {
            ghost_totalClaimed += amt;
        } catch {}
    }

    function sumOfAllClaimable() external view returns (uint256 sum) {
        for (uint256 i = 0; i < lps.length; i++) {
            sum += vault.claimable(address(lps[i]), TICK_LOWER, TICK_UPPER, bytes32(0));
        }
    }

    receive() external payable {}
}
