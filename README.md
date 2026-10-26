# revenue-router

A revenue destination for the Reserve Protocol `Distributor` that forwards the eUSD it receives to a
governed list of recipients, pro rata to the multiplier-weighted eUSD balances of a paired list of
holders.

## Behavior

- **Funding.** eUSD governance points part of eUSD's revenue at the router through
  `Distributor.setDistributions`; the planned split is 80% of eUSD revenue to the router and 20% of
  RSR revenue to StRSR. The Distributor pushes eUSD with a plain transfer and no callback.
- **Destinations.** Each is a `{holder, recipient, multiplier}` triple: `holder`'s eUSD balance
  times `multiplier` sets the weight, and `recipient` receives the revenue. Holder and recipient can
  be the same address. `multiplier` is a `uint96` in D18 (`1e18` = 1x). The weight is
  `mulDiv(balance, multiplier, 1e18)`, rounded down to whole wei.
- **`poke()`** (permissionless). Reads every holder's eUSD balance, then sends the router's whole
  eUSD balance to the recipients pro rata to balance × multiplier, emitting `Distributed(holder,
  recipient, amount)` per payout. Holders with no eUSD earn nothing. Rounding dust (< 1 wei per
  destination) stays for the next poke. Reverts when every weight rounds to zero, for example when no holder holds eUSD.
- **`addDestinations(Destination[])`** (governance). Appends to the list. Holders must be new and
  distinct; recipients may repeat. Neither can be the zero address, the router, or eUSD. The
  multiplier must be nonzero. To change a destination, remove it and add it again in the same
  governance proposal; otherwise a `poke()` between the two transactions pays the other
  destinations the whole balance.
- **`removeDestinations(address[] holders)`** (governance). Removes the destinations of `holders`.
  Reverts on a holder that is not in the list.
- **`sweep(token, to, amount)`** (governance). Emergency transfer of any token, including eUSD and
  tokens like USDT that return nothing from `transfer`.
- **Governance** is any holder of the `OWNER` role on eUSD's Main, which is the eUSD governance
  timelock. Main is read once from `eUSD.main()` at construction.
- **Paused and frozen states are ignored.** Neither `poke()` nor `sweep()` checks them, and both
  keep working while eUSD is trading-paused, issuance-paused, or frozen.
- **Spot-balance weights.** `poke()` reads spot balances and anyone can call it, so governance
  must only add holders whose eUSD balance third parties cannot inflate. For example, if a holder
  is a vault that anyone can deposit into and that is also the recipient, an attacker can
  flash-borrow eUSD, deposit, `poke()`, and redeem most of the payout. Removing the holder
  afterwards does not recover that payout.
- **Not upgradeable, and no pause of its own.**

## Deployments

| network  | address                                                                                                                 | commit    |
| -------- | ----------------------------------------------------------------------------------------------------------------------- | --------- |
| mainnet  | [`0xdfD0CF858afe6010C83238461C6d7142d1b5265d`](https://etherscan.io/address/0xdfD0CF858afe6010C83238461C6d7142d1b5265d) | `4f889a3` |

## Limits

`MAX_DESTINATIONS = 100`. The cap keeps every call under half of the EIP-7825 per-transaction gas
cap (2^24 = 16,777,216), leaving headroom for future gas repricings. Worst cases were measured by `test_gas_maxDestinations`
on a mainnet fork, with all state cold, every holder holding eUSD, and every recipient holding none:

| destinations | `addDestinations` (from empty) | `poke` |
| -----------: | -----------------------------: | -----: |
|          100 |                          7.22M |  3.70M |
|          150 |                  10.82M (over) |  5.55M |

`poke` is the binding call because it always covers every destination: ~37k gas per destination
when recipients start empty, and less once they hold eUSD. `addDestinations` costs more per
destination, ~72k for three fresh storage slots (the set's value and index, plus the recipient and
multiplier packed in one slot), but governance can split a large addition across calls. The numbers
exclude intrinsic and calldata gas.

## Development

```sh
pnpm install
pnpm test                                     # unit tests
MAINNET_RPC_URL=<archive rpc> pnpm test:fork  # mainnet fork tests
```

The fork tests pin block 26,243,013, so `MAINNET_RPC_URL` must point at an archive node.
