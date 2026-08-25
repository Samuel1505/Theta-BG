// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LPInsuranceVault} from "../../src/LPInsuranceVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockYieldStrategy} from "../mocks/MockYieldStrategy.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @notice Invariant suite for LPInsuranceVault's reward-accounting
/// solvency: no matter what sequence of liquidity changes, slashes, and
/// claims occurs, the vault must never become able to pay out more than it
/// was ever funded with, and it must always be holding enough to cover
/// every LP's currently-outstanding claimable balance.
contract LPInsuranceVaultInvariantTest is Test, Deployers {
    LPInsuranceVault vault;
    MockWETH weth;
    MockYieldStrategy strategy;
    VaultHandler handler;
    PoolKey poolKey;

    uint256 constant NUM_LPS = 5;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        weth = new MockWETH();
        strategy = new MockYieldStrategy(IERC20(address(weth)));

        (poolKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1);
        PoolId poolId = poolKey.toId();

        address predictedHandler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new LPInsuranceVault(manager, poolId, IWETH9(address(weth)), IERC4626(address(strategy)), predictedHandler);
        handler = new VaultHandler(
            manager, poolKey, vault, Currency.unwrap(currency0), Currency.unwrap(currency1), NUM_LPS
        );
        require(address(handler) == predictedHandler, "handler address prediction mismatch");

        targetContract(address(handler));
    }

    /// @notice The vault can never have paid out more (via claims) than it
    /// was ever funded with (via slashes) — the core solvency guarantee.
    function invariant_neverClaimsMoreThanFunded() public view {
        assertLe(handler.ghost_totalClaimed(), handler.ghost_totalFunded());
    }

    /// @notice Every LP's currently-outstanding claimable balance, summed
    /// across all tracked LPs, must never exceed what the vault actually
    /// holds right now.
    function invariant_outstandingClaimsNeverExceedHeldAssets() public view {
        assertLe(handler.sumOfAllClaimable(), vault.availableBalance());
    }

    /// @notice Total funded, minus total already claimed, minus what's
    /// still outstanding as claimable, must never go negative in spirit —
    /// restated as: funded >= claimed + currently-claimable. Any slack is
    /// FullMath rounding that always favors the vault (rounds down),
    /// exactly as intended — LPs are never overpaid.
    function invariant_fundedCoversClaimedPlusOutstanding() public view {
        assertGe(handler.ghost_totalFunded(), handler.ghost_totalClaimed() + handler.sumOfAllClaimable());
    }

    /// @notice The vault's idle+strategy balance can never be funded from
    /// thin air — it must always be attributable to (funded - claimed),
    /// within the small rounding slack introduced by ERC4626 share math on
    /// each deposit/withdraw cycle.
    function invariant_availableBalanceNeverExceedsFundedMinusClaimed() public view {
        uint256 netFunded = handler.ghost_totalFunded() - handler.ghost_totalClaimed();
        // A tiny epsilon accounts for ERC4626 share-rounding compounding
        // across many deposit/withdraw cycles in a long invariant run.
        assertLe(vault.availableBalance(), netFunded + 1000);
    }
}
