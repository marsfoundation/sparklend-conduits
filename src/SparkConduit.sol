// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IPool }      from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { WadRayMath } from 'aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol';

import { IERC20 }    from 'erc20-helpers/interfaces/IERC20.sol';
import { SafeERC20 } from 'erc20-helpers/SafeERC20.sol';

import { UpgradeableProxied } from 'upgradeable-proxy/UpgradeableProxied.sol';

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
    using SafeERC20  for address;

    /**********************************************************************************************/
    /*** Storage                                                                                ***/
    /**********************************************************************************************/

    address public immutable pool;
    address public immutable pot;

    address public roles;
    address public registry;
    uint256 public subsidySpread;

    // TODO: Override
    mapping(address => bool) public enabled;

    mapping(address => uint256) public totalShares;
    mapping(address => uint256) public totalRequestedShares;

    mapping(address => mapping(bytes32 => uint256)) public shares;
    mapping(address => mapping(bytes32 => uint256)) public requestedShares;

    /**********************************************************************************************/
    /*** Modifiers                                                                              ***/
    /**********************************************************************************************/

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

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address _pool, address _pot) {
        pool = _pool;
        pot  = _pot;
    }

    /**********************************************************************************************/
    /*** Admin Functions                                                                        ***/
    /**********************************************************************************************/

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

    function setAssetEnabled(address asset, bool enabled_) external auth {
        enabled[asset] = enabled_;
        asset.safeApprove(pool, enabled_ ? type(uint256).max : 0);

        emit SetAssetEnabled(asset, enabled_);
    }

    /**********************************************************************************************/
    /*** Operator Functions                                                                     ***/
    /**********************************************************************************************/

    function deposit(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        require(enabled[asset], "SparkConduit/asset-disabled");
        require(
            requestedShares[asset][ilk] == 0,
            "SparkConduit/no-deposit-with-pending-withdrawals"
        );

        address source = RegistryLike(registry).buffers(ilk);

        // Convert asset amount to shares
        uint256 newShares = amount.rayDiv(IPool(pool).getReserveNormalizedIncome(asset));

        shares[asset][ilk] += newShares;
        totalShares[asset] += newShares;

        asset.safeTransferFrom(source, address(this), amount);
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
        uint256 ilkDeposits = shares[asset][ilk].rayMul(IPool(pool).getReserveNormalizedIncome(asset));
        amount = ilkDeposits < amount ? ilkDeposits : amount;

        uint256 removedShares = amount.rayDiv(IPool(pool).getReserveNormalizedIncome(asset));

        shares[asset][ilk] -= removedShares;
        totalShares[asset] -= removedShares;

        uint256 withdrawals = requestedShares[asset][ilk];

        if (withdrawals > 0) {
            if (removedShares <= withdrawals) {
                requestedShares[asset][ilk] -= removedShares;
                totalRequestedShares[asset] -= removedShares;
            } else {
                requestedShares[asset][ilk] = 0;
                totalRequestedShares[asset] -= withdrawals;
            }
        }

        address destination = RegistryLike(registry).buffers(ilk);

        IPool(pool).withdraw(asset, amount, destination);

        emit Withdraw(ilk, asset, destination, amount);
    }

    function requestFunds(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        uint256 liquidityAvailable = IERC20(asset).balanceOf(IPool(pool).getReserveData(asset).aTokenAddress);
        require(liquidityAvailable == 0, "SparkConduit/non-zero-liquidity");

        // Convert asset amount to shares
        uint256 newRequestedShares = amount.rayDiv(IPool(pool).getReserveNormalizedIncome(asset));

        uint256 currentShares = shares[asset][ilk];

        require(newRequestedShares <= currentShares, "SparkConduit/amount-too-large");

        uint256 prevRequestedShares = requestedShares[asset][ilk];

        requestedShares[asset][ilk] = newRequestedShares;

        totalRequestedShares[asset]
            = totalRequestedShares[asset] + newRequestedShares - prevRequestedShares;

        emit RequestFunds(ilk, asset, amount);
    }

    function cancelFundRequest(bytes32 ilk, address asset) external ilkAuth(ilk) {
        uint256 withdrawals = requestedShares[asset][ilk];
        require(withdrawals > 0, "SparkConduit/no-active-fund-requests");

        requestedShares[asset][ilk]  = 0;
        totalRequestedShares[asset] -= withdrawals;

        emit CancelFundRequest(ilk, asset);
    }

    /**********************************************************************************************/
    /*** View Functions                                                                         ***/
    /**********************************************************************************************/

    function maxDeposit(bytes32, address asset) public view returns (uint256 maxDeposit_) {
        // Note: Purposefully ignoring any potental supply cap limits on Spark.
        //       This is because we assume the supply cap on this asset to be turned off.
        return enabled[asset] ? type(uint256).max : 0;
    }

    function maxWithdraw(bytes32 ilk, address asset) public view returns (uint256 maxWithdraw_) {
        maxWithdraw_ = shares[asset][ilk].rayMul(IPool(pool).getReserveNormalizedIncome(asset));
        uint256 liquidityAvailable = IERC20(asset).balanceOf(IPool(pool).getReserveData(asset).aTokenAddress);
        if (maxWithdraw_ > liquidityAvailable) maxWithdraw_ = liquidityAvailable;
    }

    function getInterestData(address asset) external view returns (InterestData memory data) {
        // Convert the DSR to a yearly APR
        uint256 dsr          = (PotLike(pot).dsr() - 1e27) * 365 days;
        uint256 totalShares_ = totalShares[asset];
        uint256 index        = IPool(pool).getReserveNormalizedIncome(asset);

        return InterestData({
            baseRate:    uint128(dsr + subsidySpread),
            subsidyRate: uint128(dsr),
            currentDebt: uint128(totalShares_.rayMul(index)),
            targetDebt:  uint128((totalShares_ - totalRequestedShares[asset]).rayMul(index))
        });
    }

    function getAssetData(address asset)
        external view returns (bool _enabled, uint256 _totalDeposits, uint256 _totalWithdrawals)
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        return (
            enabled[asset],
            totalShares[asset].rayMul(liquidityIndex),
            totalRequestedShares[asset].rayMul(liquidityIndex)
        );
    }

    function isAssetEnabled(address asset) external view returns (bool) {
        return enabled[asset];
    }

    function getTotalDeposits(address asset) external view returns (uint256) {
        return totalShares[asset].rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function getTotalPendingWithdrawals(address asset) external view returns (uint256) {
        return totalRequestedShares[asset].rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function getPosition(bytes32 ilk, address asset)
        external view returns (uint256 _deposits, uint256 _requestedShares)
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        return (
            shares[asset][ilk].rayMul(liquidityIndex),
            requestedShares[asset][ilk].rayMul(liquidityIndex)
        );
    }

    function getDeposits(bytes32 ilk, address asset) external view returns (uint256) {
        return shares[asset][ilk].rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function getPendingWithdrawals(bytes32 ilk, address asset) external view returns (uint256) {
        return requestedShares[asset][ilk].rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

}
