// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

import { IConduit } from 'dss-conduits/IConduit.sol';

contract SparkConduit is IConduit {

    /// @inheritdoc IConduit
    function deposit(address asset, uint256 amount) external {

    }

    /// @inheritdoc IConduit
    function isCancelable(uint256 withdrawalId) external view returns (bool isCancelable_) {

    }

    /// @inheritdoc IConduit
    function initiateWithdraw(uint256 amount) external returns (uint256 withdrawalId) {

    }

    /// @inheritdoc IConduit
    function cancelWithdraw(uint256 withdrawalId) external {

    }

    /// @inheritdoc IConduit
    function withdraw(uint256 withdrawalId) external returns (uint256 resultingWithdrawalId) {

    }

    /// @inheritdoc IConduit
    function withdrawStatus(uint256 withdrawId) external returns (address owner, uint256 amount, StatusEnum status) {

    }

    /// @inheritdoc IConduit
    function activeWithdraws(address owner) external returns (uint256[] memory withdrawIds, uint256 totalAmount) {

    }

    /// @inheritdoc IConduit
    function totalActiveWithdraws() external returns (uint256 totalAmount) {

    }

}
