// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IAllocatorConduit } from 'dss-allocator/IAllocatorConduit.sol';

/**
 * @title  ISparkConduit
 * @notice This interface extends the IAllocatorConduit interfaces and manages asset
 *         and fund operations
 */
interface ISparkConduit is IAllocatorConduit {

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    /**
     *  @notice Event emitted when roles address is set.
     *  @param  roles The new roles address.
     */
    event SetRoles(address roles);

    /**
     *  @notice Event emitted when registry address is set.
     *  @param  registry The new registry address.
     */
    event SetRegistry(address registry);

    /**
     *  @notice Event emitted when an asset's status is enabled or disabled.
     *  @dev    This will give infinite token approval to the pool as well.
     *  @param  asset The address of the asset.
     *  @param  enabled The new status of the asset.
     */
    event SetAssetEnabled(address indexed asset, bool enabled);

    /**********************************************************************************************/
    /*** State Variables                                                                        ***/
    /**********************************************************************************************/

    /**
     *  @notice Returns the pool associated with the spark conduit.
     *  @return The address of the pool.
     */
    function pool() external view returns (address);

    /**
     *  @notice Returns the roles contract.
     *  @return The address representing the roles.
     */
    function roles() external view returns (address);

    /**
     *  @notice Returns the registry contract.
     *  @return The address representing the registry.
     */
    function registry() external view returns (address);

    /**
     *  @notice Determines whether a given asset is whitelisted or not.
     *  @param  asset The address of the asset.
     *  @return A boolean representing the enabled state.
     */
    function enabled(address asset) external view returns (bool);

    /**
     *  @notice Get the total number of shares that are held custody for a given asset.
     *  @param  asset The address of the asset.
     *  @return The total number of shares for the asset.
     */
    function totalShares(address asset) external view returns (uint256);

    /**
     *  @notice Get the number of shares a given ilk has ownership of for a given asset.
     *  @param asset The address of the asset.
     *  @param ilk   The unique identifier for a subDAO.
     *  @return The number of shares for the asset and ilk.
     */
    function shares(address asset, bytes32 ilk) external view returns (uint256);

    /**********************************************************************************************/
    /*** External Functions                                                                     ***/
    /**********************************************************************************************/

    /**
     *  @notice Sets the roles address.
     *  @param  _roles The new roles address.
     */
    function setRoles(address _roles) external;

    /**
     *  @notice Sets the registry address.
     *  @param  _registry The new registry address.
     */
    function setRegistry(address _registry) external;

    /**
     *  @notice Enables or disables an asset.
     *  @param  asset   The address of the asset.
     *  @param  enabled The new status of the asset.
     */
    function setAssetEnabled(address asset, bool enabled) external;

    /**********************************************************************************************/
    /*** View Functions                                                                         ***/
    /**********************************************************************************************/

    /**
     *  @notice Returns the amount of available liquidity in the Spark pool for a given asset.
     *  @return The balance of tokens in the asset's reserve's aToken address.
     */
    function getAvailableLiquidity(address asset) external view returns (uint256);

    /**
     *  @notice Gets the total deposits of an asset.
     *  @param  asset The address of the asset.
     *  @return The total amount of deposits for the asset.
     */
    function getTotalDeposits(address asset) external view returns (uint256);

    /**
     *  @notice Gets the deposits for a given ilk and asset.
     *  @param  asset The asset to get the deposits for.
     *  @param  ilk   The ilk to get the deposits for.
     *  @return The total amount of deposits for the given ilk and asset.
     */
    function getDeposits(address asset, bytes32 ilk) external view returns (uint256);

}

