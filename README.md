# Spark Conduit

![Foundry CI](https://github.com/marsfoundation/spark-conduits/actions/workflows/ci.yml/badge.svg)
[![Foundry][foundry-badge]][foundry]
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://github.com/marsfoundation/spark-conduits/blob/master/LICENSE)

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

## Overview

Conduits required to connect the Maker allocation system to Spark. There will be two versions. One that is for local instances on Ethereum (and Goerli) and another for chains that require a bridge.

The general idea of the Spark Conduit (both versions) is to allow allocators to provision asset(s) to the market via the `deposit()` function which is standard to all Conduits. The funds will then be forwarded to the pool and the depositor credited.

Conversely if the allocator wants to withdraw funds they can call `withdraw()` provided there is idle liquidity available. If not they will need to signal their intent for withdrawal which will increase the interest rate on the pool to encourage third party deposits and repayments of loans.

Signaling intent to withdraw is done by the allocator calling `requestFunds()` and specifying how much they are looking to withdraw. The reason it is done this way instead of using a kink on the pool is to avoid thrashing interest rates on the pool. IE there is 10m idle liquidity and allocator wants to withdraw 100m. With the interest rate kink the process would be withdraw 10m, interest rates max out, 3rd party depositor/repay occurs of ~10m and the rates go back down. This process would repeat 10x which is a bad experience for users. Instead the allocator signals the intent to withdraw 100m and the pool will set the interest rates accordingly and only bringing the rate back down when the allocator completes the full withdraw (or partial ones along the way).

Allocators can cancel withdrawal intents by calling `cancelFundRequest()`.

Calling `requestFunds()` twice will override the previous fund request instead of add to it.

## Functionality

### `deposit`

The `deposit` function is used to move funds from a given `ilk`s `buffer` into the Conduit. From the Conduit, the funds can be deployed to a yield bearing strategy. This can happen atomically in the case of DeFi protocols, or can happen in a separate function call made by a permissioned actor in the case of Real World Asset strategies.

![DepositSpark](https://github.com/marsfoundation/spark-conduits/assets/44272939/ae246844-94de-4720-99d0-7ee8f7683a80)

### `withdraw`

The `withdraw` function is used to move funds from the Conduit into a given `ilk`s `buffer`. This can pull funds atomically from a yield bearing strategy in the case of DeFi protocols, or can pull the funds directly from the Conduit in the case of a Real World Asset strategy where the permissioned actor has returned the funds manually. Both situations require that there is available liquidity, which is why `maxWithdraw` exists. This view function should report the maximum amount of `asset` that can be withdrawn for a given `ilk`.

![WithdrawSpark](https://github.com/marsfoundation/spark-conduits/assets/44272939/a3e15eca-b8f8-42e8-bd18-0bc964c3efc7)

## `SparkConduit`

`SparkConduit` is used for a local instance of Spark Lend. All dependency values are immediately accessible. The contract is upgradable to facilitate changes to logic if needed.

## Upgradeability

Since Conduits will likely require maintenance as their desired usage evolves, they will be upgradeable contracts, using [`upgradeable-proxy`](https://github.com/marsfoundation/upgradeable-proxy) for upgradeable logic. This is a non-transparent proxy contract that gives upgrade rights to the PauseProxy.

## Testing

To run the tests, do the following:

```
forge test
```

### Configuration

`roles` - The roles contract to perform operator authentication.
`registry` - Maps ilks to allocation buffer.
`subsidySpread` - The delta between the Base Rate and the Subsidy Rate. [RAY]
