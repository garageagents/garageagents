// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GarageTestBase} from "../checker/GarageTestBase.sol";
import {Idea} from "../../src/ideas/agent/Idea.sol";

/// @notice Grr Mondays: the bear burns 1% of the pot per hour Tuesday to Sunday, and on Monday pays 20% to the
///         last buyer and burns the rest before the day ends.
contract IdeaScenarioTest is GarageTestBase {
    Idea internal bear;
    address internal trader;
    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        bear = Idea(idea);
        trader = newWallet("trader");
        alice = newWallet("alice");
        bob = newWallet("bob");
    }

    // ------------------------------------------------------------------ helpers

    /// Next Monday 00:00 UTC (a week ahead if it is Monday now).
    function _nextMondayStart() internal view returns (uint256) {
        uint256 day = vm.getBlockTimestamp() / 1 days;
        return (day + 7 - (day + 3) % 7) * 1 days;
    }

    function _waitUntil(uint256 t) internal {
        uint256 nowTs = vm.getBlockTimestamp();
        require(t > nowTs, "target in the past");
        wait(t - nowTs);
    }

    /// Next Tuesday 12:00 UTC: a grumbling day.
    function _toTuesdayNoon() internal {
        _waitUntil(_nextMondayStart() + 1 days + 12 hours);
    }

    /// Trading fills the pot; the idea is paid its share without an act().
    function _fillPot() internal returns (uint256 pot) {
        buy(trader, 1 ether);
        sellAll(trader);
        claimIdeaFees();
        pot = idea.balance;
        assertGt(pot, 0, "fees reached the pot");
    }

    // ------------------------------------------------------------------ Tuesday to Sunday

    function test_WeekdayBurnsOnePercentPerHour() public {
        _toTuesdayNoon();
        assertFalse(bear.isMonday());
        uint256 pot = _fillPot();
        uint256 supply = token.totalSupply();

        act();
        uint256 spent = pot / 100;
        assertEq(idea.balance, pot - spent, "1% of the pot spent");
        assertEq(bear.totalSpent(), spent);
        assertLt(token.totalSupply(), supply, "bought tokens are burned");
        assertEq(supply - token.totalSupply(), bear.totalBurned());
        assertEq(token.balanceOf(idea), 0, "the bear keeps no tokens");

        // A second call in the same hour does not burn again
        uint256 burned = bear.totalBurned();
        act();
        assertEq(bear.totalBurned(), burned, "one buyback per hour");
        assertEq(bear.totalSpent(), spent);

        // Next hour: 1% of the pot again
        wait(1 hours);
        claimIdeaFees();
        uint256 pot2 = idea.balance;
        act();
        assertEq(idea.balance, pot2 - pot2 / 100, "1% of the pot the next hour");
        assertGt(bear.totalBurned(), burned);
        assertEq(bear.wakeCount(), 0, "no wake-up outside Monday");
    }

    function test_WakeUpOnlyOnMonday() public {
        _toTuesdayNoon();
        assertEq(bear.secondsUntilMonday(), 5 days + 12 hours);
        assertFalse(bear.canWakeUp());
        vm.expectRevert(Idea.NotMonday.selector);
        bear.wakeUp();

        // Sunday 23:59 is still too early
        _waitUntil(_nextMondayStart() - 1 minutes);
        vm.expectRevert(Idea.NotMonday.selector);
        bear.wakeUp();
    }

    // ------------------------------------------------------------------ Monday

    function test_MondayWakeUpPaysLastBuyerNotCaller() public {
        startLeakCheck();
        _toTuesdayNoon();
        _fillPot();

        // Sunday 23:30: the trader buys, then alice buys last; a later sell does not change the last buyer
        _waitUntil(_nextMondayStart() - 30 minutes);
        buy(trader, 0.1 ether);
        buy(alice, 0.01 ether);
        sell(trader, token.balanceOf(trader) / 2);
        (address cand,, bool ok) = bear.currentCandidate();
        assertEq(cand, alice);
        assertTrue(ok);

        // Monday 00:00:10: bob wakes the bear up, alice is paid
        _waitUntil(_nextMondayStart() + 10);
        assertTrue(bear.isMonday());
        assertTrue(bear.canWakeUp());
        assertEq(bear.secondsUntilMonday(), 0);
        claimIdeaFees();
        uint256 pot = idea.balance;
        uint256 prize = pot * 2000 / 10_000;
        assertEq(bear.projectedPrize(), prize);
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        bear.wakeUp();

        assertEq(alice.balance, aliceBefore + prize, "last buyer gets 20%");
        assertEq(bob.balance, bobBefore, "the caller gets nothing");
        assertEq(idea.balance, pot - prize, "the rest stays for the Monday burns");
        assertEq(bear.lastWinner(), alice);
        assertEq(bear.lastPrize(), prize);
        assertEq(bear.totalPrizes(), prize);
        assertEq(bear.wakeCount(), 1);
        assertEq(bear.totalSpent(), 0, "wakeUp itself burns nothing");
        assertFalse(bear.canWakeUp());

        // Only one wake-up per Monday
        vm.prank(alice);
        vm.expectRevert(Idea.AlreadyAwake.selector);
        bear.wakeUp();

        // A buy after the wake-up does not win today; act() burns instead of paying again
        wait(1 minutes);
        buy(bob, 0.01 ether);
        act();
        assertEq(alice.balance, aliceBefore + prize, "paid once");
        assertEq(bear.wakeCount(), 1);
        assertEq(bear.lastWinner(), alice);
        assertGt(bear.totalSpent(), 0, "Monday burn ran");
        assertEq(token.balanceOf(idea), 0);
        // bob's buy counts for next Monday
        (cand,, ok) = bear.currentCandidate();
        assertEq(cand, bob);
        assertTrue(ok);

        assertNoLeak();
    }

    function test_ActWakesUpAndEmptiesPotByEndOfMonday() public {
        startLeakCheck();
        _toTuesdayNoon();
        _fillPot();
        _waitUntil(_nextMondayStart() - 1 hours);
        buy(alice, 0.01 ether);

        // Monday 00:30: nobody called wakeUp(), the hourly act() does it
        _waitUntil(_nextMondayStart() + 30 minutes);
        claimIdeaFees();
        uint256 pot = idea.balance;
        uint256 prize = pot / 5;
        uint256 aliceBefore = alice.balance;
        act();
        assertEq(alice.balance, aliceBefore + prize, "act() paid the last buyer");
        uint256 rest = pot - prize;
        assertEq(idea.balance, rest - rest / 24, "first Monday hour burns 1/24 of the rest");
        assertFalse(bear.canWakeUp());

        // Hourly through Monday: the pot is empty when Monday ends (fees from the burns included)
        for (uint256 h = 1; h < 24; h++) {
            wait(1 hours);
            assertTrue(bear.isMonday());
            act();
            assertEq(token.balanceOf(idea), 0);
        }
        assertEq(idea.balance, 0, "pot empty at the end of Monday");
        assertEq(alice.balance, aliceBefore + prize, "paid only once");
        assertEq(bear.wakeCount(), 1);
        assertGt(bear.totalBurned(), 0);

        // Tuesday: back to grumbling
        wait(1 hours);
        assertFalse(bear.isMonday());
        act();
        assertEq(bear.wakeCount(), 1);
        assertNoLeak();
    }

    function test_StaleBuyerDoesNotWinAgain() public {
        _toTuesdayNoon();
        buy(trader, 1 ether);
        buy(alice, 0.01 ether);
        claimIdeaFees();

        _waitUntil(_nextMondayStart() + 1 minutes);
        uint256 aliceBefore = alice.balance;
        bear.wakeUp();
        assertGt(alice.balance, aliceBefore, "alice won week one");
        uint256 firstPrize = bear.lastPrize();

        // The next week only sells happen: alice is still the last buyer, but her buy is stale
        _waitUntil(_nextMondayStart() - 1 days);
        sellAll(trader);
        claimIdeaFees();
        (address cand,, bool ok) = bear.currentCandidate();
        assertEq(cand, alice);
        assertFalse(ok);

        _waitUntil(_nextMondayStart() + 1 minutes);
        uint256 aliceMid = alice.balance;
        uint256 pot = idea.balance;
        act();
        assertEq(alice.balance, aliceMid, "no prize for a stale buy");
        assertEq(bear.wakeCount(), 2);
        assertEq(bear.lastPrize(), firstPrize);
        assertEq(idea.balance, pot - pot / 24, "the whole pot goes to the Monday burns");
    }

    function test_TinyLastBuyDoesNotWin() public {
        _toTuesdayNoon();
        _fillPot();
        _waitUntil(_nextMondayStart() - 1 hours);
        buy(alice, 0.0005 ether);
        (address cand, uint256 value, bool ok) = bear.currentCandidate();
        assertEq(cand, alice);
        assertLt(value, 0.001 ether);
        assertFalse(ok);

        _waitUntil(_nextMondayStart() + 1 minutes);
        uint256 before = alice.balance;
        uint256 pot = idea.balance;
        bear.wakeUp();
        assertEq(alice.balance, before, "a buy under 0.001 ETH does not win");
        assertEq(bear.lastWinner(), address(0));
        assertEq(bear.wakeCount(), 1);
        assertGe(idea.balance, pot, "nothing left the pot");
    }

    // ------------------------------------------------------------------ a quiet market

    function test_QuietTwoWeeksKeepTheBearBusy() public {
        address[3] memory ws = [newWallet("q"), newWallet("q"), newWallet("q")];
        _waitUntil(_nextMondayStart() + 1 days + 30 minutes); // Tuesday 00:30
        startLeakCheck();
        for (uint256 i; i < 14 * 24; i++) {
            if (i % 2 == 0) {
                address w = ws[(i / 2) % 3];
                uint256 bal = token.balanceOf(w);
                if ((i / 2) % 2 == 0 || bal == 0) buy(w, 0.05 ether);
                else sell(w, bal / 2);
            }
            act();
            assertEq(token.balanceOf(idea), 0, "keeps no tokens");
            if (bear.isMonday() && vm.getBlockTimestamp() % 1 days >= 23 hours) {
                assertEq(idea.balance, 0, "pot empty when Monday ends");
            }
            wait(1 hours);
        }
        assertEq(bear.wakeCount(), 2);
        assertGt(bear.totalPrizes(), 0);
        assertGt(bear.totalBurned(), 0);
        assertNoLeak();
    }
}
