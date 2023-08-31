// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IPool }      from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { WadRayMath } from 'aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol';

import { UpgradeableProxied } from "upgradeable-proxy/UpgradeableProxied.sol";

import { IERC20 }    from 'erc20-helpers/interfaces/IERC20.sol';
import { SafeERC20 } from 'erc20-helpers/SafeERC20.sol';

import { IInterestRateDataSource }          from './interfaces/IInterestRateDataSource.sol';
import { ISparkConduit, IAllocatorConduit } from './interfaces/ISparkConduit.sol';

interface PotLike {
    function dsr() external view returns (uint256);
}

interface RolesLike {
    function canCall(bytes32, address, address, bytes4) external view returns (bool);
}

interface RegistryLike {
    function buffers(bytes32 ilk) external view returns (address buffer);
}

contract SparkConduit is UpgradeableProxied, ISparkConduit, IInterestRateDataSource {

    using WadRayMath for uint256;
    using SafeERC20 for address;

    // Please note shares/pendingWithdrawals are in aToken "shares" instead of the underlying asset
    struct Position {
        uint256 shares;
        uint256 pendingWithdrawals;
    }

    // Please note totalShares/totalPendingWithdrawals are in aToken "shares"
    // instead of the underlying asset
    struct AssetData {
        bool enabled;
        uint256 totalShares;
        uint256 totalPendingWithdrawals;
        mapping (bytes32 => Position) positions;
    }

    // -- Storage --

    mapping(address => AssetData) private assets;

    /// @inheritdoc ISparkConduit
    address public roles;
    /// @inheritdoc ISparkConduit
    address public registry;
    /// @inheritdoc ISparkConduit
    uint256 public subsidySpread;

    // -- Immutable/constant --

    /// @inheritdoc ISparkConduit
    IPool   public immutable pool;
    /// @inheritdoc ISparkConduit
    address public immutable pot;

    uint256 private constant RAY = 10 ** 27;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    modifier auth() {
        require(wards[msg.sender] == 1, "SparkConduit/not-authorized");
        _;
    }

    modifier ilkAuth(bytes32 ilk) {
        require(
            RolesLike(roles).canCall(ilk, msg.sender, address(this), msg.sig),
            "SparkConduit/ilk-not-authorized"
        );
        _;
    }

    constructor(IPool  _pool, address _pot) {
        pool = _pool;
        pot  = _pot;
    }

    /// @inheritdoc IAllocatorConduit
    function deposit(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        require(assets[asset].enabled, "SparkConduit/asset-disabled");
        require(
            assets[asset].positions[ilk].pendingWithdrawals == 0,
            "SparkConduit/no-deposit-with-pending-withdrawals"
        );
        require(amount <= maxDeposit(ilk, asset), "SparkConduit/max-deposit-exceeded");

        address source = RegistryLike(registry).buffers(ilk);

        asset.safeTransferFrom(source, address(this), amount);

        pool.supply(asset, amount, address(this), 0);

        // Convert asset amount to shares
        uint256 shares = amount.rayDiv(pool.getReserveNormalizedIncome(asset));

        assets[asset].positions[ilk].shares += shares;
        assets[asset].totalShares           += shares;

        emit Deposit(ilk, asset, source, amount);
    }

    /// @inheritdoc IAllocatorConduit
    function withdraw(bytes32 ilk, address asset, uint256 maxAmount)
        external ilkAuth(ilk) returns (uint256 amount)
    {
        uint256 liquidityAvailable
            = IERC20(asset).balanceOf(pool.getReserveData(asset).aTokenAddress);

        // Constrain by the amount of liquidity available of the token
        amount = liquidityAvailable < maxAmount ? liquidityAvailable : maxAmount;
        
        // Constrain by the amount of shares this ilk has
        uint256 ilkDeposits = assets[asset].positions[ilk].shares.rayMul(pool.getReserveNormalizedIncome(asset));
        amount = ilkDeposits < maxAmount ? ilkDeposits : maxAmount;

        // Normally you should update local state first for re-entrancy,
        // but we need an update-to-date liquidity index for that
        amount = pool.withdraw(asset, amount, address(this));
        uint256 shares = amount.rayDiv(pool.getReserveNormalizedIncome(asset));

        assets[asset].positions[ilk].shares -= shares;
        assets[asset].totalShares           -= shares;

        uint256 withdrawals = assets[asset].positions[ilk].pendingWithdrawals;
        if (withdrawals > 0) {
            if (shares <= withdrawals) {
                assets[asset].positions[ilk].pendingWithdrawals -= shares;
                assets[asset].totalPendingWithdrawals           -= shares;
            } else {
                assets[asset].positions[ilk].pendingWithdrawals = 0;
                assets[asset].totalPendingWithdrawals           -= withdrawals;
            }
        }

        address destination = RegistryLike(registry).buffers(ilk);

        asset.safeTransfer(destination, amount);

        emit Withdraw(ilk, asset, destination, amount);
    }

    /// @inheritdoc IAllocatorConduit
    function maxDeposit(bytes32, address asset) public view returns (uint256 maxDeposit_) {
        // Note: Purposefully ignoring any potental supply cap limits on Spark
        return assets[asset].enabled ? type(uint256).max : 0;
    }

    /// @inheritdoc IAllocatorConduit
    function maxWithdraw(bytes32 ilk, address asset) public view returns (uint256 maxWithdraw_) {
        maxWithdraw_ = assets[asset].positions[ilk].shares.rayMul(pool.getReserveNormalizedIncome(asset));
        uint256 liquidityAvailable = IERC20(asset).balanceOf(pool.getReserveData(asset).aTokenAddress);
        if (maxWithdraw_ > liquidityAvailable) maxWithdraw_ = liquidityAvailable;
    }

    /// @inheritdoc ISparkConduit
    function requestFunds(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        uint256 liquidityAvailable = IERC20(asset).balanceOf(pool.getReserveData(asset).aTokenAddress);
        require(liquidityAvailable == 0, "SparkConduit/non-zero-liquidity");

        // Convert asset amount to shares
        uint256 shares = amount.rayDiv(pool.getReserveNormalizedIncome(asset));

        uint256 pshares = assets[asset].positions[ilk].shares;
        require(shares <= pshares, "SparkConduit/amount-too-large");

        uint256 prevWithdrawals = assets[asset].positions[ilk].pendingWithdrawals;

        assets[asset].positions[ilk].pendingWithdrawals = shares;
        assets[asset].totalPendingWithdrawals= assets[asset].totalPendingWithdrawals + shares - prevWithdrawals;

        emit RequestFunds(ilk, asset, amount);
    }

    /// @inheritdoc ISparkConduit
    function cancelFundRequest(bytes32 ilk, address asset) external ilkAuth(ilk) {
        uint256 withdrawals = assets[asset].positions[ilk].pendingWithdrawals;
        require(withdrawals > 0, "SparkConduit/no-active-fund-requests");

        assets[asset].positions[ilk].pendingWithdrawals = 0;
        assets[asset].totalPendingWithdrawals           -= withdrawals;

        emit CancelFundRequest(ilk, asset);
    }

    /// @inheritdoc IInterestRateDataSource
    function getInterestData(address asset) external view returns (InterestData memory data) {
        // Convert the DSR to a yearly APR
        uint256 dsr    = (PotLike(pot).dsr() - RAY) * SECONDS_PER_YEAR;
        uint256 shares = assets[asset].totalShares;
        uint256 index  = pool.getReserveNormalizedIncome(asset);

        return InterestData({
            baseRate:    uint128(dsr + subsidySpread),
            subsidyRate: uint128(dsr),
            currentDebt: uint128(shares.rayMul(index)),
            targetDebt:  uint128((shares - assets[asset].totalPendingWithdrawals).rayMul(index))
        });
    }

    /// @inheritdoc ISparkConduit
    function setRoles(address _roles) external auth {
        roles = _roles;

        emit SetRoles(_roles);
    }

    /// @inheritdoc ISparkConduit
    function setRegistry(address _registry) external auth {
        registry = _registry;

        emit SetRegistry(_registry);
    }

    /// @inheritdoc ISparkConduit
    function setSubsidySpread(uint256 _subsidySpread) external auth {
        subsidySpread = _subsidySpread;

        emit SetSubsidySpread(_subsidySpread);
    }

    /// @inheritdoc ISparkConduit
    function setAssetEnabled(address asset, bool enabled) external auth {
        assets[asset].enabled = enabled;
        asset.safeApprove(address(pool), enabled ? type(uint256).max : 0);

        emit SetAssetEnabled(asset, enabled);
    }

    /// @inheritdoc ISparkConduit
    function getAssetData(address asset)
        external view returns (bool _enabled, uint256 _totalDeposits, uint256 _totalWithdrawals)
    {
        uint256 liquidityIndex = pool.getReserveNormalizedIncome(asset);
        return (
            assets[asset].enabled,
            assets[asset].totalShares.rayMul(liquidityIndex),
            assets[asset].totalPendingWithdrawals.rayMul(liquidityIndex)
        );
    }

    /// @inheritdoc ISparkConduit
    function isAssetEnabled(address asset) external view returns (bool) {
        return assets[asset].enabled;
    }

    /// @inheritdoc ISparkConduit
    function getTotalDeposits(address asset) external view returns (uint256) {
        return assets[asset].totalShares.rayMul(pool.getReserveNormalizedIncome(asset));
    }

    /// @inheritdoc ISparkConduit
    function getTotalPendingWithdrawals(address asset) external view returns (uint256) {
        return assets[asset].totalPendingWithdrawals.rayMul(pool.getReserveNormalizedIncome(asset));
    }

    /// @inheritdoc ISparkConduit
    function getPosition(bytes32 ilk, address asset)
        external view returns (uint256 _deposits, uint256 _pendingWithdrawals)
    {
        uint256 liquidityIndex = pool.getReserveNormalizedIncome(asset);
        Position memory position = assets[asset].positions[ilk];
        return (
            position.shares.rayMul(liquidityIndex),
            position.pendingWithdrawals.rayMul(liquidityIndex)
        );
    }

    /// @inheritdoc ISparkConduit
    function getDeposits(bytes32 ilk, address asset) external view returns (uint256) {
        return
            assets[asset].positions[ilk].shares
                .rayMul(pool.getReserveNormalizedIncome(asset));
    }

    /// @inheritdoc ISparkConduit
    function getPendingWithdrawals(bytes32 ilk, address asset) external view returns (uint256) {
        return
            assets[asset].positions[ilk].pendingWithdrawals
                .rayMul(pool.getReserveNormalizedIncome(asset));
    }

}
