# Spark Conduits

![Foundry CI](https://github.com/marsfoundation/spark-conduits/actions/workflows/ci.yml/badge.svg)
[![Foundry][foundry-badge]][foundry]
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://github.com/marsfoundation/spark-conduits/blob/master/LICENSE)

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

## Overview

The Spark Conduit is a conduit contract designed to be used within the Maker Allocation System. It implements the IAllocatorConduit interface, so it will be able to work within the constraints on the Allocation System design. There are two contracts in this repo:

1. `SparkConduit`: Facilitates the movement of funds between the Maker Allocation System and the SparkLend protocol.
2. `DaiInterestRateStrategy`: Calculates the interest rate that is to be paid by all borrowers of DAI through the SparkLend protocol.

## Roles/Permissions

1. `wards`: The `wards` mapping tracks the administrative permissions on this contract. Admin can upgrade the contract and set key storage values.
2. `operator`: The `operator` performs actions on behalf of a given `ilk` (SubDAO identifier in the Maker Allocation System). The operator can deposit, withdraw, request funds, and cancel fund requests in the Conduit. Onboarding and offboarding of `operator` actors is done by Maker admin in the core system.

### Admin Configuration

1. `roles`: The roles contract to perform operator authentication.
2. `registry`: Returns the `buffer` contract for a given ilk (source of funds).
3. `subsidySpread`: The delta between the Base Rate and the Subsidy Rate. [RAY]

## Functionality

### `deposit`

The `deposit` function is used to move funds from a given `ilk`'s `buffer` into the Conduit. From the Conduit, the funds are used to `supply` in the SparkLend Pool. The result is that:
1. Funds are moved from the `buffer` to SparkLend's aToken for that asset.
2. aTokens are minted and sent to the Conduit.
3. The Conduit state to track the `ilk`'s portion of the aTokens in the Conduit is increased.

<p align="center">
  <img src="https://github.com/marsfoundation/spark-conduits/assets/44272939/2a7cf453-3a7b-4d04-a0cd-d390cfeb8ec2" height="500" />
</p>

### `withdraw`

The `withdraw` function is used to `withdraw` funds from the SparkLend Pool into the Conduit. From the Conduit, the funds are sent to the `ilk`'s `buffer`. The result is that:

1. Funds are moved from SparkLend's aToken for that asset to the `buffer`.
2. The Conduit's aTokens corresponding to the underlying asset withdrawn are burned.
3. The Conduit state to track the `ilk`'s portion of the aTokens in the Conduit is reduced.

<p align="center">
  <img src="https://github.com/marsfoundation/spark-conduits/assets/44272939/a55a7a74-1cc3-41ad-9f39-94f30a7a7ab5" height="500" />
</p>

### `requestFunds`
The `requestFunds` function is used to signal that a given `ilk` would like to withdraw funds from the Conduit. This is only possible when there is zero liquidity in SparkLend for the desired asset.

The result is that:
- The Conduit state to track the `ilk`'s requested funds in the Conduit is increased. Importantly, `totalRequestedShares[asset]` is increased.

When `recompute()` is called in DaiInterestRateStrategy, it calls `getInterestData` on the SparkConduit. The `targetDebt` that is returned will be lower because it is `totalShares - totalRequestedShares`. This means that the `debtRatio` that is saved to storage will be greater than one, which means that the conditional logic to raise the interest rates (outlined in the `DaiInterestRateStrategy` section) is put into effect.

`totalRequestedShares` only reduces when an `ilk` either:
1. Cancels a withdrawal request.
2. Withdraws funds from the Conduit.

### `cancelRequest`
The `cancelRequest` function is used to signal that a given `ilk` would like to cancel a request to withdraw funds from the Conduit. This is only possible when there is an active request to withdraw funds from the Conduit.

The result is that:
- The Conduit state to track the `ilk`'s requested funds in the Conduit is decreased. Importantly, `totalRequestedShares[asset]` is decreased.

## Invariants

$$ totalShares[asset] = \sum_{n=0}^{numIlks}{shares[asset][ilk]} $$

$$ totalRequestedShares[asset] = \sum_{n=0}^{numIlks}{requestedShares[asset][ilk]} $$

$$ getTotalDeposits(asset) = \sum_{n=0}^{numIlks}{getDeposits(asset, ilk)} $$

$$ getTotalRequestedFunds(asset) = \sum_{n=0}^{numIlks}{getRequestedFunds(asset, ilk)} $$

$$ totalRequestedShares[asset] = \sum_{n=0}^{numIlks}{requestedShares[asset][ilk]} $$

$$ totalShares[asset] \le aToken.scaledBalanceOf(conduit) $$

$$ getTotalDeposits(asset) \le aToken.balanceOf(conduit) $$

**NOTE**: The last two invariants are not strict equalities because of the potential for a permissionless transfer of the aToken into the conduit. For this reason alone, they are expressed as inequalities.

## Upgradeability

Since the Spark Conduit will likely require maintenance as its desired usage evolves, it will be an upgradeable contract, using [`upgradeable-proxy`](https://github.com/marsfoundation/upgradeable-proxy) for upgradeable logic. This is a non-transparent proxy contract that gives upgrade rights to the PauseProxy.

## `DaiInterestRateStrategy`

The `DaiInterestRateStrategy` contract is used to calculate the interest rate that is to be paid by all borrowers of DAI through the SparkLend protocol. It implements the `IInterestRateStrategy` interface, which is standard in SparkLend for all interest strategies. It is an auxiliary contract to SparkConduit that allows SubDAOs to influence interest rates if they require liquidity and it is not available.

To clarify interest rate-related naming in the contracts:
- `subsidyRate` (SparkConduit): Annualized `dsr` from Maker Core
- `subsidySpread` (SparkConduit): Spread set by Maker to make lending to decentralized collateral protocols advantageous. Borrow rate for DAI for the subDAOs.
- `baseRate` (SparkConduit): Base rate that is used for borrowing by all subDAOs.
- `spread` (DaiInterestRateStrategy): Spread above the `subsidyRate` that borrowers pay and SubDAOs earn.

The `DaiInterestRateStrategy` implements two important functions:

### `calculateInterestRates()`
This function is called by SparkLend.
The important distinction between this contract and the standard implementation is that there are two paths to determine interest:

#### `debtRatio == 1`
When `debtRatio == 1`, the interest rate used to charge to DAI borrowers is the `baseRate`. This value is determined by Maker core governance.
#### `debtRatio > 1`
When `debtRatio > 1`, the interest rate is dynamically calculated based on the following function:

$$ borrowRate = maxRate - \frac{maxRate - baseRate}{\frac{currentDebt}{targetDebt}} $$

Below is an illustrative example of the above formula, with the following configuration:
1. `maxRate = 75%`
2. `baseRate = 5%`
3. `currentDebt = 100`

Each of the lines demonstrates a different scenario, where the amount of requested funds (and therefore the `targetDebt` is different). In the functions below, `r` is defined as the resulting interest rate, and `a` as the amount that has been returned after the original change in the target debt. The domains of each of these functions are limited from `debtRatio > 1`. It can be seen that the minimum rate returns back to the `baseBorrowRate` in all scenarios once all the requested liquidity has been repaid.

<img width="1240" alt="Screenshot 2023-09-12 at 3 51 21 PM" src="https://github.com/marsfoundation/spark-conduits/assets/44272939/b383163d-c8ab-40dc-89ce-41464a7e4cc6">

It is important to note that Maker will penalize SubDAOs that do not perform withdrawals after the funds are returned by users. This is to prevent gamification occurring where SubDAOs can profit by artificially requesting funds to spike interest rates. This results in a very bad UX for SparkLend borrowers, so it is the intention that this functionality be used very rarely, and when it is done that the SubDAOs are financially incentivized to withdraw the returned liquidity immediately.

## Testing

To run the tests, do the following:

```
forge test
```

