// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {GarageInitializer} from "../src/GarageInitializer.sol";
import {LaunchGuardToken} from "../src/LaunchGuardToken.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MainBurner} from "../src/MainBurner.sol";

interface INative30Kernel {
    function token() external view returns (address);
    function feeVault() external view returns (address);
    function module() external view returns (address);
    function initialSqrtPriceX96() external view returns (uint160);
    function creatorBuyFeeBps() external view returns (uint16);
    function creatorSellFeeBps() external view returns (uint16);
}

interface INative30Vault {
    function platformAccrued() external view returns (uint256);
    function creatorAccrued() external view returns (uint256);
    function creatorRecipient() external view returns (address);
    function claimPlatform() external returns (uint256);
    function claimCreator() external returns (uint256);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// EthereumNative30HookV3.PoolConfig, field for field.
struct Native30PoolConfig {
    address token;
    uint24 lpFee;
    int24 tickSpacing;
    uint160 initialSqrtPriceX96;
    address initializer;
    address creatorFeeRecipient;
    uint16 creatorBuyFeeBps;
    uint16 creatorSellFeeBps;
    address module;
    uint24 maxModuleLpFeePips;
}

/// Swap parameters of the Universal Router deployed on mainnet (v4-periphery without minHopPriceX36).
struct UrExactInputSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// The main token on Programmable's EthereumNative30HookV3, the way the launch graph deploys it: initializer, token,
/// splitter, the kernel (Programmable's exact reviewed bytecode, no module, at an address with its hook flags), burner;
/// then initialize(kernel, startTick) with the launch buy. On a mainnet fork. Shared by the behaviour tests and the
/// platform fee evidence.
abstract contract Native30Base is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IUniversalRouter constant UR = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IUniversalRouter constant PROGRAMMABLE_ROUTER = IUniversalRouter(0xd92A36B0000531EF3063dEd4De20A0783308446C);
    uint256 constant SUPPLY = 1_000_000_000 ether;
    int24 constant START_TICK = 200_280; // ~2 ETH FDV
    uint16 constant CREATOR_BPS = 270; // 3% in all with Programmable's 0.3%
    uint160 constant FLAGS = 0x20CC; // beforeInitialize, beforeSwap, afterSwap, before/afterSwapReturnDelta

    PoolSwapTest router;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    address agents = makeAddr("garage.n30.agents");
    address treasury = makeAddr("garage.n30.treasury");
    address trader;

    GarageInitializer init;
    LaunchGuardToken token;
    FeeSplitter splitter;
    address kernel;
    INative30Vault vault;
    MainBurner burner;
    PoolKey key;

    function setUp() public virtual {
        vm.createSelectFork("ethereum");
        router = new PoolSwapTest(MANAGER);
        trader = _wallet("garage.n30.trader");
    }

    // ───────────── launch ─────────────

    function _launch(uint256 initialBuy) internal {
        init = new GarageInitializer(MANAGER);
        token = new LaunchGuardToken("KEYLESS", "KEYLESS", SUPPLY, address(init), address(0));
        splitter = new FeeSplitter(address(0), address(0), agents, treasury);
        kernel = _deployKernel(
            Native30PoolConfig({
                token: address(token),
                lpFee: 0,
                tickSpacing: 60,
                initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(START_TICK),
                initializer: address(init),
                creatorFeeRecipient: address(splitter),
                creatorBuyFeeBps: CREATOR_BPS,
                creatorSellFeeBps: CREATOR_BPS,
                module: address(0),
                maxModuleLpFeePips: 0
            })
        );
        vault = INative30Vault(INative30Kernel(kernel).feeVault());
        burner = new MainBurner(kernel, address(token));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 60, IHooks(kernel));
        vm.deal(address(this), 10 ether);
        init.initialize{value: initialBuy}(kernel, START_TICK);
    }

    /// An agent token: its idea contract (deployed from `ideaCode`, constructor (manager, initializer)), its token, the
    /// splitter (80% idea, 10% agents, 10% treasury; idle idea shares burn the main token through `burner`) and
    /// Programmable's kernel with the agent's total fee `feeBps`. No launch buy, as for agent tokens. The main token
    /// must be launched first (_launch).
    struct AgentLaunch {
        GarageInitializer init;
        address idea;
        LaunchGuardToken token;
        FeeSplitter splitter;
        address kernel;
        INative30Vault vault;
        PoolKey key;
    }

    function _launchAgent(bytes memory ideaCode, uint16 feeBps) internal returns (AgentLaunch memory a) {
        a.init = new GarageInitializer(MANAGER);
        if (ideaCode.length != 0) {
            bytes memory initCode = abi.encodePacked(ideaCode, abi.encode(MANAGER, address(a.init)));
            address at;
            assembly {
                at := create(0, add(initCode, 0x20), mload(initCode))
            }
            require(at != address(0), "idea deployment failed");
            a.idea = at;
        }
        return _launchAgentWith(a, feeBps);
    }

    /// The same with an idea contract deployed by the test itself (a.init and a.idea set by the caller).
    function _launchAgentWith(AgentLaunch memory a, uint16 feeBps) internal returns (AgentLaunch memory) {
        a.token = new LaunchGuardToken("Agent", "AGENT", SUPPLY, address(a.init), a.idea);
        a.splitter = new FeeSplitter(a.idea, address(burner), agents, treasury);
        a.kernel = _deployKernel(
            Native30PoolConfig({
                token: address(a.token),
                lpFee: 0,
                tickSpacing: 60,
                initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(START_TICK),
                initializer: address(a.init),
                creatorFeeRecipient: address(a.splitter),
                creatorBuyFeeBps: feeBps - 30,
                creatorSellFeeBps: feeBps - 30,
                module: address(0),
                maxModuleLpFeePips: 0
            })
        );
        a.vault = INative30Vault(INative30Kernel(a.kernel).feeVault());
        a.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(a.token)), 0, 60, IHooks(a.kernel));
        a.init.initialize(a.kernel, START_TICK);
        return a;
    }

    function _agentSwapAs(AgentLaunch memory a, address who, bool buy, int256 amountSpecified, uint256 value) internal returns (BalanceDelta d) {
        vm.prank(who, who);
        d = router.swap{value: value}(
            a.key, SwapParams(buy, amountSpecified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, ""
        );
    }

    /// Programmable's exact reviewed creation bytecode, deployed with CREATE2 at an address carrying its hook flags.
    function _deployKernel(Native30PoolConfig memory c) internal returns (address at) {
        bytes memory creation = vm.parseJsonBytes(vm.readFile("vendor/native30/EthereumNative30HookV3.artifact.json"), ".creationBytecode");
        bytes memory initCode = abi.encodePacked(creation, abi.encode(MANAGER, c));
        bytes32 codeHash = keccak256(initCode);
        bytes32 salt;
        for (uint256 i;; i++) {
            salt = bytes32(i);
            at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, codeHash)))));
            if (uint160(at) & 0x3FFF == FLAGS) break;
        }
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && at.code.length > 0, "kernel deployment failed");
    }

    function _wallet(string memory label) internal returns (address w) {
        w = makeAddr(label);
        vm.etch(w, ""); // no EIP-7702 code on test wallets
        vm.deal(w, 100 ether);
    }

    function _swapAs(address who, bool buy, int256 amountSpecified, uint256 value) internal returns (BalanceDelta d) {
        vm.prank(who, who);
        d = router.swap{value: value}(
            key, SwapParams(buy, amountSpecified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, ""
        );
    }

    function _approveRouter(address who) internal {
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
    }

    function _ceil(uint256 gross, uint256 bps) internal pure returns (uint256) {
        return (gross * bps + 9_999) / 10_000;
    }

    /// One trade's fee in the vault: exactly one Programmable charge (30 bps of gross, rounded up), the rest creator.
    function _assertOneCharge(string memory what, uint256 gross, uint256 platformDelta, uint256 creatorDelta) internal pure {
        _assertOneCharge(what, gross, platformDelta, creatorDelta, 300);
    }

    /// The same for a pool whose total fee is `totalBps` (an agent token: 1-4%).
    function _assertOneCharge(string memory what, uint256 gross, uint256 platformDelta, uint256 creatorDelta, uint256 totalBps)
        internal
        pure
    {
        assertEq(platformDelta, _ceil(gross, 30), string.concat(what, ": one 30 bps platform charge"));
        assertEq(platformDelta + creatorDelta, _ceil(gross, totalBps), string.concat(what, ": the pool's fee in all"));
    }

    function _vaultBalances() internal view returns (uint256, uint256) {
        return (vault.platformAccrued(), vault.creatorAccrued());
    }

    /// A buy and a sell through a router with only the swap: no payment command to anyone besides the pool.
    function _bareBuy(IUniversalRouter r, uint256 amountIn) internal {
        UrExactInputSingle memory p = UrExactInputSingle(key, true, uint128(amountIn), 1, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(address(0), amountIn); // SETTLE_ALL ETH
        params[2] = abi.encode(address(token), uint256(1)); // TAKE_ALL token, to the caller
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", params);
        vm.prank(trader, trader);
        r.execute{value: amountIn}(hex"10", inputs, block.timestamp + 600); // V4_SWAP only
    }

    function _bareSell(IUniversalRouter r, uint256 amount) internal {
        vm.prank(trader);
        token.transfer(address(r), amount); // the router settles from its own balance
        UrExactInputSingle memory p = UrExactInputSingle(key, false, uint128(amount), 1, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(address(token), amount, false); // SETTLE token, paid by the router
        params[2] = abi.encode(address(0), uint256(1)); // TAKE_ALL ETH, to the caller
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060b0f", params);
        vm.prank(trader, trader);
        r.execute(hex"10", inputs, block.timestamp + 600); // V4_SWAP only
    }
}
