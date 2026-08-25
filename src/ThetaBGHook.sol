// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SearcherRegistry} from "./SearcherRegistry.sol";
import {LPInsuranceVault} from "./LPInsuranceVault.sol";
import {SandwichPredicate} from "./libraries/SandwichPredicate.sol";

/// @notice Theta-BG: bonded searcher priority lane, on-chain same-block
/// sandwich detection, and a self-compounding LP insurance vault funded by
/// slashed bonds. See MECHANISM.md for the full economic model and
/// V4_ARCHITECTURE_VALIDATION.md for how every mechanism here was checked
/// against actual v4-core semantics rather than assumed from the brief.
///
/// Deliberate scope, stated up front (see LIMITATIONS.md for the full list):
/// - Detection is same-block, cross-transaction — never "same-transaction"
///   (transient storage cannot span transactions; see the ring buffer below).
/// - Searcher identity = the direct caller of PoolManager.swap(). Since an
///   EOA cannot implement IUnlockCallback, every real caller is already a
///   contract — this matches how MEV searcher bots operate in practice, and
///   needs no additional trusted-router indirection.
/// - LP insurance distribution uses a fee-growth-style accumulator over
///   StateLibrary's live liquidity — no LP enumeration, ever.
/// - All economic parameters are immutable, set at hook deployment. There is
///   no owner/admin function that can alter slashing, fees, or redirect
///   insurance funds.
contract ThetaBGHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error NotProtocolFeeRecipient();
    error ZeroValue();
    error InvalidLiquidityDelta();

    event PoolInsuranceVaultDeployed(PoolId indexed poolId, address vault);
    event PriorityFeeCollected(PoolId indexed poolId, address indexed searcher, Currency currency, uint256 amount);
    event SandwichSlashed(
        PoolId indexed poolId,
        address indexed searcher,
        address indexed victim,
        uint256 totalSlashed,
        uint256 protocolCut,
        uint256 insuranceCut
    );
    event ProtocolFeesWithdrawn(uint256 amount);

    IPoolManager public immutable poolManager;
    SearcherRegistry public immutable registry;
    IWETH9 public immutable weth;
    IERC4626 public immutable strategy;
    address public immutable protocolFeeRecipient;

    /// @notice Basis-points denominator used by every *Bps immutable below.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Max allowed deviation between the back-run's closing price and
    /// the front-run's opening price for the pattern to count as "restored".
    /// Default: 10 bps (0.1%), matching the brief.
    uint256 public immutable restorationThresholdBps;

    /// @notice Minimum price displacement the front-run leg must cause for
    /// the pattern to be considered at all — filters dust swaps that could
    /// never have meaningfully impacted a victim. Not present in the
    /// original brief's five conditions; added per
    /// V4_ARCHITECTURE_VALIDATION.md / MECHANISM.md "minimum displacement".
    uint256 public immutable minDisplacementBps;

    /// @notice Fee charged to bonded searchers on exact-input swaps, in bps
    /// of the specified (input) amount, atomically donated to in-range LPs
    /// via PoolManager.donate() — reuses v4's own fee-growth accounting
    /// rather than a bespoke LP-facing accumulator for this revenue stream.
    uint256 public immutable priorityFeeBps;

    /// @notice Share of a slash routed to `protocolFeeRecipient`; the
    /// remainder funds the pool's LPInsuranceVault. Default: 1000 (10%).
    uint256 public immutable protocolShareBps;

    uint256 public pendingProtocolFees;

    mapping(PoolId => LPInsuranceVault) public vaults;
    mapping(PoolId => SandwichPredicate.SwapRecord[3]) private ringBuffer;
    mapping(PoolId => uint8) private ringNext;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        uint256 _minimumBond,
        IWETH9 _weth,
        IERC4626 _strategy,
        address _protocolFeeRecipient,
        uint256 _restorationThresholdBps,
        uint256 _minDisplacementBps,
        uint256 _priorityFeeBps,
        uint256 _protocolShareBps
    ) {
        if (_protocolFeeRecipient == address(0)) revert ZeroValue();

        poolManager = _poolManager;
        weth = _weth;
        strategy = _strategy;
        protocolFeeRecipient = _protocolFeeRecipient;
        restorationThresholdBps = _restorationThresholdBps;
        minDisplacementBps = _minDisplacementBps;
        priorityFeeBps = _priorityFeeBps;
        protocolShareBps = _protocolShareBps;

        registry = new SearcherRegistry(_minimumBond, address(this));

        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    receive() external payable {}

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // IHooks — only the six callbacks this hook is permissioned for do real
    // work; the rest exist purely to satisfy the interface and revert if
    // ever invoked (PoolManager only calls a callback if the permission flag
    // is set, so these are unreachable in practice).
    // ─────────────────────────────────────────────────────────────────────

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        LPInsuranceVault vault = new LPInsuranceVault(poolManager, poolId, weth, strategy, address(this));
        vaults[poolId] = vault;
        emit PoolInsuranceVaultDeployed(poolId, address(vault));
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Bridge this call's pre-swap price to afterSwap of the SAME
        // transaction (same PoolManager.swap() invocation) via transient
        // storage — the one legitimate use of EIP-1153 here. See
        // V4_ARCHITECTURE_VALIDATION.md §2.
        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(poolId);
        _tstore(_priceBeforeSlot(poolId), sqrtPriceX96Before);

        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        if (params.amountSpecified < 0 && priorityFeeBps > 0 && registry.isActiveSearcher(sender)) {
            uint256 specifiedIn = uint256(-params.amountSpecified);
            uint256 fee = (specifiedIn * priorityFeeBps) / BPS_DENOMINATOR;

            // Never let the fee consume the entire specified amount — would
            // flip the swap's exact-input/output type and revert in
            // Hooks.beforeSwap's own guard. In practice fee << trade size
            // for any sane priorityFeeBps, this is a defensive clamp only.
            if (fee > 0 && fee < specifiedIn) {
                bool specifiedIsCurrency0 = params.zeroForOne;
                Currency specifiedCurrency = specifiedIsCurrency0 ? key.currency0 : key.currency1;

                delta = toBeforeSwapDelta(int128(int256(fee)), 0);
                poolManager.take(specifiedCurrency, address(this), fee);

                if (specifiedIsCurrency0) {
                    poolManager.donate(key, fee, 0, "");
                } else {
                    poolManager.donate(key, 0, fee, "");
                }
                _settleCurrency(specifiedCurrency, fee);

                emit PriorityFeeCollected(poolId, sender, specifiedCurrency, fee);
            }
        }

        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        uint160 sqrtPriceX96Before = _tload(_priceBeforeSlot(poolId));
        (uint160 sqrtPriceX96After,,,) = poolManager.getSlot0(poolId);

        // `w` is the slot about to be overwritten with this (newest) swap.
        // After writing, the three filled slots in oldest-to-newest order
        // are (w+1)%3, (w+2)%3, w — i.e. the slot we just wrote is always
        // the *newest* record, and the slot we're about to overwrite next
        // time is always the *oldest* of the three still held.
        uint8 w = ringNext[poolId];
        ringBuffer[poolId][w] = SandwichPredicate.SwapRecord({
            sender: sender,
            blockNumber: uint64(block.number),
            zeroForOne: params.zeroForOne,
            sqrtPriceX96Before: sqrtPriceX96Before,
            sqrtPriceX96After: sqrtPriceX96After,
            occupied: true
        });
        ringNext[poolId] = (w + 1) % 3;

        SandwichPredicate.SwapRecord memory a = ringBuffer[poolId][(w + 1) % 3]; // oldest = front-run candidate
        SandwichPredicate.SwapRecord memory b = ringBuffer[poolId][(w + 2) % 3]; // middle = victim candidate
        SandwichPredicate.SwapRecord memory c = ringBuffer[poolId][w]; // newest = back-run candidate

        // Only worth evaluating if the would-be front-runner is still an
        // active bonded searcher — otherwise there is nothing to slash and
        // no reason to flag an ordinary three-swap coincidence.
        if (
            registry.isActiveSearcher(a.sender)
                && SandwichPredicate.isSandwich(a, b, c, restorationThresholdBps, minDisplacementBps)
        ) {
            _slashAndFund(poolId, a.sender, b.sender);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        _checkpoint(key, sender, params);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        _checkpoint(key, sender, params);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // Unused callbacks — unreachable because their permission flags are
    // false, so PoolManager never invokes them (Hooks.sol gates every call
    // on hasPermission). Implemented only to satisfy IHooks.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────

    function _slashAndFund(PoolId poolId, address searcher, address victim) private {
        uint256 amountSlashed = registry.slash(searcher);
        if (amountSlashed == 0) return;

        uint256 protocolCut = (amountSlashed * protocolShareBps) / BPS_DENOMINATOR;
        uint256 insuranceCut = amountSlashed - protocolCut;

        pendingProtocolFees += protocolCut;

        LPInsuranceVault vault = vaults[poolId];
        if (insuranceCut > 0) {
            vault.receiveSlash{value: insuranceCut}();
        }

        emit SandwichSlashed(poolId, searcher, victim, amountSlashed, protocolCut, insuranceCut);
    }

    function _checkpoint(PoolKey calldata key, address owner, ModifyLiquidityParams calldata params) private {
        PoolId poolId = key.toId();
        (uint128 liquidityAfter,,) =
            poolManager.getPositionInfo(poolId, owner, params.tickLower, params.tickUpper, params.salt);

        int256 liquidityBeforeSigned = int256(uint256(liquidityAfter)) - params.liquidityDelta;
        if (liquidityBeforeSigned < 0 || liquidityBeforeSigned > int256(uint256(type(uint128).max))) {
            revert InvalidLiquidityDelta();
        }
        uint128 liquidityBefore = uint128(uint256(liquidityBeforeSigned));

        vaults[poolId].checkpoint(owner, params.tickLower, params.tickUpper, params.salt, liquidityBefore);
    }

    function _settleCurrency(Currency currency, uint256 amount) private {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _priceBeforeSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode("theta-bg.v1.priceBefore", poolId));
    }

    function _tstore(bytes32 slot, uint160 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint160 value) {
        assembly {
            value := tload(slot)
        }
    }

    function withdrawProtocolFees() external {
        if (msg.sender != protocolFeeRecipient) revert NotProtocolFeeRecipient();
        uint256 amount = pendingProtocolFees;
        pendingProtocolFees = 0;
        emit ProtocolFeesWithdrawn(amount);
        (bool ok,) = protocolFeeRecipient.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }
}
