// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Native30Base, IUniversalRouter} from "./Native30Base.sol";

/// Evidence for Programmable: the pool's hook is Programmable's exact EthereumNative30HookV3, and every trade pays
/// exactly one platform charge (30 bps of the gross native amount, rounded up) into its EthereumNativeFeeVaultV3: the
/// initial buy, every swap kind through an alternate router, a bare Universal Router buy and sell with no payment
/// command, programmable.market's own router with the swap only, and the garage's buyback. Nothing reaches the
/// platform recipient outside that vault, and claimPlatform pays only the fixed recipient.
/// Each scenario logs evidence.<scenario>.{grossNative,expectedCeil30bps,platformAccruedDelta,creatorAccruedDelta}.
contract PlatformFeeNative30ForkTest is Native30Base {
    uint256 constant INITIAL_BUY = 0.01 ether;

    function _evidence(string memory name, uint256 gross, uint256 platformDelta, uint256 creatorDelta) internal {
        emit log_named_uint(string.concat("evidence.", name, ".grossNative"), gross);
        emit log_named_uint(string.concat("evidence.", name, ".expectedCeil30bps"), _ceil(gross, 30));
        emit log_named_uint(string.concat("evidence.", name, ".platformAccruedDelta"), platformDelta);
        emit log_named_uint(string.concat("evidence.", name, ".creatorAccruedDelta"), creatorDelta);
        _assertOneCharge(name, gross, platformDelta, creatorDelta);
    }

    function _ready() internal {
        _launch(INITIAL_BUY);
        vm.roll(block.number + 3); // past the anti-sniper window
        _approveRouter(trader);
    }

    function test_initialBuy() public {
        _launch(INITIAL_BUY);
        _evidence("initial-buy", INITIAL_BUY, vault.platformAccrued(), vault.creatorAccrued());
    }

    function test_alternateRouterAllSwapTypes() public {
        _ready();
        (uint256 p0, uint256 c0) = _vaultBalances();
        _swapAs(trader, true, -0.2 ether, 0.2 ether);
        (uint256 p1, uint256 c1) = _vaultBalances();
        _evidence("buy-exact-in", 0.2 ether, p1 - p0, c1 - c0);

        BalanceDelta d = _swapAs(trader, true, 1_000_000 ether, 1 ether);
        (uint256 p2, uint256 c2) = _vaultBalances();
        _evidence("buy-exact-out", uint256(-int256(d.amount0())), p2 - p1, c2 - c1);

        d = _swapAs(trader, false, -2_000_000 ether, 0);
        (uint256 p3, uint256 c3) = _vaultBalances();
        _evidence("sell-exact-in", uint256(int256(d.amount0())) + (p3 - p2) + (c3 - c2), p3 - p2, c3 - c2);

        d = _swapAs(trader, false, 0.01 ether, 0);
        (uint256 p4, uint256 c4) = _vaultBalances();
        _evidence("sell-exact-out", uint256(int256(d.amount0())) + (p4 - p3) + (c4 - c3), p4 - p3, c4 - c3);
    }

    function _routeEvidence(IUniversalRouter r, string memory name) internal {
        uint256 platformWallet = PLATFORM.balance;
        (uint256 p0, uint256 c0) = _vaultBalances();
        _bareBuy(r, 0.05 ether);
        (uint256 p1, uint256 c1) = _vaultBalances();
        _evidence(string.concat(name, "-buy"), 0.05 ether, p1 - p0, c1 - c0);

        uint256 eth = trader.balance;
        _bareSell(r, token.balanceOf(trader) / 2);
        (uint256 p2, uint256 c2) = _vaultBalances();
        _evidence(string.concat(name, "-sell"), trader.balance - eth + (p2 - p1) + (c2 - c1), p2 - p1, c2 - c1);
        assertEq(PLATFORM.balance, platformWallet, "no payment to the platform outside the pool's charge");
    }

    /// The mainnet Universal Router with V4_SWAP only: no TRANSFER, no PAY_PORTION.
    function test_bareUniversalRouter() public {
        _ready();
        _routeEvidence(UR, "universal-router");
    }

    /// programmable.market's router (0xd92A...) with the swap only, as it routes a pool whose native30 waiver applies.
    function test_programmableRouter() public {
        _ready();
        _routeEvidence(PROGRAMMABLE_ROUTER, "programmable-router");
    }

    /// The garage's buyback (MainBurner.buyAndBurn, callable by anyone) is a trade like any other.
    function test_ownBuyback() public {
        _ready();
        (uint256 p0, uint256 c0) = _vaultBalances();
        vm.prank(trader);
        burner.buyAndBurn{value: 0.1 ether}();
        (uint256 p1, uint256 c1) = _vaultBalances();
        _evidence("own-buyback", 0.1 ether, p1 - p0, c1 - c0);
    }

    function test_claimPaysOnlyTheRecipient() public {
        _ready();
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
