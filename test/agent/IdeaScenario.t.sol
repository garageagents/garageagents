// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GarageTestBase} from "../checker/GarageTestBase.sol";
import {Idea} from "../../src/ideas/agent/Idea.sol";

/// @notice Stress Ball ($SQUISH): every hour the idea compares the price with the highest hourly reading of the last
///         72 hours and buys back and burns 1.5% / 4% / 8% / 15% of its pot, the deeper the dip the more.
contract IdeaScenarioTest is GarageTestBase {
    Idea internal squish;
    address internal whale;
    address internal donor;
    address internal stranger;

    function setUp() public override {
        super.setUp();
        squish = Idea(idea);
        whale = newWallet("whale");
        donor = newWallet("donor");
        stranger = newWallet("stranger");
    }

    // ---------------- helpers ----------------

    function _donate(uint256 amount) internal {
        vm.prank(donor);
        (bool ok,) = idea.call{value: amount}("");
        assertTrue(ok, "the pot must accept donations");
    }

    /// Move to the first second of the next hour.
    function _toNextHour() internal {
        wait(1 hours - (vm.getBlockTimestamp() % 1 hours));
    }

    function _hour() internal view returns (uint256) {
        return vm.getBlockTimestamp() / 1 hours;
    }

    function _drawdown() internal view returns (uint256 dd) {
        (,, dd,,,) = squish.stressLevel();
    }

    function _sampleAt(uint256 hour) internal view returns (uint256 hourIndex, uint256 price) {
        (uint64 h, uint192 p) = squish.samples(hour % 72);
        return (uint256(h), uint256(p));
    }

    function _sellUntil(uint256 chunk, uint256 minDd) internal {
        for (uint256 i; i < 400 && _drawdown() < minDd; i++) sell(whale, chunk);
        assertGe(_drawdown(), minDd, "could not push the price down far enough");
    }

    function _assertDip(uint256 peak, uint256 lo, uint256 hi) internal view {
        (uint256 price, uint256 high, uint256 dd,,,) = squish.stressLevel();
        assertEq(high, peak, "the high is the best reading of the last 72 hours");
        assertEq(dd, (high - price) * 10_000 / high, "drawdown in bps");
        assertGe(dd, lo, "drawdown too small for this tier");
        assertLt(dd, hi, "drawdown too big for this tier");
    }

    /// One hourly act(), checked against the rule: the tier's share of the pot is spent, everything bought is burned,
    /// and the reading stored for this hour is the price from before the buy.
    function _squeezeAndCheck(uint256 expectedRate, string memory expectedTier) internal {
        claimIdeaFees(); // so the pot act() works with is known exactly
        (uint256 price,,, uint256 rate, string memory tier, uint256 pot) = squish.stressLevel();
        assertEq(pot, idea.balance, "pot is the contract's ETH");
        assertEq(rate, expectedRate, "rate");
        assertEq(tier, expectedTier, "tier");
        uint256 spend = pot * rate / 10_000;
        if (pot - spend < squish.DUST()) spend = pot;

        uint256 spentBefore = squish.totalEthSpent();
        uint256 burnedBefore = squish.totalBurned();
        uint256 supplyBefore = token.totalSupply();
        act();

        assertEq(pot - idea.balance, spend, "spent the tier's share of the pot");
        assertEq(squish.totalEthSpent() - spentBefore, spend, "totalEthSpent");
        assertEq(token.balanceOf(idea), 0, "keeps no tokens");
        uint256 burned = squish.totalBurned() - burnedBefore;
        assertEq(supplyBefore - token.totalSupply(), burned, "everything bought is burned");
        if (spend != 0) assertGt(burned, 0, "a squeeze burns tokens");
        (uint256 h, uint256 p) = _sampleAt(_hour());
        assertEq(h, _hour(), "reading stored for this hour");
        assertEq(p, price, "reading taken before the buy");
        assertEq(uint256(squish.lastActHour()), _hour());
    }

    // ---------------- tests ----------------

    /// The four tiers, one hour each, then back to calm.
    function test_TheDeeperTheDipTheHarderItSqueezes() public {
        startLeakCheck();
        uint256 bag = buy(whale, 3 ether);
        _donate(2 ether);

        // First reading: nothing to compare with, so the high is the price itself.
        _toNextHour();
        (uint256 price, uint256 high, uint256 dd,,,) = squish.stressLevel();
        assertEq(high, price);
        assertEq(dd, 0);
        _squeezeAndCheck(150, "calm");
        (, uint256 peak) = _sampleAt(_hour());
        assertGt(peak, 0);
        (uint256 after_,,,,,) = squish.stressLevel();
        assertGt(after_, peak, "its own buy lifts the price after the reading");
        uint256 chunk = bag / 150;

        // 10-25% below the high: tense, 4% of the pot.
        _toNextHour();
        _sellUntil(chunk, 1000);
        _assertDip(peak, 1000, 2500);
        _squeezeAndCheck(400, "tense");

        // 25-50% below: stressed, 8%.
        _toNextHour();
        _sellUntil(chunk, 2500);
        _assertDip(peak, 2500, 5000);
        _squeezeAndCheck(800, "stressed");

        // 50% or more below: panic, 15%.
        _toNextHour();
        _sellUntil(chunk, 5000);
        _assertDip(peak, 5000, 10_001);
        _squeezeAndCheck(1500, "panic");

        // Back within 10% of the high: calm again.
        _toNextHour();
        for (uint256 i; i < 400 && _drawdown() >= 1000; i++) buy(whale, 0.02 ether);
        assertLt(_drawdown(), 1000);
        _squeezeAndCheck(150, "calm");

        assertNoLeak();
    }

    /// One squeeze per hour index, whoever calls and however often.
    function test_OnlyOneSqueezePerHour() public {
        startLeakCheck();
        _donate(1 ether);
        _toNextHour();

        vm.prank(stranger);
        squish.act(); // anyone may call it
        uint256 spent = squish.totalEthSpent();
        assertEq(spent, 1 ether * 150 / 10_000);
        uint256 supply = token.totalSupply();
        uint256 hour = _hour();

        // Later in the same hour: fees are collected, but no second squeeze.
        wait(30 minutes);
        buy(whale, 0.5 ether);
        act();
        assertEq(squish.totalEthSpent(), spent);
        assertEq(token.totalSupply(), supply);
        assertGt(idea.balance, 1 ether - spent, "fees were collected into the pot");

        wait(29 minutes + 59 seconds); // last second of the hour
        assertEq(_hour(), hour);
        vm.prank(stranger);
        squish.act();
        assertEq(squish.totalEthSpent(), spent);
        assertEq(token.totalSupply(), supply);

        // Next hour: squeezes again.
        wait(1);
        assertEq(_hour(), hour + 1);
        _squeezeAndCheck(150, "calm");
        assertGt(squish.totalEthSpent(), spent);
        assertNoLeak();
    }

    /// The high only remembers readings from the last 72 hours; hours nobody acted leave no reading.
    function test_HighIsForgottenAfter72Hours() public {
        uint256 bag = buy(whale, 3 ether);
        _donate(0.1 ether);
        _toNextHour();
        uint256 h0 = _hour();
        _squeezeAndCheck(150, "calm");
        (, uint256 peak) = _sampleAt(h0);

        sell(whale, bag * 3 / 4); // a deep dip
        (uint256 price, uint256 high, uint256 dd,, string memory tier,) = squish.stressLevel();
        assertEq(high, peak);
        assertGe(dd, 5000);
        assertEq(tier, "panic");

        // Nobody acts for 71 hours: the old high still counts in its last hour...
        wait(71 hours);
        assertEq(_hour(), h0 + 71);
        (uint256 price2, uint256 high2, uint256 dd2,,,) = squish.stressLevel();
        assertEq(price2, price);
        assertEq(high2, peak);
        assertEq(dd2, dd);

        // ...and is gone 72 hours after it was taken: the price itself is the high again.
        wait(1 hours);
        (, uint256 high3, uint256 dd3,, string memory tier3,) = squish.stressLevel();
        assertEq(high3, price);
        assertEq(dd3, 0);
        assertEq(tier3, "calm");
        (uint256 skipped,) = _sampleAt(h0 + 1);
        assertEq(skipped, 0, "a missed hour has no reading");
        _squeezeAndCheck(150, "calm");
    }

    /// Nobody else touches it: hourly calls alone keep spending 1.5% of the pot per hour.
    function test_CalmMarketSqueezesEveryHour() public {
        startLeakCheck();
        _donate(1 ether);
        for (uint256 i; i < 48; i++) {
            _toNextHour();
            _squeezeAndCheck(150, "calm"); // its own buys only lift the price, so it stays calm
        }
        assertLt(idea.balance, 0.5 ether, "about half the pot is spent in 48 calm hours");
        assertGt(squish.totalBurned(), 0);
        assertNoLeak();
    }

    /// When only dust would stay behind, the whole pot is spent.
    function test_SmallPotIsSpentWhole() public {
        _donate(0.001 ether);
        _toNextHour();
        _squeezeAndCheck(150, "calm");
        assertEq(idea.balance, 0);
        assertEq(squish.totalEthSpent(), 0.001 ether);

        // Above the dust line only the tier's share goes.
        _donate(0.01 ether);
        _toNextHour();
        claimIdeaFees();
        uint256 pot = idea.balance;
        _squeezeAndCheck(150, "calm");
        assertEq(idea.balance, pot - pot * 150 / 10_000);
    }

    /// An empty pot still takes the hourly reading and never reverts.
    function test_EmptyPotJustTakesTheReading() public {
        assertEq(idea.balance, 0);
        _toNextHour();
        (uint256 price,,,,, uint256 pot) = squish.stressLevel();
        assertEq(pot, 0);
        act();
        act();
        assertEq(squish.totalEthSpent(), 0);
        assertEq(squish.totalBurned(), 0);
        assertEq(uint256(squish.lastActHour()), _hour());
        (uint256 h, uint256 p) = _sampleAt(_hour());
        assertEq(h, _hour());
        assertEq(p, price);
    }

    /// Tokens sent to the contract are burned with the next squeeze: it never holds or sells tokens.
    function test_TokensSentToTheContractAreBurnedToo() public {
        startLeakCheck();
        uint256 bag = buy(whale, 0.1 ether);
        vm.prank(whale);
        token.transfer(idea, bag / 2);
        _donate(0.1 ether);
        _toNextHour();
        uint256 supply = token.totalSupply();
        act();
        assertEq(token.balanceOf(idea), 0);
        assertGt(supply - token.totalSupply(), bag / 2);
        assertEq(supply - token.totalSupply(), squish.totalBurned());
        assertNoLeak();
    }
}
