// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import { SparkConduit } from "src/SparkConduit.sol";

contract SparkConduitHarness is SparkConduit {
    constructor(address _pool, address _pot) SparkConduit(_pool, _pot) {}

    function divUp(uint256 x, uint256 y) external pure returns (uint256) {
        return _divUp(x, y);
    }
}
