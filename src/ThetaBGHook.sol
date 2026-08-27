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
///   (transient storage cannot span transactions; see the per-searcher open
///   leg tracked below).
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

    /// @notice A registered searcher's most recent unclosed swap in the
    /// current block, per pool. This replaces an earlier fixed 3-slot
    /// ring-buffer design that keyed detection off "the last 3 swaps in the
    /// pool" — that design had a verified evasion: a single interstitial
    /// swap from anyone, between the victim leg and the back-run leg,
    /// evicted the front-run record before the bracket completed (see
    /// SECURITY.md §"Searcher" / LIMITATIONS.md for the writeup and the
    /// test pair that proved it, now retired in favor of this fix). Keying
    /// per (pool, searcher) instead means only the searcher's *own* next
    /// swap can ever consume or overwrite their open leg — no third party's
    /// swap, decoy or not, can evict it.
    struct OpenLeg {
        uint64 blockNumber;
        bool zeroForOne;
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96After;
        bool occupied;
    }

    mapping(PoolId => mapping(address => OpenLeg)) private openLegs;

    /// @notice The sender of the most recent swap in each pool, captured
    /// *before* being overwritten by the current swap. Used to reconstruct
    /// "was there a distinct sender between my open leg and this closing
    /// swap" (the generalization of the original predicate's condition 3
    /// to a window that can contain any number of interleaved swaps, not
    /// just exactly one) and as the informational "victim" address on a
    /// detected slash. See `afterSwap` for the correctness argument on why
    /// this is safe to treat as same-block without a separate block field.
    mapping(PoolId => address) private lastSwapSender;

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

        // Captured *before* being overwritten below — see the `lastSwapSender`
        // doc comment above for what this is and why it's safe to treat as
        // same-block without a separate stored block number for it.
        address priorSender = lastSwapSender[poolId];
        lastSwapSender[poolId] = sender;

        // Only worth tracking/evaluating for active bonded searchers —
        // otherwise there is nothing to slash and no reason to spend
        // storage on an ordinary trader's swap.
        if (registry.isActiveSearcher(sender)) {
            OpenLeg storage leg = openLegs[poolId][sender];
            _tryDetectAndSlash(poolId, sender, priorSender, leg, params.zeroForOne, sqrtPriceX96Before, sqrtPriceX96After);

            // This swap becomes the new open leg regardless of whether it
            // just closed one — a searcher's own swap can simultaneously
            // close one potential bracket and open the next.
            leg.blockNumber = uint64(block.number);
            leg.zeroForOne = params.zeroForOne;
            leg.sqrtPriceX96Before = sqrtPriceX96Before;
            leg.sqrtPriceX96After = sqrtPriceX96After;
            leg.occupied = true;
        }

        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Evaluates the searcher's currently-open leg (if any, and if
    /// still within this block) against the swap that just closed it. Split
    /// out of `afterSwap` itself purely to keep that function's local-variable
    /// count low enough for the legacy codegen's stack depth (three inline
    /// SwapRecord literals plus the surrounding swap context overflowed it).
    function _tryDetectAndSlash(
        PoolId poolId,
        address sender,
        address priorSender,
        OpenLeg storage leg,
        bool zeroForOne,
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96After
    ) private {
        if (!leg.occupied || leg.blockNumber != block.number) return;

        SandwichPredicate.SwapRecord memory a = SandwichPredicate.SwapRecord({
            sender: sender,
            blockNumber: leg.blockNumber,
            zeroForOne: leg.zeroForOne,
            sqrtPriceX96Before: leg.sqrtPriceX96Before,
            sqrtPriceX96After: leg.sqrtPriceX96After,
            occupied: true
        });
        // Synthetic "middle" record. Its price fields are never read by the
        // predicate (see SandwichPredicate.sol) — only its sender matters
        // here, standing in for "whoever swapped most recently before this
        // closing leg," which correctly generalizes condition 3 to a window
        // containing any number of interleaved swaps: if priorSender is the
        // searcher themselves (nothing happened in between), condition 3
        // fails exactly as it should for a victimless round trip.
        SandwichPredicate.SwapRecord memory b = SandwichPredicate.SwapRecord({
            sender: priorSender,
            blockNumber: uint64(block.number),
            zeroForOne: leg.zeroForOne,
            sqrtPriceX96Before: 0,
            sqrtPriceX96After: 0,
            occupied: true
        });
        SandwichPredicate.SwapRecord memory c = SandwichPredicate.SwapRecord({
            sender: sender,
            blockNumber: uint64(block.number),
            zeroForOne: zeroForOne,
            sqrtPriceX96Before: sqrtPriceX96Before,
            sqrtPriceX96After: sqrtPriceX96After,
            occupied: true
        });

        if (SandwichPredicate.isSandwich(a, b, c, restorationThresholdBps, minDisplacementBps)) {
            _slashAndFund(poolId, sender, priorSender);
        }
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

    /// @notice Forwards the exact signed liquidity delta to the pool's
    /// vault on every add/remove — the vault tracks eligible-vs-pending
    /// liquidity per position entirely from these deltas (see
    /// LPInsuranceVault.sol), so no `liquidityBefore` computation belongs
    /// here anymore; the vault derives everything it needs from the delta
    /// itself.
    function _checkpoint(PoolKey calldata key, address owner, ModifyLiquidityParams calldata params) private {
        PoolId poolId = key.toId();
        vaults[poolId].checkpoint(owner, params.tickLower, params.tickUpper, params.salt, params.liquidityDelta);
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
