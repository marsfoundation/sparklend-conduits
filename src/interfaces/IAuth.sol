// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

/**
 * @title IAuth
 * @notice This interface declares the authorization related methods and events
 */
interface IAuth {

    /**
     * @notice Event to log the addition of a new authorized user
     * @param usr The address of the user who is granted permission
     */
    event Rely(address indexed usr);
    
    /**
     * @notice Event to log the removal of an authorized user
     * @param usr The address of the user who is denied permission
     */
    event Deny(address indexed usr);

    /**
     * @notice Returns the authorization status of a user
     * @param usr The address of the user whose authorization status is to be checked
     * @return The authorization status of the given user. 1 means authorized, 0 means not authorized.
     */
    function wards(address usr) external view returns (uint256);

    /**
     * @notice Adds a new authorized user
     * @param usr The address of the user to be added as an authorized user
     */
    function rely(address usr) external;

    /**
     * @notice Removes an authorized user
     * @param usr The address of the user to be removed from the list of authorized users
     */
    function deny(address usr) external;

}
