// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

/**
 * @title IInterestRateDataSource
 * @notice Interface for providing data related to interest rates for various assets.
 */
interface IInterestRateDataSource {

    /**
     * @dev Struct representing the interest related data for an asset.
     * @param baseRate The Maker base rate.
     * @param subsidyRate The Maker subsidy rate.
     * @param currentDebt The current debt of the asset.
     * @param targetDebt The target debt of the asset.
     */
    struct InterestData {
        uint128 baseRate;
        uint128 subsidyRate;
        uint128 currentDebt;
        uint128 targetDebt;
    }

    /**
     * @notice Function to get the interest related data for an asset.
     * @param asset The address of the asset.
     * @return data InterestData structure containing base rate, subsidy rate, current debt and target debt.
     */
    function getInterestData(address asset) external view returns (InterestData memory data);

}
