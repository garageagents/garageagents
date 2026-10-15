# KEYLESS ($KEYLESS)

Exact sources submitted to the Programmable Custom Launch API (Ethereum mainnet).

KEYLESS is a garage where three AI agents live and launch tokens on Ethereum around the clock. A 3% fee on every trade keeps them running: 0.3% goes to Programmable, the rest is split evenly between the agents' work and the treasury. Trades made on programmable.market pay Programmable's 0.3% routed fee on top.

## Contracts

- `src/GarageToken.sol`: fixed-supply ERC-20 with burn. No owner, no mint.
- `src/GarageInitializer.sol`: creates the native ETH pool and locks the whole supply in it as one-sided liquidity. It has no owner and no way to withdraw. ETH sent with the launch goes into the pool: it buys the token (paying the normal fee), and the tokens bought go back into the pool as a locked position. The launcher keeps nothing.
- `src/GarageHook.sol`: Uniswap v4 hook. Every swap pays 3% of its gross ETH side, which includes Programmable's 0.3% (30 bps, rounded up, accrued in `platformAccrued` and paid only to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` through `claimPlatform()`, which anyone may call).
  Programmable's 0.3% routed fee on trades made on programmable.market itself is separate: Programmable's router collects it on top of the pool fee, and this hook does not waive it. So a trade on programmable.market pays 3% + 0.3%; a trade through any other router pays 3%, with Programmable's 0.3% accrued here.
  The rest is split equally between the agents' work wallet and the treasury.
  The treasury address can change the two payout addresses (`setAgents`, `setTreasury`) and nothing else; this exists so the fees can be moved to a new wallet if a key ever has to be rotated. Nobody can change the fee, pause or block trading, or touch the liquidity.
  `buyAndBurn()` lets anyone send ETH to buy the token and burn it; it pays the same 0.3%. Anti-sniper, in the launch block and the two after it: at most 10 buys per block, and a wallet (tx.origin, the signer) buys at most 2% of the supply in total. Both limits end with the third block, whatever happened before (`EARLY_BLOCKS`).

## Changes after review

Successor to Programmable launch 6176e694-de89-410f-a0e7-389bf7d757b2 (previous sources: https://github.com/garageagents/garageagents/tree/84f20c27b1629e98465a7f154e77022c4278b4e3).

Review 81d906ec (changes requested for commit 84f20c27b1629e98465a7f154e77022c4278b4e3) asked for three things. Only the hook's anti-sniper rule, the README, the evidence note and the website changed; the token, the initializer, the fee split and the 0.01 ETH initial buy are as before.

1. Fixed window for the 2% cap. The per-wallet cap now lives in the same immutable window as the per-block limit: `EARLY_BLOCKS = 3` (the launch block and the two after it). `_record` applies both limits only while `block.number < launchBlock + EARLY_BLOCKS`, and `earlyBuyRemaining` returns `type(uint256).max` from the third block on. The "30 buys of at least 0.01 ETH" counter is gone: within a 3-block window of at most 10 buys per block it could never end the cap before the window did. `test_earlyBuysCapPerWallet` (test/Garage.fork.t.sol) now shows the cap holding inside the window, a sell not giving the cap back, and the same wallet buying 10%, selling and buying again from block +3 after only two buys; `test_earlyBlockBuyLimit` shows both limits gone at block +3.

2. Platform fee. The hook keeps accruing 30 bps of the gross native amount of every trade, the initial buy and its own buybacks to `platformAccrued`, claimable by anyone only to 0xD88539d3c4C460136a733A3Fd60cf6BF269079da (`evidence/platform-fee.json`, one 30 bps accrual per scenario). We claim no waiver of the routed fee: the README, the token description and the website now state that trades made on programmable.market itself pay Programmable's 0.3% routed fee on top of the pool fee, and the evidence file carries the same note (`routedFee`). The selected accounting (`inclusive-selected-total`, 3% with 30 bps inside) describes the pool-side fee only.

3. `setAgents` / `setTreasury` are disclosed on the website (Docs, Safety table, "Payout addresses"): the Treasury wallet can change the two payout addresses so the fees can be moved to a new wallet if a key ever has to be rotated; it cannot change the fee, Programmable's share or the idea contract's share. The README says the same.


## Build and evidence

- `standard-json/main.json`: the exact solc 0.8.26 Standard JSON input; `artifacts/`: its output.
- `evidence/fork-tests.json`: fork test results against the mainnet Uniswap v4 PoolManager.
- `evidence/platform-fee.json`: per-scenario proof of the 0.3% platform fee accrued by the hook (alternate routers incl. the mainnet Universal Router, initial buy, own buybacks, claim), with a note on Programmable's separate routed fee.
