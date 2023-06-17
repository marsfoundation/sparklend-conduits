// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IAllocatorConduit } from 'dss-allocator/src/interfaces/IAllocatorConduit.sol';
import { IPool } from 'aave-v3-core/contracts/interfaces/IPool.sol';
import { IERC20 } from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

import { IAuth } from './IAuth.sol';

interface ISparkConduit is IAllocatorConduit, IAuth {

    event RequestFunds(bytes32 indexed domain, address indexed asset, uint256 amount);

    event CancelFundRequest(bytes32 indexed domain, address indexed asset);

    event CompleteFundRequest(bytes32 indexed domain, address indexed asset, uint256 amount);

    event SetSubsidySpread(uint256 subsidySpread);

    event SetAssetEnabled(address indexed asset, bool enabled);
    
    function pool() external view returns (IPool);

    function pot() external view returns (address);

    function roles() external view returns (address);

    function subsidySpread() external view returns (uint256);

    function requestFunds(bytes32 domain, address asset, address destination, uint256 amount) external;

    function cancelFundRequest(bytes32 domain, address asset) external;

    function completeFundRequest(bytes32 domain, address asset) external;

    function setSubsidySpread(uint256 _subsidySpread) external;

    function setAssetEnabled(address asset, bool enabled) external;

    function getAssetData(address asset) external view returns (bool enabled, uint256 totalDeposits, uint256 totalWithdrawals);

    function getDomainPosition(bytes32 domain, address asset) external view returns (uint256 deposits, uint256 withdrawals);

}
