// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {GarageInitializer} from "../src/GarageInitializer.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MainBurner} from "../src/MainBurner.sol";
import {Sniper} from "./ideas/TestIdeas.sol";
import {Native30Base, INative30Kernel, IUniversalRouter} from "./Native30Base.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// Behaviour of the main token on Programmable's EthereumNative30HookV3 (no module): one platform charge on every
/// route, the payouts, and the token's anti-sniper rules of the first three blocks.
contract Native30ForkTest is Native30Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ───────────── the launch ─────────────

    function test_launchUsesTheKernelAndChargesTheInitialBuyOnce() public {
        _launch(0.01 ether);
        assertEq(INative30Kernel(kernel).token(), address(token));
        assertEq(INative30Kernel(kernel).module(), address(0), "no module: the kernel runs as reviewed");
        assertEq(vault.creatorRecipient(), address(splitter), "the garage's share goes to the splitter");
        (uint160 sqrtPrice,,,) = MANAGER.getSlot0(key.toId());
        assertLt(sqrtPrice, TickMath.getSqrtPriceAtTick(START_TICK), "the launch buy moved the price");
        _assertOneCharge("initial buy", 0.01 ether, vault.platformAccrued(), vault.creatorAccrued());
        assertGt(token.balanceOf(address(MANAGER)), SUPPLY * 99 / 100, "the supply sits in the pool");
        assertEq(token.balanceOf(address(init)), 0);
        vm.expectRevert(GarageInitializer.AlreadyLaunched.selector);
        init.initialize(kernel, START_TICK);
    }

    // ───────────── one platform charge on every route ─────────────

    function test_testRouterAllSwapKinds() public {
        _launch(0.01 ether);
        vm.roll(block.number + 3);
        _approveRouter(trader);
        (uint256 p0, uint256 c0) = _vaultBalances();
        _swapAs(trader, true, -0.2 ether, 0.2 ether); // buy, exact input
        (uint256 p1, uint256 c1) = _vaultBalances();
        _assertOneCharge("buy exact-in", 0.2 ether, p1 - p0, c1 - c0);

        BalanceDelta d = _swapAs(trader, true, 1_000_000 ether, 1 ether); // buy, exact output
        (uint256 p2, uint256 c2) = _vaultBalances();
        _assertOneCharge("buy exact-out", uint256(-int256(d.amount0())), p2 - p1, c2 - c1);

        d = _swapAs(trader, false, -2_000_000 ether, 0); // sell, exact input: gross = what the pool paid out
        (uint256 p3, uint256 c3) = _vaultBalances();
        _assertOneCharge("sell exact-in", uint256(int256(d.amount0())) + (p3 - p2) + (c3 - c2), p3 - p2, c3 - c2);

        d = _swapAs(trader, false, 0.01 ether, 0); // sell, exact output
        (uint256 p4, uint256 c4) = _vaultBalances();
        _assertOneCharge("sell exact-out", uint256(int256(d.amount0())) + (p4 - p3) + (c4 - c3), p4 - p3, c4 - c3);
    }

    function _routeEvidence(IUniversalRouter r, string memory name) internal {
        uint256 platformWallet = PLATFORM.balance;
        (uint256 p0, uint256 c0) = _vaultBalances();
        _bareBuy(r, 0.05 ether);
        (uint256 p1, uint256 c1) = _vaultBalances();
        _assertOneCharge(string.concat(name, " buy"), 0.05 ether, p1 - p0, c1 - c0);

        uint256 eth = trader.balance;
        _bareSell(r, token.balanceOf(trader) / 2);
        (uint256 p2, uint256 c2) = _vaultBalances();
        _assertOneCharge(string.concat(name, " sell"), trader.balance - eth + (p2 - p1) + (c2 - c1), p2 - p1, c2 - c1);
        assertEq(PLATFORM.balance, platformWallet, "nothing paid to Programmable outside the pool's charge");
    }

    function test_bareUniversalRouterBuyAndSell() public {
        _launch(0.01 ether);
        vm.roll(block.number + 3);
        _routeEvidence(UR, "universal router");
    }

    /// programmable.market's router (0xd92A...) with the route it builds once the pool qualifies for the native30
    /// waiver: the swap only, no routed fee. Still exactly one platform charge: the pool's.
    function test_programmableRouterBuyAndSell() public {
        _launch(0.01 ether);
        vm.roll(block.number + 3);
        _routeEvidence(PROGRAMMABLE_ROUTER, "programmable router");
    }

    function test_burnerBuybackPaysOnce() public {
        _launch(0.01 ether);
        vm.roll(block.number + 3);
        uint256 supply = token.totalSupply();
        (uint256 p0, uint256 c0) = _vaultBalances();
        vm.prank(trader);
        uint256 burned = burner.buyAndBurn{value: 0.1 ether}();
        (uint256 p1, uint256 c1) = _vaultBalances();
        _assertOneCharge("own buyback", 0.1 ether, p1 - p0, c1 - c0);
        assertEq(token.totalSupply(), supply - burned, "bought and burned");
        assertEq(burner.totalBurned(), burned);
        vm.expectRevert(MainBurner.NothingToBuy.selector);
        burner.buyAndBurn();
    }

    // ───────────── payouts ─────────────

    function test_claimsGoOnlyToTheirRecipients() public {
        _launch(0.01 ether);
        vm.roll(block.number + 3);
        _swapAs(trader, true, -1 ether, 1 ether);
        uint256 owedPlatform = vault.platformAccrued();
        uint256 owedCreator = vault.creatorAccrued();
        uint256 before = PLATFORM.balance;
        vm.prank(makeAddr("garage.n30.anyone"));
        vault.claimPlatform();
        assertEq(PLATFORM.balance - before, owedPlatform, "Programmable's share only to its fixed address");

        vm.prank(makeAddr("garage.n30.anyone"));
        vault.claimCreator();
        assertEq(address(splitter).balance, owedCreator, "the garage's share to the splitter");
        vm.prank(makeAddr("garage.n30.anyone"));
        splitter.payOut();
        assertEq(agents.balance, owedCreator / 2);
        assertEq(treasury.balance, owedCreator - owedCreator / 2);
        vm.expectRevert(FeeSplitter.NothingToPay.selector);
        splitter.payOut();
    }

    function test_onlyTreasuryChangesPayoutAddresses() public {
        _launch(0);
        address other = makeAddr("garage.n30.other");
        vm.prank(trader);
        vm.expectRevert(FeeSplitter.NotTreasury.selector);
        splitter.setAgents(other);
        vm.prank(trader);
        vm.expectRevert(FeeSplitter.NotTreasury.selector);
        splitter.setTreasury(other);
        vm.prank(treasury);
        splitter.setAgents(other);
        assertEq(splitter.agents(), other);
    }

    // ───────────── anti-sniper ─────────────

    /// In the launch block and the two after it a signer buys at most 2% of the supply, and a sell does not give the
    /// cap back. From the third block on there is no cap: the same wallet buys, sells and buys again, far above 2%.
    function test_capPerSignerForThreeBlocks() public {
        _launch(0.01 ether);
        uint256 cap = SUPPLY * 2 / 100;
        assertEq(token.earlyBuyRemaining(trader), cap);
        _approveRouter(trader);
        vm.expectRevert();
        _swapAs(trader, true, int256(cap + 1), 10 ether);
        _swapAs(trader, true, int256(cap * 75 / 100), 10 ether);
        vm.roll(block.number + 2); // the third block of the window
        _swapAs(trader, true, int256(cap * 20 / 100), 10 ether);
        _swapAs(trader, false, -int256(cap * 50 / 100), 0);
        assertEq(token.earlyBuyRemaining(trader), cap - cap * 95 / 100, "a sell does not give the cap back");
        vm.expectRevert();
        _swapAs(trader, true, int256(cap * 10 / 100), 10 ether);

        vm.roll(block.number + 1); // block +3: over, after only two buys
        assertEq(token.earlyBuyRemaining(trader), type(uint256).max);
        _swapAs(trader, true, int256(cap * 5), 50 ether);
        _swapAs(trader, false, -int256(cap * 3), 0);
        _swapAs(trader, true, int256(cap * 5), 50 ether);
        assertGt(token.balanceOf(trader), cap * 7, "buy, sell, buy after the window, all above the old cap");
    }

    /// The trick seen in the wild: one transaction creates fresh contracts that each buy. The cap is per signer
    /// (tx.origin), so the second sub-buy breaks it and the whole transaction reverts.
    function test_subContractsAreOneBuyer() public {
        _launch(0.01 ether);
        address eoa = _wallet("garage.n30.sniper");
        Sniper sniper = new Sniper(router);
        vm.prank(eoa, eoa);
        sniper.strike{value: 0.03 ether}(key, 1, 0.03 ether); // about 1.3% of the supply
        assertGt(token.earlyBought(eoa), 0, "booked on the signer");
        vm.prank(eoa, eoa);
        vm.expectRevert();
        sniper.strike{value: 0.06 ether}(key, 2, 0.03 ether);
    }

    function test_tenBuysPerBlockForThreeBlocks() public {
        _launch(0.01 ether);
        for (uint256 b; b < 3; b++) {
            if (b > 0) vm.roll(block.number + 1);
            assertEq(token.blockBuysRemaining(), 10);
            for (uint256 i; i < 10; i++) {
                _swapAs(_wallet(string.concat("garage.n30.b", vm.toString(b), ".", vm.toString(i))), true, -0.001 ether, 0.001 ether);
            }
            vm.expectRevert();
            _swapAs(_wallet(string.concat("garage.n30.b", vm.toString(b), ".eleventh")), true, -0.001 ether, 0.001 ether);
        }
        vm.roll(block.number + 1);
        assertEq(token.blockBuysRemaining(), type(uint256).max);
        for (uint256 i; i < 12; i++) _swapAs(_wallet(string.concat("garage.n30.b3.", vm.toString(i))), true, -0.001 ether, 0.001 ether);
    }

    function test_sellsAreNeverLimited() public {
        _launch(0.01 ether);
        _approveRouter(trader);
        _swapAs(trader, true, -0.02 ether, 0.02 ether);
        _swapAs(trader, false, -int256(token.balanceOf(trader)), 0);
        assertEq(token.balanceOf(trader), 0);
    }

    /// The owner's launch bundle: six wallets each buy 19.9M tokens (just under 2%) in the launch block.
    function test_launchBundleFits() public {
        _launch(0.01 ether);
        for (uint256 i; i < 6; i++) _swapAs(_wallet(string.concat("garage.n30.bundle.", vm.toString(i))), true, int256(19_900_000 ether), 1 ether);
        assertEq(token.blockBuysRemaining(), 4);
    }
}
