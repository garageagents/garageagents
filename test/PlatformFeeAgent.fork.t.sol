// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Native30Base, INative30Vault, IUniversalRouter} from "./Native30Base.sol";
import {Idea} from "../src/ideas/agent/Idea.sol";

/// Evidence for Programmable: this agent token's pool hook is Programmable's exact EthereumNative30HookV3, and every
/// trade pays exactly one platform charge (30 bps of the gross native amount, rounded up) into its
/// EthereumNativeFeeVaultV3: every swap kind through an alternate router, a bare Universal Router buy and sell with no
/// payment command, programmable.market's own router with the swap only. An idea share left unclaimed for a day buys
/// back and burns the garage's main token in the main token's pool (also on the kernel) and pays the platform charge
/// there once. Nothing reaches the platform recipient outside the vaults, and claimPlatform pays only the fixed
/// recipient. The token is launched the way its launch graph deploys it: the idea contract from
/// src/ideas/agent/Idea.sol, LaunchGuardToken, FeeSplitter (80% idea, 10% agents, 10% treasury), the kernel.
/// Each scenario logs evidence.<scenario>.{grossNative,expectedCeil30bps,platformAccruedDelta,creatorAccruedDelta}.
contract PlatformFeeAgentForkTest is Native30Base {
    uint16 constant FEE_BPS = 200; // this token's total fee, Programmable's 0.3% included
    INative30Vault mainVault;

    function setUp() public override {
        super.setUp();
        _launch(0.01 ether); // the garage's main token: idle idea shares buy it back and burn it
        mainVault = vault;
        AgentLaunch memory a = _launchAgent(type(Idea).creationCode, FEE_BPS);
        // From here on the base's helpers trade this agent token.
        init = a.init;
        token = a.token;
        splitter = a.splitter;
        kernel = a.kernel;
        vault = a.vault;
        key = a.key;
        vm.roll(block.number + 3); // past the anti-sniper window
        _approveRouter(trader);
    }

    function _evidence(string memory name, uint256 gross, uint256 platformDelta, uint256 creatorDelta, uint256 totalBps) internal {
        emit log_named_uint(string.concat("evidence.", name, ".grossNative"), gross);
        emit log_named_uint(string.concat("evidence.", name, ".expectedCeil30bps"), _ceil(gross, 30));
        emit log_named_uint(string.concat("evidence.", name, ".platformAccruedDelta"), platformDelta);
        emit log_named_uint(string.concat("evidence.", name, ".creatorAccruedDelta"), creatorDelta);
        _assertOneCharge(name, gross, platformDelta, creatorDelta, totalBps);
    }

    function test_alternateRouterAllSwapTypes() public {
        (uint256 p0, uint256 c0) = _vaultBalances();
        _swapAs(trader, true, -0.2 ether, 0.2 ether);
        (uint256 p1, uint256 c1) = _vaultBalances();
        _evidence("buy-exact-in", 0.2 ether, p1 - p0, c1 - c0, FEE_BPS);

        BalanceDelta d = _swapAs(trader, true, 1_000_000 ether, 1 ether);
        (uint256 p2, uint256 c2) = _vaultBalances();
        _evidence("buy-exact-out", uint256(-int256(d.amount0())), p2 - p1, c2 - c1, FEE_BPS);

        d = _swapAs(trader, false, -2_000_000 ether, 0);
        (uint256 p3, uint256 c3) = _vaultBalances();
        _evidence("sell-exact-in", uint256(int256(d.amount0())) + (p3 - p2) + (c3 - c2), p3 - p2, c3 - c2, FEE_BPS);

        d = _swapAs(trader, false, 0.01 ether, 0);
        (uint256 p4, uint256 c4) = _vaultBalances();
        _evidence("sell-exact-out", uint256(int256(d.amount0())) + (p4 - p3) + (c4 - c3), p4 - p3, c4 - c3, FEE_BPS);
    }

    function _routeEvidence(IUniversalRouter r, string memory name) internal {
        uint256 platformWallet = PLATFORM.balance;
        (uint256 p0, uint256 c0) = _vaultBalances();
        _bareBuy(r, 0.05 ether);
        (uint256 p1, uint256 c1) = _vaultBalances();
        _evidence(string.concat(name, "-buy"), 0.05 ether, p1 - p0, c1 - c0, FEE_BPS);

        uint256 eth = trader.balance;
        _bareSell(r, token.balanceOf(trader) / 2);
        (uint256 p2, uint256 c2) = _vaultBalances();
        _evidence(string.concat(name, "-sell"), trader.balance - eth + (p2 - p1) + (c2 - c1), p2 - p1, c2 - c1, FEE_BPS);
        assertEq(PLATFORM.balance, platformWallet, "no payment to the platform outside the pool's charge");
    }

    /// The mainnet Universal Router with V4_SWAP only: no TRANSFER, no PAY_PORTION.
    function test_bareUniversalRouter() public {
        _routeEvidence(UR, "universal-router");
    }

    /// programmable.market's router (0xd92A...) with the swap only, as it routes a pool whose native30 waiver applies.
    function test_programmableRouter() public {
        _routeEvidence(PROGRAMMABLE_ROUTER, "programmable-router");
    }

    /// The idea's share, left unclaimed for a day, buys back and burns the main token (anyone can trigger it): a swap
    /// in the main token's pool, charged once there at that pool's 3%.
    function test_idleIdeaShareMainBuyback() public {
        _swapAs(trader, true, -0.5 ether, 0.5 ether);
        vault.claimCreator();
        splitter.sync();
        uint256 share = splitter.ideaAccrued();
        assertGt(share, 0);
        vm.warp(vm.getBlockTimestamp() + splitter.IDEA_GRACE());
        uint256 p0 = mainVault.platformAccrued();
        uint256 c0 = mainVault.creatorAccrued();
        vm.prank(makeAddr("garage.n30.anyone"));
        splitter.burnIdleIdeaShare();
        _evidence("idle-idea-share-main-buyback", share, mainVault.platformAccrued() - p0, mainVault.creatorAccrued() - c0, 300);
        assertGt(splitter.mainBurned(), 0);
    }

    function test_claimPaysOnlyTheRecipient() public {
        _swapAs(trader, true, -0.3 ether, 0.3 ether);
        uint256 owed = vault.platformAccrued();
        uint256 before = PLATFORM.balance;
        vm.prank(makeAddr("garage.n30.anyone"));
        vault.claimPlatform();
        emit log_named_uint("evidence.claim.platformAccruedBefore", owed);
        emit log_named_uint("evidence.claim.recipientBalanceDelta", PLATFORM.balance - before);
        emit log_named_address("evidence.claim.recipient", PLATFORM);
        assertEq(PLATFORM.balance - before, owed);
        assertEq(vault.platformAccrued(), 0);
    }
}
