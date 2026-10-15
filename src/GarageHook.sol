// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IGarageHookBurn {
    function buyAndBurn() external payable returns (uint256 burned);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title GarageHook
/// @notice Uniswap v4 hook for one native ETH / TOKEN pool launched through Programmable. Every swap pays the pool fee
///         on its ETH side. The fee (feeBps, 1-4%) is fixed at deployment and includes Programmable's share:
///         - 0.3% of the gross ETH amount goes to Programmable (rounded up), claimable only to PLATFORM_RECIPIENT;
///         - the rest is the project's. With an idea contract: 80% to the idea, 10% to the agents' work wallet and
///           10% to the treasury. Without one (the main token): half to the agents, half to the treasury.
///         Use it or lose it: if the idea leaves its share unclaimed for a day, anyone can spend that share on
///         buying back and burning the main token.
///         buyAndBurn: anyone can send ETH to buy this pool's token and burn it (the garage turns fees into burns);
///         it pays Programmable's 0.3% like any trade.
/// @dev    Swaps never call third-party code: fees accrue to the hook as ERC6909 claims in the PoolManager and are
///         paid out by separate claim calls. A broken idea contract can only break its own claimIdea, never trading.
///         The hook keeps pool stats for the idea contract to read.
///         Anti-sniper, in the launch block and the two after it: a wallet buys at most 2% of the supply in total,
///         and each block takes at most 10 buys. The wallet is tx.origin, the account that signed the transaction:
///         buying through contracts, or through fresh contracts created inside the transaction, still counts for
///         the signer. Both limits end with the third block, whatever happened before.
contract GarageHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    /// @notice Pool stats for the idea contract. ETH amounts are what went through the pool, without the hook fee.
    ///         The buyer is tx.origin: the wallet that sent the transaction.
    ///         Only market activity counts: not the initializer's launch buy (it is burned), and not the idea
    ///         contract's own buys (they would otherwise be credited to whoever called it).
    struct PoolStats {
        uint64 launchBlock;
        uint64 launchedAt;
        uint64 swapCount;
        uint64 buyCount;
        address lastBuyer;
        uint64 lastBuyAt;
        uint64 lastSwapAt;
        uint128 lastBuyEth;
        uint128 lastBuyTokens;
        uint128 buyVolumeEth;
        uint128 sellVolumeEth;
    }

    // ───────────── Constants ─────────────

    uint256 public constant PLATFORM_FEE_BPS = 30; // 0.3% Programmable share, part of feeBps
    /// Recipient of the Programmable share (policy programmable.ethereum-routed-native-fee.v2). Never changes.
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint256 public constant MIN_FEE_BPS = 100; // 1%
    uint256 public constant MAX_FEE_BPS = 400; // 4%
    uint256 public constant IDEA_SHARE_BPS = 8_000; // 80% of the project share goes to the idea
    uint256 internal constant BPS = 10_000;
    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant EARLY_BLOCKS = 3; // the anti-sniper window: the launch block and the two after it
    uint256 public constant EARLY_BLOCK_BUYS = 10; // at most this many buys per block in the window
    uint256 public constant EARLY_BUY_BPS = 200; // at most 2% of the supply per signing wallet in the window
    uint256 public constant IDEA_GRACE = 1 days; // unclaimed idea share older than this goes to the main token
    uint256 internal constant ETH_ID = 0; // ERC6909 id of native ETH in the PoolManager
    uint8 internal constant OP_PAY = 0;
    uint8 internal constant OP_BUY = 1;

    // ───────────── Immutables ─────────────

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable initializer;
    address public immutable idea; // 0: no idea contract (the main token)
    uint256 public immutable feeBps;
    address public immutable mainHook; // hook of the main token's pool; unclaimed idea shares buy and burn it

    // ───────────── State ─────────────

    address public agents; // the agents' work wallet: compute and gas
    address public treasury; // treasury; can change both payout addresses, never the fees

    bool public initialized;
    PoolId public poolId;
    uint256 public maxEarlyBuy;
    PoolStats internal _stats;
    mapping(address => uint256) public earlyBought; // tokens bought per signing wallet in the window
    uint64 public blockBuysBlock; // block of the last buy within the first EARLY_BLOCKS blocks
    uint32 public blockBuys; // buys in that block

    uint256 public platformAccrued;
    uint256 public agentsAccrued;
    uint256 public treasuryAccrued;
    uint256 public ideaAccrued;
    uint256 public ideaAccruedSince; // when the oldest unclaimed idea share arrived
    uint256 public ideaTotal; // idea share accrued since launch
    uint256 public mainBurned; // main tokens bought back and burned with unclaimed idea shares
    uint256 public boughtAndBurned; // this pool's tokens bought and burned through buyAndBurn
    uint256 public totalFees; // collected since launch, Programmable share included

    bool private _paying;

    // ───────────── Events and errors ─────────────

    event FeeTaken(address indexed sender, bool isBuy, uint256 grossEth, uint256 fee, uint256 platformFee);
    event Claimed(address indexed to, uint256 amount);
    event IdeaShareBurnedMain(uint256 ethIn, uint256 mainTokensBurned);
    event BoughtAndBurned(address indexed sender, uint256 ethIn, uint256 tokensBurned);
    event AgentsSet(address agents);
    event TreasurySet(address treasury);

    error NotPoolManager();
    error NotTreasury();
    error TooEarly();
    error InvalidConfiguration();
    error InvalidPool();
    error InvalidInitializer();
    error HookNotImplemented();
    error NothingToClaim();
    error TransferFailed();
    error EarlyBuyLimit();
    error BlockBuyLimit();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param mainHook_ 0 for the main token itself; required when there is an idea contract
    constructor(
        IPoolManager manager,
        address token_,
        address initializer_,
        address idea_,
        uint256 feeBps_,
        address agents_,
        address treasury_,
        address mainHook_
    ) {
        if (
            address(manager) == address(0) || token_ == address(0) || initializer_ == address(0)
                || agents_ == address(0) || treasury_ == address(0) || feeBps_ < MIN_FEE_BPS || feeBps_ > MAX_FEE_BPS
                || (idea_ != address(0) && mainHook_ == address(0))
        ) revert InvalidConfiguration();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        poolManager = manager;
        token = token_;
        initializer = initializer_;
        idea = idea_;
        feeBps = feeBps_;
        mainHook = mainHook_;
        agents = agents_;
        treasury = treasury_;
        emit AgentsSet(agents_);
        emit TreasurySet(treasury_);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice The only pool of this hook: native ETH / token, LP fee 0, tick spacing 60.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), LP_FEE, TICK_SPACING, IHooks(address(this)));
    }

    // ═════════════════════════ PoolManager callbacks ═════════════════════════

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != initializer) revert InvalidInitializer();
        if (initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey().toId())) revert InvalidPool();
        initialized = true;
        poolId = key.toId();
        maxEarlyBuy = IERC20(token).totalSupply() * EARLY_BUY_BPS / BPS;
        _stats.launchBlock = uint64(block.number);
        _stats.launchedAt = uint64(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyOurPool(key);
        if (!_ethIsSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        // ETH is the specified amount: exact-input buy or exact-output sell.
        uint256 fee = _collect(_abs(params.amountSpecified), params.amountSpecified > 0, sender, params.zeroForOne);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _onlyOurPool(key);
        uint256 fee;
        // ETH is the unspecified side: exact-output buy or exact-input sell.
        // Otherwise the fee was already taken in beforeSwap.
        if (!_ethIsSpecified(params)) {
            fee = _collect(_abs(delta.amount0()), params.amountSpecified > 0, sender, params.zeroForOne);
        }
        // The launch buy and the idea's own buys pay the fee but are not market activity: they are not recorded and
        // not held to the anti-sniper cap (an idea's hourly buy must not revert on, or count for, its caller).
        if (sender != initializer && sender != idea) _record(params.zeroForOne, delta);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ═════════════════════════ Reads ═════════════════════════

    /// @notice Pool stats (see PoolStats).
    function stats() external view returns (PoolStats memory) {
        return _stats;
    }

    /// @notice Buys still allowed in this block; type(uint256).max once the first EARLY_BLOCKS blocks are over.
    function blockBuysRemaining() external view returns (uint256) {
        if (block.number >= _stats.launchBlock + EARLY_BLOCKS) return type(uint256).max;
        uint256 used = blockBuysBlock == uint64(block.number) ? blockBuys : 0;
        return used >= EARLY_BLOCK_BUYS ? 0 : EARLY_BLOCK_BUYS - used;
    }

    /// @notice How many tokens a wallet can still buy now; type(uint256).max once the first EARLY_BLOCKS blocks are over.
    function earlyBuyRemaining(address wallet) external view returns (uint256) {
        if (block.number >= _stats.launchBlock + EARLY_BLOCKS) return type(uint256).max;
        uint256 used = earlyBought[wallet];
        return used >= maxEarlyBuy ? 0 : maxEarlyBuy - used;
    }

    /// @notice Gross ETH amount of a trade and its fees (each rounded up). The Programmable share is computed from
    ///         the gross amount independently of the project share, as in the Programmable Native30 reference.
    /// @param amountIsNet true if ethAmount excludes the fee (pool input of an exact-output buy,
    ///        or the ETH a trader wants to receive in an exact-output sell).
    function quoteFee(uint256 ethAmount, bool amountIsNet)
        public
        view
        returns (uint256 gross, uint256 platformFee, uint256 projectFee)
    {
        gross = amountIsNet ? Math.mulDiv(ethAmount, BPS, BPS - feeBps, Math.Rounding.Ceil) : ethAmount;
        uint256 total = amountIsNet ? gross - ethAmount : Math.mulDiv(gross, feeBps, BPS, Math.Rounding.Ceil);
        platformFee = Math.min(Math.mulDiv(gross, PLATFORM_FEE_BPS, BPS, Math.Rounding.Ceil), total);
        projectFee = total - platformFee;
    }

    // ═════════════════════════ Payouts ═════════════════════════
    // Anyone can pay the gas; the money only goes to its fixed recipient.

    /// @notice Pay Programmable its accrued share. No transfer happens inside swaps, so the recipient cannot
    ///         break trading.
    function claimPlatform() external {
        uint256 amount = platformAccrued;
        platformAccrued = 0;
        _pay(PLATFORM_RECIPIENT, amount);
    }

    function claimAgents() external {
        uint256 amount = agentsAccrued;
        agentsAccrued = 0;
        _pay(agents, amount);
    }

    function claimTreasury() external {
        uint256 amount = treasuryAccrued;
        treasuryAccrued = 0;
        _pay(treasury, amount);
    }

    /// @notice Pay the idea contract what it has accrued. If its receive reverts, only this call reverts.
    function claimIdea() external {
        uint256 amount = ideaAccrued;
        ideaAccrued = 0;
        _pay(idea, amount);
    }

    /// @notice Use it or lose it: an idea share left unclaimed for IDEA_GRACE buys the main token at the market
    ///         and burns it (through the main hook's buyAndBurn). Anyone can call.
    function burnIdleIdeaShare() external {
        uint256 amount = ideaAccrued;
        if (amount == 0) revert NothingToClaim();
        if (block.timestamp < ideaAccruedSince + IDEA_GRACE) revert TooEarly();
        ideaAccrued = 0;
        _withdraw(amount);
        uint256 burned = IGarageHookBurn(mainHook).buyAndBurn{value: amount}();
        mainBurned += burned;
        emit IdeaShareBurnedMain(amount, burned);
    }

    /// @notice Buy this pool's token with all the ETH sent, at any price, and burn it. Anyone can call.
    ///         Programmable's 0.3% of the ETH sent is taken first (rounded up); the project share is not charged.
    /// @dev    The hook swaps in its own pool, so the PoolManager skips the hook callbacks: the fee is taken here,
    ///         and the purchase is not counted in the pool stats or the anti-sniper cap.
    function buyAndBurn() external payable returns (uint256 burned) {
        if (msg.value == 0) revert NothingToClaim();
        if (!initialized) revert InvalidPool();
        uint256 platformFee = Math.mulDiv(msg.value, PLATFORM_FEE_BPS, BPS, Math.Rounding.Ceil);
        platformAccrued += platformFee;
        totalFees += platformFee;
        _paying = true;
        burned = abi.decode(poolManager.unlock(abi.encode(OP_BUY, msg.value, platformFee)), (uint256));
        _paying = false;
        IBurnable(token).burn(burned);
        boughtAndBurned += burned;
        emit FeeTaken(msg.sender, true, msg.value, platformFee, platformFee);
        emit BoughtAndBurned(msg.sender, msg.value, burned);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_paying) revert InvalidConfiguration();
        if (abi.decode(data, (uint8)) == OP_BUY) return _buyCallback(data);
        // OP_PAY: turn `amount` of the hook's ETH claims into ETH held by the hook.
        (, uint256 amount) = abi.decode(data, (uint8, uint256));
        poolManager.burn(address(this), ETH_ID, amount); // +amount ETH credit
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        return "";
    }

    /// @dev buyAndBurn: pay in all the ETH sent, keep the platform fee as a claim, buy with the rest.
    function _buyCallback(bytes calldata data) private returns (bytes memory) {
        (, uint256 amount, uint256 platformFee) = abi.decode(data, (uint8, uint256, uint256));
        poolManager.settle{value: amount}();
        poolManager.mint(address(this), ETH_ID, platformFee);
        uint256 spend = amount - platformFee;
        PoolKey memory key = poolKey();
        BalanceDelta d = poolManager.swap(key, SwapParams(true, -int256(spend), TickMath.MIN_SQRT_PRICE + 1), "");
        if (d.amount0() != -int256(spend) || d.amount1() <= 0) revert InvalidConfiguration();
        uint256 bought = uint256(int256(d.amount1()));
        poolManager.take(key.currency1, address(this), bought);
        return abi.encode(bought);
    }

    /// @dev ETH only arrives here from the PoolManager inside _pay.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ═════════════════════════ Addresses ═════════════════════════

    function setAgents(address agents_) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (agents_ == address(0)) revert InvalidConfiguration();
        agents = agents_;
        emit AgentsSet(agents_);
    }

    function setTreasury(address treasury_) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (treasury_ == address(0)) revert InvalidConfiguration();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    // ═════════════════════════ Internal ═════════════════════════

    function _onlyOurPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    /// @dev Calls no external code except PoolManager.mint. Every swap pays, whoever routes it.
    function _collect(uint256 ethAmount, bool amountIsNet, address sender, bool isBuy) private returns (uint256 fee) {
        (uint256 gross, uint256 platformFee, uint256 projectFee) = quoteFee(ethAmount, amountIsNet);
        fee = platformFee + projectFee;
        if (fee == 0) return 0;
        poolManager.mint(address(this), ETH_ID, fee);
        totalFees += fee;
        platformAccrued += platformFee;

        uint256 rest = projectFee;
        if (idea != address(0)) {
            uint256 ideaPart = projectFee * IDEA_SHARE_BPS / BPS;
            if (ideaAccrued == 0) ideaAccruedSince = block.timestamp;
            ideaAccrued += ideaPart;
            ideaTotal += ideaPart;
            rest -= ideaPart;
        }
        uint256 agentsPart = rest / 2;
        agentsAccrued += agentsPart;
        treasuryAccrued += rest - agentsPart;
        emit FeeTaken(sender, isBuy, gross, fee, platformFee);
    }

    /// @dev Swap delta from the swapper's side: on a buy amount0 < 0 (ETH in), amount1 > 0 (tokens out).
    function _record(bool isBuy, BalanceDelta delta) private {
        PoolStats storage st = _stats;
        uint256 eth = _abs(delta.amount0());
        st.swapCount++;
        st.lastSwapAt = uint64(block.timestamp);
        if (!isBuy) {
            st.sellVolumeEth += uint128(eth);
            return;
        }
        uint256 tokens = _abs(delta.amount1());
        // The launch block and the two after it: at most EARLY_BLOCK_BUYS buys each, whoever buys, and at most
        // EARLY_BUY_BPS of the supply per signing wallet in total. Both limits end with the window, whatever happened.
        if (block.number < st.launchBlock + EARLY_BLOCKS) {
            if (blockBuysBlock != uint64(block.number)) {
                blockBuysBlock = uint64(block.number);
                blockBuys = 0;
            }
            if (++blockBuys > EARLY_BLOCK_BUYS) revert BlockBuyLimit();
            uint256 total = earlyBought[tx.origin] + tokens;
            if (total > maxEarlyBuy) revert EarlyBuyLimit();
            earlyBought[tx.origin] = total;
        }
        st.buyCount++;
        st.buyVolumeEth += uint128(eth);
        st.lastBuyer = tx.origin;
        st.lastBuyAt = uint64(block.timestamp);
        st.lastBuyEth = uint128(eth);
        st.lastBuyTokens = uint128(tokens);
    }

    function _pay(address to, uint256 amount) private {
        if (amount == 0 || to == address(0)) revert NothingToClaim();
        _withdraw(amount);
        // The transfer happens outside unlock: the recipient cannot act as the hook in the PoolManager.
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(to, amount);
    }

    /// @dev Turn `amount` of the hook's ETH claims in the PoolManager into ETH held by the hook.
    function _withdraw(uint256 amount) private {
        _paying = true;
        poolManager.unlock(abi.encode(OP_PAY, amount));
        _paying = false;
    }

    /// @dev currency0 is ETH. The specified side is currency0 if (exact input) == (zeroForOne).
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    // ═════════════════════════ Unused hooks ═════════════════════════

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
