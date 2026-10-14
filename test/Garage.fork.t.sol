// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {GarageHook} from "../src/GarageHook.sol";
import {GarageInitializer} from "../src/GarageInitializer.sol";
import {GarageToken} from "../src/GarageToken.sol";
import {HoldIdea, TradeIdea, LastBuyerIdea, BrokenIdea, ReentrantIdea, RejectingWallet, RandomIdea, Sniper} from "./ideas/TestIdeas.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// A launch the way the Programmable factory performs it: initializer, token (whole supply to the initializer),
/// idea contract (optional), hook at an address with the right flags, then initialize(hook, startTick).
contract GarageForkTest is Test {
    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    int24 constant START_TICK = 200_280; // ~2 ETH FDV
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PoolSwapTest router;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    address agents = makeAddr("garage.agents");
    address treasury = makeAddr("garage.treasury");
    address trader = makeAddr("garage.trader");
    uint160 launches;
    Launch mainL; // the main token: agent tokens burn it with idle idea shares

    struct Launch {
        GarageInitializer init;
        GarageToken token;
        GarageHook hook;
        PoolKey key;
        address idea;
    }

    enum IdeaKind {
        None,
        Hold,
        Trade,
        LastBuyer,
        Broken
    }

    function setUp() public {
        vm.createSelectFork("ethereum");
        // Well-known addresses can have EIP-7702 code on mainnet that forwards ETH elsewhere.
        vm.etch(agents, "");
        vm.etch(treasury, "");
        vm.etch(trader, "");
        router = new PoolSwapTest(MANAGER);
        vm.deal(trader, 10_000 ether);
        mainL = _deploy(300, IdeaKind.None, 0);
        _endEarlyPhase(mainL.hook);
    }

    // ───────────── helpers ─────────────

    function _deploy(uint256 feeBps, IdeaKind kind, uint256 initialBuy) internal returns (Launch memory L) {
        L.init = new GarageInitializer(MANAGER);
        L.token = new GarageToken("Test", "TEST", SUPPLY, address(L.init));
        if (kind == IdeaKind.Hold) L.idea = address(new HoldIdea(MANAGER, address(L.init)));
        if (kind == IdeaKind.Trade) L.idea = address(new TradeIdea(MANAGER, address(L.init)));
        if (kind == IdeaKind.LastBuyer) L.idea = address(new LastBuyerIdea(MANAGER, address(L.init)));
        if (kind == IdeaKind.Broken) L.idea = address(new BrokenIdea());
        address hookAddr = address(FLAGS | (uint160(0x4444 + launches++) << 144));
        deployCodeTo(
            "GarageHook.sol:GarageHook",
            abi.encode(MANAGER, address(L.token), address(L.init), L.idea, feeBps, agents, treasury, kind == IdeaKind.None ? address(0) : address(mainL.hook)),
            hookAddr
        );
        L.hook = GarageHook(payable(hookAddr));
        L.key = L.hook.poolKey();
        L.init.initialize{value: initialBuy}(hookAddr, START_TICK);
        vm.prank(trader);
        L.token.approve(address(router), type(uint256).max);
    }

    /// Launch and skip the anti-sniper phase (as if 30 counted buys had happened) and the first blocks' buy limit.
    function _launch(uint256 feeBps, IdeaKind kind) internal returns (Launch memory L) {
        L = _deploy(feeBps, kind, 0);
        _endEarlyPhase(L.hook);
    }

    function _endEarlyPhase(GarageHook h) internal {
        stdstore.target(address(h)).sig("earlyBuys()").checked_write(h.EARLY_BUYS());
        vm.roll(vm.getBlockNumber() + h.EARLY_BLOCKS()); // past the per-block limit of the first blocks
    }

    function _swap(Launch memory L, bool buy, int256 amountSpecified, uint256 value) internal returns (BalanceDelta) {
        return _swapAs(trader, L, buy, amountSpecified, value);
    }

    function _swapAs(address who, Launch memory L, bool buy, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta d)
    {
        vm.prank(who, who);
        d = router.swap{value: value}(
            L.key, SwapParams(buy, amountSpecified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, ""
        );
    }

    function _owed(GarageHook h) internal view returns (uint256) {
        return h.platformAccrued() + h.agentsAccrued() + h.treasuryAccrued() + h.ideaAccrued();
    }

    function _wallet(string memory label) internal returns (address w) {
        w = makeAddr(label);
        vm.etch(w, "");
        vm.deal(w, 100 ether);
    }

    // ───────────── launch ─────────────

    function test_launchLocksWholeSupply() public {
        Launch memory L = _deploy(300, IdeaKind.None, 0);
        (, int24 tick,,) = MANAGER.getSlot0(L.key.toId());
        assertEq(tick, START_TICK);
        assertEq(L.token.balanceOf(address(L.init)), 0, "initializer keeps nothing");
        assertEq(L.token.balanceOf(address(MANAGER)), L.token.totalSupply(), "everything is in the pool");
        assertGt(L.token.totalSupply(), SUPPLY - 1e9, "dust negligible");
        bytes32 pos = Position.calculatePositionKey(address(L.init), TickMath.minUsableTick(60), START_TICK, bytes32(0));
        assertEq(MANAGER.getPositionLiquidity(L.key.toId(), pos), L.init.lockedLiquidity());
        assertGt(L.init.lockedLiquidity(), 0);
    }

    /// The launch buy goes into the pool: all its ETH buys (the fee is paid, the rest of the ETH is now in the pool),
    /// then the tokens bought go back into the pool as a locked position. The launcher keeps nothing.
    function test_launchBuyGoesIntoThePool() public {
        uint256 ethIn = 0.01 ether;
        uint256 managerEth = address(MANAGER).balance;
        Launch memory L = _deploy(300, IdeaKind.None, ethIn);

        assertEq(L.hook.totalFees(), ethIn * 3 / 100, "3% fee on the whole buy");
        assertEq(L.hook.platformAccrued(), ethIn * 3 / 1000, "0.3% of it to Programmable");
        assertEq(address(MANAGER).balance - managerEth, ethIn, "all the launch ETH is in the pool manager (pool and fees)");
        assertEq(address(L.init).balance, 0, "the initializer keeps no ETH");
        assertEq(L.token.balanceOf(address(L.init)), 0, "the initializer keeps no tokens");
        assertEq(L.token.balanceOf(address(MANAGER)), L.token.totalSupply(), "every token is in the pool");
        assertLt(L.init.initialBuyBurned(), 1e9, "only rounding dust is burned");
        assertGt(L.init.initialBuyTokens(), 0);
        assertEq(L.hook.stats().swapCount, 0, "the launch buy is not counted");

        (, int24 tick,,) = MANAGER.getSlot0(L.key.toId());
        assertLt(tick, START_TICK, "the buy lifted the price");
        assertLe(L.init.initialBuyUpperTick(), tick, "the tokens go back from the current price on");
        assertGt(L.init.initialBuyUpperTick(), tick - 60);
        bytes32 pos = Position.calculatePositionKey(address(L.init), TickMath.minUsableTick(60), L.init.initialBuyUpperTick(), bytes32(uint256(1)));
        assertEq(MANAGER.getPositionLiquidity(L.key.toId(), pos), L.init.initialBuyLiquidity());
        assertGt(L.init.initialBuyLiquidity(), 0);

        // Trading works around it: the next buyer gets those tokens first, and everyone can sell back.
        _swap(L, true, -0.02 ether, 0.02 ether);
        _swap(L, false, -int256(L.token.balanceOf(trader)), 0);
        assertEq(L.token.balanceOf(trader), 0);
    }

    function test_ideaLearnsItsTokenAtLaunch() public {
        Launch memory L = _launch(400, IdeaKind.Hold);
        assertEq(HoldIdea(payable(L.idea)).token(), address(L.token));
        assertEq(address(HoldIdea(payable(L.idea)).hook()), address(L.hook));
    }

    function test_onlyInitializerStartsThePool() public {
        GarageInitializer init = new GarageInitializer(MANAGER);
        GarageToken t = new GarageToken("X", "X", SUPPLY, address(init));
        address hookAddr = address(FLAGS | (uint160(0x5555) << 144));
        deployCodeTo("GarageHook.sol:GarageHook", abi.encode(MANAGER, address(t), address(init), address(0), 300, agents, treasury, address(0)), hookAddr);
        PoolKey memory key = GarageHook(payable(hookAddr)).poolKey();
        vm.expectRevert();
        MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(0));
        init.initialize(hookAddr, START_TICK);
        vm.expectRevert(GarageInitializer.AlreadyLaunched.selector);
        init.initialize(hookAddr, START_TICK);
    }

    function test_feeOutOfRangeRejected() public {
        GarageInitializer init = new GarageInitializer(MANAGER);
        GarageToken t = new GarageToken("X", "X", SUPPLY, address(init));
        address hookAddr = address(FLAGS | (uint160(0x6666) << 144));
        vm.expectRevert();
        deployCodeTo("GarageHook.sol:GarageHook", abi.encode(MANAGER, address(t), address(init), address(0), 99, agents, treasury, address(0)), hookAddr);
        vm.expectRevert();
        deployCodeTo("GarageHook.sol:GarageHook", abi.encode(MANAGER, address(t), address(init), address(0), 401, agents, treasury, address(0)), hookAddr);
    }

    // ───────────── fees ─────────────

    function test_mainTokenSplit() public {
        Launch memory L = _launch(300, IdeaKind.None);
        _swap(L, true, -1 ether, 1 ether);
        assertEq(L.hook.totalFees(), 0.03 ether, "3% in total");
        assertEq(L.hook.platformAccrued(), 0.003 ether, "0.3% inside it to Programmable");
        assertEq(L.hook.agentsAccrued(), 0.0135 ether);
        assertEq(L.hook.treasuryAccrued(), 0.0135 ether);
        assertEq(L.hook.ideaAccrued(), 0);
    }

    function test_agentTokenSplit() public {
        Launch memory L = _launch(400, IdeaKind.Hold);
        _swap(L, true, -1 ether, 1 ether);
        assertEq(L.hook.totalFees(), 0.04 ether);
        assertEq(L.hook.platformAccrued(), 0.003 ether);
        assertEq(L.hook.ideaAccrued(), 0.0296 ether, "80% of the project share");
        assertEq(L.hook.agentsAccrued(), 0.0037 ether);
        assertEq(L.hook.treasuryAccrued(), 0.0037 ether);
    }

    /// All four kinds of swap pay, the Programmable share is 0.3% of the gross ETH amount, rounded up,
    /// and the hook holds exactly what it owes.
    function test_allSwapKindsPayFee() public {
        Launch memory L = _launch(400, IdeaKind.Hold);

        uint256 p0 = L.hook.platformAccrued();
        _swap(L, true, -1 ether, 1 ether); // buy, exact input: gross = 1 ETH
        assertEq(L.hook.platformAccrued() - p0, 0.003 ether, "exact-in buy");

        p0 = L.hook.platformAccrued();
        uint256 f0 = L.hook.totalFees();
        BalanceDelta d = _swap(L, true, 1_000_000 ether, 1 ether); // buy, exact output: gross = ETH paid
        uint256 paid = uint256(-int256(d.amount0()));
        assertGt(L.hook.totalFees(), f0);
        assertEq(L.hook.platformAccrued() - p0, (paid * 30 + 9_999) / 10_000, "exact-out buy");

        p0 = L.hook.platformAccrued();
        f0 = L.hook.totalFees();
        d = _swap(L, false, -int256(L.token.balanceOf(trader) / 2), 0); // sell, exact input: gross = ETH before fees
        uint256 got = uint256(int256(d.amount0()));
        uint256 fee = L.hook.totalFees() - f0;
        assertEq(L.hook.platformAccrued() - p0, ((got + fee) * 30 + 9_999) / 10_000, "exact-in sell");

        p0 = L.hook.platformAccrued();
        uint256 ethBefore = trader.balance;
        _swap(L, false, 0.1 ether, 0); // sell, exact output
        assertEq(trader.balance - ethBefore, 0.1 ether, "trader gets exactly what asked");
        assertGt(L.hook.platformAccrued(), p0, "exact-out sell");

        assertEq(_owed(L.hook), L.hook.totalFees(), "accounting adds up");
        assertEq(MANAGER.balanceOf(address(L.hook), 0), L.hook.totalFees(), "hook holds what it owes");
    }

    function testFuzz_buyFeeSplit(uint16 feeBps, uint96 ethIn) public {
        feeBps = uint16(bound(feeBps, 100, 400));
        uint256 amount = bound(ethIn, 1e9, 50 ether);
        Launch memory L = _launch(feeBps, IdeaKind.Hold);
        _swap(L, true, -int256(amount), amount);
        uint256 fee = L.hook.totalFees();
        uint256 platform = (amount * 30 + 9_999) / 10_000;
        assertEq(fee, (amount * feeBps + 9_999) / 10_000, "fee rounded up");
        assertEq(L.hook.platformAccrued(), platform, "Programmable 0.3% rounded up");
        assertEq(L.hook.ideaAccrued(), (fee - platform) * 8_000 / 10_000, "idea gets 80% of the project share");
        assertEq(_owed(L.hook), fee);
    }

    // ───────────── payouts ─────────────

    function test_claimsGoToFixedAddresses() public {
        Launch memory L = _launch(400, IdeaKind.Hold);
        _swap(L, true, -1 ether, 1 ether);
        uint256 platformBefore = PLATFORM.balance;
        vm.startPrank(trader); // anyone can pay the gas
        L.hook.claimPlatform();
        L.hook.claimAgents();
        L.hook.claimTreasury();
        L.hook.claimIdea();
        vm.stopPrank();
        assertEq(PLATFORM.balance - platformBefore, 0.003 ether);
        assertEq(agents.balance, 0.0037 ether);
        assertEq(treasury.balance, 0.0037 ether);
        assertEq(L.idea.balance, 0.0296 ether);
        assertEq(MANAGER.balanceOf(address(L.hook), 0), 0);
        vm.expectRevert(GarageHook.NothingToClaim.selector);
        L.hook.claimAgents();
    }

    function test_mainTokenHasNoIdeaToPay() public {
        Launch memory L = _launch(300, IdeaKind.None);
        _swap(L, true, -1 ether, 1 ether);
        vm.expectRevert(GarageHook.NothingToClaim.selector);
        L.hook.claimIdea();
    }

    function test_onlyTreasuryChangesAddresses() public {
        Launch memory L = _launch(300, IdeaKind.None);
        vm.prank(trader);
        vm.expectRevert(GarageHook.NotTreasury.selector);
        L.hook.setAgents(trader);
        address newAgents = makeAddr("garage.newAgents");
        vm.prank(treasury);
        L.hook.setAgents(newAgents);
        assertEq(L.hook.agents(), newAgents);
    }

    /// A broken idea contract cannot stop trading or the other payouts.
    function test_brokenIdeaDoesNotBreakTrading() public {
        Launch memory L = _launch(400, IdeaKind.Broken);
        _swap(L, true, -1 ether, 1 ether);
        _swap(L, false, -int256(L.token.balanceOf(trader)), 0);
        assertEq(L.token.balanceOf(trader), 0);
        vm.expectRevert(GarageHook.TransferFailed.selector);
        L.hook.claimIdea();
        assertGt(L.hook.ideaAccrued(), 0, "idea money stays in the hook");
        L.hook.claimPlatform();
        L.hook.claimAgents();
        L.hook.claimTreasury();
    }

    // ───────────── use it or lose it ─────────────

    /// An idea that never collects its share: after a day the share buys back and burns the main token.
    function test_idleIdeaShareBurnsMainToken() public {
        Launch memory L = _launch(400, IdeaKind.Broken);
        _swap(L, true, -1 ether, 1 ether);
        uint256 share = L.hook.ideaAccrued();
        assertEq(share, 0.0296 ether);

        vm.expectRevert(GarageHook.TooEarly.selector);
        L.hook.burnIdleIdeaShare();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 supplyBefore = mainL.token.totalSupply();
        uint256 mainFeesBefore = mainL.hook.totalFees();
        vm.prank(trader); // anyone can trigger it
        L.hook.burnIdleIdeaShare();

        assertEq(L.hook.ideaAccrued(), 0);
        assertGt(L.hook.mainBurned(), 0);
        assertEq(mainL.token.totalSupply(), supplyBefore - L.hook.mainBurned(), "main tokens burned");
        assertEq(mainL.hook.totalFees() - mainFeesBefore, (share * 30 + 9_999) / 10_000, "the buyback paid Programmable's 0.3% only");
        assertEq(mainL.hook.boughtAndBurned(), L.hook.mainBurned());
        assertEq(MANAGER.balanceOf(address(L.hook), 0), _owed(L.hook), "hook still holds exactly what it owes");
    }

    /// act() collects the share, so a working idea never loses it.
    function test_actCollectsShareAndResetsTheClock() public {
        Launch memory L = _launch(400, IdeaKind.Hold);
        _swap(L, true, -1 ether, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        HoldIdea(payable(L.idea)).act();
        assertEq(L.idea.balance, 0.0296 ether);
        assertEq(L.hook.ideaAccrued(), 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectRevert(GarageHook.NothingToClaim.selector);
        L.hook.burnIdleIdeaShare();
        assertEq(L.hook.ideaTotal(), 0.0296 ether);
    }

    /// Anyone can send ETH to buy and burn the pool's token, at any price. Programmable's 0.3% is taken,
    /// the rest buys; not counted as a trade.
    function test_buyAndBurn() public {
        _swap(mainL, true, -1 ether, 1 ether);
        uint256 supplyBefore = mainL.token.totalSupply();
        uint256 feesBefore = mainL.hook.totalFees();
        uint256 platformBefore = mainL.hook.platformAccrued();
        uint256 agentsBefore = mainL.hook.agentsAccrued();
        uint256 treasuryBefore = mainL.hook.treasuryAccrued();
        uint256 swapsBefore = mainL.hook.stats().swapCount;

        uint256 managerEthBefore = address(MANAGER).balance;
        vm.prank(trader); // anyone can call
        uint256 burned = mainL.hook.buyAndBurn{value: 0.2 ether}();
        assertGt(burned, 0);
        assertEq(address(MANAGER).balance - managerEthBefore, 0.2 ether, "all the ETH went in: 0.3% kept as a claim, the rest bought");
        assertEq(mainL.token.totalSupply(), supplyBefore - burned, "burned");
        assertEq(mainL.hook.boughtAndBurned(), burned);
        assertEq(mainL.hook.platformAccrued() - platformBefore, 0.0006 ether, "Programmable got 0.3%");
        assertEq(mainL.hook.totalFees() - feesBefore, 0.0006 ether);
        assertEq(mainL.hook.agentsAccrued(), agentsBefore, "no project share on buybacks");
        assertEq(mainL.hook.treasuryAccrued(), treasuryBefore);
        assertEq(mainL.hook.stats().swapCount, swapsBefore, "not counted as a trade");
        assertEq(MANAGER.balanceOf(address(mainL.hook), 0), _owed(mainL.hook), "hook still holds exactly what it owes");
        assertEq(address(mainL.hook).balance, 0);

        mainL.hook.claimPlatform();
        vm.expectRevert(GarageHook.NothingToClaim.selector);
        mainL.hook.buyAndBurn();
    }

    function test_mainTokenCannotBurnItself() public {
        Launch memory L = _launch(300, IdeaKind.None);
        _swap(L, true, -1 ether, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(GarageHook.NothingToClaim.selector);
        L.hook.burnIdleIdeaShare();
    }

    // ───────────── idea toolkit ─────────────

    function test_ideaCanBuyBurnAndTakeDeposits() public {
        Launch memory L = _launch(400, IdeaKind.Trade);
        TradeIdea idea = TradeIdea(payable(L.idea));
        _swap(L, true, -5 ether, 5 ether);
        L.hook.claimIdea();
        uint256 eth = L.idea.balance;

        uint256 supplyBefore = L.token.totalSupply();
        uint256 burned = idea.buyAndBurn(eth / 2);
        assertEq(L.token.totalSupply(), supplyBefore - burned);

        uint256 mine = L.token.balanceOf(trader) / 3;
        vm.startPrank(trader);
        L.token.approve(L.idea, mine);
        assertEq(idea.deposit(mine), mine, "pulls tokens from the caller");
        vm.stopPrank();
        vm.prank(makeAddr("garage.stranger"));
        vm.expectRevert();
        idea.deposit(1);

        uint256 held = idea.tokenBalance();
        uint256 bought = idea.buyAndHold(eth / 4);
        assertGt(bought, 0);
        assertEq(idea.tokenBalance(), held + bought, "bought tokens stay in the idea");
    }

    function test_ideaClaimsItself() public {
        Launch memory L = _launch(400, IdeaKind.Hold);
        HoldIdea idea = HoldIdea(payable(L.idea));
        assertEq(idea.claim(), 0, "nothing yet, no revert");
        _swap(L, true, -1 ether, 1 ether);
        assertEq(idea.claim(), 0.0296 ether);
        assertEq(L.idea.balance, 0.0296 ether);
    }

    function test_lastBuyerIdeaUsesStats() public {
        Launch memory L = _launch(400, IdeaKind.LastBuyer);
        address alice = _wallet("garage.alice");
        _swap(L, true, -1 ether, 1 ether);
        _swapAs(alice, L, true, -1 ether, 1 ether);
        vm.expectRevert("not yet");
        LastBuyerIdea(payable(L.idea)).payout();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 before = alice.balance;
        LastBuyerIdea(payable(L.idea)).act(); // the hourly step pays out
        assertEq(alice.balance - before, 0.0592 ether, "the idea share of both buys");
    }

    // ───────────── stats ─────────────

    function test_statsTrackSwaps() public {
        Launch memory L = _launch(300, IdeaKind.None);
        vm.warp(vm.getBlockTimestamp() + 100);
        BalanceDelta d = _swap(L, true, -1 ether, 1 ether);
        _swap(L, false, -int256(L.token.balanceOf(trader) / 2), 0);
        GarageHook.PoolStats memory st = L.hook.stats();
        assertEq(st.swapCount, 2);
        assertEq(st.buyCount, 1);
        assertEq(st.lastBuyer, trader);
        assertEq(st.lastBuyAt, vm.getBlockTimestamp());
        assertEq(st.lastBuyEth, 0.97 ether, "ETH into the pool after the 3% fee");
        assertEq(st.lastBuyTokens, uint256(int256(d.amount1())));
        assertGt(st.sellVolumeEth, 0);
    }

    /// The idea contract's own buys pay the fee but are not market activity: no stats, no anti-sniper cap, and they
    /// do not count towards ending the anti-sniper phase.
    function test_ideaBuysAreNotMarketActivity() public {
        Launch memory L = _deploy(400, IdeaKind.Trade, 0); // the anti-sniper phase is still on
        _swap(L, true, -0.02 ether, 0.02 ether);
        GarageHook.PoolStats memory before = L.hook.stats();
        uint256 counted = L.hook.earlyBuys();
        uint256 platformBefore = L.hook.platformAccrued();

        address keeper = _wallet("garage.keeper");
        vm.deal(L.idea, 5 ether);
        vm.prank(keeper, keeper);
        uint256 bought = TradeIdea(payable(L.idea)).buyAndHold(1 ether);
        assertGt(bought, SUPPLY * 2 / 100, "an idea buy is not held to the 2% early cap of its caller");

        GarageHook.PoolStats memory st = L.hook.stats();
        assertEq(st.swapCount, before.swapCount, "not counted as a swap");
        assertEq(st.buyCount, before.buyCount, "not counted as a buy");
        assertEq(st.lastBuyer, trader, "the caller does not become the last buyer");
        assertEq(st.buyVolumeEth, before.buyVolumeEth);
        assertEq(L.hook.earlyBuys(), counted, "does not end the anti-sniper phase");
        assertEq(L.hook.earlyBuyRemaining(keeper), SUPPLY * 2 / 100, "nothing booked on the caller");
        assertGt(L.hook.platformAccrued(), platformBefore, "the fee is still paid");
    }

    // ───────────── anti-sniper ─────────────

    /// Until 30 buys of at least 0.01 ETH have happened, a wallet buys at most 2% of the supply in total.
    function test_earlyBuysCapPerWallet() public {
        Launch memory L = _deploy(300, IdeaKind.None, 0);
        uint256 cap = SUPPLY * 2 / 100;
        assertEq(L.hook.maxEarlyBuy(), cap);

        vm.expectRevert();
        _swap(L, true, int256(cap + 1), 10 ether);

        _swap(L, true, int256(cap * 75 / 100), 10 ether);
        vm.roll(vm.getBlockNumber() + 50); // time does not end the cap
        _swap(L, true, int256(cap * 20 / 100), 10 ether);
        assertEq(L.hook.earlyBuyRemaining(trader), cap - cap * 75 / 100 - cap * 20 / 100);
        vm.expectRevert();
        _swap(L, true, int256(cap * 10 / 100), 10 ether);
        assertEq(L.hook.earlyBuys(), 1, "the first buy (about 0.03 ETH) counts, the second (about 0.008 ETH) does not");

        // Dust buys are capped too, but they do not count: they cannot end the phase.
        address duster = _wallet("garage.duster");
        for (uint256 i; i < 30; i++) _swapAs(duster, L, true, -0.0001 ether, 0.0001 ether);
        assertEq(L.hook.earlyBuys(), 1, "dust does not count");

        // A 0.01 ETH buy counts: the fee is part of the 0.01.
        for (uint256 i; i < 28; i++) _swapAs(_wallet(string.concat("garage.buyer.", vm.toString(i))), L, true, -0.01 ether, 0.01 ether);
        assertEq(L.hook.earlyBuys(), 29);
        assertLt(L.hook.earlyBuyRemaining(trader), cap, "one counted buy to go: still capped");
        address last = _wallet("garage.buyer.last");
        _swapAs(last, L, true, -0.01 ether, 0.01 ether);
        assertEq(L.hook.earlyBuys(), 30);
        assertEq(L.hook.earlyBuyRemaining(trader), type(uint256).max, "the cap is over");
        _swap(L, true, int256(cap * 5), 50 ether);
    }

    /// The launch block and the two after it take at most 10 buys each (dust included; sells are free); from the
    /// third block on there is no per-block limit, only the wallet cap until 30 counted buys.
    function test_earlyBlockBuyLimit() public {
        Launch memory L = _deploy(300, IdeaKind.None, 0);
        for (uint256 b; b < 3; b++) {
            if (b > 0) vm.roll(vm.getBlockNumber() + 1);
            assertEq(L.hook.blockBuysRemaining(), 10);
            address w;
            for (uint256 i; i < 10; i++) {
                w = _wallet(string.concat("garage.block", vm.toString(b), ".buyer", vm.toString(i)));
                _swapAs(w, L, true, i == 0 ? -0.01 ether : -0.0001 ether, i == 0 ? 0.01 ether : 0.0001 ether); // dust counts too
            }
            assertEq(L.hook.blockBuysRemaining(), 0);
            vm.expectRevert();
            _swapAs(_wallet(string.concat("garage.block", vm.toString(b), ".eleventh")), L, true, -0.01 ether, 0.01 ether);
            vm.prank(w);
            L.token.approve(address(router), type(uint256).max);
            _swapAs(w, L, false, -int256(L.token.balanceOf(w)), 0); // a sell in a full block still works
        }
        vm.roll(vm.getBlockNumber() + 1); // block +3
        assertEq(L.hook.blockBuysRemaining(), type(uint256).max, "no per-block limit any more");
        for (uint256 i; i < 12; i++) _swapAs(_wallet(string.concat("garage.block3.buyer", vm.toString(i))), L, true, -0.01 ether, 0.01 ether);
        assertLt(L.hook.earlyBuys(), 30, "the wallet cap is still on");
        vm.expectRevert();
        _swap(L, true, int256(SUPPLY * 3 / 100), 10 ether);
    }

    /// The sniper's trick from the wild: one transaction creates fresh contracts that each buy 2%. Our cap is per
    /// signer (tx.origin), so every one of those buys counts for the sniper's own wallet: the second one exceeds 2%
    /// and the whole transaction reverts. One sub-contract works, and the signer, not the contract, is the buyer.
    function test_attack_subContractsAreOneBuyer() public {
        Launch memory L = _deploy(300, IdeaKind.None, 0);
        address eoa = _wallet("garage.sniper");
        Sniper sniper = new Sniper(router);

        vm.prank(eoa, eoa);
        sniper.strike{value: 0.03 ether}(L.key, 1, 0.03 ether); // about 1.3% of the supply
        assertGt(L.hook.earlyBought(eoa), 0, "the buy is booked on the signer");
        assertEq(L.hook.earlyBought(address(sniper)), 0, "not on the contract");
        assertEq(L.hook.stats().lastBuyer, eoa, "the signer is the buyer");
        uint256 booked = L.hook.earlyBought(eoa);

        vm.prank(eoa, eoa);
        vm.expectRevert();
        sniper.strike{value: 0.06 ether}(L.key, 2, 0.03 ether); // 2 x 1.3% on top: the second buy breaks the 2% cap
        assertEq(L.hook.earlyBought(eoa), booked, "nothing of the reverted transaction stuck");

        vm.prank(eoa, eoa);
        vm.expectRevert();
        sniper.strike{value: 0.1 ether}(L.key, 10, 0.01 ether); // ten smaller sub-buyers: the same wallet, the same cap
    }

    function test_sellsNotLimitedEarly() public {
        Launch memory L = _deploy(300, IdeaKind.None, 0);
        _swap(L, true, -0.02 ether, 0.02 ether);
        _swap(L, false, -int256(L.token.balanceOf(trader)), 0);
        assertEq(L.token.balanceOf(trader), 0);
    }

    function test_initialBuyIsNotCapped() public {
        Launch memory L = _deploy(300, IdeaKind.None, 1 ether); // about a third of the supply
        assertGt(L.init.initialBuyTokens(), SUPPLY * 2 / 100);
    }

    // ───────────── attacks ─────────────

    /// A launch with a hand-picked idea contract and payout addresses.
    function _deployWith(address idea, address agents_, address treasury_) internal returns (Launch memory L) {
        L.init = new GarageInitializer(MANAGER);
        L.token = new GarageToken("Test", "TEST", SUPPLY, address(L.init));
        L.idea = idea;
        address hookAddr = address(FLAGS | (uint160(0x5555 + launches++) << 144));
        deployCodeTo(
            "GarageHook.sol:GarageHook",
            abi.encode(MANAGER, address(L.token), address(L.init), idea, 400, agents_, treasury_, idea == address(0) ? address(0) : address(mainL.hook)),
            hookAddr
        );
        L.hook = GarageHook(payable(hookAddr));
        L.key = L.hook.poolKey();
        L.init.initialize(hookAddr, START_TICK);
        vm.prank(trader);
        L.token.approve(address(router), type(uint256).max);
        _endEarlyPhase(L.hook);
    }

    /// An idea that re-enters the hook from its receive() is paid exactly once, and the hook stays solvent.
    function test_attack_reentrantIdeaIsPaidOnce() public {
        ReentrantIdea idea = new ReentrantIdea();
        Launch memory L = _deployWith(address(idea), agents, treasury);
        idea.setHook(L.hook);
        _swap(L, true, -1 ether, 1 ether);
        uint256 share = L.hook.ideaAccrued();

        idea.act();
        assertEq(idea.received(), share, "paid exactly its share");
        assertEq(idea.reentered(), 0, "no second payout, no idle burn from inside the payout");
        assertEq(L.hook.ideaAccrued(), 0);
        assertGt(L.hook.boughtAndBurned(), 0, "its nested buyAndBurn went through on its own money");
        assertEq(MANAGER.balanceOf(address(L.hook), 0), _owed(L.hook), "hook still holds exactly what it owes");
        assertEq(address(L.hook).balance, 0);
    }

    /// A payout address that refuses ETH blocks only its own claim: trading and the other payouts go on.
    function test_attack_rejectingRecipientBlocksOnlyItself() public {
        address rejecting = address(new RejectingWallet());
        Launch memory L = _deployWith(address(0), rejecting, treasury);
        _swap(L, true, -1 ether, 1 ether);
        vm.expectRevert(GarageHook.TransferFailed.selector);
        L.hook.claimAgents();
        L.hook.claimTreasury();
        L.hook.claimPlatform();
        _swap(L, false, -int256(L.token.balanceOf(trader) / 2), 0);
        _swap(L, true, -0.5 ether, 0.5 ether);
        assertGt(L.hook.agentsAccrued(), 0, "the agents' share waits for a working address");
        vm.prank(treasury);
        L.hook.setAgents(agents);
        L.hook.claimAgents();
        assertEq(MANAGER.balanceOf(address(L.hook), 0), _owed(L.hook));
    }

    /// Third-party liquidity and donations to the pool do not touch the hook's accounting or skip its fee.
    function test_attack_thirdPartyLiquidityAndDonations() public {
        Launch memory L = mainL;
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(MANAGER);
        PoolDonateTest donor = new PoolDonateTest(MANAGER);
        address stranger = _wallet("garage.stranger");
        // ETH-only liquidity above the current price, and liquidity around it after a buy.
        vm.prank(stranger);
        lp.modifyLiquidity{value: 5 ether}(L.key, ModifyLiquidityParams(START_TICK + 60, START_TICK + 6000, 1e18, 0), "");
        _swap(L, true, -1 ether, 1 ether);
        uint256 feesBefore = L.hook.totalFees();
        _swap(L, false, -int256(L.token.balanceOf(trader) / 3), 0);
        _swap(L, true, -0.3 ether, 0.3 ether);
        assertGt(L.hook.totalFees(), feesBefore, "trades through the extra liquidity still pay");
        vm.prank(stranger);
        donor.donate{value: 0.1 ether}(L.key, 0.1 ether, 0, "");
        assertEq(MANAGER.balanceOf(address(L.hook), 0), _owed(L.hook), "hook still holds exactly what it owes");
        L.hook.claimAgents();
        L.hook.claimTreasury();
        L.hook.claimPlatform();
        assertEq(MANAGER.balanceOf(address(L.hook), 0), 0);
    }

    /// Dust trades either fail or pay at least 1 wei: rounding never lets a trade through for free.
    function test_attack_dustTradesPay() public {
        Launch memory L = mainL;
        _swap(L, true, -0.1 ether, 0.1 ether); // some tokens to sell
        for (uint256 i = 1; i <= 30; i++) {
            for (uint256 kind; kind < 4; kind++) {
                bool buy = kind < 2;
                int256 amount = kind % 2 == 0 ? -int256(i) : int256(i);
                uint256 fees = L.hook.totalFees();
                vm.prank(trader, trader);
                try router.swap{value: buy ? 1 ether : 0}(
                    L.key, SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, ""
                ) returns (BalanceDelta d) {
                    if (d.amount0() != 0) assertGt(L.hook.totalFees(), fees, "a trade that moved ETH paid a fee");
                } catch {}
            }
        }
        assertEq(MANAGER.balanceOf(address(L.hook), 0), _owed(L.hook));
    }

    /// Router settings and hook data do not change the fee.
    function test_attack_routerSettingsDoNotSkipFee() public {
        Launch memory L = mainL;
        PoolSwapTest.TestSettings memory claims = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        uint256 pa = L.hook.platformAccrued();
        uint256 fees = L.hook.totalFees();
        vm.prank(trader, trader);
        router.swap{value: 1 ether}(L.key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), claims, hex"deadbeef");
        assertEq(L.hook.totalFees() - fees, 0.03 ether, "3% of the gross, as always");
        assertEq(L.hook.platformAccrued() - pa, 0.003 ether);
    }

    /// The early-block cap also holds for exact-input buys.
    function test_attack_earlyCapExactInput() public {
        Launch memory L = _deploy(300, IdeaKind.None, 0);
        vm.expectRevert();
        _swap(L, true, -1 ether, 1 ether); // about a third of the supply
        _swap(L, true, -0.01 ether, 0.01 ether);
    }

    // ───────────── fair randomness ─────────────

    /// A ticket's number does not exist when the ticket is taken, then is the same for every caller.
    function test_fairRandomRecentBlock() public {
        RandomIdea idea = new RandomIdea(MANAGER, address(0xBEEF));
        uint256 b = vm.getBlockNumber();
        idea.commit();
        assertEq(idea.ticket(), b + 1);
        (bool ready,) = idea.reveal(7);
        assertFalse(ready, "the ticket's block does not exist yet");

        vm.roll(b + 1);
        (ready,) = idea.reveal(7);
        assertFalse(ready, "still the ticket's own block");

        bytes32 h = keccak256("the ticket block");
        vm.setBlockhash(b + 1, h);
        vm.roll(b + 5);
        (bool r1, uint256 v1) = idea.reveal(7);
        vm.prank(makeAddr("garage.someone-else"));
        (bool r2, uint256 v2) = idea.reveal(7);
        assertTrue(r1 && r2);
        assertEq(v1, uint256(keccak256(abi.encode(h, uint256(7), address(idea)))));
        assertEq(v1, v2, "whoever asks gets the same number");
        (, uint256 v3) = idea.reveal(8);
        assertTrue(v3 != v1, "the salt separates draws");
    }

    /// Older than 256 blocks: the hash comes from the EIP-2935 history contract; older than 8191 blocks: not ready.
    function test_fairRandomOldBlocks() public {
        RandomIdea idea = new RandomIdea(MANAGER, address(0xBEEF));
        uint256 b = vm.getBlockNumber();
        (bool ok, bytes memory out) = address(0x0000F90827F1C53a10cb7A02335B175320002935).staticcall(abi.encode(b - 1000));
        assertTrue(ok && out.length == 32, "history contract answers on mainnet");
        bytes32 h = abi.decode(out, (bytes32));
        assertTrue(h != bytes32(0));
        (bool ready, uint256 v) = idea.revealAt(b - 1000, 1);
        assertTrue(ready);
        assertEq(v, uint256(keccak256(abi.encode(h, uint256(1), address(idea)))));

        (ready, v) = idea.revealAt(b - 9000, 1);
        assertFalse(ready, "older than the history window");
        assertEq(v, 0);
    }
}
