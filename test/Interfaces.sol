// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

interface IAToken is IERC20 {
    function scaledBalanceOf(address user) external view returns (uint256);
}
