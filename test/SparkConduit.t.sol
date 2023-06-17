// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "dss-test/DssTest.sol";

import { SparkConduit, ISparkConduit, IAuth, IPool } from "../src/SparkConduit.sol";

contract PoolMock {

}

contract PotMock {

}

contract RolesMock {

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

}
