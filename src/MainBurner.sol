// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title MainBurner
/// @notice Buys the token of one pool with all the ETH sent and burns it. Anyone can call. The swap goes through the
///         pool's hook like any trade and pays its full fee, Programmable's 0.3% included. The garage's agent tokens
///         and its bookkeeper spend fees on burning the main token through here.
contract MainBurner is IUnlockCallback {
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    address public immutable hook;
    address public immutable token;
    uint256 public totalBurned;
    bool private _buying;

    event BoughtAndBurned(address indexed sender, uint256 ethIn, uint256 tokensBurned);

    error NotPoolManager();
    error NothingToBuy();
    error InvalidSettlement();

    constructor(address hook_, address token_) {
        hook = hook_;
        token = token_;
    }

    /// @notice The pool: native ETH / token, LP fee 0, tick spacing 60, this launch's hook.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 60, IHooks(hook));
    }

    function buyAndBurn() external payable returns (uint256 burned) {
        if (msg.value == 0) revert NothingToBuy();
        _buying = true;
        burned = abi.decode(POOL_MANAGER.unlock(abi.encode(msg.value)), (uint256));
        _buying = false;
        IBurnable(token).burn(burned);
        totalBurned += burned;
        emit BoughtAndBurned(msg.sender, msg.value, burned);
    }

    /// @dev Exact-input buy with the ETH sent (msg.value is 0 inside the callback, so the amount is in data).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_buying) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        BalanceDelta d = POOL_MANAGER.swap(poolKey(), SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), "");
        if (d.amount0() != -int256(amount) || d.amount1() <= 0) revert InvalidSettlement();
        POOL_MANAGER.settle{value: amount}();
        uint256 bought = uint256(int256(d.amount1()));
        POOL_MANAGER.take(Currency.wrap(token), address(this), bought);
        return abi.encode(bought);
    }
}
