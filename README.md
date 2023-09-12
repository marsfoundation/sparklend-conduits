# Spark Conduits

![Foundry CI](https://github.com/marsfoundation/spark-conduits/actions/workflows/ci.yml/badge.svg)
[![Foundry][foundry-badge]][foundry]
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://github.com/marsfoundation/spark-conduits/blob/master/LICENSE)

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

## Overview

The Spark Conduit is a conduit contract designed to be used within the Maker Allocation system. It implements the IAllocatorConduit interface, so it will be able to work within the constraints on the Allocation system design. There are two contracts in this repo:

1. `SparkConduit`: Facilitates the movement of funds between the Maker allocation system and the SparkLend protocol.
2. `DaiInterestRateStrategy`: Calculates the interest rate that is to be paid by all borrowers of DAI through the SparkLend protocol.

## Roles/Permissions

1. `wards`: The `wards` mapping tracks the administrative permissions on this contract. Admin can upgrade the contract and set key storage values.
2. `operator`: The `operator` performs actions on behalf of a given `ilk` (SubDAO identifier in the Maker allocation system). The operator can deposit, withdraw, requestFunds, and cancel fund requests in the Conduit. Onboarding and offboarding of `operator` actors is done by Maker admin in the core system.

### Admin Configuration

1. `roles`: The roles contract to perform operator authentication.
2. `registry`:Maps ilks to allocation buffer.
3. `subsidySpread`: The delta between the Base Rate and the Subsidy Rate. [RAY]

## `DaiInterestRateStrategy`

The `DaiInterestRateStrategy` contract is used to calculate the interest rate that is to be paid by all borrowers of DAI through the SparkLend protocol. It implements the `IInterestRateStrategy` interface, which is standard in SparkLend for all interest strategies. It is an auxiliary contract to SparkConduit that allows SubDAOs to influence interest rates if they require liquidity and it is not available.

The `DaiInterestRateStrategy` implements two important functions:

1. `calculateInterestRates()`: This function is called by SparkLend. The important distinction between this contract and the standard implementation is that there are two paths to determine interest.
   1. When the `debtRatio` is greater than one, it means that the `targetDebt` is lower than the `currentDebt`, and the amount of outstanding debt needs to decrease. In this case: the borrow rate is calculated as follows:

    $$ borrowRate = maxRate - \frac{baseRate}{debtRatio} $$

2. `recompute()`: This function is publicly callable and updates state.

<img width="1718" alt="Screenshot 2023-09-12 at 3 17 15 PM" src="https://github.com/marsfoundation/spark-conduits/assets/44272939/9d879b61-2943-413d-ab85-e4f1391df37e">

## Functionality

### `deposit`

The `deposit` function is used to move funds from a given `ilk`'s `buffer` into the Conduit. From the Conduit, the funds are used to `supply` in the Spark Pool. The result is that:
1. Funds are moved from the `buffer` to SparkLend's aToken for that asset.
2. aTokens are minted and sent to the Conduit.
3. The Conduit state to track the `ilk`'s portion of the aTokens in the Conduit is increased.

<p align="center">
  <img src="https://github.com/marsfoundation/spark-conduits/assets/44272939/2a7cf453-3a7b-4d04-a0cd-d390cfeb8ec2" height="500" />
</p>

### `withdraw`

The `withdraw` function is used to move funds from the Conduit into a given `ilk`'s `buffer`. From the Conduit, the funds are used to `withdraw` from the Spark Pool. The result is that:

1. Funds are moved from SparkLend's aToken for that asset to the `buffer`.
2. The Conduit's aTokens corresponding to the underlying asset withdrawn are burned.
3. The Conduit state to track the `ilk`'s portion of the aTokens in the Conduit is reduced.

<p align="center">
  <img src="https://github.com/marsfoundation/spark-conduits/assets/44272939/fd64b9e2-28f3-45c6-8deb-7d43283e9443" height="500" />
</p>

### `requestFunds`
The `requestFunds` function is used to signal that a given `ilk` would like to withdraw funds from the Conduit. This is only possible when there is zero liquidity in SparkLend for the desired asset.

The result is that:
- The Conduit state to track the `ilk`'s requested funds in the Conduit is increased. Importantly, `totalRequestedShares[asset]` is increased.

When `recompute()` is called in DaiInterestRateStrategy, it calls `getInterestData` on the SparkConduit. The `targetDebt` that is returned will be lower because it is `totalShares - totalRequestedShares`. This means that the `debtRatio` that is saved to storage will be greater than one, which means that the conditional logic to raise the interest rates is put into effect.

`totalRequestedShares` only reduces when an `ilk` either:
1. Cancels a withdrawal request.
2. Withdraws funds from the Conduit.

### `cancelRequest`
The `cancelRequest` function is used to signal that a given `ilk` would like to cancel a request to withdraw funds from the Conduit. This is only possible when there is an active request to withdraw funds from the Conduit.

The result is that:
- The Conduit state to track the `ilk`'s requested funds in the Conduit is decreased. Importantly, `totalRequestedShares[asset]` is decreased.

## Invariants

$$ totalShares[asset] = \sum_{n=0}^{numIlks}{shares[asset][ilk]}  $$
$$ totalRequestedShares[asset] = \sum_{n=0}^{numIlks}{requestedShares[asset][ilk]}  $$
$$ totalShares[asset] = aToken.scaledBalanceOf(conduit)  $$
$$ getTotalDeposits(assets) = aToken.balanceOf(conduit) $$

## Upgradeability

Since Conduits will likely require maintenance as their desired usage evolves, they will be upgradeable contracts, using [`upgradeable-proxy`](https://github.com/marsfoundation/upgradeable-proxy) for upgradeable logic. This is a non-transparent proxy contract that gives upgrade rights to the PauseProxy.

## Testing

To run the tests, do the following:

```
forge test
```

