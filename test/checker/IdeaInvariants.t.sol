// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LaunchGuardToken} from "../../src/LaunchGuardToken.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {GarageTestBase, IIdeaAct, INative30Vault} from "./GarageTestBase.sol";

/// Random traders, time and payouts to the idea. Calls that revert are simply skipped.
contract TradeHandler is Test {
    PoolSwapTest immutable router;
    PoolKey key;
    LaunchGuardToken immutable token;
    INative30Vault immutable vault;
    FeeSplitter immutable splitter;
    PoolId immutable poolId;
    address[] actors;

    constructor(PoolSwapTest r, PoolKey memory k, LaunchGuardToken t, INative30Vault v, FeeSplitter s, PoolId id, address[] memory a) {
        router = r;
        key = k;
        token = t;
        vault = v;
        splitter = s;
        poolId = id;
        actors = a;
    }

    function buy(uint256 seed, uint256 eth) external {
        address who = actors[seed % actors.length];
        eth = bound(eth, 0.001 ether, 3 ether);
        vm.prank(who, who);
        router.swap{value: eth}(key, SwapParams(true, -int256(eth), TickMath.MIN_SQRT_PRICE + 1), _s(), "");
    }

    function sell(uint256 seed, uint256 pct) external {
        address who = actors[seed % actors.length];
        uint256 amount = token.balanceOf(who) * bound(pct, 1, 100) / 100;
        if (amount == 0) return;
        vm.startPrank(who, who);
        token.approve(address(router), amount);
        router.swap(key, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), _s(), "");
        vm.stopPrank();
    }

    function wait(uint256 secs) external {
        secs = bound(secs, 1, 3 days);
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12 + 1);
    }

    function claimIdea() external {
        if (vault.creatorAccrued() != 0) vault.claimCreator();
        splitter.sync();
        if (splitter.ideaAccrued() != 0) splitter.claimIdea();
    }

    function _s() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}

/// @notice Properties every idea must keep. Between checks the fuzzer calls, in random order, trading,
///         waiting, payouts to the idea and every function of the idea itself, with random arguments
///         and from random addresses.
contract IdeaInvariantsTest is GarageTestBase {
    TradeHandler handler;
    address probe;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](5);
        for (uint256 i; i < actors.length; i++) {
            actors[i] = newWallet("trader");
            vm.deal(actors[i], 10_000 ether);
        }
        handler = new TradeHandler(router, key, token, feeVault, splitter, poolId, actors);
        know(address(handler));
        probe = newWallet("probe");

        // Some history, so the idea has something to work with.
        for (uint256 i; i < actors.length; i++) {
            buy(actors[i], 0.2 ether);
        }

        targetContract(address(handler));
        targetContract(idea);
        // The idea is called by the traders, so anything it pays its caller stays with a known wallet.
        for (uint256 i; i < actors.length; i++) targetSender(actors[i]);
        startLeakCheck();
    }

    /// ETH and tokens never reach an address nobody gave the idea (a hard-coded destination).
    function invariant_noLeak() public view {
        assertNoLeak();
    }

    /// A fresh wallet can always buy the token and sell it back.
    function invariant_tradingAlwaysWorks() public {
        uint256 snap = vm.snapshotState();
        uint256 tokens = buy(probe, 0.01 ether);
        assertGt(tokens, 0, "buy returned no tokens");
        uint256 eth = sellAll(probe);
        assertGt(eth, 0, "sell returned no ETH");
        vm.revertToState(snap);
    }

    /// The accrued share can always be paid to the idea: its receive never breaks.
    function invariant_ideaAcceptsFees() public {
        if (ideaFeesAccrued() == 0) return;
        uint256 snap = vm.snapshotState();
        if (feeVault.creatorAccrued() != 0) feeVault.claimCreator();
        splitter.sync();
        if (splitter.ideaAccrued() != 0) {
            try splitter.claimIdea() {}
            catch {
                assertTrue(false, "idea rejected its fees: claimIdea reverted");
            }
        }
        vm.revertToState(snap);
    }

    /// The garage calls act() every hour: it must never revert, whatever happened before.
    function invariant_actNeverReverts() public {
        uint256 snap = vm.snapshotState();
        try IIdeaAct(idea).act() {}
        catch {
            assertTrue(false, "act() reverted");
        }
        vm.revertToState(snap);
    }

    /// The fee vault holds exactly what it owes, and the splitter at least what it has booked.
    function invariant_feesSolvent() public view {
        assertEq(MANAGER.balanceOf(address(feeVault), 0), feeVault.platformAccrued() + feeVault.creatorAccrued(), "fee vault accounting");
        assertGe(
            address(splitter).balance,
            splitter.ideaAccrued() + splitter.agentsAccrued() + splitter.treasuryAccrued(),
            "splitter accounting"
        );
    }

}
