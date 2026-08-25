// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Dedicated liquidity-provider executor, deployed once per
/// simulated LP for the same identity reasons as ActorRouter (see its
/// header) — and, unlike v4-core's own PoolModifyLiquidityTest, this one
/// implements `receive()` so it can actually collect an ETH-denominated
/// insurance payout in tests.
contract LPRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct CallbackData {
        PoolKey key;
        ModifyLiquidityParams params;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result = manager.unlock(abi.encode(CallbackData(key, params)));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        CallbackData memory d = abi.decode(data, (CallbackData));

        (BalanceDelta delta,) = manager.modifyLiquidity(d.key, d.params, "");
        _settleDelta(d.key.currency0, BalanceDeltaLibrary.amount0(delta));
        _settleDelta(d.key.currency1, BalanceDeltaLibrary.amount1(delta));

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
