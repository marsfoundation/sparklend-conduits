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
     *  @notice Event emitted when a new fund request is made.
     *  @param  ilk    The ilk from which the funds are requested.
     *  @param  asset  The asset for which the funds are requested.
     *  @param  amount The amount of funds requested.
     */
    event RequestFunds(bytes32 indexed ilk, address indexed asset, uint256 amount);

    /**
     *  @notice Event emitted when a fund request is cancelled.
     *  @param  ilk   The ilk whose fund request is cancelled.
     *  @param  asset The asset whose fund request is cancelled.
     */
    event CancelFundRequest(bytes32 indexed ilk, address indexed asset);

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
     *  @notice Event emitted when subsidy spread is set.
     *  @param  subsidySpread The new subsidy spread value.
     */
    event SetSubsidySpread(uint256 subsidySpread);

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
     *  @notice Returns the pot.
     *  @return The address of the pot.
     */
    function pot() external view returns (address);

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
     *  @notice Returns the subsidy spread associated with the spark conduit.
     *  @return The value of the subsidy spread.
     */
    function subsidySpread() external view returns (uint256);

    /**********************************************************************************************/
    /*** External Functions                                                                     ***/
    /**********************************************************************************************/

    /**
     *  @notice Makes a request for funds.
     *          This will override any previous request with a new `amount`.
     *  @param  ilk    The ilk from which the funds are requested.
     *  @param  asset  The asset for which the funds are requested.
     *  @param  amount The amount of funds requested.
     */
    function requestFunds(bytes32 ilk, address asset, uint256 amount) external;

    /**
     *  @notice Cancels a fund request.
     *  @param  ilk   The ilk whose fund request is to be cancelled.
     *  @param  asset The asset whose fund request is to be cancelled.
     */
    function cancelFundRequest(bytes32 ilk, address asset) external;

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
     *  @notice Sets the subsidy spread.
     *  @param  _subsidySpread The new subsidy spread value.
     */
    function setSubsidySpread(uint256 _subsidySpread) external;

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
     *  @notice Returns data associated with an asset.
     *  @param  asset               The address of the asset.
     *  @return enabled             The status of the asset.
     *  @return totalDeposits       The total deposits of the asset.
     *  @return totalRequestedFunds The total pending withdrawals of the asset.
     */
    function getAssetData(address asset)
        external view returns (
            bool enabled,
            uint256 totalDeposits,
            uint256 totalRequestedFunds
        );

    /**
     *  @notice Gets the total deposits of an asset.
     *  @param  asset The address of the asset.
     *  @return The total amount of deposits for the asset.
     */
    function getTotalDeposits(address asset) external view returns (uint256);

    /**
     *  @notice Gets the total requested funds of an asset.
     *  @param  asset The address of the asset.
     *  @return The total amount of pending requested funds for the asset.
     */
    function getTotalRequestedFunds(address asset) external view returns (uint256);

    /**
     *  @notice Returns the position of a ilk for an asset.
     *  @param  asset          The asset for which to return the position.
     *  @param  ilk            The ilk for which to return the position.
     *  @return deposits       The total deposits for the ilk.
     *  @return requestedFunds The total pending requested funds for the ilk.
     */
    function getPosition(address asset, bytes32 ilk)
        external view returns (uint256 deposits, uint256 requestedFunds);

    /**
     *  @notice Gets the deposits for a given ilk and asset.
     *  @param  asset The asset to get the deposits for.
     *  @param  ilk   The ilk to get the deposits for.
     *  @return The total amount of deposits for the given ilk and asset.
     */
    function getDeposits(address asset, bytes32 ilk) external view returns (uint256);

    /**
     *  @notice Gets the pending requested funds for a given ilk and asset.
     *  @param  asset The asset to get the requested funds for.
     *  @param  ilk   The ilk to get the requested funds for.
     *  @return The total amount of requested funds for the given ilk and asset.
     */
    function getRequestedFunds(address asset, bytes32 ilk) external view returns (uint256);

}

