// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';

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

    using SafeERC20  for address;

    /**********************************************************************************************/
    /*** Storage                                                                                ***/
    /**********************************************************************************************/

    address public override immutable pool;
    address public override immutable pot;

    address public override roles;
    address public override registry;
    uint256 public override subsidySpread;

    mapping(address => bool) public override enabled;

    mapping(address => uint256) public override totalShares;
    mapping(address => uint256) public override totalRequestedShares;

    mapping(address => mapping(bytes32 => uint256)) public override shares;
    mapping(address => mapping(bytes32 => uint256)) public override requestedShares;

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

    function setRoles(address _roles) external override auth {
        roles = _roles;

        emit SetRoles(_roles);
    }

    function setRegistry(address _registry) external override auth {
        registry = _registry;

        emit SetRegistry(_registry);
    }

    function setSubsidySpread(uint256 _subsidySpread) external override auth {
        subsidySpread = _subsidySpread;

        emit SetSubsidySpread(_subsidySpread);
    }

    function setAssetEnabled(address asset, bool enabled_) external override auth {
        enabled[asset] = enabled_;
        asset.safeApprove(pool, enabled_ ? type(uint256).max : 0);

        emit SetAssetEnabled(asset, enabled_);
    }

    /**********************************************************************************************/
    /*** Operator Functions                                                                     ***/
    /**********************************************************************************************/

    function deposit(bytes32 ilk, address asset, uint256 amount) external override ilkAuth(ilk) {
        require(enabled[asset], "SparkConduit/asset-disabled");
        require(
            requestedShares[asset][ilk] == 0,
            "SparkConduit/no-deposit-with-requested-shares"
        );

        address source = RegistryLike(registry).buffers(ilk);

        require(source != address(0), "SparkConduit/no-buffer-registered");

        // Convert asset amount to shares
        uint256 newShares = _convertToShares(asset, amount);

        shares[asset][ilk] += newShares;
        totalShares[asset] += newShares;

        asset.safeTransferFrom(source, address(this), amount);
        IPool(pool).supply(asset, amount, address(this), 0);

        emit Deposit(ilk, asset, source, amount);
    }

    function withdraw(bytes32 ilk, address asset, uint256 maxAmount)
        public override ilkAuth(ilk) returns (uint256 amount)
    {
        // Constrain the amount that can be withdrawn by the max amount
        amount = _min(maxAmount, maxWithdraw(ilk, asset));

        // Convert the amount to withdraw to shares
        // Round up to be conservative but prevent underflow
        uint256 withdrawalShares
            = _min(shares[asset][ilk], _convertToSharesRoundUp(asset, amount));

        // Reduce share accounting by the amount withdrawn
        shares[asset][ilk] -= withdrawalShares;
        totalShares[asset] -= withdrawalShares;

        uint256 currentRequestedShares = requestedShares[asset][ilk];

        if (currentRequestedShares > 0) {
            // Reduce pending withdrawals by the min between amount pending and amount withdrawn
            uint256 requestedSharesToRemove = _min(withdrawalShares, currentRequestedShares);

            requestedShares[asset][ilk] -= requestedSharesToRemove;
            totalRequestedShares[asset] -= requestedSharesToRemove;
        }

        address destination = RegistryLike(registry).buffers(ilk);

        require(destination != address(0), "SparkConduit/no-buffer-registered");

        IPool(pool).withdraw(asset, amount, destination);

        emit Withdraw(ilk, asset, destination, amount);
    }

    function requestFunds(bytes32 ilk, address asset, uint256 maxRequestAmount)
        public override ilkAuth(ilk) returns (uint256 requestedFunds)
    {
        require(getAvailableLiquidity(asset) == 0, "SparkConduit/non-zero-liquidity");

        // Limit remaining requested funds to the amount of shares the user has
        uint256 sharesToRequest = _min(
            shares[asset][ilk],
            _convertToShares(asset, maxRequestAmount)
        );

        // Cache previous withdrawal amount for accounting update
        uint256 prevRequestedShares = requestedShares[asset][ilk];

        requestedShares[asset][ilk] = sharesToRequest;  // Overwrite pending withdrawals

        totalRequestedShares[asset]
            = totalRequestedShares[asset] + sharesToRequest - prevRequestedShares;

        requestedFunds = _convertToAssets(asset, sharesToRequest);

        emit RequestFunds(ilk, asset, requestedFunds);
    }

    function withdrawAndRequestFunds(bytes32 ilk, address asset, uint256 maxWithdrawAmount)
        external override ilkAuth(ilk) returns (uint256 amountWithdrawn, uint256 requestedFunds)
    {
        uint256 availableLiquidity = getAvailableLiquidity(asset);

        // If there is liquidity available, withdraw it before requesting.
        if (availableLiquidity != 0) {
            uint256 amountToWithdraw = _min(availableLiquidity, maxWithdrawAmount);
            amountWithdrawn = withdraw(ilk, asset, amountToWithdraw);
        }

        // If the withdrawal didn't satisfy the full desired amount, request the remainder.
        if (maxWithdrawAmount > amountWithdrawn) {
            unchecked { requestedFunds = maxWithdrawAmount - amountWithdrawn; }
            requestFunds(ilk, asset, requestedFunds);
        }
    }

    function cancelFundRequest(bytes32 ilk, address asset) external override ilkAuth(ilk) {
        uint256 requestedShares_ = requestedShares[asset][ilk];
        require(requestedShares_ > 0, "SparkConduit/no-active-fund-requests");

        requestedShares[asset][ilk] -= requestedShares_;
        totalRequestedShares[asset] -= requestedShares_;

        emit CancelFundRequest(ilk, asset);
    }

    /**********************************************************************************************/
    /*** View Functions                                                                         ***/
    /**********************************************************************************************/

    function maxDeposit(bytes32, address asset) public view override returns (uint256 maxDeposit_) {
        // Note: Purposefully ignoring any potential supply cap limits on Spark.
        //       This is because we assume the supply cap on this asset to be turned off.
        return enabled[asset] ? type(uint256).max : 0;
    }

    function maxWithdraw(bytes32 ilk, address asset)
        public view override returns (uint256 maxWithdraw_)
    {
        return _min(_convertToAssets(asset, shares[asset][ilk]), getAvailableLiquidity(asset));
    }

    function getInterestData(address asset)
        external view override returns (InterestData memory data)
    {
        // Convert the DSR to a yearly APR
        uint256 dsr          = (PotLike(pot).dsr() - 1e27) * 365 days;
        uint256 totalShares_ = totalShares[asset];
        uint256 index        = IPool(pool).getReserveNormalizedIncome(asset);

        return InterestData({
            baseRate:    uint128(dsr + subsidySpread),
            subsidyRate: uint128(dsr),
            currentDebt: uint128(_rayMul(totalShares_, index)),
            targetDebt:  uint128(_rayMul(totalShares_ - totalRequestedShares[asset], index))
        });
    }

    function getAssetData(address asset)
        external view override returns (
            bool _enabled,
            uint256 _totalDeposits,
            uint256 _totalRequestedFunds
        )
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        return (
            enabled[asset],
            _rayMul(totalShares[asset],         liquidityIndex),
            _rayMul(totalRequestedShares[asset],liquidityIndex)
        );
    }

    function getPosition(address asset, bytes32 ilk)
        external view override returns (uint256 _deposits, uint256 _requestedFunds)
    {
        uint256 liquidityIndex = IPool(pool).getReserveNormalizedIncome(asset);
        return (
            _rayMul(shares[asset][ilk],          liquidityIndex),
            _rayMul(requestedShares[asset][ilk], liquidityIndex)
        );
    }

    function getTotalDeposits(address asset) external view override returns (uint256) {
        return _convertToAssets(asset, totalShares[asset]);
    }

    function getTotalRequestedFunds(address asset) external view override returns (uint256) {
        return _convertToAssets(asset, totalRequestedShares[asset]);
    }

    function getDeposits(address asset, bytes32 ilk) external view override returns (uint256) {
        return _convertToAssets(asset, shares[asset][ilk]);
    }

    function getRequestedFunds(address asset, bytes32 ilk)
        external view override returns (uint256)
    {
        return _convertToAssets(asset, requestedShares[asset][ilk]);
    }

    function getAvailableLiquidity(address asset) public view override returns (uint256) {
        return IERC20(asset).balanceOf(IPool(pool).getReserveData(asset).aTokenAddress);
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _convertToAssets(address asset, uint256 amount) internal view returns (uint256) {
        return _rayMul(amount, IPool(pool).getReserveNormalizedIncome(asset));
    }

    function _convertToShares(address asset, uint256 amount) internal view returns (uint256) {
        return _rayDiv(amount, IPool(pool).getReserveNormalizedIncome(asset));
    }

    // Note: This function rounds up to the nearest share to prevent dust in conduit state.
    function _convertToSharesRoundUp(address asset, uint256 amount)
        internal view returns (uint256)
    {
        return _divUp(amount * 1e27, IPool(pool).getReserveNormalizedIncome(asset));
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x != 0 ? ((x - 1) / y) + 1 : 0;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _rayMul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y / 1e27;
    }

    function _rayDiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * 1e27 / y;
    }

}
