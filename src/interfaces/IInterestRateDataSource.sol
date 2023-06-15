// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

interface IInterestRateDataSource {

    struct InterestData {
        uint128 baseRate;
        uint128 subsidyRate;
        uint128 currentDebt;
        uint128 targetDebt;
    }

    function getInterestData() external view returns (InterestData memory data);

}
