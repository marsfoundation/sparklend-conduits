// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import "dss-test/DssTest.sol";

import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";
import { IPool }   from "aave-v3-core/contracts/interfaces/IPool.sol";

import { AllocatorRegistry } from "dss-allocator/AllocatorRegistry.sol";
import { AllocatorRoles }    from "dss-allocator/AllocatorRoles.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { UpgradeableProxy } from "upgradeable-proxy/UpgradeableProxy.sol";

import { SparkConduit, IInterestRateDataSource } from 'src/SparkConduit.sol';

contract ConduitTestBase is DssTest {

    address DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address ADAI = 0x4DEDf26112B3Ec8eC46e7E31EA5e123490B05B8B;
    address POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address POT  = 0x197E90f9FAD81970bA7976f33CbD77088E5D7cf7;

    address admin    = makeAddr("admin");
    address buffer   = makeAddr("buffer");
    address operator = makeAddr("operator");

    bytes32 constant ILK = 'some-ilk';

    uint256 LIQUIDITY;    // dai.balanceOf(ADAI)
    uint256 ADAI_SUPPLY;  // aToken.totalSupply()
    uint256 INDEX;        // pool.getReserveNormalizedIncome(DAI)

    AllocatorRegistry registry;
    AllocatorRoles    roles;

    IERC20  dai    = IERC20(DAI);
    IAToken aToken = IAToken(ADAI);
    IPool   pool   = IPool(POOL);

    SparkConduit conduit;

    function setUp() public virtual {
        vm.createSelectFork(getChain('mainnet').rpcUrl, 18_090_400);

        // Starting state at block 18_090_400
        LIQUIDITY   = 3042.894995046294009693 ether;
        ADAI_SUPPLY = 200_668_890.552846452355198767 ether;
        INDEX       = 1.006574692939479711169088718e27;

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkConduit     impl  = new SparkConduit(POOL, POT);

        proxy.setImplementation(address(impl));

        conduit = SparkConduit(address(proxy));

        registry = new AllocatorRegistry();
        roles    = new AllocatorRoles();

        conduit.setRoles(address(roles));
        conduit.setRegistry(address(registry));

        registry.file(ILK, "buffer", buffer);

        _setupOperatorRole(ILK, address(this));  // TODO: Change

        // TODO: Use real buffer
        vm.prank(buffer);
        IERC20(DAI).approve(address(conduit), type(uint256).max);

        conduit.setAssetEnabled(DAI, true);
    }

    function test_deposit_integration() external {
        deal(DAI, buffer, 100 ether);

        assertEq(dai.balanceOf(buffer), 100 ether);
        assertEq(dai.balanceOf(ADAI),   LIQUIDITY);

        assertEq(aToken.scaledBalanceOf(address(conduit)), 0);
        assertEq(aToken.balanceOf(address(conduit)),       0);
        assertEq(aToken.totalSupply(),                     ADAI_SUPPLY);

        assertEq(conduit.shares(DAI, ILK), 0);
        assertEq(conduit.totalShares(DAI), 0);

        conduit.deposit(ILK, DAI, 100 ether);

        assertEq(dai.balanceOf(buffer), 0);
        assertEq(dai.balanceOf(ADAI),   LIQUIDITY + 100 ether);

        uint256 expectedShares = 100 ether * 1e27 / INDEX;

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), expectedShares, 1);
        assertApproxEqAbs(conduit.shares(DAI, ILK),                 expectedShares, 1);
        assertApproxEqAbs(conduit.totalShares(DAI),                 expectedShares, 1);

        assertEq(aToken.balanceOf(address(conduit)), 100 ether);
        assertEq(aToken.totalSupply(),               ADAI_SUPPLY + 100 ether);

        vm.warp(block.timestamp + 1 days);

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), expectedShares, 1);
        assertApproxEqAbs(conduit.shares(DAI, ILK),                 expectedShares, 1);
        assertApproxEqAbs(conduit.totalShares(DAI),                 expectedShares, 1);

        uint256 newIndex = pool.getReserveNormalizedIncome(DAI);

        uint256 expectedValue  = expectedShares * newIndex / 1e27;
        uint256 expectedSupply = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * newIndex / 1e27;

        // Show interest accrual
        assertEq(expectedValue, 100.013366958918209600 ether);

        assertApproxEqAbs(aToken.balanceOf(address(conduit)), expectedValue,  2);
        assertApproxEqAbs(aToken.totalSupply(),               expectedSupply, 1);
    }

    function test_withdraw_integration() external {
        deal(DAI, buffer, 100 ether);

        conduit.deposit(ILK, DAI, 100 ether);

        assertEq(dai.balanceOf(buffer), 0);
        assertEq(dai.balanceOf(ADAI),   LIQUIDITY + 100 ether);

        uint256 expectedShares = 100 ether * 1e27 / INDEX;

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), expectedShares, 1);
        assertApproxEqAbs(conduit.shares(DAI, ILK),                 expectedShares, 1);
        assertApproxEqAbs(conduit.totalShares(DAI),                 expectedShares, 1);

        assertEq(aToken.balanceOf(address(conduit)), 100 ether);
        assertEq(aToken.totalSupply(),               ADAI_SUPPLY + 100 ether);

        vm.warp(block.timestamp + 1 days);

        uint256 newIndex = pool.getReserveNormalizedIncome(DAI);

        uint256 expectedValue  = expectedShares * newIndex / 1e27;
        uint256 expectedSupply = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * newIndex / 1e27;

        // Show interest accrual
        assertEq(expectedValue, 100.013366958918209600 ether);

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), expectedShares, 1);
        assertApproxEqAbs(conduit.shares(DAI, ILK),                 expectedShares, 1);
        assertApproxEqAbs(conduit.totalShares(DAI),                 expectedShares, 1);

        assertApproxEqAbs(aToken.balanceOf(address(conduit)), expectedValue,  2);
        assertApproxEqAbs(aToken.totalSupply(),               expectedSupply, 1);

        uint256 amountWithdrawn = conduit.withdraw(ILK, DAI, expectedValue);

        assertEq(amountWithdrawn, expectedValue);

        assertEq(dai.balanceOf(buffer), expectedValue);
        assertEq(dai.balanceOf(ADAI),   LIQUIDITY + 100 ether - expectedValue);

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), 0, 2);
        assertApproxEqAbs(aToken.balanceOf(address(conduit)),       0, 2);
        assertApproxEqAbs(conduit.shares(DAI, ILK),                 0, 2);
        assertApproxEqAbs(conduit.totalShares(DAI),                 0, 2);

        assertApproxEqAbs(aToken.totalSupply(), expectedSupply - expectedValue, 1);
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
