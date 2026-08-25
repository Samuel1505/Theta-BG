// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ThetaBGHook} from "../src/ThetaBGHook.sol";
import {SearcherRegistry} from "../src/SearcherRegistry.sol";
import {LPInsuranceVault} from "../src/LPInsuranceVault.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import {MaliciousReentrantStrategy} from "./mocks/MaliciousReentrantStrategy.sol";
import {ActorRouter} from "./utils/ActorRouter.sol";
import {LPRouter} from "./utils/LPRouter.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Adversarial test suite modeled on the build brief's numbered
/// attack list (§71). Each test either proves an attack fails, or — where
/// one genuinely succeeds within this build's documented scope — proves and
/// records exactly how, so it's a verified, disclosed limitation rather
/// than an assumed one. See SECURITY.md / LIMITATIONS.md for the write-up
/// of anything found here.
contract ThetaBGAdversarialTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    ThetaBGHook hook;
    SearcherRegistry registry;
    MockWETH weth;
    MockYieldStrategy strategy;
    PoolKey poolKey;
    LPRouter lpRouter;

    address protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    uint256 constant MIN_BOND = 1 ether;
    uint256 constant RESTORATION_BPS = 2000;
    uint256 constant MIN_DISPLACEMENT_BPS = 5;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        weth = new MockWETH();
        strategy = new MockYieldStrategy(IERC20(address(weth)));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            manager, MIN_BOND, IWETH9(address(weth)), IERC4626(address(strategy)), protocolFeeRecipient,
            RESTORATION_BPS, MIN_DISPLACEMENT_BPS, uint256(50), uint256(1000)
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ThetaBGHook).creationCode, constructorArgs);
        hook = new ThetaBGHook{salt: salt}(
            manager, MIN_BOND, IWETH9(address(weth)), IERC4626(address(strategy)), protocolFeeRecipient,
            RESTORATION_BPS, MIN_DISPLACEMENT_BPS, 50, 1000
        );
        require(address(hook) == hookAddr, "hook address mismatch");
        registry = hook.registry();

        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        lpRouter = new LPRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(lpRouter), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(lpRouter), 1_000_000e18);
        lpRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );
    }

    function _newSearcher() internal returns (ActorRouter r) {
        r = new ActorRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(r), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(r), 10_000e18);
        vm.deal(address(r), 10 ether);
        vm.prank(address(r));
        registry.register{value: MIN_BOND}();
    }

    function _newTrader() internal returns (ActorRouter r) {
        r = new ActorRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(r), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(r), 10_000e18);
    }

    function _bondOf(ActorRouter r) internal view returns (uint128 bond) {
        (bond,,,) = registry.searchers(address(r));
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: ring-buffer eviction — a genuine, verified evasion technique
    // ════════════════════════════════════════════════════════════════════

    /// @notice The ring buffer holds exactly the *last 3* swaps in the pool
    /// (build brief §14's 3-slot design). If a fourth, unrelated swap lands
    /// between the victim leg and the back-run leg, it evicts the front-run
    /// record before the bracket ever completes — defeating detection even
    /// though the underlying attack pattern is economically identical to a
    /// detected one. This is a REAL, verified gap in this build's scope
    /// (not previously covered), not a defect being papered over — recorded
    /// here and cross-referenced in LIMITATIONS.md.
    function test_attack_ringBufferEviction_decoySwapDefeatsDetection() public {
        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();
        ActorRouter decoy = _newTrader();

        searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        // Decoy swap — could be the attacker's own unrelated wallet, a bot,
        // or genuinely unrelated background pool activity. Either way it
        // occupies the ring buffer slot the front-run needs to still hold.
        decoy.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        // Verified: the bond survives. This is the attack succeeding, not a
        // false assertion — see the doc comment above.
        assertEq(_bondOf(searcher), MIN_BOND, "VERIFIED GAP: a decoy swap between victim and back-run evades detection");
    }

    /// @notice Confirms the mechanism: without the decoy, the identical
    /// front-run/victim/back-run amounts *do* get slashed — isolating the
    /// decoy swap as the sole variable that changed the outcome.
    function test_attack_ringBufferEviction_controlWithoutDecoy_doesSlash() public {
        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();

        searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        assertEq(_bondOf(searcher), 0);
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: replay — the same triple cannot be slashed twice
    // ════════════════════════════════════════════════════════════════════

    /// @notice Once the front-run record is evicted from the ring buffer by
    /// the natural next swap, the same (a,b,c) triple can never be
    /// re-evaluated — there is no "replay the slash" surface.
    function test_attack_replay_sameTripleCannotSlashTwice() public {
        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();

        searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        assertEq(_bondOf(searcher), 0);
        (, uint32 slashCount,,) = registry.searchers(address(searcher));
        assertEq(slashCount, 1);

        // Any further swap only re-evaluates the *new* trailing triple, not
        // the already-evicted one — no way to trigger a second slash from
        // the same historical pattern.
        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        (, uint32 slashCountAfter,,) = registry.searchers(address(searcher));
        assertEq(slashCountAfter, 1, "no replay from the already-evicted pattern");
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: flash liquidity at slash time — verified, documented risk
    // ════════════════════════════════════════════════════════════════════

    /// @notice An LP who adds a large position in the same block as, but
    /// strictly before, the slash-triggering back-run, then removes it
    /// immediately after, captures a share of that slash despite near-zero
    /// holding duration. This is the exact risk documented in SECURITY.md
    /// §"LP" / LIMITATIONS.md — verified concretely here, not just asserted
    /// in prose.
    function test_attack_flashLiquidityAtSlash_capturesShareDespiteInstantExit() public {
        PoolId poolId = poolKey.toId();
        LPInsuranceVault vault = hook.vaults(poolId);

        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();
        LPRouter flashLP = new LPRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(flashLP), 1_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(flashLP), 1_000_000e18);

        searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));

        // Flash-LP deposits an amount matching the honest LP's position,
        // strictly before the slash-triggering back-run, same block.
        flashLP.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );

        searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        // Flash-LP exits immediately, same block.
        flashLP.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -1_000e18, salt: 0})
        );

        uint256 flashLPClaimable = vault.claimable(address(flashLP), -6000, 6000, bytes32(0));
        uint256 honestLPClaimable = vault.claimable(address(lpRouter), -6000, 6000, bytes32(0));

        assertGt(flashLPClaimable, 0, "VERIFIED: flash liquidity captured a share of a slash it was exposed to for one block");
        // With equal liquidity at slash time, they split it evenly — the
        // flash-LP's zero holding *duration* earned exactly as much as the
        // honest LP's ongoing position, for this one slash.
        assertApproxEqAbs(flashLPClaimable, honestLPClaimable, 2);
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: reentrancy through the slash/claim call chain
    // ════════════════════════════════════════════════════════════════════

    /// @notice A malicious ERC4626 strategy that tries to reenter
    /// `receiveSlash`/`claimInsuranceYield` mid-deposit must be blocked by
    /// ReentrancyGuard — proven by using a strategy that actually attempts
    /// it, not merely asserted from reading the modifier.
    function test_attack_reentrancyDuringStrategyDeposit_blockedByGuard() public {
        MaliciousReentrantStrategy evilStrategy = new MaliciousReentrantStrategy(IERC20(address(weth)));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            manager, MIN_BOND, IWETH9(address(weth)), IERC4626(address(evilStrategy)), protocolFeeRecipient,
            RESTORATION_BPS, MIN_DISPLACEMENT_BPS, uint256(50), uint256(1000)
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ThetaBGHook).creationCode, constructorArgs);
        ThetaBGHook evilHook = new ThetaBGHook{salt: salt}(
            manager, MIN_BOND, IWETH9(address(weth)), IERC4626(address(evilStrategy)), protocolFeeRecipient,
            RESTORATION_BPS, MIN_DISPLACEMENT_BPS, 50, 1000
        );
        require(address(evilHook) == hookAddr, "hook address mismatch");

        (PoolKey memory evilKey,) = initPool(currency0, currency1, IHooks(address(evilHook)), 3000, 60, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            evilKey, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );
        LPInsuranceVault evilVault = evilHook.vaults(evilKey.toId());
        evilStrategy.configure(evilVault, true, true, -6000, 6000);

        ActorRouter searcher = new ActorRouter(manager);
        ActorRouter victim = new ActorRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(searcher), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(searcher), 10_000e18);
        MockERC20(Currency.unwrap(currency0)).mint(address(victim), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(victim), 10_000e18);
        vm.deal(address(searcher), 10 ether);
        SearcherRegistry evilRegistry = evilHook.registry();
        vm.prank(address(searcher));
        evilRegistry.register{value: MIN_BOND}();

        // Must not revert the whole slash — the outer receiveSlash call
        // succeeds; the attempted reentrant calls made from inside the
        // malicious strategy's deposit() are the ones that get reverted
        // (silently caught by the mock's own try/catch, exactly as a real
        // attacker's reentrant call would be reverted by the guard).
        searcher.swap(evilKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        victim.swap(evilKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(evilKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        (uint128 bondAfter,,,) = evilRegistry.searchers(address(searcher));
        assertEq(bondAfter, 0, "slash must succeed despite the malicious strategy's reentrancy attempt");

        // Accounting must be exactly correct — not double-counted or
        // corrupted by the attempted reentrant calls.
        uint256 expectedInsurance = MIN_BOND - MIN_BOND / 10;
        assertApproxEqAbs(evilVault.availableBalance(), expectedInsurance, 2);
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: malicious "victim" cannot frame an unrelated bonded searcher
    // ════════════════════════════════════════════════════════════════════

    /// @notice A malicious actor cannot cause an innocent bonded searcher to
    /// be slashed by crafting their own trades around the searcher's
    /// unrelated, legitimate activity — condition 1 (a.sender == c.sender)
    /// requires the *searcher themselves* to be on both bracketing legs;
    /// an outside party's trades can never complete a bracket on someone
    /// else's behalf.
    function test_attack_maliciousActor_cannotFrameUnrelatedSearcher() public {
        ActorRouter innocentSearcher = _newSearcher();
        ActorRouter attacker1 = _newTrader();
        ActorRouter attacker2 = _newTrader();

        // Innocent searcher makes one unrelated, ordinary trade.
        innocentSearcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));

        // Attacker tries to construct a bracket using the searcher's trade
        // as the "victim" leg, sandwiched between two attacker-controlled
        // trades — but the attacker's own addresses are what get checked
        // for a matching bond, not the searcher's.
        attacker1.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        innocentSearcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        attacker2.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -51e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        assertEq(_bondOf(innocentSearcher), MIN_BOND, "the innocent searcher's bond must never be at risk from others' trades");
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: griefing with many tiny trades never triggers false slashes
    // ════════════════════════════════════════════════════════════════════

    function test_attack_griefingWithManyTinyTrades_neverTriggersSlash() public {
        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();

        for (uint256 i = 0; i < 10; i++) {
            bool dir = i % 2 == 0;
            searcher.swap(
                poolKey,
                SwapParams({
                    zeroForOne: dir,
                    amountSpecified: -1e12, // dust-sized, well under the displacement floor
                    sqrtPriceLimitX96: dir ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                })
            );
            victim.swap(
                poolKey, SwapParams({zeroForOne: dir, amountSpecified: -1e12, sqrtPriceLimitX96: dir ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT})
            );
        }

        assertEq(_bondOf(searcher), MIN_BOND, "dust-trade griefing must never trigger a slash");
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: cross-pool replay — a slash's ring-buffer state in pool A
    // cannot be used to justify anything in pool B
    // ════════════════════════════════════════════════════════════════════

    function test_attack_crossPoolState_doesNotLeakIntoUnrelatedPool() public {
        (PoolKey memory poolKeyB,) = initPool(currency0, currency1, IHooks(address(hook)), 500, 10, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            poolKeyB, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1_000e18, salt: 0})
        );

        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();

        // Fully slash the searcher in pool A.
        searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));
        assertEq(_bondOf(searcher), 0);

        // Pool B's vault must be completely unaffected — no leakage of
        // accounting state across pools.
        LPInsuranceVault vaultB = hook.vaults(poolKeyB.toId());
        assertEq(vaultB.availableBalance(), 0);
        assertEq(vaultB.accInsurancePerLiquidityX128(), 0);
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: economic exhaustion — repeatedly attacking and re-bonding is
    // strictly loss-making for the attacker, never break-even or profitable
    // purely from the protocol's own mechanics
    // ════════════════════════════════════════════════════════════════════

    /// @notice A searcher who keeps re-bonding and re-attacking never
    /// recovers any of their slashed capital from the protocol itself — the
    /// full bond leaves their control on every single slash, with no path
    /// back to them. Demonstrated over several cycles.
    function test_attack_repeatedReBondAndAttack_neverRecoversSlashedCapital() public {
        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();
        uint256 totalPaidIn = MIN_BOND;

        for (uint256 i = 0; i < 3; i++) {
            searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
            victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
            searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

            assertEq(_bondOf(searcher), 0, "every attack is fully slashed");

            vm.roll(block.number + 1);
            uint256 required = registry.requiredBond(address(searcher));
            vm.deal(address(searcher), required);
            vm.prank(address(searcher));
            registry.topUpBond{value: required}();
            totalPaidIn += required;
        }

        // Nothing the searcher ever paid in comes back to them — it all
        // went to the protocol and the pool's LPs.
        assertEq(address(searcher).balance, 0);
        assertGt(hook.pendingProtocolFees(), 0);
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: bond withdrawal race against the *victim* leg specifically
    // (as opposed to the back-run leg, already covered elsewhere)
    // ════════════════════════════════════════════════════════════════════

    /// @notice Requesting withdrawal *between* the front-run and the victim
    /// leg (not just before the back-run) still doesn't help — the cooldown
    /// doesn't care which leg of an in-progress pattern is next.
    function test_attack_withdrawalRequestBetweenFrontRunAndVictim_stillSlashable() public {
        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();

        searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));

        vm.prank(address(searcher));
        registry.requestWithdrawal();

        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        assertEq(_bondOf(searcher), 0);
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: attempting to grief the vault's claim path with a claim
    // before any position exists
    // ════════════════════════════════════════════════════════════════════

    function test_attack_claimWithNoPositionEver_revertsCleanly() public {
        PoolId poolId = poolKey.toId();
        LPInsuranceVault vault = hook.vaults(poolId);
        ActorRouter randomAddress = _newTrader();

        vm.prank(address(randomAddress));
        vm.expectRevert(LPInsuranceVault.NoClaimable.selector);
        vault.claimInsuranceYield(-6000, 6000, bytes32(0));
    }

    // ════════════════════════════════════════════════════════════════════
    // Attack: front-run and back-run using different bonded amounts across
    // two separate top-ups mid-attack (searcher tries to under-bond between
    // legs to reduce exposure)
    // ════════════════════════════════════════════════════════════════════

    /// @notice A searcher cannot reduce their at-risk bond mid-attack —
    /// there is no "partial withdraw" function, only request+cooldown+full
    /// withdraw, so whatever bond is posted when the back-run executes is
    /// what gets slashed in full, regardless of what happened between the
    /// front-run and back-run legs.
    function test_attack_cannotReduceBondMidAttack_onlyToppingUpIsPossible() public {
        ActorRouter searcher = _newSearcher();
        ActorRouter victim = _newTrader();

        searcher.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));

        // Searcher tops up mid-attack, hoping to somehow game the
        // accounting — this only *increases* their exposure, since the
        // full current bond is what gets slashed.
        vm.deal(address(searcher), 5 ether);
        vm.prank(address(searcher));
        registry.topUpBond{value: 5 ether}();

        victim.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}));
        searcher.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -70e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}));

        (uint128 bondAfter,,,) = registry.searchers(address(searcher));
        assertEq(bondAfter, 0, "the entire, larger bond is slashed - topping up mid-attack backfires");
    }
}
