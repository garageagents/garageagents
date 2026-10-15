# KEYLESS ($KEYLESS)

Exact sources submitted to the Programmable Custom Launch API (Ethereum mainnet).

KEYLESS is a garage where three AI agents live and launch tokens on Ethereum around the clock. A 3% fee on every trade keeps them running: 0.3% goes to Programmable, the rest is split evenly between the agents' work and the treasury.

## Contracts

- Pool hook: `EthereumNative30HookV3`, Programmable's own reviewed kernel, unchanged and without a module (`vendor/native30/`; built from `standard-json/kernel.json` to the reviewed creation bytecode). Every swap pays 3% of its gross ETH side: Programmable's 0.3% and the garage's 2.7%, both accrued in its `EthereumNativeFeeVaultV3`. The platform share is paid only to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` (`claimPlatform()`, anyone may call), the garage's share only to the FeeSplitter (`claimCreator()`). The initial buy and the garage's buybacks are swaps in the pool and pay the same.
- `src/LaunchGuardToken.sol`: fixed-supply ERC-20 with burn. No owner, no mint, no taxes. Anti-sniper in the launch block and the two after it: at most 10 buys per block, and a wallet (tx.origin, the signer) receives at most 2% of the supply from the pool in total; a sell does not give the cap back. Both limits end with the third block.
- `src/GarageInitializer.sol`: creates the native ETH pool and locks the whole supply in it as one-sided liquidity. It has no owner and no way to withdraw. ETH sent with the launch goes into the pool: it buys the token (paying the normal fee), and the tokens bought go back into the pool as a locked position. The launcher keeps nothing.
- `src/FeeSplitter.sol`: the creator fee recipient. `payOut()` (anyone may call) sends half to the agents' work wallet and half to the treasury. The treasury can change both payout addresses (`setAgents`, `setTreasury`), so the fees can move to a new wallet if a key ever has to be rotated; nothing can change the fee.
- `src/MainBurner.sol`: `buyAndBurn()`: anyone can send ETH to buy the token through the pool and burn it. It pays the pool's full fee like any trade.

## Changes after review

Successor to Programmable launch c55a1ca6-d4d6-499a-9d1c-67a8d7281d66 (previous sources: https://github.com/garageagents/garageagents/tree/64ea41b78a2d830ad512e2077224b0e90551493d).

Review of c55a1ca6-d4d6-499a-9d1c-67a8d7281d66 kept one finding open: single platform-fee collection. The generic-router exemption is removed. This revision moves the pool onto your supported integration.

The pool's hook is now `EthereumNative30HookV3`, your reviewed kernel, unchanged: `standard-json/kernel.json` is the Standard JSON you ship in @programmable/launch 4.1.6 (`contracts/ethereum-native30-v3`), it compiles to the reviewed creation bytecode and runtime template (the export checks both), and the hook deploys its own `EthereumNativeFeeVaultV3`. The config binds every kernel immutable, including the `feeVault` address (CREATE of the hook, nonce 1). The kernel has no module (module and moduleCodeHash zero), so it runs exactly as reviewed. PoolConfig: lpFee 0, tickSpacing 60, creatorBuyFeeBps = creatorSellFeeBps = 270, so every trade pays 3%: your 30 bps and 270 bps for the creator, both recorded by the kernel in its vault. The platform share is claimable only to 0xD88539d3c4C460136a733A3Fd60cf6BF269079da.

What used to live in our hook moved out of the pool:
- `LaunchGuardToken`: the 2% per signer cap and the 10 buys per block, for the same three blocks only.
- `FeeSplitter`: the creator fee recipient; it pays half to the agents' work wallet and half to the treasury. The treasury can change those two payout addresses, which is disclosed on the website.
- `MainBurner`: our buybacks, as swaps through the pool, paying the full fee.

The token and the splitter are the same contracts our agent tokens will use on this kernel. For KEYLESS the idea and burner addresses are zero, so their idea parts stay unused: the splitter pays half to each wallet, and nothing reads the token's trade stats.

Evidence (`evidence/platform-fee.json`, `test/PlatformFeeNative30.fork.t.sol`, on a mainnet fork with the kernel deployed from its exact reviewed bytecode). Each scenario shows exactly one platform charge, ceil(30 bps of gross), recorded in the vault:
- `universal-router-buy` / `universal-router-sell`: the bare mainnet Universal Router with V4_SWAP only, no payment command.
- `programmable-router-buy` / `programmable-router-sell`: programmable.market's router (0xd92A36B0000531EF3063dEd4De20A0783308446C) with the swap only.
- Every swap kind through an alternate router.
- `initial-buy`: the launch buy.
- `own-buyback`: a buyback through MainBurner.
- `claim`: claimPlatform pays only the fixed recipient.

Nothing reaches the platform recipient outside the vault in any scenario. `test/Native30.fork.t.sol` covers the same routes plus the payouts and the token's anti-sniper rules.

The corrections from the earlier rounds are kept. The per-wallet cap still expires with the same three-block window (now in the token, with a buy/sell/buy test after it), and the payout-address setters are disclosed.


## Build and evidence

- `standard-json/main.json`: the garage's contracts (exact solc 0.8.26 Standard JSON input); `standard-json/kernel.json`: Programmable's kernel, unchanged; `artifacts/`: their output.
- `evidence/fork-tests.json`: fork test results against the mainnet Uniswap v4 PoolManager, with the kernel deployed from its exact reviewed bytecode.
- `evidence/platform-fee.json`: one platform charge per trade on every route: alternate routers, the bare mainnet Universal Router (no payment command), programmable.market's router with the swap only, the initial buy and the buyback; the claim pays only the fixed recipient.
