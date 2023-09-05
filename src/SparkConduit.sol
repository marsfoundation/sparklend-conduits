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
    mapping(address => uint256) public totalPendingWithdrawals;

    mapping(address => mapping(bytes32 => uint256)) public shares;
    mapping(address => mapping(bytes32 => uint256)) public pendingWithdrawals;

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
            pendingWithdrawals[asset][ilk] == 0,
            "SparkConduit/no-deposit-with-pending-withdrawals"
        );

        address source = RegistryLike(registry).buffers(ilk);

        // Convert asset amount to shares
        uint256 newShares = _convertToShares(asset, amount);

        shares[asset][ilk] += newShares;
        totalShares[asset] += newShares;

        asset.safeTransferFrom(source, address(this), amount);
        IPool(pool).supply(asset, amount, address(this), 0);

        emit Deposit(ilk, asset, source, amount);
    }

    function withdraw(bytes32 ilk, address asset, uint256 maxAmount)
        external ilkAuth(ilk) returns (uint256 amount)
    {
        // Constrain the amount that can be withdrawn by the max amount
        amount = _min(maxAmount, maxWithdraw(ilk, asset));

        uint256 removedShares = _convertToShares(asset, amount);

        // Reduce share accounting by the amount withdrawn
        shares[asset][ilk] -= removedShares;
        totalShares[asset] -= removedShares;

        uint256 withdrawals = pendingWithdrawals[asset][ilk];

        if (withdrawals > 0) {
            // Reduce pending withdrawals by the min between amount pending and amount withdrawn
            uint256 pendingWithdrawalsToRemove = _min(withdrawals, removedShares);

            pendingWithdrawals[asset][ilk] -= pendingWithdrawalsToRemove;
            totalPendingWithdrawals[asset] -= pendingWithdrawalsToRemove;
        }

        address destination = RegistryLike(registry).buffers(ilk);

        IPool(pool).withdraw(asset, amount, destination);

        emit Withdraw(ilk, asset, destination, amount);
    }

    function requestFunds(bytes32 ilk, address asset, uint256 amount) external ilkAuth(ilk) {
        // TODO: Update this to avoid DoS vector
        require(getAvailableLiquidity(asset) == 0, "SparkConduit/non-zero-liquidity");

        uint256 requestedShares = _convertToShares(asset, amount);

        require(requestedShares <= shares[asset][ilk], "SparkConduit/amount-too-large");

        // Cache previous withdrawal amount for accounting update
        uint256 prevWithdrawals = pendingWithdrawals[asset][ilk];

        pendingWithdrawals[asset][ilk] = requestedShares;  // Overwrite pending withdrawals

        totalPendingWithdrawals[asset]
            = totalPendingWithdrawals[asset] + requestedShares - prevWithdrawals;

        emit RequestFunds(ilk, asset, amount);
    }

    function cancelFundRequest(bytes32 ilk, address asset) external ilkAuth(ilk) {
        uint256 withdrawals = pendingWithdrawals[asset][ilk];
        require(withdrawals > 0, "SparkConduit/no-active-fund-requests");

        pendingWithdrawals[asset][ilk] -= withdrawals;
        totalPendingWithdrawals[asset] -= withdrawals;

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
        return _min(_convertToAssets(asset, shares[asset][ilk]), getAvailableLiquidity(asset));
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
            targetDebt:  uint128((totalShares_ - totalPendingWithdrawals[asset]).rayMul(index))
        });
    }

    function getAssetData(address asset)
        external view returns (bool _enabled, uint256 _totalDeposits, uint256 _totalWithdrawals)
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        return (
            enabled[asset],
            totalShares[asset].rayMul(liquidityIndex),
            totalPendingWithdrawals[asset].rayMul(liquidityIndex)
        );
    }

    function getPosition(bytes32 ilk, address asset)
        external view returns (uint256 _deposits, uint256 _pendingWithdrawals)
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        return (
            shares[asset][ilk].rayMul(liquidityIndex),
            pendingWithdrawals[asset][ilk].rayMul(liquidityIndex)
        );
    }

    function getTotalDeposits(address asset) external view returns (uint256) {
        return _convertToAssets(asset, totalShares[asset]);
    }

    function getTotalPendingWithdrawals(address asset) external view returns (uint256) {
        return _convertToAssets(asset, totalPendingWithdrawals[asset]);
    }

    function getDeposits(bytes32 ilk, address asset) external view returns (uint256) {
        return _convertToAssets(asset, shares[asset][ilk]);
    }

    function getPendingWithdrawals(bytes32 ilk, address asset) external view returns (uint256) {
        return _convertToAssets(asset, pendingWithdrawals[asset][ilk]);
    }

    function getAvailableLiquidity(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(IPool(pool).getReserveData(asset).aTokenAddress);
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _convertToAssets(address asset, uint256 amount) internal view returns (uint256) {
        return amount.rayMul(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function _convertToShares(address asset, uint256 amount) internal view returns (uint256) {
        return amount.rayDiv(IPool(pool).getReserveNormalizedIncome(asset));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

}
