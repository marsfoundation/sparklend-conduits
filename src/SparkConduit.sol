// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { DataTypes } from 'aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol';
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

    // Please note deposits/withdrawals are in aToken "shares" instead of the underlying asset
    struct DomainPosition {
        uint256 deposits;
        uint256 withdrawals;
    }

    // Please note totalDeposits/totalWithdrawals are in aToken "shares" instead of the underlying asset
    struct AssetData {
        bool enabled;
        uint256 totalDeposits;
        uint256 totalWithdrawals;
        mapping (bytes32 => DomainPosition) positions;
    }

    uint256 private constant WAD = 10 ** 18;
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

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event RequestFunds(bytes32 indexed allocator, address indexed asset, uint256 amount, bytes data, uint256 fundRequestId);
    event CancelRequest(bytes32 indexed allocator, address indexed asset, uint256 amount, bytes data, uint256 fundRequestId);

    modifier auth() {
        require(wards[msg.sender] == 1, "SparkConduit/not-authorized");
        _;
    }

    modifier domainAuth(bytes32 domain) {
        require(RolesLike(roles).canCall(domain, msg.sender, address(this), msg.sig), "SparkConduit/domain-not-authorized");
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
    }

    /// @inheritdoc IAuth
    function rely(address usr) external override auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /// @inheritdoc IAuth
    function deny(address usr) external override auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    /// @inheritdoc IAllocatorConduit
    function deposit(bytes32 domain, address asset, uint256 amount) external override domainAuth(domain) {
        require(assets[asset].enabled, "SparkConduit/asset-disabled");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount),  "SparkConduit/transfer-failed");
        
        pool.supply(asset, amount, address(this), 0);

        // Convert asset amount to shares
        uint256 liquidityIndex = pool.getReserveData(asset).liquidityIndex;
        amount = amount * RAY / liquidityIndex;

        uint256 withdrawals = assets[asset].positions[domain].withdrawals;
        if (amount <= withdrawals) {
            assets[asset].positions[domain].withdrawals -= amount;
            assets[asset].totalWithdrawals -= amount;
        } else {
            uint256 depositDelta = amount - withdrawals;

            assets[asset].positions[domain].deposits += depositDelta;
            assets[asset].totalDeposits += depositDelta;
            assets[asset].positions[domain].withdrawals = 0;
            assets[asset].totalWithdrawals -= withdrawals;
        }

        emit Deposit(domain, asset, amount);
    }

    /// @inheritdoc IAllocatorConduit
    function withdraw(bytes32 domain, address asset, address destination, uint256 amount) external override domainAuth(domain) {
        // Normally you should update state first for re-entrancy, but we need an update-to-date liquidity index for that
        pool.withdraw(asset, amount, destination);

        // Convert asset amount to shares
        uint256 liquidityIndex = pool.getReserveData(asset).liquidityIndex;
        amount = amount * RAY / liquidityIndex;

        uint256 withdrawals = assets[asset].positions[domain].withdrawals;
        if (amount <= withdrawals) {
            assets[asset].positions[domain].withdrawals -= amount;
            assets[asset].totalWithdrawals -= amount;
        } else {
            uint256 depositDelta = amount - withdrawals;

            assets[asset].positions[domain].deposits -= depositDelta;
            assets[asset].totalDeposits -= depositDelta;
            assets[asset].positions[domain].withdrawals = 0;
            assets[asset].totalWithdrawals -= withdrawals;
        }

        emit Withdraw(domain, asset, destination, amount);
    }

    /// @inheritdoc IAllocatorConduit
    function maxDeposit(bytes32, address) external override pure returns (uint256 maxDeposit_) {
        maxDeposit_ = type(uint256).max;   // Purposefully ignoring any potental supply cap limits
    }

    /// @inheritdoc IAllocatorConduit
    function maxWithdraw(bytes32 domain, address asset) public override view returns (uint256 maxWithdraw_) {
        maxWithdraw_ = assets[asset].positions[domain].deposits;

        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
        uint256 liquidityAvailable = IERC20(asset).balanceOf(reserveData.aTokenAddress);
        if (maxWithdraw_ > liquidityAvailable) maxWithdraw_ = liquidityAvailable;
    }

    /// @inheritdoc ISparkConduit
    function requestFunds(bytes32 domain, address asset, uint256 amount) external override domainAuth(domain) {
        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
        uint256 liquidityAvailable = IERC20(asset).balanceOf(reserveData.aTokenAddress);
        require(liquidityAvailable == 0, "SparkConduit/must-withdraw-all-available-liquidity-first");

        // Convert asset amount to shares
        // Please note the interest conversion may be slightly out of date as there is no index update
        uint256 liquidityIndex = pool.getReserveData(asset).liquidityIndex;
        amount = amount * RAY / reserveData.liquidityIndex;

        assets[asset].positions[domain].withdrawals += amount;
        assets[asset].totalWithdrawals += amount;

        emit RequestFunds(domain, asset, amount);
    }

    /// @inheritdoc ISparkConduit
    function cancelFundRequest(bytes32 domain, address asset) external override domainAuth(domain) {
        uint256 withdrawals = assets[asset].positions[domain].withdrawals;
        require(withdrawals > 0, "SparkConduit/no-active-fund-requests");
        assets[asset].positions[domain].withdrawals = 0;
        assets[asset].totalWithdrawals -= withdrawals;

        emit CancelFundRequest(domain, asset);
    }

    /// @inheritdoc IInterestRateDataSource
    function getInterestData(address asset) external override view returns (InterestData memory data) {
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
    function getAssetData(address asset) external view returns (bool enabled, uint256 totalDeposits, uint256 totalWithdrawals) {
        return (
            assets[asset].enabled,
            assets[asset].totalDeposits,
            assets[asset].totalWithdrawals
        );
    }

    /// @inheritdoc ISparkConduit
    function getDomainPosition(bytes32 domain, address asset) external view returns (uint256 deposits, uint256 withdrawals) {
        DomainPosition memory position = assets[asset].positions[domain];
        return (
            position.deposits,
            position.withdrawals
        );
    }

}
