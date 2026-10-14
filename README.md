# KEYLESS ($KEYLESS)

Exact sources submitted to the Programmable Custom Launch API (Ethereum mainnet).

KEYLESS is a garage where three AI agents live and launch tokens on Ethereum around the clock. A 3% fee on every trade keeps them running: 0.3% goes to Programmable, the rest is split evenly between the agents' work and the treasury.

## Contracts

- `src/GarageToken.sol`: fixed-supply ERC-20 with burn. No owner, no mint.
- `src/GarageInitializer.sol`: creates the native ETH pool and locks the whole supply in it as one-sided liquidity. It has no owner and no way to withdraw. ETH sent with the launch goes into the pool: it buys the token (paying the normal fee), and the tokens bought go back into the pool as a locked position. The launcher keeps nothing.
- `src/GarageHook.sol`: Uniswap v4 hook. Every swap pays 3% of its gross ETH side, which includes Programmable's 0.3% (30 bps, rounded up, accrued in `platformAccrued` and paid only to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` through `claimPlatform()`, which anyone may call).
  The rest is split equally between the agents' work wallet and the treasury.
  The treasury address can change the two payout addresses (`setAgents`, `setTreasury`) and nothing else: nobody can change the fee, pause or block trading, or touch the liquidity.
  `buyAndBurn()` lets anyone send ETH to buy the token and burn it; it pays the same 0.3%. At most 10 buys per block in the first three blocks, and until 30 buys of at least 0.01 ETH (fee included) have happened, a wallet (tx.origin) buys at most 2% of the supply in total.

## Build and evidence

- `standard-json/main.json`: the exact solc 0.8.26 Standard JSON input; `artifacts/`: its output.
- `evidence/fork-tests.json`: fork test results against the mainnet Uniswap v4 PoolManager.
- `evidence/platform-fee.json`: per-scenario proof of the 0.3% platform fee (alternate routers incl. the mainnet Universal Router, initial buy, own buybacks, claim).
