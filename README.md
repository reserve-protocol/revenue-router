# revenue-router

A revenue destination for the Reserve Protocol `Distributor` that forwards the eUSD it receives to a
governed list of recipients, pro rata to their eUSD holdings.

## Behavior

- **Funding.** eUSD governance points part of eUSD's revenue at the router through
  `Distributor.setDistributions`; the planned split is 80% of eUSD revenue to the router and 20% of
  RSR revenue to StRSR. The Distributor pushes eUSD with a plain transfer and no callback.
- **`poke()`** (permissionless). Reads every destination's eUSD balance, then sends the router's
  whole eUSD balance out pro rata to those balances. Destinations holding no eUSD get nothing.
  Rounding dust (< 1 wei per destination) stays for the next poke. Reverts while eUSD trading is
  paused, below `MIN_POKE_AMOUNT`, or when no destination holds eUSD.
- **`setDestinations(address[])`** (governance). Replaces the whole list. Entries must be distinct
  and cannot be the zero address, the router, or eUSD.
- **`sweep(token, to, amount)`** (governance). Emergency transfer of any token, including eUSD and
  tokens like USDT that return nothing from `transfer`.
- **Governance** is any holder of the `OWNER` role on eUSD's Main, which is the eUSD governance
  timelock. Main is read once from `eUSD.main()` at construction.
- **Paused and frozen states.** `poke()` reverts while eUSD trading is paused and ignores
  issuance-paused and frozen. `sweep()` ignores all of them.
- **Spot-balance weights.** Destinations are a governance-approved whitelist, so a destination that
  games its balance around a poke can be removed.
- **Not upgradeable, no pause.**

## Limits

`MAX_DESTINATIONS = 160` and `MIN_POKE_AMOUNT = MAX_DESTINATIONS` wei, so every destination slot
can receive at least 1 wei on average.

The cap keeps every call under half of the EIP-7825 per-transaction gas cap (2^24 = 16,777,216),
leaving headroom for future gas repricings. Worst cases were measured by `test_gas_maxDestinations`
on a mainnet fork, with all state cold and every destination holding eUSD:

| destinations | `setDestinations` (from empty) | `poke` |
| -----------: | -----------------------------: | -----: |
|          160 |                          7.72M |  2.13M |
|          170 |                   8.46M (over) |  2.26M |

`setDestinations` is the binding call: 22.1k gas per fresh storage slot plus the O(n²) duplicate
check. `poke` costs ~13.3k gas per destination. The numbers exclude intrinsic and calldata gas.

## Development

```sh
pnpm install
pnpm test                                     # unit tests
MAINNET_RPC_URL=<archive rpc> pnpm test:fork  # mainnet fork tests
```

The fork tests pin block 26,243,013, so `MAINNET_RPC_URL` must point at an archive node.
