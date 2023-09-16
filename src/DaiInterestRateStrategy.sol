// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IERC20 }    from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import { DataTypes } from 'aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol';

import { IReserveInterestRateStrategy }
    from 'aave-v3-core/contracts/interfaces/IReserveInterestRateStrategy.sol';

import { IInterestRateDataSource } from './interfaces/IInterestRateDataSource.sol';

/**
 *  @title DaiInterestRateStrategy
 *  @notice Flat interest rate curve which is a spread on the Subsidy Rate unless Allocators
 *          need liquidity.
 *  @dev    The interest rate strategy is intended to be used by SparkLend Pools within the context
 *          of the Maker Allocation System. Further, is implemented for DAI so that the SparkLend
 *          protocol should be able to unwind in case of debt limit changes downwards by
 *          incentivizing borrowers and lenders to move DAI into the protocol.
 *          Hence, it operates in two modes. Namely, it distinguishes the unhealthy scenario,
 *          where the Allocators supplied too much (targetDebt < currentDebt), from the healthy one,
 *          where the allocation is healthy.
 *
 *  Note that the spread is constant, while the subsidy rate is queried from the Spark Conduit.
 *  The base borrow rate is defined as:
 *
 *  ```
 *  Rbase = min(Rsubsidy + Rspread, Rmax)
 *  ```
 *
 *  Meaning, that the sum of the base rate and the spread cannot exceed the maximum rate.
 *
 *  This is done by clamping the subsidy rate before calculating the base borrow rate:
 *
 *  ```
 *  Rsubsidy = min(Rsubsidy, Rmax - Rspread)
 *  ```
 *
 *  Assume the allocation is healthy. The borrow rate is a constant defined as the subsidy
 *  rate + spread. The supply rate is computed as the borrow rate, multiplied with the ratio
 *  of the amount, that went over the premium and the total liquidity (borrows + available capital)
 *  in the pool. Hence, the rates can be described as follows:
 *
 *  ```
 *  Rborrow = Rbase
 *  Rsupply = Rborrow *  Cborrowed / (Cborrowed + Cavailable) or 0 if Cborrowed + Cavailable == 0
 *  ```
 *
 *  Note in the healthy case that the borrow rate is always constant. Therefore, third-party
 *  suppliers are not incentivized as the supply rate will be below market rate unless allocators
 *  need capital returned.
 *
 *  In case the allocation is unhealthy, meaning that the debt is higher than the target debt,
 *  the allocators will try to wind down. In that scenario, the interest rate strategy will
 *  incentivize borrowers to pay back their debt, and will try to incentivize suppliers to start
 *  lending DAI. Hence, the borrow and supply rate will increase according to the debt ratio of the
 *  D3M. More specifically, the rates are defined as:
 *
 *  ```
 *  Rborrow = Rmax − (Rmax − Rbase) / debtRatio
 *  Rsupply = Rborrow *  Cborrowed / (Cborrowed + Cavailable)
 *  ```
 *
 *  Note, that if the debt ratio increases, the borrow rate increases as a negated inverse function
 *  (starting at the regular borrowing rate). Similarly, the supply rate will increase in terms of
 *  the debt ratio, however, scaled by the utilization ratio. Thus, the higher the utilization, the
 *  closer will the supply rate be to the borrow rate. Ultimately, that leads to the protocol
 *  forfeiting potential revenue by sharing it with third-party supplier to incentivize the
 *  allocators stabilization. Note that the stable borrow rate is always 0.
 *
 *  The interest rate definition described above is implemented in calculateInterestRates().
 *  However, note that the debt ratio and the base borrow rate are both not queried on every
 *  interest rate calculation; but, retrieved from a cache (as these will not change often).
 *  The variables can be recomputed with function recompute() that sets the base borrow rate to
 *  the current subsidy rate + spread and computes the debt ratio as the ratio of the currentDebt
 *  and targetDebt. It is assumed that the recomputation is triggered on a regular basis.
 *
 *  Only supports variable interest pool.
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

    uint256 private constant WAD = 10 ** 18;
    uint256 private constant RAY = 10 ** 27;

    address                 public immutable asset;
    IInterestRateDataSource public immutable dataSource;
    uint256                 public immutable spread;
    uint256                 public immutable maxRate;

    Slot0 private _slot0;

    /**
     *  @param _asset      The asset this strategy is for
     *  @param _dataSource Interest rate data source
     *  @param _spread     The spread to apply on top of the subsidy rate for the borrow rate
     *  @param _maxRate    The maximum rate that can be returned by this strategy in RAY units
     */
    constructor(
        address _asset,
        IInterestRateDataSource _dataSource,
        uint256 _spread,
        uint256 _maxRate
    ) {
        require(_maxRate >= _spread, "DaiInterestRateStrategy/spread-too-large");

        asset      = _asset;
        dataSource = _dataSource;
        spread     = _spread;
        maxRate    = _maxRate;

        recompute();
    }

    /**
     *  @notice Fetch debt ceiling and base borrow rate. Expensive operation should be called
     *          only when underlying values change.
     *  @dev    This incurs a lot of SLOADs and infrequently changes.
     *          No need to call this on every calculation.
     */
    function recompute() public {
        IInterestRateDataSource.InterestData memory data = dataSource.getInterestData(asset);

        // Base borrow rate cannot be larger than the max rate
        uint256 subsidyRate = data.subsidyRate;
        if (subsidyRate + spread > maxRate) {
            unchecked {
                // This is safe because spread <= maxRate in constructor
                subsidyRate = maxRate - spread;
            }
        }

        uint256 debtRatio;
        if (data.currentDebt > 0) {
            if (data.targetDebt > 0) {
                debtRatio = data.currentDebt * WAD / data.targetDebt;
                if (debtRatio > type(uint88).max) {
                    debtRatio = type(uint88).max;
                }
            } else {
                debtRatio = type(uint88).max;
            }
        } else {
            debtRatio = 0;
        }

        _slot0 = Slot0({
            debtRatio:           uint88(debtRatio),
            baseBorrowRate:      uint128(subsidyRate + spread),
            lastUpdateTimestamp: uint40(block.timestamp)
        });
    }

    /// @inheritdoc IReserveInterestRateStrategy
    function calculateInterestRates(DataTypes.CalculateInterestRatesParams memory params)
        external view override
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

        uint256 debtRatio  = slot0.debtRatio;
        variableBorrowRate = slot0.baseBorrowRate;

        if (debtRatio > WAD) {
            // debt > debt ceiling - rates increase until debt is brought
            // back down to the debt ceiling
            uint256 maxRateDelta;
            unchecked {
                // Safety enforced by conditional above
                maxRateDelta = maxRate - variableBorrowRate;
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
