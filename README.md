# SparkLend Conduits ⚡

![Foundry CI](https://github.com/marsfoundation/spark-conduits/actions/workflows/ci.yml/badge.svg)
[![Foundry][foundry-badge]][foundry]
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://github.com/marsfoundation/spark-conduits/blob/master/LICENSE)

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

## Overview

The SparkLend Conduit is a conduit contract designed to be used within the Maker Allocation System. It implements the IAllocatorConduit interface, so it will be able to work within the constraints on the Allocation System design. There is one contract in this repo:

`SparkLendConduit`: Facilitates the movement of funds between the Maker Allocation System and the SparkLend instance.

In later iterations of this code's development, it is expected for other SparkLend Conduits to be developed to support multichain deployments.

## Roles/Permissions

1. `wards`: The `wards` mapping tracks the administrative permissions on this contract. Admin can upgrade the contract and set key storage values.
2. `operator`: The `operator` performs actions on behalf of a given `ilk` (SubDAO identifier in the Maker Allocation System). The operator can deposit, withdraw, request funds, and cancel fund requests in the Conduit. Onboarding and offboarding of `operator` actors is done by Maker admin in the core system.

### Admin Configuration

1. `roles`: The roles contract to perform operator authentication.
2. `registry`: Returns the `buffer` contract for a given ilk (source of funds).

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

## Invariants

$$ totalShares[asset] = \sum_{n=0}^{numIlks}{shares[asset][ilk]} $$

$$ getTotalDeposits(asset) = \sum_{n=0}^{numIlks}{getDeposits(asset, ilk)} $$

$$ totalRequestedShares[asset] = \sum_{n=0}^{numIlks}{requestedShares[asset][ilk]} $$

$$ totalShares[asset] \le aToken.scaledBalanceOf(conduit) $$

$$ getTotalDeposits(asset) \le aToken.balanceOf(conduit) $$

**NOTE**: The last two invariants are not strict equalities because of A) the potential for a permissionless transfer of the aToken into the conduit and/or B) the rounding behaviour difference (round on SparkLend vs round-down on SparkLend Conduit).

## Upgradeability

Since the SparkLend Conduit will likely require maintenance as its desired usage evolves, it will be an upgradeable contract, using [`upgradeable-proxy`](https://github.com/marsfoundation/upgradeable-proxy) for upgradeable logic. This is a non-transparent proxy contract that gives upgrade rights to the PauseProxy.

## Technical Assumptions

As with most MakerDAO contracts, non standard token implementations are assumed to not be supported. As examples, this includes tokens that:
   - Do not have a decimals field or have more than 18 decimals.
   - Do not revert and instead rely on a return value.
   - Implement fee on transfer.
   - Include rebasing logic.
   - Implement callbacks/hooks.

## Testing

To run the tests, do the following:

```
forge test
```

***
*The IP in this repository was assigned to Mars SPC Limited in respect of the MarsOne SP*
