// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {GarageInitializer} from "../../src/GarageInitializer.sol";
import {LaunchGuardToken} from "../../src/LaunchGuardToken.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {MainBurner} from "../../src/MainBurner.sol";

interface IIdeaAct {
    function act() external;
}

/// @notice Programmable's EthereumNative30HookV3 and its fee vault, as the tests read them.
interface INative30Kernel {
    function feeVault() external view returns (address);
}

interface INative30Vault {
    function platformAccrued() external view returns (uint256);
    function creatorAccrued() external view returns (uint256);
    function claimCreator() external returns (uint256);
    function PLATFORM_RECIPIENT() external view returns (address);
}

/// @notice Common base of the checker's tests: a fork of Ethereum mainnet and two launches deployed the way the
///         Programmable factory deploys them, both on Programmable's EthereumNative30HookV3 (its exact reviewed
///         bytecode): the garage's main token, and the agent's token with the idea contract from
///         src/ideas/agent/Idea.sol. Every trade's fee lands in the kernel's fee vault; the garage's part goes to the
///         FeeSplitter, which pays the idea 80% of it. The agent's test inherits this base and uses the helpers below.
abstract contract GarageTestBase is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    int24 internal constant START_TICK = 200_280; // about 2 ETH FDV
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address private constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 private constant FLAGS = 0x20CC; // the kernel's hook flags

    GarageInitializer internal initializer;
    address internal hook; // the agent token's kernel
    INative30Vault internal feeVault; // its fee vault
    FeeSplitter internal splitter; // pays the idea its share
    PoolSwapTest internal router;
    LaunchGuardToken internal token;
    PoolKey internal key;
    PoolId internal poolId;
    address payable internal idea;

    address internal agents;
    address internal treasury;
    LaunchGuardToken internal mainToken;
    MainBurner internal mainBurner;
    uint256 private _wallets;

    // Everyone the test knows: its wallets, the garage, the pools and Programmable. Money may move between them;
    // money that reaches anyone else went to an address the test never gave out (a hard-coded destination).
    address[] private _known;
    uint256 private _ethBaseline;
    uint256 private _tokenBaseline;

    struct KernelConfig {
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

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("FORK_URL"), vm.envUint("FORK_BLOCK"));
        agents = newWallet("garage.agents");
        treasury = newWallet("garage.treasury");
        router = new PoolSwapTest(MANAGER);

        // The garage's main token: idea shares left unclaimed for a day buy it back and burn it.
        GarageInitializer mainInit = new GarageInitializer(MANAGER);
        mainToken = new LaunchGuardToken("Main", "MAIN", SUPPLY, address(mainInit), address(0));
        FeeSplitter mainSplitter = new FeeSplitter(address(0), address(0), agents, treasury);
        address mainHook = _deployKernel(address(mainToken), address(mainInit), address(mainSplitter), 300);
        mainBurner = new MainBurner(MANAGER, mainHook, address(mainToken));
        mainInit.initialize(mainHook, START_TICK);

        // The agent's token, launched the way the Programmable factory does it.
        initializer = new GarageInitializer(MANAGER);
        idea = payable(deployCode("Idea.sol:Idea", abi.encode(MANAGER, address(initializer))));
        token = new LaunchGuardToken(vm.envString("IDEA_NAME"), vm.envString("IDEA_SYMBOL"), SUPPLY, address(initializer), idea);
        splitter = new FeeSplitter(idea, address(mainBurner), agents, treasury);
        hook = _deployKernel(address(token), address(initializer), address(splitter), uint16(vm.envUint("IDEA_FEE_BPS")));
        feeVault = INative30Vault(INative30Kernel(hook).feeVault());
        initializer.initialize(hook, START_TICK);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 60, IHooks(hook));
        poolId = key.toId();

        address[16] memory system = [
            address(this), DEFAULT_SENDER, idea, hook, address(feeVault), address(splitter), mainHook,
            INative30Kernel(mainHook).feeVault(), address(mainSplitter), address(mainBurner), address(MANAGER),
            address(router), address(initializer), address(mainInit), feeVault.PLATFORM_RECIPIENT(), address(0xdEaD)
        ];
        for (uint256 i; i < system.length; i++) _known.push(system[i]);
        _known.push(address(token));
        _known.push(address(mainToken));
        _known.push(address(0));
        // Idea tests start after the anti-sniper window (the launch block and the two after it).
        vm.roll(vm.getBlockNumber() + token.EARLY_BLOCKS());
    }

    /// @dev Programmable's exact reviewed kernel (vendor/native30), at a CREATE2 address carrying its hook flags.
    function _deployKernel(address token_, address init_, address recipient, uint16 feeBps) private returns (address at) {
        bytes memory creation = vm.parseJsonBytes(vm.readFile("vendor/native30/EthereumNative30HookV3.artifact.json"), ".creationBytecode");
        KernelConfig memory c = KernelConfig(token_, 0, 60, TickMath.getSqrtPriceAtTick(START_TICK), init_, recipient, feeBps - 30, feeBps - 30, address(0), 0);
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

    // ───────────── Helpers ─────────────

    /// @notice A new clean wallet with 100 ETH.
    function newWallet(string memory label) internal returns (address w) {
        w = makeAddr(string.concat(label, ".", vm.toString(++_wallets)));
        vm.etch(w, ""); // well-known addresses can have EIP-7702 code on mainnet
        vm.deal(w, 100 ether);
        _known.push(w);
    }

    /// @notice Buy the token for `eth` as `who` (msg.sender and tx.origin). Returns the tokens received.
    function buy(address who, uint256 eth) internal returns (uint256 tokens) {
        vm.prank(who, who);
        BalanceDelta d = router.swap{value: eth}(
            key, SwapParams(true, -int256(eth), TickMath.MIN_SQRT_PRICE + 1), _settings(), ""
        );
        tokens = uint256(int256(d.amount1()));
    }

    /// @notice Sell `tokens` as `who`. Returns the ETH received.
    function sell(address who, uint256 tokens) internal returns (uint256 eth) {
        vm.startPrank(who, who);
        token.approve(address(router), tokens);
        BalanceDelta d = router.swap(
            key, SwapParams(false, -int256(tokens), TickMath.MAX_SQRT_PRICE - 1), _settings(), ""
        );
        vm.stopPrank();
        eth = uint256(int256(d.amount0()));
    }

    function sellAll(address who) internal returns (uint256) {
        return sell(who, token.balanceOf(who));
    }

    /// @notice Wait: move time forward by `secs` and blocks by one per 12 seconds.
    function wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12 + 1);
    }

    /// @notice ETH owed to the idea and not yet paid: its part of what waits in the fee vault plus what the splitter
    ///         has booked for it.
    function ideaFeesAccrued() internal view returns (uint256) {
        return splitter.ideaAccrued() + feeVault.creatorAccrued() * splitter.IDEA_SHARE_BPS() / 10_000;
    }

    /// @notice The garage's hourly call: the idea collects its share and takes its step.
    function act() internal {
        IIdeaAct(idea).act();
    }

    /// @notice Pay the idea its share (as anyone could): vault to splitter, then splitter to the idea.
    function claimIdeaFees() internal {
        if (feeVault.creatorAccrued() != 0) feeVault.claimCreator();
        splitter.sync();
        if (splitter.ideaAccrued() != 0) splitter.claimIdea();
    }

    function poolStats() internal view returns (LaunchGuardToken.PoolStats memory) {
        return token.stats();
    }

    /// @notice Add an address the test hands out (a helper contract of the test).
    function know(address a) internal {
        _known.push(a);
    }

    /// @notice From now on, ETH and tokens may only move between known addresses (or tokens be burned).
    function startLeakCheck() internal {
        _ethBaseline = _knownEth();
        _tokenBaseline = _knownTokens();
    }

    /// @notice Fails if ETH or tokens reached an address the test does not know.
    function assertNoLeak() internal view {
        assertEq(_knownEth(), _ethBaseline, "ETH went to an address nobody in the test knows (a hard-coded destination?)");
        assertEq(_knownTokens(), _tokenBaseline, "tokens went to an address nobody in the test knows (a hard-coded destination?)");
    }

    function _knownEth() private view returns (uint256 sum) {
        for (uint256 i; i < _known.length; i++) sum += _known[i].balance;
    }

    /// Tokens held by known addresses, plus burned ones.
    function _knownTokens() private view returns (uint256 sum) {
        for (uint256 i; i < _known.length; i++) sum += token.balanceOf(_known[i]);
        sum += SUPPLY - token.totalSupply();
    }

    function _settings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
