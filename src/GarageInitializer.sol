// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IIdea} from "./IIdea.sol";

/// @notice What the initializer reads from the launch's hook, Programmable's EthereumNative30HookV3.
interface ILaunchHookView {
    function token() external view returns (address);
    function initializer() external view returns (address);
}

interface IBurnableToken {
    function burn(uint256 amount) external;
}

/// @title GarageInitializer
/// @notice Starts the ETH/TOKEN pool in the launch transaction: creates it at the start price and adds the whole
///         supply as a one-sided position from the minimum price up to the start price. The pool is native ETH /
///         token, LP fee 0, tick spacing 60, with the launch's hook. If the hook has an idea contract, it learns its
///         token and pool here.
///         ETH sent with the call is the launch buy, and all of it ends up in the pool: it buys the token (paying the
///         pool's fee like any buy, so its ETH is in the pool), then the tokens bought go back into the pool as a
///         second position, for sale again from the current price on. The launcher keeps nothing.
/// @dev    The positions can never be withdrawn: this contract has no owner and no function to remove liquidity.
///         Rounding dust is burned.
contract GarageInitializer is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 private constant ADD_SUPPLY = 0;
    uint8 private constant BUY = 1;
    uint8 private constant ADD_BOUGHT = 2;
    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;

    bool public launched;
    uint128 public lockedLiquidity;
    int24 public startTick;
    uint256 public initialBuyEth; // ETH sent with the launch
    uint256 public initialBuyTokens; // tokens it bought
    uint128 public initialBuyLiquidity; // the position those tokens went back into
    int24 public initialBuyUpperTick; // its upper tick: the price right after the buy (rounded to the tick spacing)
    uint256 public initialBuyBurned; // rounding dust of those tokens

    event Launched(address indexed hook, int24 startTick, uint128 liquidity, uint256 tokensInPool, uint256 dustBurned);
    event LaunchBuyAddedToPool(uint256 ethIn, uint256 tokensBought, uint128 liquidity, uint256 tokensBurned);

    error AlreadyLaunched();
    error NotPoolManager();
    error WrongHook();
    error InvalidStartTick();
    error InvalidSettlement();

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    /// @notice Called once, by the launch factory, right after all contracts are deployed.
    /// @param hook       this launch's hook (its initializer() must point here)
    /// @param startTick_ start price tick, a multiple of the tick spacing
    function initialize(address hook, int24 startTick_) external payable {
        if (launched) revert AlreadyLaunched();
        launched = true;

        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(ILaunchHookView(hook).token()), LP_FEE, TICK_SPACING, IHooks(hook));
        if (ILaunchHookView(hook).initializer() != address(this)) revert WrongHook();
        if (
            startTick_ % key.tickSpacing != 0 || startTick_ <= TickMath.minUsableTick(key.tickSpacing)
                || startTick_ > TickMath.maxUsableTick(key.tickSpacing)
        ) revert InvalidStartTick();

        startTick = startTick_;
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(startTick_));
        poolManager.unlock(abi.encode(ADD_SUPPLY, key, startTick_, uint256(0)));

        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 dust = token.balanceOf(address(this));
        if (dust != 0) IBurnableToken(address(token)).burn(dust);
        emit Launched(hook, startTick_, lockedLiquidity, token.balanceOf(address(poolManager)), dust);

        address idea = _ideaOf(hook);
        if (idea != address(0)) IIdea(idea).onLaunch(address(token), key);

        if (msg.value != 0) {
            poolManager.unlock(abi.encode(BUY, key, startTick_, msg.value));
            uint256 bought = token.balanceOf(address(this));
            poolManager.unlock(abi.encode(ADD_BOUGHT, key, startTick_, uint256(0)));
            uint256 left = token.balanceOf(address(this));
            if (left != 0) IBurnableToken(address(token)).burn(left);
            initialBuyEth = msg.value;
            initialBuyTokens = bought;
            initialBuyBurned = left;
            emit LaunchBuyAddedToPool(msg.value, bought, initialBuyLiquidity, left);
        }
    }

    /// @dev The launch's idea contract, or 0 if it has none: Programmable's kernel pays the creator fee from its vault
    ///      to the FeeSplitter, and the splitter knows the idea. Any missing link means no idea.
    function _ideaOf(address hook) private view returns (address) {
        address vault = _addressOf(hook, "feeVault()");
        address splitter = vault == address(0) ? address(0) : _addressOf(vault, "creatorRecipient()");
        return splitter == address(0) ? address(0) : _addressOf(splitter, "idea()");
    }

    function _addressOf(address target, string memory signature) private view returns (address a) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        if (ok && ret.length == 32) a = abi.decode(ret, (address));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 op, PoolKey memory key, int24 upper, uint256 ethIn) = abi.decode(data, (uint8, PoolKey, int24, uint256));
        if (op == BUY) return _initialBuy(key, ethIn);
        if (op == ADD_BOUGHT) return _addBought(key);

        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        // The price sits exactly at the position's upper bound, so the position is entirely in the token.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), token.balanceOf(address(this))
        );
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)), ""
        );
        if (delta.amount0() != 0 || delta.amount1() >= 0) revert InvalidSettlement();

        poolManager.sync(key.currency1);
        token.transfer(address(poolManager), uint256(uint128(-delta.amount1())));
        poolManager.settle();
        lockedLiquidity = liquidity;
        return "";
    }

    /// @dev Exact-input buy for the launch ETH (msg.value is 0 inside the callback, so the amount is in data).
    ///      It pays the pool's normal fee, Programmable share included.
    function _initialBuy(PoolKey memory key, uint256 ethIn) private returns (bytes memory) {
        BalanceDelta d = poolManager.swap(key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), "");
        if (d.amount0() != -int256(ethIn) || d.amount1() <= 0) revert InvalidSettlement();
        poolManager.settle{value: ethIn}();
        poolManager.take(key.currency1, address(this), uint256(int256(d.amount1())));
        return "";
    }

    /// @dev The tokens bought go back into the pool: a position from the minimum price up to the current price, so it
    ///      holds the token only, like the supply position, and sells it again as the price rises. Its upper tick is
    ///      the current tick rounded down to the spacing. Unused rounding dust stays here and is burned by initialize.
    function _addBought(PoolKey memory key) private returns (bytes memory) {
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = tick / key.tickSpacing * key.tickSpacing;
        if (tick < 0 && tick % key.tickSpacing != 0) upper -= key.tickSpacing;
        if (upper <= lower) revert InvalidStartTick();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), token.balanceOf(address(this))
        );
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(uint256(1))), ""
        );
        if (delta.amount0() != 0 || delta.amount1() >= 0) revert InvalidSettlement();

        poolManager.sync(key.currency1);
        token.transfer(address(poolManager), uint256(uint128(-delta.amount1())));
        poolManager.settle();
        initialBuyLiquidity = liquidity;
        initialBuyUpperTick = upper;
        return "";
    }
}
