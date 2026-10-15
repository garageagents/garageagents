# KEYLESS ($KEYLESS)

Exact sources submitted to the Programmable Custom Launch API (Ethereum mainnet).

KEYLESS is a garage where three AI agents live and launch tokens on Ethereum around the clock. A 3% fee on every trade keeps them running: 0.3% goes to Programmable, the rest is split evenly between the agents' work and the treasury. On programmable.market Programmable's own router collects that 0.3% and the hook takes only the garage's share, so every trade pays it exactly once.

## Contracts

- `src/GarageToken.sol`: fixed-supply ERC-20 with burn. No owner, no mint.
- `src/GarageInitializer.sol`: creates the native ETH pool and locks the whole supply in it as one-sided liquidity. It has no owner and no way to withdraw. ETH sent with the launch goes into the pool: it buys the token (paying the normal fee), and the tokens bought go back into the pool as a locked position. The launcher keeps nothing.
- `src/GarageHook.sol`: Uniswap v4 hook. Every swap pays 3% of its gross ETH side, which includes Programmable's 0.3% (30 bps, rounded up, accrued in `platformAccrued` and paid only to `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` through `claimPlatform()`, which anyone may call).
  Programmable's own router (`PROGRAMMABLE_ROUTER`, 0xd92A36B0000531EF3063dEd4De20A0783308446C) pays Programmable its 0.3% itself, so for the swaps it sends the hook charges only the project share (2.7%): every trade pays Programmable 0.3% exactly once, on programmable.market and on any other router alike, and the trader pays 3% either way. Only Programmable (`PLATFORM_RECIPIENT`) can point the hook at a new router of theirs (`setPlatformRouter`); nothing else about the fee can change.
  The rest is split equally between the agents' work wallet and the treasury.
  The treasury address can change the two payout addresses (`setAgents`, `setTreasury`) and nothing else; this exists so the fees can be moved to a new wallet if a key ever has to be rotated. Nobody can change the fee, pause or block trading, or touch the liquidity.
  `buyAndBurn()` lets anyone send ETH to buy the token and burn it; it pays the same 0.3%. Anti-sniper, in the launch block and the two after it: at most 10 buys per block, and a wallet (tx.origin, the signer) buys at most 2% of the supply in total. Both limits end with the third block, whatever happened before (`EARLY_BLOCKS`).

## Changes after review

Successor to Programmable launch 084500ae-6879-49cf-951d-dd727bd1558e (previous sources: https://github.com/garageagents/garageagents/tree/4248211f550d64a9a9e7bfbb90950e92b50ac6c4).

Review 81d906ec, revision 2, left one finding open: single platform-fee collection. The two findings resolved in revision 2 (the three-block expiry of the 2% cap, the setAgents/setTreasury disclosure) are unchanged here; this revision changes only how the platform fee is collected on Programmable's own route, and the texts that describe it.

What changed. The hook still accrues 30 bps of the gross native amount of every trade, the initial buy and its own buybacks to `platformAccrued`, claimable by anyone only to 0xD88539d3c4C460136a733A3Fd60cf6BF269079da, on every router except Programmable's own. For the swaps that router (`PROGRAMMABLE_ROUTER`, 0xd92A36B0000531EF3063dEd4De20A0783308446C) sends, the hook charges only the project share (`quoteFeeFor`, 2.7% of gross for the main token), because that router pays Programmable its 30 bps itself: a TRANSFER to the recipient before a buy, a PAY_PORTION after a sell. So the platform fee is charged exactly once on every route, the trader pays 3% everywhere, and alternate routes are not left unpaid. Only `PLATFORM_RECIPIENT` can point the hook at a new router of yours (`setPlatformRouter`); nothing else about the fee can change. The previous "plus 0.3% routed fee" wording is gone from the token description, the README, the evidence and the website.

Evidence (`evidence/platform-fee.json`, `test/PlatformFee.fork.t.sol` on a mainnet fork):
- `programmable-route-buy` and `programmable-route-sell` run the mainnet router contract at 0xd92A36B0000531EF3063dEd4De20A0783308446C with the route it uses on programmable.market (TRANSFER of 30 bps to the recipient, V4_SWAP with SWAP_EXACT_IN_SINGLE / SETTLE_ALL / TAKE_ALL, SWEEP; for the sell V4_SWAP, PAY_PORTION of 30 bps, SWEEP): the router paid the recipient the 30 bps, the hook's platform accrual stayed at zero, and the hook charged exactly the project share.
- `initial-buy`, `buy-exact-in`, `buy-exact-out`, `sell-exact-in`, `sell-exact-out`, `universal-router-buy-exact-in`, `own-buyback`: one 30 bps accrual each on every other route, as before; `claim` pays only the fixed recipient.
- `test_programmableRouterChargesPlatformOnce` and `test_onlyProgrammableMovesItsRouter` in `test/Garage.fork.t.sol` cover the same route and the router setter.

No other feature of the hook, the token or the initializer changed; the 0.01 ETH initial buy is as before.


## Build and evidence

- `standard-json/main.json`: the exact solc 0.8.26 Standard JSON input; `artifacts/`: its output.
- `evidence/fork-tests.json`: fork test results against the mainnet Uniswap v4 PoolManager.
- `evidence/platform-fee.json`: per-scenario proof of the 0.3% platform fee (alternate routers incl. the mainnet Universal Router, initial buy, own buybacks, claim), and of the single charge through Programmable's own mainnet router (its route on the fork: the router pays the 30 bps, the hook takes the project share only).
