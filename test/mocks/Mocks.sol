// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import 'dss-test/DssTest.sol';

import { DataTypes } from 'aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol';

import { MockERC20 } from 'erc20-helpers/MockERC20.sol';

import { SparkLendConduit, IERC20 } from 'src/SparkLendConduit.sol';

import { ATokenMock } from "./ATokenMock.sol";

contract DaiMock {

    uint256 public liquidity;

    function setLiquidity(uint256 _liquidity) external {
        liquidity += _liquidity;
    }

    function balanceOf(address) external view returns (uint256) {
        return liquidity;
    }

}

contract PoolMock {

    Vm vm;

    ATokenMock public atoken;

    uint256 public liquidityIndex = 10 ** 27;

    constructor(Vm vm_) {
        vm     = vm_;
        atoken = new ATokenMock('aToken', 'aTKN', 18, address(this));
    }

    function supply(address asset, uint256 amount, address, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(atoken), amount);
        atoken.mint(msg.sender, _convertToShares(amount));
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 liquidityAvailable = IERC20(asset).balanceOf(address(atoken));
        if (amount > liquidityAvailable) {
            amount = liquidityAvailable;
        }
        vm.prank(address(atoken));
        IERC20(asset).transfer(to, amount);

        atoken.burn(msg.sender, _convertToShares(amount));
        return amount;
    }

    function getReserveData(address) external view returns (DataTypes.ReserveData memory) {
        return DataTypes.ReserveData({
            configuration:               DataTypes.ReserveConfigurationMap(0),
            liquidityIndex:              uint128(liquidityIndex),
            currentLiquidityRate:        0,
            variableBorrowIndex:         0,
            currentVariableBorrowRate:   0,
            currentStableBorrowRate:     0,
            lastUpdateTimestamp:         0,
            id:                          0,
            aTokenAddress:               address(atoken),
            stableDebtTokenAddress:      address(0),
            variableDebtTokenAddress:    address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury:           0,
            unbacked:                    0,
            isolationModeTotalDebt:      0
        });
    }

    function getReserveNormalizedIncome(address) external view returns (uint256) {
        return liquidityIndex;
    }

    function setLiquidityIndex(uint256 _liquidityIndex) external {
        liquidityIndex = _liquidityIndex;
    }

    function _convertToShares(uint256 amount) internal view returns (uint256) {
        return amount * 1e27 / liquidityIndex;
    }

}

contract RolesMock {

    bool public canCallSuccess = true;

    function canCall(bytes32, address, address, bytes4) external view returns (bool) {
        return canCallSuccess;
    }

    function setCanCall(bool _on) external {
        canCallSuccess = _on;
    }

}

contract RegistryMock {

    address public buffer;

    function buffers(bytes32) external view returns (address) {
        return buffer;
    }

    function setBuffer(address b) external {
        buffer = b;
    }

}
