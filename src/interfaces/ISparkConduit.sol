// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IAllocatorConduit } from 'dss-allocator/src/interfaces/IAllocatorConduit.sol';
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { IERC20 } from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

import { IAuth } from './IAuth.sol';

/**
 * @title ISparkConduit
 * @notice This interface extends the IAllocatorConduit and IAuth interfaces and manages asset and fund operations
 */
interface ISparkConduit is IAllocatorConduit, IAuth {

    /**
     * @notice Event emitted when a new fund request is made
     * @param domain The domain from which the funds are requested
     * @param asset The asset for which the funds are requested
     * @param amount The amount of funds requested
     */
    event RequestFunds(bytes32 indexed domain, address indexed asset, uint256 amount);

    /**
     * @notice Event emitted when a fund request is cancelled
     * @param domain The domain whose fund request is cancelled
     * @param asset The asset whose fund request is cancelled
     */
    event CancelFundRequest(bytes32 indexed domain, address indexed asset);

    /**
     * @notice Event emitted when a fund request is completed
     * @param domain The domain whose fund request is completed
     * @param asset The asset whose fund request is completed
     * @param amount The amount of funds fulfilled
     */
    event CompleteFundRequest(bytes32 indexed domain, address indexed asset, uint256 amount);

    /**
     * @notice Event emitted when subsidy spread is set
     * @param subsidySpread The new subsidy spread value
     */
    event SetSubsidySpread(uint256 subsidySpread);

    /**
     * @notice Event emitted when an asset's status is enabled or disabled
     * @dev This will give infinite token approval to the pool as well
     * @param asset The address of the asset
     * @param enabled The new status of the asset
     */
    event SetAssetEnabled(address indexed asset, bool enabled);
    
    /**
     * @notice Returns the pool associated with the spark conduit
     * @return The pool interface
     */
    function pool() external view returns (IPool);

    /**
     * @notice Returns the pot
     * @return The address of the pot
     */
    function pot() external view returns (address);

    /**
     * @notice Returns the roles contract
     * @return The address representing the roles
     */
    function roles() external view returns (address);

    /**
     * @notice Returns the subsidy spread associated with the spark conduit
     * @return The value of the subsidy spread
     */
    function subsidySpread() external view returns (uint256);

    /**
     * @notice Makes a request for funds
     * @param domain The domain from which the funds are requested
     * @param asset The asset for which the funds are requested
     * @param destination The destination where the funds should be transferred
     * @param amount The amount of funds requested
     */
    function requestFunds(bytes32 domain, address asset, address destination, uint256 amount) external;

    /**
     * @notice Cancels a fund request
     * @param domain The domain whose fund request is to be cancelled
     * @param asset The asset whose fund request is to be cancelled
     */
    function cancelFundRequest(bytes32 domain, address asset) external;

    /**
     * @notice Completes a fund request
     * @dev This is a permissionless function to prevent AllocatorDAOs from not withdrawing and keeping interest rates high
     * @param domain The domain whose fund request is to be completed
     * @param asset The asset whose fund request is to be completed
     */
    function completeFundRequest(bytes32 domain, address asset) external;

    /**
     * @notice Sets the subsidy spread
     * @param _subsidySpread The new subsidy spread value
     */
    function setSubsidySpread(uint256 _subsidySpread) external;

    /**
     * @notice Enables or disables an asset
     * @param asset The address of the asset
     * @param enabled The new status of the asset
     */
    function setAssetEnabled(address asset, bool enabled) external;

    /**
     * @notice Returns data associated with an asset
     * @param asset The address of the asset
     * @return enabled The status of the asset
     * @return totalDeposits The total deposits of the asset
     * @return totalWithdrawals The total withdrawals of the asset
     */
    function getAssetData(address asset) external view returns (bool enabled, uint256 totalDeposits, uint256 totalWithdrawals);

    /**
     * @notice Returns the position of a domain for an asset
     * @param domain The domain for which to return the position
     * @param asset The asset for which to return the position
     * @return deposits The total deposits for the domain
     * @return withdrawals The total withdrawals for the domain
     */
    function getDomainPosition(bytes32 domain, address asset) external view returns (uint256 deposits, uint256 withdrawals);

}

