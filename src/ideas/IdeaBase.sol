// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchGuardToken} from "../LaunchGuardToken.sol";
import {FeeSplitter} from "../FeeSplitter.sol";
import {IIdea} from "../IIdea.sol";

/// @dev What IdeaBase reads from Programmable's EthereumNative30HookV3 and its fee vault.
interface INative30Kernel {
    function feeVault() external view returns (address);
}

interface INative30Vault {
    function creatorAccrued() external view returns (uint256);
    function creatorRecipient() external view returns (address);
    function claimCreator() external returns (uint256);
}

/// @title IdeaBase
/// @notice Building blocks for idea contracts, with no meaning of their own.
///         An idea inherits this contract and decides what to do with the ETH it gets from its pool's fees.
///
///         The pool's hook is Programmable's EthereumNative30HookV3: every trade's fee lands in its fee vault, the
///         garage's part goes on to the FeeSplitter, and 80% of that is this contract's.
///
///         act() is the idea's heartbeat: the garage calls it every hour and anyone else may call it at any time.
///         It first collects the idea's share, then runs the idea's own step, _act(). _act() must never revert:
///         when there is nothing to do, it returns. A share left uncollected for a day is spent by the splitter on
///         buying back and burning the garage's main token instead.
///
///         What is available:
///         - token / poolKey           its own token and pool (set by the initializer in onLaunch)
///         - _claimFees()              collect the idea's share (ETH arrives here)
///         - _buy                      buy its own token in its pool (pays the normal pool fee). An idea can never
///                                     sell: tokens it holds can only be burned or sent away
///         - _burn                     burn tokens held by this contract
///         - _sendEth / _sendTokens    send to an address; _sendEth does not revert, it returns success
///         - _pullTokensFromSender     take tokens from the caller (who approved this contract first)
///         - _stats()                  pool stats from the token: buys, sells, volumes in tokens, the last buyer,
///                                     the time and size of the last buy (market activity only: this contract's
///                                     own buys are not counted). For an ETH figure use _ethValue(tokens)
///         - _tick / _sqrtPriceX96     current pool price (tick = log1.0001(tokens per 1 ETH))
///         - _ethValue(tokens)         what `tokens` are worth in ETH at the current pool price
///         - _random(salt)             pseudo-random number from the current block. Anyone can compute it before calling,
///                                     so a caller can choose to call only when the outcome suits them
///         - _commitRandom / _revealRandom  fair randomness in two steps: take a ticket now, read the number once
///                                     the ticket's block exists; nobody knows it when the ticket is taken and no
///                                     caller can change it afterwards (valid for about 27 hours)
///         - _afterLaunch()            override if the idea needs to do something at launch
///
///         Buys execute at the current price: for meaningful amounts pass a sensible minTokens,
///         otherwise the transaction can be sandwiched.
abstract contract IdeaBase is IIdea, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// EIP-2935 system contract: hashes of the last 8191 blocks (about 27 hours).
    address internal constant BLOCK_HASH_HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    uint256 internal constant BLOCK_HASH_WINDOW = 8191;

    IPoolManager public immutable poolManager;
    address public immutable initializer;

    address public token;
    PoolKey public poolKey;
    address public hook; // Programmable's EthereumNative30HookV3
    address public feeVault; // its fee vault: every trade's fee lands here
    FeeSplitter public splitter; // pays this contract its share

    error NotInitializer();
    error NotPoolManager();
    error AlreadyLaunched();
    error NotLaunched();
    error Slippage();

    constructor(IPoolManager manager, address initializer_) {
        poolManager = manager;
        initializer = initializer_;
    }

    function onLaunch(address token_, PoolKey calldata key) external {
        if (msg.sender != initializer) revert NotInitializer();
        if (token != address(0)) revert AlreadyLaunched();
        token = token_;
        poolKey = key;
        hook = address(key.hooks);
        feeVault = INative30Kernel(hook).feeVault();
        splitter = FeeSplitter(payable(INative30Vault(feeVault).creatorRecipient()));
        _afterLaunch();
    }

    /// @notice The splitter pays the fee share in here. Do nothing here that can revert.
    receive() external payable virtual {}

    /// @notice Collect the idea's share, then take the idea's next step. Called every hour by the garage.
    function act() external {
        _claimFees();
        _act();
    }

    /// @dev The idea's own step. Must never revert; return early when there is nothing to do.
    function _act() internal virtual;

    // ───────────── Building blocks ─────────────

    function _afterLaunch() internal virtual {}

    /// @return amount ETH received (0 if nothing had accrued). Moves the garage's share from the fee vault to the
    ///         splitter first (anyone may), then takes this contract's part of it.
    function _claimFees() internal returns (uint256 amount) {
        if (INative30Vault(feeVault).creatorAccrued() != 0) INative30Vault(feeVault).claimCreator();
        splitter.sync();
        amount = splitter.ideaAccrued();
        if (amount != 0) splitter.claimIdea();
    }

    function _buy(uint256 ethIn, uint256 minTokens) internal returns (uint256 tokensOut) {
        tokensOut = abi.decode(poolManager.unlock(abi.encode(ethIn)), (uint256));
        if (tokensOut < minTokens) revert Slippage();
    }

    function _burn(uint256 tokens) internal {
        ERC20Burnable(token).burn(tokens);
    }

    function _sendEth(address to, uint256 amount) internal returns (bool ok) {
        (ok,) = to.call{value: amount}("");
    }

    function _sendTokens(address to, uint256 amount) internal {
        IERC20(token).transfer(to, amount);
    }

    /// @return received tokens actually received
    function _pullTokensFromSender(uint256 amount) internal returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    function _stats() internal view returns (LaunchGuardToken.PoolStats memory) {
        return LaunchGuardToken(token).stats();
    }

    /// @notice What `tokens` are worth in ETH at the current pool price (rounded down; ignores price impact and fees).
    function _ethValue(uint256 tokens) internal view returns (uint256) {
        uint256 sqrtPrice = _sqrtPriceX96(); // sqrt(tokens per ETH) * 2^96
        return Math.mulDiv(Math.mulDiv(tokens, 1 << 96, sqrtPrice), 1 << 96, sqrtPrice);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolKey.toId());
    }

    function _sqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
    }

    function _random(uint256 salt) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(block.prevrandao, block.timestamp, salt, address(this))));
    }

    /// @notice Fair randomness, step 1: a ticket for a number nobody can know yet (the hash of the next block).
    ///         Store the ticket together with whatever the number will decide (a round, a bet, a buyer).
    function _commitRandom() internal view returns (uint256 ticket) {
        ticket = block.number + 1;
    }

    /// @notice Fair randomness, step 2: the number for a ticket. Whoever calls, whenever, it is the same number.
    /// @return ready false while the ticket's block does not exist yet, and after about 27 hours (8191 blocks), when
    ///         the network no longer keeps that block's hash: decide in advance what happens then (e.g. a new ticket)
    function _revealRandom(uint256 ticket, uint256 salt) internal view returns (bool ready, uint256 value) {
        if (ticket >= block.number || block.number - ticket > BLOCK_HASH_WINDOW) return (false, 0);
        bytes32 h;
        if (block.number - ticket <= 256) {
            h = blockhash(ticket);
        } else {
            (bool ok, bytes memory out) = BLOCK_HASH_HISTORY.staticcall(abi.encode(ticket));
            if (!ok || out.length != 32) return (false, 0);
            h = abi.decode(out, (bytes32));
        }
        if (h == bytes32(0)) return (false, 0);
        return (true, uint256(keccak256(abi.encode(h, salt, address(this)))));
    }

    function _tokenBalance() internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ───────────── Buys (do not touch) ─────────────

    /// @dev Only ever buys (ETH in, tokens out): an idea has no way to sell.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (token == address(0)) revert NotLaunched();
        uint256 ethIn = abi.decode(data, (uint256));
        PoolKey memory key = poolKey;
        BalanceDelta d = poolManager.swap(key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), "");
        uint256 spent = uint256(-int256(d.amount0()));
        uint256 out = uint256(int256(d.amount1()));
        poolManager.settle{value: spent}();
        poolManager.take(key.currency1, address(this), out);
        return abi.encode(out);
    }
}
