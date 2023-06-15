// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import { FIFOConduitBase } from 'dss-conduits/FIFOConduitBase.sol';
import { IPool } from 'aave-v3-core/interfaces/IPool.sol';
import { IERC20 } from 'aave-v3-core/dependencies/openzeppelin/contracts/IERC20.sol';

import { ISparkConduit } from './interfaces/ISparkConduit.sol';
import { IInterestRateDataSource } from './interfaces/IInterestRateDataSource.sol';

interface PotLike {
    function dsr() external view returns (uint256);
}

contract SparkConduit is FIFOConduitBase, ISparkConduit, IInterestRateDataSource {

    uint256 private constant RAY = 10 ** 27;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    IPool public immutable pool;
    IERC20 public immutable token;
    PotLike public immutable pot;

    uint256 public subsidySpread;

    constructor(
        IPool _pool,
        address _token,
        address _pot
    ) {
        pool = _pool;
        token = IERC20(_token);
        pot = PotLike(_pot);

        token.approve(address(pool), type(uint256).max);
    }

    function setSubsidySpread(uint256 _subsidySpread) external auth {
        subsidySpread = _subsidySpread;
    }

    function _deposit(address asset, uint256 amount) internal override {
        pool.supply(asset, amount, address(this), 0);
    }

    function _withdraw(address asset, address destination, uint256 amount) internal override {
        pool.withdraw(asset, amount, destination);
    }

    function getInterestData() external override view returns (InterestData memory data) {
        // Convert the DSR a yearly APR
        uint256 dsr = (PotLike(pot).dsr() - RAY) * SECONDS_PER_YEAR;

        return InterestData({
            baseRate: uint128(dsr + subsidySpread),
            subsidyRate: uint128(dsr),
            currentDebt: uint128(currentDebt),
            targetDebt: uint128(targetDebt)
        });
    }

}
