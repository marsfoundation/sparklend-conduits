// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import { IERC20 } from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import { IReserveInterestRateStrategy } from 'aave-v3-core/contracts/interfaces/IReserveInterestRateStrategy.sol';
import { DataTypes } from 'aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol';

import { IInterestRateDataSource } from './interfaces/IInterestRateDataSource.sol';

/**
 * @title DaiInterestRateStrategy
 * @notice Flat interest rate curve which is a spread on the Stability Fee Base Rate unless Allocators needs liquidity.
 * @dev The interest rate strategy is intended to be used by Spark Lend pool that is supplied by a AllocatorDAO Conduit. Further, is implemented for DAI so that a the Spark Lend protocol should be able to unwind as fast as possible in case of debt limit changes downwards by incentivizing borrowers and lenders to move DAI into the protocol. Hence, it operates in two modes. Namely, it distinguishes the unhealthy scenario, where the D3M supplied too much (the Spark Lend D3M ink's debt exceeds the debt limit), from the healthy one, where the D3M is healthy.
 * 
 * Note that the base rate conversion, maximum rate and the borrow and supply spreads are constants, while the DSR rate is queried from Maker's Pot contract. The base rate is defined as:
 * 
 * ```
 * Rbase = min(Rdsr * baseRateConversion, Rmax − RborrowSpread)
 * ```
 * 
 * Meaning, that the sum of the base rate and the borrow spread cannot exceed the maximum rate.
 * 
 * Assume the D3M is healthy. The borrow rate is a constant defined as the Dai Savings Rate plus a borrow spread. While the borrowed amount is below a certain performance value, the supply rate is set to zero. Once the borrowed amount reaches the performance value, the supply rate is computed as the Dai Savings Rate plus a supply spread, multiplied with the ratio of the amount, that went over the premium and the total liquidity (borrows + available capital) in the pool. Hence, the rates can be described as follows:
 * 
 * ```
 * Rborrow = Rbase + RborrowSpread
 * Rsupply = (Rbase + RsupplySpread) * max(0, Cborrowed − Cperformance) / (Cborrowed + Cavailable)
 * ```
 * 
 * Note it yields that the borrow rate is always constant. Further, suppliers are only incentivized to supply capital after a minimum borrow amount is reached. During the times, as the third-party suppliers are not incentivized, we expect that the D3M provides sufficient DAI for the lending market. However, once the protocol makes sufficient profits, it will incentivize third party suppliers (as the D3M will have a certain debt limit).
 * 
 * In case the D3M is unhealthy, meaning that the debt is higher than the debt limit, the D3M will try to wind down. In that scenario, the interest rate strategy will try to incentivize borrowers to pay back their debt, and will try to incentivize suppliers to start lending DAI. Hence, the borrow and supply rate will increase according to the debt ratio of the D3M. More specifically, the rates are defined as:
 * 
 * ```
 * Rborrow = Rmax − (Rmax − (rbase + rborrowSpread)) / debtRatio
 * Rsupply = (Cborrowed / (Cborrowed + Cavailable)) * Rborrow
 * ```
 * 
 * Note, that if the debt ratio increases, the borrow rate increases as a negated inverse function (starting at the regular borrowing rate). Similarly, the supply rate will increase in terms of the debt ratio, however, scaled by the utilization ratio. Thus, the higher the utilization, the closer will the supply rate be to the borrow rate. Ultimately, that leads to the protocol forfeiting potential revenue by sharing it with third-party supplier to incentivize the D3M's stabilization. Note that the stable borrow rate is always 0.
 * 
 * The interest rate definition described above is implemented in calculateInterestRates(). However, note that the debt ratio and the base rate are both not queried on every interest rate calculation; but, retrieved from a cache (as these will not change often). The variables can be recomputed with function recompute() that sets the base rate to the current Dai Savings Rate and computes the debt ratio as the ratio of the current Ilk.Art and current Ilk.line. It is assumed that the recomputation is triggered on a regular basis.
 * 
 * Only supports variable interest pool.
 */
contract DaiInterestRateStrategy is IReserveInterestRateStrategy {

    struct Slot0 {
        // The ratio of outstanding debt to debt ceiling in the vault. Expressed in wad
        uint88 debtRatio;
        // The base borrow rate of the reserve. Expressed in ray
        uint128 baseBorrowRate;
        // Timestamp of last update
        uint40 lastUpdateTimestamp;
    }

    uint256 private constant HWAD = 10 ** 9;
    uint256 private constant WAD = 10 ** 18;
    uint256 private constant RAY = 10 ** 27;
    uint256 private constant RAD = 10 ** 45;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    IInterestRateDataSource public immutable dataSource;
    uint256 public immutable spread;
    uint256 public immutable maxRate;

    Slot0 private _slot0;

    /**
     * @param _dataSource Interest rate data source
     * @param _spread The spread to apply on top of the subsidy rate for the borrow rate
     * @param _maxRate The maximum rate that can be returned by this strategy in RAY units
     */
    constructor(
        IInterestRateDataSource _dataSource,
        uint256 _spread,
        uint256 _maxRate
    ) {
        require(_maxRate >= _spread, "DaiInterestRateStrategy/spread-too-large");

        dataSource = _dataSource;
        spread = _spread;
        maxRate = _maxRate;

        recompute();
    }

    /**
    * @notice Fetch debt ceiling and base borrow rate. Expensive operation should be called only when underlying values change.
    * @dev This incurs a lot of SLOADs and infrequently changes. No need to call this on every calculation.
    */
    function recompute() public {
        IInterestRateDataSource.InterestData memory data = dataSource.getInterestData();
        
        // Base borrow rate cannot be larger than the max rate
        uint256 subsidyRate = data.subsidyRate;
        if (subsidyRate + spread > maxRate) {
            unchecked {
                subsidyRate = maxRate - spread;  // This is safe because spread <= maxRate in constructor
            }
        }

        uint256 debtRatio = data.targetDebt > 0 ? data.currentDebt * WAD / data.targetDebt : type(uint88).max;
        if (debtRatio > type(uint88).max) {
            debtRatio = type(uint88).max;
        }

        _slot0 = Slot0({
            debtRatio: uint88(debtRatio),
            baseBorrowRate: uint128(subsidyRate + spread),
            lastUpdateTimestamp: uint40(block.timestamp)
        });
    }

    /// @inheritdoc IReserveInterestRateStrategy
    function calculateInterestRates(DataTypes.CalculateInterestRatesParams memory params)
        external
        view
        override
        returns (
            uint256 supplyRate,
            uint256 stableBorrowRate,
            uint256 variableBorrowRate
        )
    {
        stableBorrowRate = 0;   // Avoid warning message

        Slot0 memory slot0 = _slot0;

        uint256 outstandingBorrow = params.totalVariableDebt;
        uint256 supplyUtilization;
        
        if (outstandingBorrow > 0) {
            uint256 availableLiquidity =
                IERC20(params.reserve).balanceOf(params.aToken) +
                params.liquidityAdded -
                params.liquidityTaken;
            supplyUtilization = outstandingBorrow * WAD / (availableLiquidity + outstandingBorrow);
        }

        uint256 debtRatio = slot0.debtRatio;
        variableBorrowRate = slot0.baseBorrowRate;

        if (debtRatio > WAD) {
            // debt > debt ceiling - rates increase until debt is brought back down to the debt ceiling
            uint256 maxRateDelta;
            unchecked {
                maxRateDelta = maxRate - variableBorrowRate;  // Safety enforced by conditional above
            }
            
            variableBorrowRate = maxRate - maxRateDelta * WAD / debtRatio;
        }

        // Set the supply rate based on utilization
        supplyRate = variableBorrowRate * supplyUtilization / WAD;
    }

    function getDebtRatio() external view returns (uint256) {
        return _slot0.debtRatio;
    }

    function getBaseBorrowRate() external view returns (uint256) {
        return _slot0.baseBorrowRate;
    }

    function getLastUpdateTimestamp() external view returns (uint256) {
        return _slot0.lastUpdateTimestamp;
    }

}
