// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IPool } from 'aave-v3-core/interfaces/IPool.sol';
import { DataTypes } from 'aave-v3-core/protocol/libraries/types/DataTypes.sol';
import { IERC20 } from 'aave-v3-core/dependencies/openzeppelin/contracts/IERC20.sol';

import { ISparkConduit } from './interfaces/ISparkConduit.sol';
import { IInterestRateDataSource } from './interfaces/IInterestRateDataSource.sol';

interface PotLike {
    function dsr() external view returns (uint256);
}

contract SparkConduit is ISparkConduit, IInterestRateDataSource {

    struct DomainPosition {
        uint256 currentDebt;
        uint256 targetDebt;
    }

    struct AssetConfiguration {
        bool enabled;
        uint256 totalCurrentDebt;
        uint256 totalTargetDebt;
        mapping (bytes32 => DomainPosition) positions;
    }

    uint256 private constant RAY = 10 ** 27;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    IPool public immutable pool;
    PotLike public immutable pot;

    uint256 public subsidySpread;

    mapping (address => AssetConfiguration) private assets;

    event RequestFunds(bytes32 indexed allocator, address indexed asset, uint256 amount, bytes data, uint256 fundRequestId);

    event CancelRequest(bytes32 indexed allocator, address indexed asset, uint256 amount, bytes data, uint256 fundRequestId);

    constructor(
        IPool _pool,
        address _pot
    ) {
        pool = _pool;
        pot = PotLike(_pot);

        token.approve(address(pool), type(uint256).max);
    }

    function deposit(bytes32 domain, address asset, uint256 amount) external override canDomain(domain) {
        require(assets[asset].enabled, "SparkConduit/asset-disabled");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount),  "SparkConduit/transfer-failed");
        
        pool.supply(asset, amount, address(this), 0);

        DomainPosition memory position = assets[asset].positions[domain];
        uint256 prevCurrentDebt = position.currentDebt;
        uint256 prevTargetDebt = position.prevTargetDebt;
        if (position.currentDebt > position.targetDebt) {
            // There is pending fund requests that can be cancelled out
            position.targetDebt += amount;
            if (position.currentDebt < position.targetDebt) {
                position.currentDebt = position.targetDebt;
            }
        } else {
            // No pending fund requests
            position.currentDebt += amount;
            position.targetDebt = position.currentDebt;
        }
        assets[asset].positions[domain] = position;
        assets[asset].totalCurrentDebt = position.currentDebt - prevCurrentDebt;
        assets[asset].totalTargetDebt = position.targetDebt - prevTargetDebt;

        emit Deposit(domain, asset, amount);
    }

    function withdraw(bytes32 domain, address asset, address destination, uint256 amount) external override canDomain(domain) {
        DomainPosition memory position = assets[asset].positions[domain];
        if (position.currentDebt > position.targetDebt) {
            // There is pending fund requests that can be cancelled out
            position.currentDebt -= amount;
            if (position.currentDebt < position.targetDebt) {
                position.targetDebt = position.currentDebt;
            }
        } else {
            // No pending fund requests
            position.currentDebt += amount;
            position.targetDebt = position.currentDebt;
        }
        assets[asset].positions[domain] = position;
        assets[asset].totalCurrentDebt = prevCurrentDebt - position.currentDebt;
        assets[asset].totalTargetDebt = prevTargetDebt - position.targetDebt;

        pool.withdraw(asset, amount, destination);

        emit Withdraw(domain, asset, destination, amount);
    }

    function maxDeposit(bytes32, address) external view returns (uint256 maxDeposit_) {
        maxDeposit_ = type(uint256).max;   // Purposefully ignoring any potental supply cap limits
    }

    function maxWithdraw(bytes32 allocator, address asset) public view returns (uint256 maxWithdraw_) {
        maxWithdraw_ = assets[asset].positions[domain].currentDebt;

        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
        uint256 liquidityAvailable = IERC20(asset).balanceOf(reserveData.aTokenAddress);
        if (maxWithdraw_ > liquidityAvailable) maxWithdraw_ = liquidityAvailable;
    }

    function requestFunds(bytes32 domain, address asset, uint256 amount, bytes memory data) external override canDomain(domain) returns (uint256 fundRequestId) {
        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
        uint256 liquidityAvailable = IERC20(asset).balanceOf(reserveData.aTokenAddress);
        require(liquidityAvailable == 0, "SparkConduit/must-withdraw-all-available-liquidity-first");

        RequestFundsHints memory hints = RequestFundsHints({
            urgencyMultiplier: WAD
        });
        if (data.length > 0) {
            // There are custom hints
            hints = abi.decode(data, (RequestFundsHints));
            require(hints.urgencyMultiplier <= WAD, "SparkConduit/invalid-hints");
            amount = amount * hints.urgencyMultiplier / WAD;
        }

        assets[asset].positions[domain].targetDebt -= amount;
        assets[asset].targetDebt -= amount;

        fundRequestId = 0;

        emit RequestFunds(domain, asset, amount, data);
    }

    function cancelFundRequest(bytes32 domain, address asset, uint256 fundRequestId) external override {
        require(fundRequestId == 0, "SparkConduit/invalid-fund-request-id");

        Position memory position = assets[asset].positions[domain];
        require(position.targetDebt < position.currentDebt, "SparkConduit/no-active-fund-requests");
        uint256 delta = position.targetDebt - position.currentDebt;
        position.targetDebt = position.currentDebt;
        assets[asset].targetDebt += delta;

        emit cancelFundRequest(domain, asset, fundRequestId);
    }

    function isCancelable(bytes32 domain, address asset, uint256 fundRequestId) external override view returns (bool isCancelable_) {
        require(fundRequestId == 0, "SparkConduit/invalid-fund-request-id");

        isCancelable_ = assets[asset].positions[domain].targetDebt < assets[asset].positions[domain].currentDebt;
    }

    function activeFundRequests(bytes32 domain, address asset) external override returns (uint256[] memory fundRequestIds, uint256 totalAmount) {
        // TODO figure out if these are necessary
    }

    function totalActiveFundRequests(address asset) external override returns (uint256 totalAmount) {
        // TODO figure out if these are necessary
    }

    /// @inheritdoc IInterestRateDataSource
    function getInterestData(address asset) external override view returns (InterestData memory data) {
        // Convert the DSR a yearly APR
        uint256 dsr = (PotLike(pot).dsr() - RAY) * SECONDS_PER_YEAR;

        return InterestData({
            baseRate: uint128(dsr + subsidySpread),
            subsidyRate: uint128(dsr),
            currentDebt: uint128(assets[asset].currentDebt),
            targetDebt: uint128(assets[asset].targetDebt)
        });
    }

    function setSubsidySpread(uint256 _subsidySpread) external auth {
        subsidySpread = _subsidySpread;

        emit SetSubsidySpread(subsidySpread);
    }

    function setAssetEnabled(address asset, bool enabled) external auth {
        assets[asset].enabled = enabled;

        emit SetAssetEnabled(asset, enabled);
    }

    function getAssetConfiguration(address asset) external view returns (bool enabled, uint256 totalCurrentDebt, uint256 totalTargetDebt) {
        AssetConfiguration memory config = assets[asset];
        return (
            config.enabled,
            config.totalCurrentDebt,
            config.totalTargetDebt
        );
    }

    function getDomainPosition(bytes32 domain, address asset) external view returns (uint256 currentDebt, uint256 targetDebt) {
        DomainPosition memory position = assets[asset].positions[domain];
        return (
            position.currentDebt,
            position.targetDebt
        );
    }

}
