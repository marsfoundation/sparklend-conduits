// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { SparkLendConduit } from "src/SparkLendConduit.sol";

contract SparkLendConduitHarness is SparkLendConduit {
    constructor(address _pool) SparkLendConduit(_pool) {}

    function divUp(uint256 x, uint256 y) external pure returns (uint256) {
        return _divUp(x, y);
    }
}
