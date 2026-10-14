// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {GarageHook} from "../../src/GarageHook.sol";
import {IdeaBase} from "../../src/ideas/IdeaBase.sol";
import {IIdea} from "../../src/IIdea.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// Test-only idea contracts that exercise the IdeaBase building blocks. They are not shown to the agents.

/// Does nothing: just keeps its ETH.
contract HoldIdea is IdeaBase {
    constructor(IPoolManager m, address i) IdeaBase(m, i) {}

    function _act() internal override {}

    function claim() external returns (uint256) {
        return _claimFees();
    }
}

/// Buys and burns, or buys and holds: exercises _buy and _burn (an idea cannot sell).
contract TradeIdea is IdeaBase {
    constructor(IPoolManager m, address i) IdeaBase(m, i) {}

    function _act() internal override {}

    function buyAndBurn(uint256 eth) external returns (uint256 bought) {
        bought = _buy(eth, 1);
        _burn(bought);
    }

    function buyAndHold(uint256 eth) external returns (uint256 bought) {
        bought = _buy(eth, 1);
    }

    function deposit(uint256 amount) external returns (uint256) {
        return _pullTokensFromSender(amount);
    }

    function tokenBalance() external view returns (uint256) {
        return _tokenBalance();
    }
}

/// The last buyer takes the pot after 10 quiet minutes: exercises _stats.
contract LastBuyerIdea is IdeaBase {
    constructor(IPoolManager m, address i) IdeaBase(m, i) {}

    function payout() external {
        GarageHook.PoolStats memory s = _stats();
        require(s.lastBuyer != address(0) && block.timestamp >= s.lastBuyAt + 10 minutes, "not yet");
        _claimFees();
        require(_sendEth(s.lastBuyer, address(this).balance), "send failed");
    }

    /// The hourly step pays out whenever the pot is due; otherwise it does nothing.
    function _act() internal override {
        GarageHook.PoolStats memory s = _stats();
        if (s.lastBuyer == address(0) || block.timestamp < s.lastBuyAt + 10 minutes || address(this).balance == 0) return;
        _sendEth(s.lastBuyer, address(this).balance);
    }
}

/// Breaks wherever it can: refuses ETH.
contract BrokenIdea is IIdea {
    function onLaunch(address, PoolKey calldata) external {}

    function act() external {}

    receive() external payable {
        revert("broken");
    }
}

/// An attacking idea: when paid, it tries to re-enter the hook (claim again, burn its share as idle) and calls
/// buyAndBurn itself. Counts what got through.
contract ReentrantIdea is IIdea {
    GarageHook public hook;
    uint256 public received;
    uint256 public reentered;

    function setHook(GarageHook h) external {
        hook = h;
    }

    function onLaunch(address, PoolKey calldata) external {}

    function act() external {
        hook.claimIdea();
    }

    receive() external payable {
        received += msg.value;
        try hook.claimIdea() {
            reentered++;
        } catch {}
        try hook.burnIdleIdeaShare() {
            reentered++;
        } catch {}
        // Anyone may buy and burn; doing it from inside a payout must not upset the hook's accounting.
        try hook.buyAndBurn{value: msg.value / 2}() {} catch {}
    }
}

/// A wallet that refuses ETH.
contract RejectingWallet {
    receive() external payable {
        revert("no");
    }
}

/// Fair randomness: a ticket now, the number later.
contract RandomIdea is IdeaBase {
    uint256 public ticket;

    constructor(IPoolManager m, address i) IdeaBase(m, i) {}

    function _act() internal override {}

    function commit() external {
        ticket = _commitRandom();
    }

    function reveal(uint256 salt) external view returns (bool, uint256) {
        return _revealRandom(ticket, salt);
    }

    function revealAt(uint256 t, uint256 salt) external view returns (bool, uint256) {
        return _revealRandom(t, salt);
    }
}

/// A buyer that is a brand-new contract: created and buying inside one transaction (the sniper's trick against
/// per-wallet caps that ask the router who the buyer is).
contract SubBuyer {
    constructor(PoolSwapTest router, PoolKey memory key) payable {
        router.swap{value: msg.value}(
            key,
            SwapParams(true, -int256(msg.value), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    receive() external payable {}
}

/// The sniper's contract: one call, n fresh sub-contracts, each buying `each` ETH worth.
contract Sniper {
    PoolSwapTest immutable router;

    constructor(PoolSwapTest r) {
        router = r;
    }

    function strike(PoolKey calldata key, uint256 n, uint256 each) external payable {
        for (uint256 i; i < n; i++) new SubBuyer{value: each}(router, key);
    }

    receive() external payable {}
}
