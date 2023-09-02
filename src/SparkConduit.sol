// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IPool }      from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { WadRayMath } from 'aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol';

import { UpgradeableProxied } from 'upgradeable-proxy/UpgradeableProxied.sol';

import { IERC20 }    from 'erc20-helpers/interfaces/IERC20.sol';
import { SafeERC20 } from 'erc20-helpers/SafeERC20.sol';

import { IInterestRateDataSource } from './interfaces/IInterestRateDataSource.sol';
import { ISparkConduit }           from './interfaces/ISparkConduit.sol';

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

    address public roles;
    address public registry;
    uint256 public subsidySpread;

    // -- Immutable/constant --

    address public immutable pool;
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

    constructor(address _pool, address _pot) {
        pool = _pool;
        pot  = _pot;
    }

    function deposit(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        require(assets[asset].enabled, "SparkConduit/asset-disabled");
        require(
            assets[asset].positions[ilk].pendingWithdrawals == 0,
            "SparkConduit/no-deposit-with-pending-withdrawals"
        );

        address source = RegistryLike(registry).buffers(ilk);

        asset.safeTransferFrom(source, address(this), amount);

        // Convert asset amount to shares
        uint256 shares = amount.rayDiv(IPool(pool).getReserveNormalizedIncome(asset));

        assets[asset].positions[ilk].shares += shares;
        assets[asset].totalShares           += shares;

        IPool(pool).supply(asset, amount, address(this), 0);

        emit Deposit(ilk, asset, source, amount);
    }

    function withdraw(bytes32 ilk, address asset, uint256 maxAmount)
        external ilkAuth(ilk) returns (uint256 amount)
    {
        uint256 liquidityAvailable
            = IERC20(asset).balanceOf(IPool(pool).getReserveData(asset).aTokenAddress);

        // Constrain by the amount of liquidity available of the token
        amount = liquidityAvailable < maxAmount ? liquidityAvailable : maxAmount;
        
        // Constrain by the amount of deposits this ilk has
        uint256 ilkDeposits = assets[asset].positions[ilk].shares.rayMul(IPool(pool).getReserveNormalizedIncome(asset));
        amount = ilkDeposits < amount ? ilkDeposits : amount;

        uint256 shares = amount.rayDiv(IPool(pool).getReserveNormalizedIncome(asset));

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

        IPool(pool).withdraw(asset, amount, destination);

        emit Withdraw(ilk, asset, destination, amount);
    }

    function maxDeposit(bytes32, address asset) public view returns (uint256 maxDeposit_) {
        // Note: Purposefully ignoring any potental supply cap limits on Spark.
        //       This is because we assume the supply cap on this asset to be turned off.
        return assets[asset].enabled ? type(uint256).max : 0;
    }

    function maxWithdraw(bytes32 ilk, address asset) public view returns (uint256 maxWithdraw_) {
        maxWithdraw_ = assets[asset].positions[ilk].shares.rayMul(IPool(pool).getReserveNormalizedIncome(asset));
        uint256 liquidityAvailable = IERC20(asset).balanceOf(IPool(pool).getReserveData(asset).aTokenAddress);
        if (maxWithdraw_ > liquidityAvailable) maxWithdraw_ = liquidityAvailable;
    }

    function requestFunds(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        uint256 liquidityAvailable = IERC20(asset).balanceOf(IPool(pool).getReserveData(asset).aTokenAddress);
        require(liquidityAvailable == 0, "SparkConduit/non-zero-liquidity");

        // Convert asset amount to shares
        uint256 shares = amount.rayDiv(IPool(pool).getReserveNormalizedIncome(asset));

        uint256 prevShares = assets[asset].positions[ilk].shares;
        require(shares <= prevShares, "SparkConduit/amount-too-large");

        uint256 prevWithdrawals = assets[asset].positions[ilk].pendingWithdrawals;

        assets[asset].positions[ilk].pendingWithdrawals = shares;
        assets[asset].totalPendingWithdrawals
            = assets[asset].totalPendingWithdrawals + shares - prevWithdrawals;

        emit RequestFunds(ilk, asset, amount);
    }

    function cancelFundRequest(bytes32 ilk, address asset) external ilkAuth(ilk) {
        uint256 withdrawals = assets[asset].positions[ilk].pendingWithdrawals;
        require(withdrawals > 0, "SparkConduit/no-active-fund-requests");

        assets[asset].positions[ilk].pendingWithdrawals = 0;
        assets[asset].totalPendingWithdrawals           -= withdrawals;

        emit CancelFundRequest(ilk, asset);
    }

    function getInterestData(address asset) external view returns (InterestData memory data) {
        // Convert the DSR to a yearly APR
        uint256 dsr    = (PotLike(pot).dsr() - RAY) * SECONDS_PER_YEAR;
        uint256 shares = assets[asset].totalShares;
        uint256 index  = IPool(pool).getReserveNormalizedIncome(asset);

        return InterestData({
            baseRate:    uint128(dsr + subsidySpread),
            subsidyRate: uint128(dsr),
            currentDebt: uint128(shares.rayMul(index)),
            targetDebt:  uint128((shares - assets[asset].totalPendingWithdrawals).rayMul(index))
        });
    }

    function setRoles(address _roles) external auth {
        roles = _roles;

        emit SetRoles(_roles);
    }

    function setRegistry(address _registry) external auth {
        registry = _registry;

        emit SetRegistry(_registry);
    }

    function setSubsidySpread(uint256 _subsidySpread) external auth {
        subsidySpread = _subsidySpread;

        emit SetSubsidySpread(_subsidySpread);
    }

    function setAssetEnabled(address asset, bool enabled) external auth {
        assets[asset].enabled = enabled;
        asset.safeApprove(pool, enabled ? type(uint256).max : 0);

        emit SetAssetEnabled(asset, enabled);
    }

    function getAssetData(address asset)
        external view returns (bool _enabled, uint256 _totalDeposits, uint256 _totalWithdrawals)
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        return (
            assets[asset].enabled,
            assets[asset].totalShares.rayMul(liquidityIndex),
            assets[asset].totalPendingWithdrawals.rayMul(liquidityIndex)
        );
    }

    function isAssetEnabled(address asset) external view returns (bool) {
        return assets[asset].enabled;
    }

    function getTotalDeposits(address asset) external view returns (uint256) {
        return assets[asset].totalShares.rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function getTotalPendingWithdrawals(address asset) external view returns (uint256) {
        return
            assets[asset].totalPendingWithdrawals.rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function getPosition(bytes32 ilk, address asset)
        external view returns (uint256 _deposits, uint256 _pendingWithdrawals)
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        Position memory position = assets[asset].positions[ilk];
        return (
            position.shares.rayMul(liquidityIndex),
            position.pendingWithdrawals.rayMul(liquidityIndex)
        );
    }

    function getDeposits(bytes32 ilk, address asset) external view returns (uint256) {
        return
            assets[asset].positions[ilk].shares
                .rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function getPendingWithdrawals(bytes32 ilk, address asset) external view returns (uint256) {
        return
            assets[asset].positions[ilk].pendingWithdrawals
                .rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

}
