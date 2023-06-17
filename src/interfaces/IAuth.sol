// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

interface IAuth {

    function wards(address usr) external view returns (uint256);

    function rely() external;

    function deny() external;

}
