// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {GarageHook} from "../src/GarageHook.sol";
import {GarageInitializer} from "../src/GarageInitializer.sol";
import {GarageToken} from "../src/GarageToken.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Evidence for Programmable: 0.3% (30 bps) of the gross native amount on every trade, through alternate routers
/// (the v4 test router and the mainnet Universal Router), on the initial buy and on the hooks' own buybacks;
/// credited to PLATFORM_RECIPIENT and paid out only there. Through Programmable's own router (the mainnet contract,
/// the route it uses: TRANSFER of 30 bps to the recipient, V4_SWAP, SWEEP) the router pays the 30 bps and the hook
/// charges only the project share: the platform fee is paid exactly once.
/// Each scenario logs evidence.<scenario>.{grossNative,expectedCeil30bps,platformAccruedDelta}.
contract PlatformFeeForkTest is Test {
    using stdStorage for StdStorage;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IUniversalRouter constant UR = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    address constant PROGRAMMABLE_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C; // programmable.market's router
    IUniversalRouter constant PR = IUniversalRouter(PROGRAMMABLE_ROUTER);
    address constant RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint256 constant FEE_BPS = 300;
    uint256 constant MAIN_FEE_BPS = 300;
    uint256 constant INITIAL_BUY = 0.01 ether;
    int24 constant START_TICK = 200_280;
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    GarageHook mainHook;
    GarageHook hook; // the launched token's hook (the main token: same as mainHook)
    GarageToken token;
    PoolKey key;
    PoolSwapTest swapRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    address trader = makeAddr("garage.platform-fee.trader");
    uint160 deployed;
    uint256 initialBuyFee;

    // Swap parameters of the deployed mainnet Universal Router (v4-periphery without minHopPriceX36)
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    function setUp() public {
        vm.createSelectFork("ethereum");
        vm.etch(trader, ""); // no EIP-7702 code on the test wallet
        vm.deal(address(this), 10 ether);
        hook = _deploy(FEE_BPS, address(0), INITIAL_BUY);
        mainHook = hook;
        token = GarageToken(hook.token());
        key = hook.poolKey();
        _endEarlyPhase(hook); // past the anti-sniper window
        swapRouter = new PoolSwapTest(MANAGER);
        vm.deal(trader, 100 ether);
        vm.prank(trader);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _deploy(uint256 feeBps, address mainHook_, uint256 initialBuy) internal returns (GarageHook h) {
        GarageInitializer init = new GarageInitializer(MANAGER);
        GarageToken t = new GarageToken("Test", "TEST", 1_000_000_000 ether, address(init));
        address idea = address(0);
        address at = address(FLAGS | (uint160(0x6a6a + deployed++) << 144));
        deployCodeTo(
            "GarageHook.sol:GarageHook",
            abi.encode(MANAGER, address(t), address(init), idea, feeBps, makeAddr("garage.agents"), makeAddr("garage.treasury"), mainHook_),
            at
        );
        h = GarageHook(payable(at));
        uint256 pa = h.platformAccrued();
        init.initialize{value: initialBuy}(at, START_TICK);
        if (initialBuy > 0) initialBuyFee = h.platformAccrued() - pa;
    }

    function _endEarlyPhase(GarageHook h) internal {
        vm.roll(vm.getBlockNumber() + h.EARLY_BLOCKS()); // past the window: no per-block limit, no wallet cap
    }

    function _ceil30(uint256 gross) internal pure returns (uint256) {
        return (gross * 30 + 9_999) / 10_000;
    }

    function _evidence(string memory name, uint256 gross, uint256 accruedDelta) internal {
        emit log_named_uint(string.concat("evidence.", name, ".grossNative"), gross);
        emit log_named_uint(string.concat("evidence.", name, ".expectedCeil30bps"), _ceil30(gross));
        emit log_named_uint(string.concat("evidence.", name, ".platformAccruedDelta"), accruedDelta);
        assertEq(accruedDelta, _ceil30(gross), string.concat(name, ": exactly 30 bps of gross native, rounded up"));
    }

    function _projectAccrued() internal view returns (uint256) {
        return hook.agentsAccrued() + hook.treasuryAccrued() + hook.ideaAccrued();
    }

    /// A trade through Programmable's own router: the router paid the recipient, the hook accrued no platform fee
    /// and exactly the project share.
    function _routeEvidence(string memory name, uint256 gross, uint256 routerPaid, uint256 platformDelta, uint256 projectDelta, uint256 expectedProject)
        internal
    {
        emit log_named_uint(string.concat("evidence.", name, ".grossNative"), gross);
        emit log_named_uint(string.concat("evidence.", name, ".expectedCeil30bps"), _ceil30(gross));
        emit log_named_uint(string.concat("evidence.", name, ".expectedFloor30bps"), gross * 30 / 10_000);
        emit log_named_uint(string.concat("evidence.", name, ".routerPaidToRecipient"), routerPaid);
        emit log_named_uint(string.concat("evidence.", name, ".platformAccruedDelta"), platformDelta);
        emit log_named_uint(string.concat("evidence.", name, ".projectFeeDelta"), projectDelta);
        assertEq(platformDelta, 0, string.concat(name, ": the hook accrues no platform fee on Programmable's route"));
        assertEq(routerPaid, gross * 30 / 10_000, string.concat(name, ": the router paid Programmable 30 bps, floored once"));
        assertEq(projectDelta, expectedProject, string.concat(name, ": the hook charged exactly the project share"));
    }

    function _swap(bool buy, int256 amountSpecified, uint256 value) internal returns (BalanceDelta d) {
        vm.prank(trader, trader);
        d = swapRouter.swap{value: value}(
            key, SwapParams(buy, amountSpecified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, ""
        );
    }

    function test_initialBuy() public {
        _evidence("initial-buy", INITIAL_BUY, initialBuyFee);
    }

    function test_alternateRouterAllSwapTypes() public {
        uint256 pa = hook.platformAccrued();
        _swap(true, -int256(0.2 ether), 0.2 ether); // buy, exact input: gross = input
        _evidence("buy-exact-in", 0.2 ether, hook.platformAccrued() - pa);

        pa = hook.platformAccrued();
        BalanceDelta d = _swap(true, 1_000_000 ether, 1 ether); // buy, exact output: gross = everything paid
        _evidence("buy-exact-out", uint256(-int256(d.amount0())), hook.platformAccrued() - pa);

        pa = hook.platformAccrued();
        uint256 claims = MANAGER.balanceOf(address(hook), 0);
        d = _swap(false, -int256(2_000_000 ether), 0); // sell, exact input: gross = pool output before fees
        uint256 fee = MANAGER.balanceOf(address(hook), 0) - claims;
        _evidence("sell-exact-in", uint256(int256(d.amount0())) + fee, hook.platformAccrued() - pa);

        pa = hook.platformAccrued();
        claims = MANAGER.balanceOf(address(hook), 0);
        d = _swap(false, int256(0.01 ether), 0); // sell, exact output: gross = pool output before fees
        fee = MANAGER.balanceOf(address(hook), 0) - claims;
        _evidence("sell-exact-out", uint256(int256(d.amount0())) + fee, hook.platformAccrued() - pa);
    }

    function test_universalRouterBuy() public {
        ExactInputSingleParams memory p = ExactInputSingleParams(key, true, uint128(0.05 ether), 1, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(address(0), uint256(0.05 ether)); // SETTLE_ALL ETH
        params[2] = abi.encode(address(token), uint256(1)); // TAKE_ALL token
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", params);
        uint256 pa = hook.platformAccrued();
        vm.prank(trader, trader);
        UR.execute{value: 0.05 ether}(hex"10", inputs, vm.getBlockTimestamp() + 600);
        assertGt(token.balanceOf(trader), 0, "Universal Router buy delivered tokens");
        _evidence("universal-router-buy-exact-in", 0.05 ether, hook.platformAccrued() - pa);
    }

    /// A buy the way programmable.market routes it: TRANSFER of 30 bps of the funded ETH to Programmable's recipient,
    /// then V4_SWAP (SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL) with the rest, then SWEEP. One platform charge.
    function test_programmableRouteBuy() public {
        uint256 value = 0.1 ether;
        uint256 portion = value * 30 / 10_000;
        ExactInputSingleParams memory p = ExactInputSingleParams(key, true, uint128(value - portion), 1, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(address(0), value - portion); // SETTLE_ALL ETH
        params[2] = abi.encode(address(token), uint256(1)); // TAKE_ALL token
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(address(0), RECIPIENT, portion); // TRANSFER: Programmable's 0.3%, by the router
        inputs[1] = abi.encode(hex"060c0f", params); // V4_SWAP
        inputs[2] = abi.encode(address(0), address(1), uint256(0)); // SWEEP leftover ETH to the trader
        uint256 pa = hook.platformAccrued();
        uint256 project = _projectAccrued();
        uint256 before = RECIPIENT.balance;
        vm.prank(trader, trader);
        PR.execute{value: value}(hex"051004", inputs, vm.getBlockTimestamp() + 600);
        assertGt(token.balanceOf(trader), 0, "Programmable's router delivered tokens");
        (,, uint256 expectedProject) = hook.quoteFeeFor(PROGRAMMABLE_ROUTER, value - portion, false);
        _routeEvidence("programmable-route-buy", value, RECIPIENT.balance - before, hook.platformAccrued() - pa, _projectAccrued() - project, expectedProject);
    }

    /// A sell the same way: V4_SWAP (SWAP_EXACT_IN_SINGLE token -> ETH, SETTLE from the router, TAKE the ETH to the
    /// router), PAY_PORTION of 30 bps to Programmable's recipient, SWEEP the rest to the trader. One platform charge.
    function test_programmableRouteSell() public {
        _swap(true, -int256(0.2 ether), 0.2 ether); // tokens to sell, bought through the test router
        uint256 amount = token.balanceOf(trader) / 2;
        vm.prank(trader);
        token.transfer(PROGRAMMABLE_ROUTER, amount); // the route settles the tokens from the router's balance
        ExactInputSingleParams memory p = ExactInputSingleParams(key, false, uint128(amount), 1, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(address(token), amount, false); // SETTLE token, paid by the router
        params[2] = abi.encode(address(0), address(2), uint256(0)); // TAKE all the ETH to the router
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(hex"060b0e", params); // V4_SWAP
        inputs[1] = abi.encode(address(0), RECIPIENT, uint256(30)); // PAY_PORTION: Programmable's 0.3% of the ETH out
        inputs[2] = abi.encode(address(0), address(1), uint256(0)); // SWEEP the rest to the trader
        uint256 pa = hook.platformAccrued();
        uint256 project = _projectAccrued();
        uint256 before = RECIPIENT.balance;
        uint256 traderBefore = trader.balance;
        vm.prank(trader, trader);
        PR.execute(hex"100604", inputs, vm.getBlockTimestamp() + 600);
        uint256 paid = RECIPIENT.balance - before;
        uint256 out = trader.balance - traderBefore + paid; // ETH the router took from the pool, after the hook's share
        uint256 projectDelta = _projectAccrued() - project;
        (,, uint256 expectedProject) = hook.quoteFeeFor(PROGRAMMABLE_ROUTER, out + projectDelta, false);
        _routeEvidence("programmable-route-sell", out, paid, hook.platformAccrued() - pa, projectDelta, expectedProject);
    }

    /// The hook's own buyback (buyAndBurn, callable by anyone) pays the 0.3% like any trade.
    function test_ownBuyback() public {
        uint256 pa = hook.platformAccrued();
        uint256 supply = token.totalSupply();
        vm.prank(trader);
        hook.buyAndBurn{value: 0.1 ether}();
        assertLt(token.totalSupply(), supply, "bought tokens were burned");
        _evidence("own-buyback", 0.1 ether, hook.platformAccrued() - pa);
    }

    function test_claimPaysOnlyTheRecipient() public {
        _swap(true, -int256(0.3 ether), 0.3 ether);
        uint256 owed = hook.platformAccrued();
        uint256 before = RECIPIENT.balance;
        vm.prank(makeAddr("garage.platform-fee.anyone"));
        hook.claimPlatform();
        emit log_named_uint("evidence.claim.platformAccruedBefore", owed);
        emit log_named_uint("evidence.claim.recipientBalanceDelta", RECIPIENT.balance - before);
        emit log_named_address("evidence.claim.recipient", RECIPIENT);
        assertEq(RECIPIENT.balance - before, owed, "the whole platform balance is credited to the recipient");
        assertEq(hook.platformAccrued(), 0);
    }
}
