// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "dss-test/DssTest.sol";

import { SparkConduit, ISparkConduit, IAuth, IPool } from "../src/SparkConduit.sol";

contract TokenMock {

    address public lastApproveAddress;
    uint256 public lastApproveAmount;

    function approve(address spender, uint256 amount) external returns (bool) {
        lastApproveAddress = spender;
        lastApproveAmount = amount;
        return true;
    }

}

contract PoolMock {

}

contract PotMock {

}

contract RolesMock {

    bool public canCallSuccess = true;
    bool public isWhitelistedDestinationSuccess = true;

    function canCall(bytes32, address, address, bytes4) external view returns (bool) {
        return canCallSuccess;
    }

    function isWhitelistedDestination(bytes32, address) external view returns (bool) {
        return isWhitelistedDestinationSuccess;
    }

    function setCanCall(bool _on) external {
        canCallSuccess = _on;
    }

    function setIsWhitelistedDestination(bool _on) external {
        isWhitelistedDestinationSuccess = _on;
    }

}

contract SparkConduitTest is DssTest {

    uint256 constant RBPS = RAY / 10000;

    PoolMock  pool;
    PotMock   pot;
    RolesMock roles;
    TokenMock token;

    SparkConduit conduit;

    event SetSubsidySpread(uint256 subsidySpread);
    event SetAssetEnabled(address indexed asset, bool enabled);

    function setUp() public {
        pool  = new PoolMock();
        pot   = new PotMock();
        roles = new RolesMock();
        token = new TokenMock();

        vm.expectEmit();
        emit Rely(address(this));
        conduit = new SparkConduit(
            IPool(address(pool)),
            address(pot),
            address(roles)
        );
    }

    function test_constructor() public {
        assertEq(address(conduit.pool()), address(pool));
        assertEq(address(conduit.pot()), address(pot));
        assertEq(address(conduit.roles()), address(roles));
        assertEq(conduit.wards(address(this)), 1);
    }

    function test_auth() public {
        checkAuth(address(conduit), "SparkConduit");
    }

    function test_authModifiers() public {
        conduit.deny(address(this));

        checkModifier(address(conduit), "SparkConduit/not-authorized", [
            SparkConduit.setSubsidySpread.selector,
            SparkConduit.setAssetEnabled.selector
        ]);
    }

    function test_domainAuthModifiers() public {
        roles.setCanCall(false);

        checkModifier(address(conduit), "SparkConduit/domain-not-authorized", [
            SparkConduit.deposit.selector,
            SparkConduit.withdraw.selector,
            SparkConduit.requestFunds.selector,
            SparkConduit.cancelFundRequest.selector
        ]);
    }

    function test_validDestinationModifiers() public {
        roles.setIsWhitelistedDestination(false);

        checkModifier(address(conduit), "SparkConduit/destination-not-authorized", [
            SparkConduit.withdraw.selector,
            SparkConduit.requestFunds.selector
        ]);
    }

    function test_setSubsidySpread() public {
        assertEq(conduit.subsidySpread(), 0);
        vm.expectEmit();
        emit SetSubsidySpread(50 * RBPS);
        conduit.setSubsidySpread(50 * RBPS);
        assertEq(conduit.subsidySpread(), 50 * RBPS);
    }

    function test_setAssetEnabled() public {
        (bool enabled,,) = conduit.getAssetData(address(token));
        assertEq(enabled, false);
        vm.expectEmit();
        emit SetAssetEnabled(address(token), true);
        conduit.setAssetEnabled(address(token), true);
        (enabled,,) = conduit.getAssetData(address(token));
        assertEq(enabled, true);
        assertEq(token.lastApproveAddress(), address(pool));
        assertEq(token.lastApproveAmount(), type(uint256).max);
    }

}
