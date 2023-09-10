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
     *  @notice Get the total number of requested shares for a given asset.
     *  @param  asset The address of the asset.
     *  @return The total number of requested shares for the asset.
     */
    function totalRequestedShares(address asset) external view returns (uint256);

    /**
     *  @notice Get the number of shares a given ilk has ownership of for a given asset.
     *  @param asset The address of the asset.
     *  @param ilk   The unique identifier for a subDAO.
     *  @return The number of shares for the asset and ilk.
     */
    function shares(address asset, bytes32 ilk) external view returns (uint256);

    /**
     *  @notice Get the number of requested shares for a specific asset and ilk.
     *  @param  asset The address of the asset.
     *  @param  ilk   The unique identifier for a subDAO.
     *  @return The number of requested shares for the asset and ilk.
     */
    function requestedShares(address asset, bytes32 ilk) external view returns (uint256);

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
     *  @notice Withdraws funds if there is available liquidity, and requests funds if there is a
     *          remaining amount after the withdrawal.
     *  @param  ilk             The ilk from which the funds are withdrawn/requested.
     *  @param  asset           The asset for which the funds are withdrawn/requested.
     *  @param  requestAmount   The amount of total funds requested.
     *  @return amountWithdrawn The resulting amount of funds withdrawn.
     *  @return requestedFunds  The resulting amount of funds requested.
     */
    function withdrawAndRequestFunds(bytes32 ilk, address asset, uint256 requestAmount)
        external returns (uint256 amountWithdrawn, uint256 requestedFunds);

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

