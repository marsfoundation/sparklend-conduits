// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "dss-test/DssTest.sol";

import { SparkConduit, ISparkConduit, IAuth, IPool } from "../src/SparkConduit.sol";

contract PoolMock {

}

contract PotMock {

}

contract RolesMock {

    bool canCallSuccess = true;
    bool isWhitelistedDestinationSuccess = true;

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

    PoolMock  pool;
    PotMock   pot;
    RolesMock roles;

    SparkConduit conduit;

    function setUp() public {
        pool  = new PoolMock();
        pot   = new PotMock();
        roles = new RolesMock();

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

}
