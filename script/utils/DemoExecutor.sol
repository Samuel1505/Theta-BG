// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice On-chain identity for a single demo role (searcher, victim, or
/// LP). Deployed once per role by the deployment scripts for the same
/// reason test/utils/ActorRouter.sol and LPRouter.sol exist: PoolManager
/// attributes swap/liquidity identity to whichever contract directly calls
/// it, so every role needs its own address to be distinguishable on-chain
/// — see V4_ARCHITECTURE_VALIDATION.md §1. Anyone may call `swap`/
/// `modifyLiquidity` on a deployed instance; the only thing that matters
/// for the demo is that each instance's *address* stays constant across
/// the front-run/victim/back-run legs it's used for. Not meant for
/// production searcher/LP use beyond this demo.
contract DemoExecutor is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;

    struct SwapCallback {
        PoolKey key;
        SwapParams params;
    }

    struct LiquidityCallback {
        PoolKey key;
        ModifyLiquidityParams params;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta delta) {
        bytes memory result = manager.unlock(abi.encode(true, abi.encode(SwapCallback(key, params))));
        delta = abi.decode(result, (BalanceDelta));
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory result = manager.unlock(abi.encode(false, abi.encode(LiquidityCallback(key, params))));
        delta = abi.decode(result, (BalanceDelta));
    }

    /// @notice Generic passthrough so this executor can act as itself for
    /// calls beyond swap/modifyLiquidity — specifically, calling
    /// SearcherRegistry.register()/requestWithdrawal()/withdraw() as the
    /// searcher identity the hook will later see as `sender`. Same
    /// demo-only scope as the rest of this contract — see the header.
    function execute(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory result) = target.call{value: value}(data);
        require(ok, "execute failed");
        return result;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (bool isSwap, bytes memory inner) = abi.decode(data, (bool, bytes));

        BalanceDelta delta;
        PoolKey memory key;
        if (isSwap) {
            SwapCallback memory d = abi.decode(inner, (SwapCallback));
            key = d.key;
            delta = manager.swap(d.key, d.params, "");
        } else {
            LiquidityCallback memory d = abi.decode(inner, (LiquidityCallback));
            key = d.key;
            (delta,) = manager.modifyLiquidity(d.key, d.params, "");
        }

        _settleDelta(key.currency0, BalanceDeltaLibrary.amount0(delta));
        _settleDelta(key.currency1, BalanceDeltaLibrary.amount1(delta));
        return abi.encode(delta);
    }

    function _settleDelta(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
