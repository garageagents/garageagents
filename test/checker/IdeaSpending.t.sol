// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GarageTestBase} from "./GarageTestBase.sol";

/// @notice Fees must actually be spent. Thirty days of a quiet but living market: about every two hours a random
///         wallet buys or sells, and every hour the garage calls act(). At the end, at most 20% of everything the
///         idea received may still sit unspent (in the idea contract, or uncollected in the splitter and the fee
///         vault). Spent means spent inside the market: after every hour, ETH and tokens must still be with the
///         wallets, the garage and the pools.
contract IdeaSpendingTest is GarageTestBase {
    uint256 constant DAYS = 30;
    uint256 constant MAX_UNSPENT_PCT = 20;

    function test_feesGetSpent() public {
        address[] memory wallets = new address[](5);
        for (uint256 i; i < wallets.length; i++) {
            wallets[i] = newWallet("market");
            vm.deal(wallets[i], 10_000 ether);
        }
        startLeakCheck();
        uint256 r = 0x5eed;
        for (uint256 h; h < DAYS * 24; h++) {
            r = uint256(keccak256(abi.encode(r)));
            if (r % 10 < 5) {
                address who = wallets[(r >> 8) % wallets.length];
                uint256 bal = token.balanceOf(who);
                if ((r >> 16) % 3 == 0 && bal > 0) sell(who, bal * (10 + (r >> 24) % 60) / 100);
                else buy(who, 0.02 ether + ((r >> 32) % 100) * 0.008 ether);
            }
            wait(1 hours);
            act();
            assertNoLeak();
        }
        uint256 pending = feeVault.creatorAccrued() * splitter.IDEA_SHARE_BPS() / 10_000; // not yet in the splitter
        uint256 received = splitter.ideaTotal() + pending;
        uint256 unspent = idea.balance + splitter.ideaAccrued() + pending;
        assertGt(received, 0, "the idea received nothing");
        assertLe(
            unspent * 100,
            received * MAX_UNSPENT_PCT,
            string.concat("more than 20% of the idea's fees were never spent (", vm.toString(unspent * 100 / received), "% left)")
        );
    }
}
