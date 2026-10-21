# revenue-router

A revenue destination for the Reserve Protocol `Distributor` that forwards the eUSD it receives to a
governed list of recipients, pro rata to their eUSD holdings.

## Behavior

- **Funding.** eUSD governance points part of eUSD's revenue at the router through
  `Distributor.setDistributions`; the planned split is 80% of eUSD revenue to the router and 20% of
  RSR revenue to StRSR. The Distributor pushes eUSD with a plain transfer and no callback.
- **`poke()`** (permissionless). Reads every destination's eUSD balance, then sends the router's
  whole eUSD balance out pro rata to those balances. Destinations holding no eUSD get nothing.
  Rounding dust (< 1 wei per destination) stays for the next poke. Reverts below
  `MIN_POKE_AMOUNT` or when no destination holds eUSD.
- **`setDestinations(address[])`** (governance). Replaces the whole list. Entries must be distinct
  and cannot be the zero address, the router, or eUSD.
- **`sweep(token, to, amount)`** (governance). Emergency transfer of any token, including eUSD.
- **Governance** is any holder of the `OWNER` role on `eUSD.main()`, which is the eUSD governance
  timelock. It's read live on every call.
- **Paused and frozen states are ignored.** eUSD transfers keep working while eUSD is
  trading-paused, issuance-paused, or frozen, and so do `poke()` and `sweep()`.
- **Not upgradeable, no pause.**

### Spot-balance weighting

Weights are balances at the moment of `poke()`. Anyone who can raise a destination's eUSD balance
and then take it back out in the same transaction (e.g. deposit into a vault destination, poke,
withdraw) can steer that poke's revenue toward it. Only list destinations whose eUSD balance
can't be cheaply moved in and out within one transaction.

## Limits

`MAX_DESTINATIONS = 160` and `MIN_POKE_AMOUNT = MAX_DESTINATIONS * 1e18` (1 eUSD per slot).

The cap keeps every call under half of the EIP-7825 per-transaction gas cap (2^24 = 16,777,216),
leaving headroom for future gas repricings. Worst cases were measured by `test_gas_maxDestinations`
on a mainnet fork, with all state cold and every destination holding eUSD:

| destinations | `setDestinations` (from empty) | `poke` |
| -----------: | -----------------------------: | -----: |
|          100 |                           3.90M |  1.34M |
|          160 |                           7.72M |  2.14M |
|          170 |                   8.47M (over) |  2.28M |

`setDestinations` is the binding call: 22.1k gas per fresh storage slot plus the O(n²) duplicate
check. `poke` costs ~13.4k gas per destination. The numbers exclude intrinsic and calldata gas.

## Development

```sh
forge build
forge test                                    # unit tests; fork tests skip
MAINNET_RPC_URL=<archive rpc> forge test      # fork tests too
```

The fork tests pin block 26,243,013, so `MAINNET_RPC_URL` must point at an archive node.
