// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import "dss-test/DssTest.sol";

import { AllocatorRegistry } from "dss-allocator/AllocatorRegistry.sol";
import { AllocatorRoles }    from "dss-allocator/AllocatorRoles.sol";

import { MockERC20 } from "erc20-helpers/MockERC20.sol";

import { UpgradeableProxy } from "upgradeable-proxy/UpgradeableProxy.sol";

import { SparkConduit, IInterestRateDataSource } from 'src/SparkConduit.sol';

import { IPool } from "aave-v3-core/contracts/interfaces/IPool.sol";

contract ConduitTestBase is DssTest {

    address POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address POT  = 0x197E90f9FAD81970bA7976f33CbD77088E5D7cf7;

    address admin    = makeAddr("admin");
    address operator = makeAddr("operator");

    bytes32 constant ILK = 'some-ilk';

    AllocatorRegistry registry = new AllocatorRegistry();
    AllocatorRoles    roles    = new AllocatorRoles();

    IPool pool = IPool(POOL);

    SparkConduit conduit;

    function setUp() public virtual {
        vm.createSelectFork(getChain('mainnet').rpcUrl, 18_090_400);

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkConduit     impl  = new SparkConduit(POOL, POT);

        proxy.setImplementation(address(impl));

        conduit = SparkConduit(address(proxy));

        conduit.setRoles(address(roles));
        conduit.setRegistry(address(registry));
    }

    function test_deposit() external {
        conduit.deposit(ILK, address(token), 100 ether);
    }

    function _setupOperatorRole(bytes32 ilk_, address operator_) internal {
        uint8 ROLE = 0;

        // Ensure address(this) can always set for a new ilk
        roles.setIlkAdmin(ilk_, address(this));

        roles.setUserRole(ilk_, operator_, ROLE, true);

        address conduit_ = address(conduit);

        roles.setRoleAction(ilk_, ROLE, conduit_, conduit.deposit.selector,           true);
        roles.setRoleAction(ilk_, ROLE, conduit_, conduit.withdraw.selector,          true);
        roles.setRoleAction(ilk_, ROLE, conduit_, conduit.requestFunds.selector,      true);
        roles.setRoleAction(ilk_, ROLE, conduit_, conduit.cancelFundRequest.selector, true);
    }

}
