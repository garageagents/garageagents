// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title LaunchGuardToken
/// @notice Fixed supply, no minting, no owner, no transfer taxes. The whole supply goes to the initializer, which locks
///         it in the pool forever. Fees are taken by the pool's hook (Programmable's EthereumNative30HookV3), not here.
///         Anti-sniper, in the launch block and the two after it (this token is deployed in the launch transaction,
///         so its deployment block is the launch block): a buy is a transfer out of the Uniswap v4 PoolManager. Each
///         block takes at most EARLY_BLOCK_BUYS buys, and each signing wallet (tx.origin) receives at most
///         EARLY_BUY_BPS of the supply in total, so buying through contracts, or through fresh contracts created
///         inside the transaction, still counts for the signer. Selling does not give the cap back. Both limits end
///         with the third block, whatever happened before. A buy whose tokens stay in the PoolManager as ERC-6909
///         claims is not a transfer, so these limits do not see it until the claims are redeemed.
///         The token also keeps the pool's market activity for an agent token's idea contract (stats()): buys are
///         transfers out of the PoolManager, sells transfers into it. The launch itself and the idea contract's own
///         buys are not market activity: they are neither counted nor capped.
contract LaunchGuardToken is ERC20, ERC20Burnable {
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint256 public constant EARLY_BLOCKS = 3; // the launch block and the two after it
    uint256 public constant EARLY_BLOCK_BUYS = 10; // buys per block in the window
    uint256 public constant EARLY_BUY_BPS = 200; // 2% of the supply per signing wallet in the window

    /// @notice Market activity as the token sees it. Amounts are in tokens (18 decimals); the buyer is tx.origin,
    ///         the wallet that signed the transaction.
    struct PoolStats {
        uint64 launchBlock;
        uint64 launchedAt;
        uint64 buyCount;
        uint64 sellCount;
        address lastBuyer;
        uint64 lastBuyAt;
        uint64 lastTradeAt;
        uint128 lastBuyTokens;
        uint128 buyVolume; // tokens bought
        uint128 sellVolume; // tokens sold
    }

    address public immutable initializer;
    address public immutable idea; // 0: no idea contract (the main token)
    uint256 public immutable maxEarlyBuy;
    /// @notice The launch block. Kept in storage: it is not known when the launch is packed.
    uint256 public launchBlock;
    mapping(address => uint256) public earlyBought; // tokens received from the PoolManager per signer in the window
    uint64 public blockBuysBlock; // block of the last buy in the window
    uint32 public blockBuys; // buys in that block
    PoolStats internal _stats;

    error EarlyBuyLimit();
    error BlockBuyLimit();

    constructor(string memory name_, string memory symbol_, uint256 supply, address initializer_, address idea_)
        ERC20(name_, symbol_)
    {
        initializer = initializer_;
        idea = idea_;
        maxEarlyBuy = supply * EARLY_BUY_BPS / 10_000;
        launchBlock = block.number;
        _stats.launchBlock = uint64(block.number);
        _stats.launchedAt = uint64(block.timestamp);
        _mint(initializer_, supply);
    }

    /// @notice The pool's market activity (see PoolStats).
    function stats() external view returns (PoolStats memory) {
        return _stats;
    }

    /// @notice How many tokens a wallet can still buy now; type(uint256).max once the window is over.
    function earlyBuyRemaining(address wallet) external view returns (uint256) {
        if (block.number >= launchBlock + EARLY_BLOCKS) return type(uint256).max;
        uint256 used = earlyBought[wallet];
        return used >= maxEarlyBuy ? 0 : maxEarlyBuy - used;
    }

    /// @notice Buys still allowed in this block; type(uint256).max once the window is over.
    function blockBuysRemaining() external view returns (uint256) {
        if (block.number >= launchBlock + EARLY_BLOCKS) return type(uint256).max;
        uint256 used = blockBuysBlock == uint64(block.number) ? blockBuys : 0;
        return used >= EARLY_BLOCK_BUYS ? 0 : EARLY_BLOCK_BUYS - used;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == POOL_MANAGER && to != initializer && to != idea) _buy(value);
        else if (to == POOL_MANAGER && from != initializer && from != idea) _sell(value);
        super._update(from, to, value);
    }

    function _buy(uint256 value) private {
        if (block.number < launchBlock + EARLY_BLOCKS) {
            if (blockBuysBlock != uint64(block.number)) {
                blockBuysBlock = uint64(block.number);
                blockBuys = 0;
            }
            if (++blockBuys > EARLY_BLOCK_BUYS) revert BlockBuyLimit();
            uint256 total = earlyBought[tx.origin] + value;
            if (total > maxEarlyBuy) revert EarlyBuyLimit();
            earlyBought[tx.origin] = total;
        }
        PoolStats storage s = _stats;
        s.buyCount++;
        s.lastBuyer = tx.origin;
        s.lastBuyAt = uint64(block.timestamp);
        s.lastTradeAt = uint64(block.timestamp);
        s.lastBuyTokens = uint128(value);
        s.buyVolume += uint128(value);
    }

    function _sell(uint256 value) private {
        PoolStats storage s = _stats;
        s.sellCount++;
        s.lastTradeAt = uint64(block.timestamp);
        s.sellVolume += uint128(value);
    }
}
