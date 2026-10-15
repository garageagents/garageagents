// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LaunchGuardToken} from "../../LaunchGuardToken.sol";
import {IdeaBase} from "../IdeaBase.sol";

/// @title Grr Mondays ($GRR)
/// @notice The fee pot lives with a grumpy bear.
///         Tuesday to Sunday (UTC) it grumbles: once an hour it spends 1% of the pot to buy back and burn GRR.
///         On Monday (UTC) it wakes up angry: the first wake-up call of the day sends 20% of the pot to whoever
///         made the most recent buy at that moment, and the rest is spent buying back and burning GRR over the
///         remaining Monday hours, until the pot is empty.
///         Anyone can call wakeUp() as soon as Monday starts; if nobody does, the hourly act() does it.
///         To win, the last buy must be worth at least 0.001 ETH (at the current pool price) and must have been
///         made after the previous wake-up.
contract Idea is IdeaBase {
    uint256 private constant BPS = 10_000;
    /// @notice Share of the pot spent per hour from Tuesday to Sunday (1%).
    uint256 public constant WEEKDAY_BPS = 100;
    /// @notice Share of the pot sent to the last buyer when the bear wakes up (20%).
    uint256 public constant PRIZE_BPS = 2_000;
    /// @notice The winning buy must be worth at least this much ETH (at the current pool price).
    uint256 public constant MIN_BUY_ETH = 0.001 ether;
    /// @notice Buybacks smaller than this are skipped; the ETH waits for a later hour.
    uint256 public constant DUST = 0.00001 ether;

    uint256 public lastWakeWeek; // week number of the last wake-up
    uint256 public lastWakeTime; // timestamp of the last wake-up (0 before the first one)
    address public lastWinner; // last wallet that was paid a prize
    uint256 public lastPrize; // and how much
    uint256 public totalPrizes; // ETH paid out as prizes
    uint256 public totalBurned; // tokens burned
    uint256 public totalSpent; // ETH spent on buybacks
    uint256 public wakeCount; // number of wake-ups so far
    uint256 public lastBurnHour; // hour number (timestamp / 3600) of the last buyback: at most one per hour

    event Woke(uint256 indexed week, address indexed winner, uint256 prize);
    event Grumbled(uint256 ethSpent, uint256 tokensBurned);

    error NotMonday();
    error AlreadyAwake();

    constructor(IPoolManager m, address i) IdeaBase(m, i) {}

    // ------------------------------------------------------------------ actions

    /// @notice Wake the bear up. Works once per Monday (UTC), for anyone. 20% of the pot goes to the most recent
    ///         buyer at this moment (not to the caller, unless that is the same wallet). No burn happens here:
    ///         the hourly act() does the Monday burns.
    function wakeUp() external {
        if (!isMonday()) revert NotMonday();
        uint256 week = currentWeekId();
        if (lastWakeWeek == week) revert AlreadyAwake();
        _claimFees();
        (address winner, uint256 prize) = _wake(week);
        if (prize != 0) _payPrize(week, winner, prize);
    }

    /// @dev The hourly step. On Monday: wake up if nobody did yet, then burn the pot spread over the hours left.
    ///      Other days: burn 1% of the pot. Never reverts.
    function _act() internal override {
        address winner;
        uint256 prize;
        uint256 week = currentWeekId();
        if (isMonday() && lastWakeWeek != week) (winner, prize) = _wake(week);
        _burnStep(prize); // the prize is set aside, it is not burned
        if (prize != 0) _payPrize(week, winner, prize); // the payment to an outside wallet comes last
    }

    // ------------------------------------------------------------------ views

    /// @notice True while it is Monday (UTC). 1970-01-01 was a Thursday.
    function isMonday() public view returns (bool) {
        return (block.timestamp / 1 days + 3) % 7 == 0;
    }

    /// @notice Week number; it goes up by one every Monday 00:00 UTC.
    function currentWeekId() public view returns (uint256) {
        return (block.timestamp / 1 days + 3) / 7;
    }

    /// @notice Seconds until the next Monday 00:00 UTC (0 while it is Monday).
    function secondsUntilMonday() external view returns (uint256) {
        if (isMonday()) return 0;
        return ((currentWeekId() + 1) * 7 - 3) * 1 days - block.timestamp;
    }

    /// @notice True when wakeUp() would work right now.
    function canWakeUp() external view returns (bool) {
        return isMonday() && lastWakeWeek != currentWeekId();
    }

    /// @notice ETH in the pot right now (fees not yet collected are not included).
    function potBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice 20% of the pot right now: what a wake-up would pay if it happened now.
    function projectedPrize() external view returns (uint256) {
        return address(this).balance * PRIZE_BPS / BPS;
    }

    /// @notice The most recent buyer, the ETH value of that buy at the current price, and whether that buy would
    ///         win the prize if the bear woke up right now.
    function currentCandidate() public view returns (address buyer, uint256 buyValueEth, bool eligible) {
        LaunchGuardToken.PoolStats memory s = _stats();
        buyer = s.lastBuyer;
        buyValueEth = _ethValue(s.lastBuyTokens);
        eligible = buyer != address(0) && buyer != address(this) && s.lastBuyAt > lastWakeTime
            && buyValueEth >= MIN_BUY_ETH;
    }

    // ------------------------------------------------------------------ internals

    /// @dev Records the wake-up for `week` and decides the prize. Does not pay it (see _payPrize).
    function _wake(uint256 week) private returns (address winner, uint256 prize) {
        (address buyer,, bool eligible) = currentCandidate(); // reads lastWakeTime before it is updated
        lastWakeWeek = week;
        lastWakeTime = block.timestamp;
        wakeCount += 1;
        if (eligible) prize = address(this).balance * PRIZE_BPS / BPS;
        if (prize == 0) {
            emit Woke(week, address(0), 0); // no prize: the whole pot stays for the Monday burns
            return (address(0), 0);
        }
        winner = buyer;
    }

    /// @dev Sends the prize. If the winner refuses the ETH it stays in the pot and is burned on Monday.
    function _payPrize(uint256 week, address winner, uint256 prize) private {
        if (_sendEth(winner, prize)) {
            lastWinner = winner;
            lastPrize = prize;
            totalPrizes += prize;
            emit Woke(week, winner, prize);
        } else {
            emit Woke(week, winner, 0);
        }
    }

    /// @dev One buyback per hour: buys GRR and burns everything bought. `reserved` is ETH kept out (the prize).
    function _burnStep(uint256 reserved) private {
        if (block.number < uint256(_stats().launchBlock) + 3) return; // anti-sniper window: no buys yet
        uint256 hour = block.timestamp / 1 hours;
        if (hour == lastBurnHour) return; // this hour's buyback already happened
        uint256 pot = address(this).balance - reserved;
        uint256 spend = isMonday() ? pot / _mondayHoursLeft() : pot * WEEKDAY_BPS / BPS;
        if (spend < DUST) return; // too small: it waits for a later hour
        lastBurnHour = hour;
        uint256 before = address(this).balance;
        _buy(spend, 0);
        uint256 used = before - address(this).balance;
        uint256 burned = _tokenBalance(); // everything it holds goes: it keeps no tokens
        if (burned != 0) _burn(burned);
        totalSpent += used;
        totalBurned += burned;
        emit Grumbled(used, burned);
    }

    /// @dev Monday hours left including the current one (24 at 00:00, 1 during 23:00-24:00).
    function _mondayHoursLeft() private view returns (uint256) {
        uint256 secsLeft = 1 days - (block.timestamp % 1 days);
        return (secsLeft + 1 hours - 1) / 1 hours;
    }
}
