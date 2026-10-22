# revenue-router

A revenue destination for the Reserve Protocol `Distributor` that forwards the eUSD it receives to a
governed list of recipients, pro rata to the eUSD balances of a paired list of holders.

## Behavior

- **Funding.** eUSD governance points part of eUSD's revenue at the router through
  `Distributor.setDistributions`; the planned split is 80% of eUSD revenue to the router and 20% of
  RSR revenue to StRSR. The Distributor pushes eUSD with a plain transfer and no callback.
- **Destinations.** Each is a `{holder, recipient}` pair: `holder`'s eUSD balance sets the weight,
  and `recipient` receives the revenue. They can be the same address.
- **`poke()`** (permissionless). Reads every holder's eUSD balance, then sends the router's whole
  eUSD balance to the recipients pro rata to those balances, emitting `Distributed(holder,
  recipient, amount)` per payout and `Poked(caller, total)` at the end. Holders with no eUSD earn
  nothing. Rounding dust (< 1 wei per destination) stays for the next poke. Reverts while eUSD
  trading is paused or eUSD is frozen, below `MIN_POKE_AMOUNT`, or when no holder holds eUSD.
- **`setDestinations(Destination[])`** (governance). Replaces the whole list. Holders must be
  distinct; recipients may repeat. Neither can be the zero address, the router, or eUSD.
- **`sweep(token, to, amount)`** (governance). Emergency transfer of any token, including eUSD and
  tokens like USDT that return nothing from `transfer`.
- **Governance** is any holder of the `OWNER` role on eUSD's Main, which is the eUSD governance
  timelock. Main is read once from `eUSD.main()` at construction.
- **Paused and frozen states.** `poke()` reverts while eUSD trading is paused or eUSD is frozen
  (`tradingPausedOrFrozen()`) and ignores issuance-paused. `sweep()` ignores all of them.
- **Spot-balance weights.** Destinations are a governance-approved whitelist, so a holder that
  games its balance around a poke can be removed.
- **Not upgradeable, no pause.**

## Limits

`MAX_DESTINATIONS = 100` and `MIN_POKE_AMOUNT = MAX_DESTINATIONS` wei, so every destination slot
can receive at least 1 wei on average.

The cap keeps every call under half of the EIP-7825 per-transaction gas cap (2^24 = 16,777,216),
leaving headroom for future gas repricings. Worst cases were measured by `test_gas_maxDestinations`
on a mainnet fork, with all state cold, every holder holding eUSD, and every recipient holding none:

| destinations | `setDestinations` (from empty) | `poke` |
| -----------: | -----------------------------: | -----: |
|          100 |                          6.98M |  3.66M |
|          150 |                  10.47M (over) |  5.47M |

`setDestinations` is the binding call: three fresh storage slots per destination (the set's value
and index, plus the recipient mapping) at ~70k gas each destination, linear in n. `poke` costs
~36.5k gas per destination when recipients start empty, and less once they hold eUSD. The numbers exclude intrinsic and calldata gas.

## Development

```sh
pnpm install
pnpm test                                     # unit tests
MAINNET_RPC_URL=<archive rpc> pnpm test:fork  # mainnet fork tests
```

The fork tests pin block 26,243,013, so `MAINNET_RPC_URL` must point at an archive node.
