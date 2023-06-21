// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { DataTypes } from 'aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol';
import { WadRayMath } from 'aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol';
import { IERC20 } from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

import { IAuth } from './interfaces/IAuth.sol';
import { ISparkConduit, IAllocatorConduit } from './interfaces/ISparkConduit.sol';
import { IInterestRateDataSource } from './interfaces/IInterestRateDataSource.sol';

interface PotLike {
    function dsr() external view returns (uint256);
}

interface RolesLike {
    function canCall(bytes32, address, address, bytes4) external view returns (bool);
}

contract SparkConduit is ISparkConduit, IInterestRateDataSource {

    using WadRayMath for uint256;

    // Please note deposits/withdrawals are in aToken "shares" instead of the underlying asset
    struct Position {
        uint256 deposits;
        uint256 withdrawals;
    }

    // Please note totalDeposits/totalWithdrawals are in aToken "shares" instead of the underlying asset
    struct AssetData {
        bool enabled;
        uint256 totalDeposits;
        uint256 totalWithdrawals;
        mapping (bytes32 => Position) positions;
    }

    uint256 private constant RAY = 10 ** 27;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @inheritdoc IAuth
    mapping(address => uint256)   public  wards;
    mapping(address => AssetData) private assets;

    /// @inheritdoc ISparkConduit
    IPool   public immutable pool;
    /// @inheritdoc ISparkConduit
    address public immutable pot;
    /// @inheritdoc ISparkConduit
    address public immutable roles;

    /// @inheritdoc ISparkConduit
    uint256 public subsidySpread;

    modifier auth() {
        require(wards[msg.sender] == 1, "SparkConduit/not-authorized");
        _;
    }

    modifier ilkAuth(bytes32 ilk) {
        require(RolesLike(roles).canCall(ilk, msg.sender, address(this), msg.sig), "SparkConduit/ilk-not-authorized");
        _;
    }

    constructor(
        IPool _pool,
        address _pot,
        address _roles
    ) {
        pool  = _pool;
        pot   = _pot;
        roles = _roles;

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    /// @inheritdoc IAuth
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /// @inheritdoc IAuth
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    /// @inheritdoc IAllocatorConduit
    function deposit(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        require(assets[asset].enabled, "SparkConduit/asset-disabled");
        require(assets[asset].positions[ilk].withdrawals == 0, "SparkConduit/no-deposit-with-pending-withdrawals");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount),  "SparkConduit/transfer-failed");
        
        pool.supply(asset, amount, address(this), 0);

        // Convert asset amount to shares
        uint256 shares = amount.rayDiv(pool.getReserveData(asset).liquidityIndex);

        assets[asset].positions[ilk].deposits += shares;
        assets[asset].totalDeposits += shares;

        emit Deposit(ilk, asset, amount);
    }

    /// @inheritdoc IAllocatorConduit
    function withdraw(bytes32 ilk, address asset, address destination, uint256 maxAmount) external ilkAuth(ilk) returns (uint256 amount) {
        // Normally you should update local state first for re-entrancy, but we need an update-to-date liquidity index for that
        amount = pool.withdraw(asset, maxAmount, address(this));

        // Convert asset amount to shares
        uint256 liquidityIndex = pool.getReserveData(asset).liquidityIndex;
        uint256 shares = amount.rayDiv(liquidityIndex);

        uint256 deposits = assets[asset].positions[ilk].deposits;
        uint256 withdrawals = assets[asset].positions[ilk].withdrawals;

        if (deposits < shares) {
            uint256 toReturnShares;
            unchecked {
                toReturnShares = shares - deposits;
            }
            uint256 toReturn = toReturnShares.rayMul(liquidityIndex);
            amount -= toReturn;
            shares = deposits;

            // Return the excess to the pool as it's other user's deposits
            // Round against the user that is withdrawing
            pool.supply(asset, toReturn, address(this), 0);
            IERC20(asset).transfer(destination, amount);
        } else {
            IERC20(asset).transfer(destination, amount);
        }

        assets[asset].positions[ilk].deposits -= shares;
        assets[asset].totalDeposits -= shares;
        if (withdrawals > 0) {
            if (shares <= withdrawals) {
                assets[asset].positions[ilk].withdrawals -= shares;
                assets[asset].totalWithdrawals -= shares;
            } else {
                assets[asset].positions[ilk].withdrawals = 0;
                assets[asset].totalWithdrawals -= withdrawals;
            }
        }

        emit Withdraw(ilk, asset, destination, amount);
    }

    /// @inheritdoc IAllocatorConduit
    function maxDeposit(bytes32, address) external pure returns (uint256 maxDeposit_) {
        maxDeposit_ = type(uint256).max;   // Purposefully ignoring any potental supply cap limits
    }

    /// @inheritdoc IAllocatorConduit
    function maxWithdraw(bytes32 ilk, address asset) public view returns (uint256 maxWithdraw_) {
        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
        maxWithdraw_ = assets[asset].positions[ilk].deposits.rayMul(reserveData.liquidityIndex);
        uint256 liquidityAvailable = IERC20(asset).balanceOf(reserveData.aTokenAddress);
        if (maxWithdraw_ > liquidityAvailable) maxWithdraw_ = liquidityAvailable;
    }

    /// @inheritdoc ISparkConduit
    function requestFunds(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
        uint256 liquidityAvailable = IERC20(asset).balanceOf(reserveData.aTokenAddress);
        // TODO Confirm that we can get the liquidity to exact zero -- may be sometimes impossible due to rounding
        require(liquidityAvailable == 0, "SparkConduit/must-withdraw-all-available-liquidity-first");

        // Convert asset amount to shares
        // Please note the interest conversion may be slightly out of date as there is no index update
        // This is fine though because we are not translating this into exact withdrawals anyways
        uint256 shares = amount.rayDiv(pool.getReserveData(asset).liquidityIndex);

        uint256 deposits = assets[asset].positions[ilk].deposits;
        require(shares <= deposits, "SparkConduit/shares-too-large");
        uint256 prevWithdrawals = assets[asset].positions[ilk].withdrawals;
        assets[asset].positions[ilk].withdrawals = shares;
        assets[asset].totalWithdrawals = assets[asset].totalWithdrawals + shares - prevWithdrawals;

        emit RequestFunds(ilk, asset, amount);
    }

    /// @inheritdoc ISparkConduit
    function cancelFundRequest(bytes32 ilk, address asset) external ilkAuth(ilk) {
        uint256 withdrawals = assets[asset].positions[ilk].withdrawals;
        require(withdrawals > 0, "SparkConduit/no-active-fund-requests");
        assets[asset].positions[ilk].withdrawals = 0;
        assets[asset].totalWithdrawals -= withdrawals;

        emit CancelFundRequest(ilk, asset);
    }

    /// @inheritdoc IInterestRateDataSource
    function getInterestData(address asset) external view returns (InterestData memory data) {
        // Convert the DSR a yearly APR
        uint256 dsr = (PotLike(pot).dsr() - RAY) * SECONDS_PER_YEAR;
        uint256 deposits = assets[asset].totalDeposits;

        return InterestData({
            baseRate: uint128(dsr + subsidySpread),
            subsidyRate: uint128(dsr),
            currentDebt: uint128(deposits),
            targetDebt: uint128(deposits - assets[asset].totalWithdrawals)
        });
    }

    /// @inheritdoc ISparkConduit
    function setSubsidySpread(uint256 _subsidySpread) external auth {
        subsidySpread = _subsidySpread;

        emit SetSubsidySpread(subsidySpread);
    }

    /// @inheritdoc ISparkConduit
    function setAssetEnabled(address asset, bool enabled) external auth {
        assets[asset].enabled = enabled;
        IERC20(asset).approve(address(pool), enabled ? type(uint256).max : 0);

        emit SetAssetEnabled(asset, enabled);
    }

    /// @inheritdoc ISparkConduit
    function getAssetData(address asset) external view returns (bool _enabled, uint256 _totalDeposits, uint256 _totalWithdrawals) {
        uint256 liquidityIndex = pool.getReserveData(asset).liquidityIndex;
        return (
            assets[asset].enabled,
            assets[asset].totalDeposits.rayMul(liquidityIndex),
            assets[asset].totalWithdrawals.rayMul(liquidityIndex)
        );
    }

    /// @inheritdoc ISparkConduit
    function isAssetEnabled(address asset) external view returns (bool) {
        return assets[asset].enabled;
    }

    /// @inheritdoc ISparkConduit
    function getTotalDeposits(address asset) external view returns (uint256) {
        return assets[asset].totalDeposits.rayMul(pool.getReserveData(asset).liquidityIndex);
    }

    /// @inheritdoc ISparkConduit
    function getTotalWithdrawals(address asset) external view returns (uint256) {
        return assets[asset].totalWithdrawals.rayMul(pool.getReserveData(asset).liquidityIndex);
    }

    /// @inheritdoc ISparkConduit
    function getPosition(bytes32 ilk, address asset) external view returns (uint256 _deposits, uint256 _withdrawals) {
        uint256 liquidityIndex = pool.getReserveData(asset).liquidityIndex;
        Position memory position = assets[asset].positions[ilk];
        return (
            position.deposits.rayMul(liquidityIndex),
            position.withdrawals.rayMul(liquidityIndex)
        );
    }

    /// @inheritdoc ISparkConduit
    function getDeposits(bytes32 ilk, address asset) external view returns (uint256) {
        return assets[asset].positions[ilk].deposits.rayMul(pool.getReserveData(asset).liquidityIndex);
    }

    /// @inheritdoc ISparkConduit
    function getWithdrawals(bytes32 ilk, address asset) external view returns (uint256) {
        return assets[asset].positions[ilk].withdrawals.rayMul(pool.getReserveData(asset).liquidityIndex);
    }

}
