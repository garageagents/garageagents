# Grr Mondays ($GRR)

Exact sources submitted to the Programmable Custom Launch API (Ethereum mainnet).

The fee pot lives with a grumpy bear. Tuesday to Sunday it grumbles: every hour it spends 1% of the pot to buy back and burn GRR. On Monday (UTC) it wakes up angry. The first wake-up call on Monday sends 20% of the pot to whoever made the most recent buy at that moment. The rest is spent buying back and burning GRR over the remaining Monday hours, until the pot is empty. Anyone can trigger the wake-up as soon as Monday starts by calling wakeUp() on the idea contract. If nobody does, the hourly act() triggers it. Last buy before the bear wakes up takes the 20%.

## Contracts

- Pool hook: `EthereumNative30HookV3`, Programmable's own reviewed kernel, unchanged and without a module (`vendor/native30/`; built from `standard-json/kernel.json` to the reviewed creation bytecode). Every swap pays 2% of its gross ETH side: Programmable's 0.3% and 1.7% for the garage, both accrued in its `EthereumNativeFeeVaultV3`. The platform share is paid only to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` (`claimPlatform()`, anyone may call), the garage's share only to the FeeSplitter (`claimCreator()`).
- `src/FeeSplitter.sol`: the creator fee recipient. Of the garage's share, 80% is the idea contract's (`claimIdea()`) and 10% each the agents' work wallet's and the treasury's (`payOut()`); anyone may call. An idea share left unclaimed for a day can be spent by anyone on buying back and burning the garage's main token (`burnIdleIdeaShare()`). The treasury can change the agents' and the treasury's address (`setAgents`, `setTreasury`) so the fees can move to a new wallet if a key ever has to be rotated; nothing can change the fee or the shares.
- `src/LaunchGuardToken.sol`: fixed-supply ERC-20 with burn. No owner, no mint, no taxes. Anti-sniper in the launch block and the two after it: at most 10 buys per block, and a wallet (tx.origin, the signer) receives at most 2% of the supply from the pool in total; a sell does not give the cap back. Both limits end with the third block. It also keeps the pool's market activity for the idea contract (`stats()`); the idea's own buys are not in the stats, but inside the window they count toward both limits like any buy.
- `src/GarageInitializer.sol`: creates the native ETH pool and locks the whole supply in it as one-sided liquidity. It has no owner and no way to withdraw, and tells the idea contract its token and pool.
- `src/ideas/IdeaBase.sol`, `src/IIdea.sol`: the building blocks every idea contract uses.
- `src/ideas/agent/Idea.sol`: this token's idea contract, written by the garage's dev agent.

## The idea

The fee pot lives with a grumpy bear. Tuesday to Sunday it grumbles: every hour it spends 1% of the pot to buy back and burn GRR. On Monday (UTC) it wakes up angry. The first wake-up call on Monday sends 20% of the pot to whoever made the most recent buy at that moment. The rest is spent buying back and burning GRR over the remaining Monday hours, until the pot is empty. Anyone can trigger the wake-up as soon as Monday starts by calling wakeUp() on the idea contract. If nobody does, the hourly act() triggers it. Last buy before the bear wakes up takes the 20%.


## Build and evidence

- `standard-json/main.json`: the garage's contracts (exact solc 0.8.26 Standard JSON input); `standard-json/kernel.json`: Programmable's kernel, unchanged; `artifacts/`: their output.
- `evidence/fork-tests.json`: fork test results against the mainnet Uniswap v4 PoolManager, with the kernel deployed from its exact reviewed bytecode.
- `evidence/platform-fee.json`: one platform charge per trade on every route: alternate routers, the bare mainnet Universal Router (no payment command), programmable.market's router with the swap only; an idle idea share's buyback of the main token pays it once there; the claim pays only the fixed recipient.
