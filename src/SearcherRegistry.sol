// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Pure bond accounting for Theta-BG searchers. No knowledge of
/// sandwich detection, pools, or Uniswap v4 lives here — the hook decides
/// *whether* to slash; this contract only executes the accounting *when*
/// told to. Bonds are posted in native ETH (see ARCHITECTURE.md
/// "bond currency" for why this is decoupled from pool currencies).
///
/// One global registry serves every pool that uses this hook deployment
/// (Section 36 Option A in the build brief) — a searcher's bond and
/// reputation are shared across pools, which is both simpler to reason
/// about and the smallest attack surface: no per-pool CREATE, no
/// per-pool bond fragmentation.
contract SearcherRegistry {
    error NotHook();
    error AlreadyRegistered();
    error NotRegistered();
    error InsufficientBond();
    error WithdrawalNotRequested();
    error CooldownNotElapsed();
    error ZeroValue();

    event SearcherRegistered(address indexed searcher, uint256 bond);
    event BondToppedUp(address indexed searcher, uint256 amount, uint256 newBond);
    event WithdrawalRequested(address indexed searcher, uint64 unlockTime);
    event WithdrawalCancelled(address indexed searcher);
    event Withdrawn(address indexed searcher, uint256 amount);
    event SearcherSlashed(address indexed searcher, uint256 amount, uint32 newSlashCount);

    struct Searcher {
        uint128 bond;
        uint32 slashCount;
        uint64 withdrawalUnlockTime; // 0 == no pending withdrawal
        bool registered;
    }

    /// @notice Base bond required for a searcher who has never been slashed.
    uint256 public immutable minimumBond;

    /// @notice Cooldown between requesting and completing a withdrawal.
    /// Prevents a searcher from front-running detection by instantly
    /// withdrawing their bond between the front-run and back-run legs of
    /// their own attack — the bond must already be posted and locked before
    /// the searcher can act.
    uint256 public constant WITHDRAWAL_COOLDOWN = 24 hours;

    /// @notice The only contract permitted to call `slash`.
    address public immutable hook;

    mapping(address searcher => Searcher) public searchers;

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(uint256 _minimumBond, address _hook) {
        if (_minimumBond == 0 || _hook == address(0)) revert ZeroValue();
        minimumBond = _minimumBond;
        hook = _hook;
    }

    /// @notice Bond required to be considered active. Flat 2x penalty after
    /// any slash (not exponential per slash count) — see ECONOMICS.md
    /// §"re-entry penalty" for why exponential escalation was rejected.
    function requiredBond(address searcher) public view returns (uint256) {
        return searchers[searcher].slashCount == 0 ? minimumBond : minimumBond * 2;
    }

    function isActiveSearcher(address searcher) external view returns (bool) {
        Searcher storage s = searchers[searcher];
        return s.registered && s.bond >= requiredBond(searcher);
    }

    function register() external payable {
        Searcher storage s = searchers[msg.sender];
        if (s.registered) revert AlreadyRegistered();
        if (msg.value < requiredBond(msg.sender)) revert InsufficientBond();

        s.registered = true;
        s.bond = uint128(msg.value);
        emit SearcherRegistered(msg.sender, msg.value);
    }

    function topUpBond() external payable {
        Searcher storage s = searchers[msg.sender];
        if (!s.registered) revert NotRegistered();
        if (msg.value == 0) revert ZeroValue();

        s.bond += uint128(msg.value);
        emit BondToppedUp(msg.sender, msg.value, s.bond);
    }

    function requestWithdrawal() external {
        Searcher storage s = searchers[msg.sender];
        if (!s.registered) revert NotRegistered();

        s.withdrawalUnlockTime = uint64(block.timestamp + WITHDRAWAL_COOLDOWN);
        emit WithdrawalRequested(msg.sender, s.withdrawalUnlockTime);
    }

    function cancelWithdrawal() external {
        Searcher storage s = searchers[msg.sender];
        if (!s.registered) revert NotRegistered();

        s.withdrawalUnlockTime = 0;
        emit WithdrawalCancelled(msg.sender);
    }

    function withdraw() external {
        Searcher storage s = searchers[msg.sender];
        if (!s.registered) revert NotRegistered();
        if (s.withdrawalUnlockTime == 0) revert WithdrawalNotRequested();
        if (block.timestamp < s.withdrawalUnlockTime) revert CooldownNotElapsed();

        uint256 amount = s.bond;
        s.bond = 0;
        s.registered = false;
        s.withdrawalUnlockTime = 0;

        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    /// @notice Slashes a searcher's *entire* current bond. There is no
    /// separate "slash amount" parameter distinct from the bond — see
    /// ECONOMICS.md §"slash amount" for why a full-bond slash was chosen
    /// over a fixed or percentage amount (it is the only choice that can
    /// never exceed available funds, so there is no "bond smaller than
    /// required slash" edge case to handle).
    /// @dev Effects (bond debit) happen before the external ETH transfer.
    /// Callable only by the hook, which is itself only reachable from
    /// PoolManager's `afterSwap` callback — not reenterable via a second
    /// slash of the same searcher within one predicate evaluation.
    function slash(address searcher) external onlyHook returns (uint256 amountSlashed) {
        Searcher storage s = searchers[searcher];
        amountSlashed = s.bond;
        if (amountSlashed == 0) return 0;

        s.bond = 0;
        unchecked {
            s.slashCount += 1;
        }
        emit SearcherSlashed(searcher, amountSlashed, s.slashCount);

        (bool ok,) = hook.call{value: amountSlashed}("");
        require(ok, "ETH transfer failed");
    }
}
