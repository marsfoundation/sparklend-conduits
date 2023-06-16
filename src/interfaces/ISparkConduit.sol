// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IConduit } from 'dss-conduits/IConduit.sol';
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { IERC20 } from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

interface ISparkConduit is IConduit {

    struct RequestFundsHints {
        uint256 urgencyMultiplier;
    }
    
    function pool() external view returns (IPool);

    function pot() external view returns (address);

    function subsidySpread() external view returns (uint256);

    function setSubsidySpread(uint256 _subsidySpread) external;

}
