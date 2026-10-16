// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LaunchGuardToken} from "../../LaunchGuardToken.sol";
import {IdeaBase} from "../IdeaBase.sol";

/// @title Stress Ball ($SQUISH)
/// @notice The deeper the dip, the harder it squeezes.
///         Every hour act() reads the SQUISH price, compares it with the highest hourly reading of the last 72 hours
///         and spends part of the contract's ETH on buying SQUISH, which it burns on the spot:
///           less than 10% below the high   ->  1.5% of the pot   (calm)
///           10% to 25% below               ->  4%                (tense)
///           25% to 50% below               ->  8%                (stressed)
///           50% or more below              ->  15%               (panic)
///         Nothing to call, nothing to enter: stressLevel() shows how hard it is squeezing right now.
///         No owner, no withdrawals, no selling. Every token the contract holds is burned when it squeezes.
contract Idea is IdeaBase {
    /// @dev One hourly reading. price = SQUISH price in wei per whole token (ETH per token, scaled 1e18).
    struct Sample {
        uint64 hourIndex; // block.timestamp / 1 hours when the reading was taken
        uint192 price;
    }

    uint256 public constant WINDOW_HOURS = 72;

    // Share of the pot spent per hourly squeeze, in bps.
    uint256 public constant CALM_BPS = 150;
    uint256 public constant TENSE_BPS = 400;
    uint256 public constant STRESSED_BPS = 800;
    uint256 public constant PANIC_BPS = 1500;

    // Drawdown below the 72-hour high at which each tier starts, in bps.
    uint256 public constant TENSE_FROM = 1000;
    uint256 public constant STRESSED_FROM = 2500;
    uint256 public constant PANIC_FROM = 5000;

    /// @notice If a squeeze would leave less than this in the pot, it spends the whole pot instead.
    uint256 public constant DUST = 0.001 ether;

    /// @dev The launch block and the two after it carry anti-sniper limits: the contract does not buy in there.
    uint256 internal constant EARLY_BLOCKS = 3;

    /// @notice Hourly readings, slot = hourIndex % 72. Slots older than 72 hours are ignored.
    Sample[WINDOW_HOURS] public samples;
    /// @notice Hour index (timestamp / 1 hour) of the last hourly step.
    uint64 public lastActHour;
    /// @notice SQUISH burned so far (18 decimals).
    uint256 public totalBurned;
    /// @notice ETH spent on buybacks so far.
    uint256 public totalEthSpent;

    event Squeezed(
        uint256 indexed hour,
        uint256 price,
        uint256 high,
        uint256 drawdownBps,
        uint256 rateBps,
        uint256 ethSpent,
        uint256 burned
    );

    constructor(IPoolManager m, address i) IdeaBase(m, i) {}

    /// @dev The hourly step: one reading and one squeeze per hour index, whoever calls.
    function _act() internal override {
        uint64 hour = uint64(block.timestamp / 1 hours);
        if (hour == lastActHour) return; // this hour is done
        if (block.number < _stats().launchBlock + EARLY_BLOCKS) return; // anti-sniper blocks: retry later this hour
        lastActHour = hour;

        // 1. The hourly reading, taken before buying anything.
        (uint256 price, uint256 high, uint256 drawdown, uint256 rate) = _reading();
        samples[hour % WINDOW_HOURS] = Sample(hour, uint192(price));

        // 2. The tier's share of the pot (all of it when only dust would stay behind).
        uint256 spend = _spendOf(address(this).balance, rate);
        if (spend == 0) return;

        // 3. Buy and burn everything the contract holds. minTokens is 0: the price is read in this same call, so a
        //    bound derived from it could not stop a sandwich anyway, and the squeeze is a small share of the pot.
        uint256 before = address(this).balance;
        _buy(spend, 0);
        uint256 left = address(this).balance;
        uint256 spent = before > left ? before - left : 0;
        uint256 burned = _tokenBalance();
        if (burned != 0) _burn(burned);

        totalEthSpent += spent;
        totalBurned += burned;
        emit Squeezed(hour, price, high, drawdown, rate, spent, burned);
    }

    // ---------------- Views ----------------

    /// @notice How hard it is squeezing right now.
    /// @return currentPrice SQUISH price now, in wei per whole token
    /// @return high72h      highest hourly reading of the last 72 hours (the current price included)
    /// @return drawdownBps  how far the price sits below that high, in bps
    /// @return rateBps      share of the pot the next hourly squeeze spends, in bps
    /// @return tier         "calm", "tense", "stressed" or "panic"
    /// @return potBalance   ETH in the contract now (fees not yet collected come on top at the next act)
    function stressLevel()
        external
        view
        returns (
            uint256 currentPrice,
            uint256 high72h,
            uint256 drawdownBps,
            uint256 rateBps,
            string memory tier,
            uint256 potBalance
        )
    {
        (currentPrice, high72h, drawdownBps, rateBps) = _reading();
        if (rateBps == CALM_BPS) tier = "calm";
        else if (rateBps == TENSE_BPS) tier = "tense";
        else if (rateBps == STRESSED_BPS) tier = "stressed";
        else tier = "panic";
        potBalance = address(this).balance;
    }

    // ---------------- Internals ----------------

    /// @dev Current price, the 72-hour high (current price included), the drawdown and the tier's rate.
    function _reading() internal view returns (uint256 price, uint256 high, uint256 drawdown, uint256 rate) {
        price = _price();
        high = price;
        uint256 hour = block.timestamp / 1 hours;
        for (uint256 i; i < WINDOW_HOURS; i++) {
            Sample memory s = samples[i];
            // Only readings from the last 72 hour indexes count: empty and expired slots are skipped.
            if (s.hourIndex + WINDOW_HOURS > hour && s.hourIndex <= hour && s.price > high) high = s.price;
        }
        if (price != 0 && price < high) drawdown = (high - price) * 10_000 / high;

        if (drawdown < TENSE_FROM) rate = CALM_BPS;
        else if (drawdown < STRESSED_FROM) rate = TENSE_BPS;
        else if (drawdown < PANIC_FROM) rate = STRESSED_BPS;
        else rate = PANIC_BPS;
    }

    /// @dev SQUISH price in wei per whole token: higher means SQUISH is more expensive. 0 before the pool is live.
    function _price() internal view returns (uint256 p) {
        if (_sqrtPriceX96() == 0) return 0;
        p = _ethValue(1 ether);
        if (p > type(uint192).max) p = type(uint192).max; // out of reach within the pool's price range
    }

    /// @dev rate of the pot, or the whole pot when less than DUST would stay behind.
    function _spendOf(uint256 pot, uint256 rate) internal pure returns (uint256 spend) {
        spend = pot * rate / 10_000;
        if (pot - spend < DUST) spend = pot;
    }
}
