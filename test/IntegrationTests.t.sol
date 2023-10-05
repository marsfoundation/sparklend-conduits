// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import "dss-test/DssTest.sol";

import { IPool }   from "aave-v3-core/contracts/interfaces/IPool.sol";
import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";

import { AllocatorRegistry } from "dss-allocator/AllocatorRegistry.sol";
import { AllocatorRoles }    from "dss-allocator/AllocatorRoles.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { UpgradeableProxy } from "upgradeable-proxy/UpgradeableProxy.sol";

import { SparkConduit, IInterestRateDataSource } from 'src/SparkConduit.sol';

contract ConduitIntegrationTestBase is DssTest {

    address DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address ADAI = 0x4DEDf26112B3Ec8eC46e7E31EA5e123490B05B8B;
    address POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address POT  = 0x197E90f9FAD81970bA7976f33CbD77088E5D7cf7;

    address admin     = makeAddr("admin");
    address buffer1   = makeAddr("buffer1");
    address buffer2   = makeAddr("buffer2");
    address operator1 = makeAddr("operator1");
    address operator2 = makeAddr("operator2");

    bytes32 constant ILK1 = 'ilk1';
    bytes32 constant ILK2 = 'ilk2';

    uint256 LIQUIDITY;           // dai.balanceOf(ADAI)
    uint256 ADAI_SUPPLY;         // aToken.totalSupply()
    uint256 ADAI_SCALED_SUPPLY;  // aToken.totalSupply()
    uint256 INDEX;               // pool.getReserveNormalizedIncome(DAI)

    AllocatorRegistry registry;
    AllocatorRoles    roles;

    IERC20  dai    = IERC20(DAI);
    IAToken aToken = IAToken(ADAI);
    IPool   pool   = IPool(POOL);

    SparkConduit conduit;

    function setUp() public virtual {
        vm.createSelectFork(getChain('mainnet').rpcUrl, 18_090_400);

        // Starting state at block 18_090_400
        LIQUIDITY          = 3042.894995046294009693 ether;
        ADAI_SUPPLY        = 200_668_890.552846452355198767 ether;
        ADAI_SCALED_SUPPLY = 199_358_171.788361925857232792 ether;
        INDEX              = 1.006574692939479711169088718e27;

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkConduit     impl  = new SparkConduit(POOL, POT);

        proxy.setImplementation(address(impl));

        conduit = SparkConduit(address(proxy));

        registry = new AllocatorRegistry();
        roles    = new AllocatorRoles();

        conduit.setRoles(address(roles));
        conduit.setRegistry(address(registry));

        registry.file(ILK1, "buffer", buffer1);
        registry.file(ILK2, "buffer", buffer2);

        _setupOperatorRole(ILK1, operator1);  // TODO: Change
        _setupOperatorRole(ILK2, operator2);

        // TODO: Use real buffer
        vm.prank(buffer1);
        IERC20(DAI).approve(address(conduit), type(uint256).max);

        vm.prank(buffer2);
        IERC20(DAI).approve(address(conduit), type(uint256).max);

        conduit.setAssetEnabled(DAI, true);
    }

    function test_assertInitialState() external {
        assertEq(LIQUIDITY,          3042.894995046294009693 ether);
        assertEq(ADAI_SUPPLY,        200_668_890.552846452355198767 ether);
        assertEq(ADAI_SCALED_SUPPLY, 199_358_171.788361925857232792 ether);
        assertEq(INDEX,              1.006574692939479711169088718e27);
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

    function _assertInvariants() internal {
        assertEq(
            conduit.totalShares(DAI),
            conduit.shares(DAI, ILK1) + conduit.shares(DAI, ILK2),
            "Invariant A"
        );

        assertEq(
            conduit.totalRequestedShares(DAI),
            conduit.requestedShares(DAI, ILK1) + conduit.requestedShares(DAI, ILK2),
            "Invariant B"
        );

        // NOTE: 1 error because 2 ilks, rounding error scales with number of ilks
        assertApproxEqAbs(
            conduit.getTotalDeposits(DAI),
            conduit.getDeposits(DAI, ILK1) + conduit.getDeposits(DAI, ILK2),
            1,
            "Invariant C"
        );

        // NOTE: 1 error because 2 ilks, rounding error scales with number of ilks
        assertApproxEqAbs(
            conduit.getTotalRequestedFunds(DAI),
            conduit.getRequestedFunds(DAI, ILK1) + conduit.getRequestedFunds(DAI, ILK2),
            1,
            "Invariant D"
        );

        assertApproxEqAbs(
            conduit.totalShares(DAI),
            aToken.scaledBalanceOf(address(conduit)),
            2,
            "Invariant E"
        );

        assertApproxEqAbs(
            conduit.getTotalDeposits(DAI),
            aToken.balanceOf(address(conduit)),
            2,
            "Invariant F"
        );
    }

    function _assertATokenState(
        uint256 scaledBalance,
        uint256 scaledTotalSupply,
        uint256 balance,
        uint256 totalSupply
    ) internal {
        assertEq(aToken.scaledBalanceOf(address(conduit)), scaledBalance,     "scaledBalance");
        assertEq(aToken.scaledTotalSupply(),               scaledTotalSupply, "scaledTotalSupply");
        assertEq(aToken.balanceOf(address(conduit)),       balance,           "balance");
        assertEq(aToken.totalSupply(),                     totalSupply,       "totalSupply");
    }

    function _assertDaiState(uint256 buffer1Balance, uint256 aTokenBalance) internal {
        assertEq(dai.balanceOf(buffer1),         buffer1Balance, "buffer1Balance");
        assertEq(dai.balanceOf(address(aToken)), aTokenBalance,  "aTokenBalance");
    }

    function _assertDaiState(
        uint256 buffer1Balance,
        uint256 buffer2Balance,
        uint256 aTokenBalance
    )
        internal
    {
        _assertDaiState(buffer1Balance, aTokenBalance);
        assertEq(dai.balanceOf(buffer2), buffer2Balance, "buffer2Balance");
    }

    function _assertConduitState(uint256 ilk1Shares, uint256 totalShares) internal {
        assertEq(conduit.shares(DAI, ILK1), ilk1Shares,  "ilk1Shares");
        assertEq(conduit.totalShares(DAI),  totalShares, "totalShares");
    }

    function _assertConduitState(
        uint256 ilk1Shares,
        uint256 ilk2Shares,
        uint256 totalShares
    )
        internal
    {
        _assertConduitState(ilk1Shares, totalShares);
        assertEq(conduit.shares(DAI, ILK2), ilk2Shares,  "ilk2Shares");
    }

}

contract ConduitDepositIntegrationTests is ConduitIntegrationTestBase {

    function test_deposit_insufficientBalanceBoundary() external {
        deal(DAI, buffer1, 100 ether);

        vm.startPrank(operator1);
        vm.expectRevert("SafeERC20/transfer-from-failed");
        conduit.deposit(ILK1, DAI, 100 ether + 1);

        conduit.deposit(ILK1, DAI, 100 ether);
    }

    function test_deposit_singleIlk_valueAccrual() external {
        deal(DAI, buffer1, 100 ether);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 100 ether,
            aTokenBalance:  LIQUIDITY
        });

        _assertATokenState({
            scaledBalance:     0,
            scaledTotalSupply: ADAI_SCALED_SUPPLY,
            balance:           0,
            totalSupply:       ADAI_SUPPLY
        });

        _assertConduitState({
            ilk1Shares:  0,
            totalShares: 0
        });

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        uint256 expectedShares        = 100 ether * 1e27 / INDEX;
        uint256 expectedScaledBalance = expectedShares + 1; // +1 for rounding

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 0,
            aTokenBalance:  LIQUIDITY + 100 ether
        });

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           100 ether,
            totalSupply:       ADAI_SUPPLY + 100 ether
        });

        _assertConduitState({
            ilk1Shares:  expectedShares,
            totalShares: expectedShares
        });

        vm.warp(block.timestamp + 1 days);

        uint256 newIndex = pool.getReserveNormalizedIncome(DAI);

        // +1 for rounding
        uint256 expectedValue  = expectedScaledBalance * newIndex / 1e27 + 1;
        uint256 expectedSupply = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * newIndex / 1e27 + 1;

        // Show interest accrual
        assertEq(expectedValue, 100.013366958918209602 ether);

        _assertInvariants();

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           expectedValue,
            totalSupply:       expectedSupply
        });
    }

    function test_deposit_multiIlk_valueAccrual() external {
        deal(DAI, buffer1, 100 ether);
        deal(DAI, buffer2, 50 ether);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 100 ether,
            buffer2Balance: 50 ether,
            aTokenBalance:  LIQUIDITY
        });

        _assertATokenState({
            scaledBalance:     0,
            scaledTotalSupply: ADAI_SCALED_SUPPLY,
            balance:           0,
            totalSupply:       ADAI_SUPPLY
        });

        _assertConduitState({
            ilk1Shares:  0,
            ilk2Shares:  0,
            totalShares: 0
        });

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        vm.warp(block.timestamp + 1 days);

        uint256 expectedIlk1Shares    = 100 ether * 1e27 / INDEX;
        uint256 expectedScaledBalance = expectedIlk1Shares + 1; // +1 for rounding

        uint256 newIndex = pool.getReserveNormalizedIncome(DAI);

        // +1 for rounding
        uint256 expectedIlk1Value = expectedScaledBalance * newIndex / 1e27 + 1;
        uint256 expectedSupply    = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * newIndex / 1e27;

        // Show interest accrual
        assertEq(expectedIlk1Value, 100.013366958918209602 ether);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 0,
            buffer2Balance: 50 ether,
            aTokenBalance:  LIQUIDITY + 100 ether
        });

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           expectedIlk1Value,
            totalSupply:       expectedSupply + 1  // Rounding
        });

        _assertConduitState({
            ilk1Shares:  expectedIlk1Shares,
            totalShares: expectedIlk1Shares
        });

        vm.prank(operator2);
        conduit.deposit(ILK2, DAI, 50 ether);

        // NOTE: Can use the same index since no time has passed since the above assertions
        uint256 expectedIlk2Shares = 50 ether * 1e27 / newIndex;  // No rounding because

        expectedScaledBalance = expectedIlk1Shares + expectedIlk2Shares + 1;  // Rounding

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 0,
            buffer2Balance: 0,
            aTokenBalance:  LIQUIDITY + 100 ether + 50 ether
        });

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           expectedIlk1Value + 50 ether,
            totalSupply:       expectedSupply + 50 ether
        });

        _assertConduitState({
            ilk1Shares:  expectedIlk1Shares,
            ilk2Shares:  expectedIlk2Shares,
            totalShares: expectedIlk1Shares + expectedIlk2Shares
        });
    }

}

contract ConduitWithdrawIntegrationTests is ConduitIntegrationTestBase {

    function test_withdrawal_singleIlk_valueAccrual() external {
        deal(DAI, buffer1, 100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        uint256 expectedShares        = 100 ether * 1e27 / INDEX;
        uint256 expectedScaledBalance = expectedShares + 1; // +1 for rounding

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 0,
            aTokenBalance:  LIQUIDITY + 100 ether
        });

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           100 ether,
            totalSupply:       ADAI_SUPPLY + 100 ether
        });

        _assertConduitState({
            ilk1Shares:  expectedShares,
            totalShares: expectedShares
        });

        vm.warp(block.timestamp + 1 days);

        uint256 newIndex = pool.getReserveNormalizedIncome(DAI);

        // +1 for rounding
        uint256 expectedValue  = expectedScaledBalance * newIndex / 1e27 + 1;
        uint256 expectedSupply = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * newIndex / 1e27 + 1;

        // Show interest accrual
        assertEq(expectedValue, 100.013366958918209602 ether);

        _assertInvariants();

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           expectedValue,
            totalSupply:       expectedSupply
        });

        vm.prank(operator1);
        uint256 amountWithdrawn = conduit.withdraw(ILK1, DAI, expectedValue);

        // Slightly less funds received than withdrawn, causing dust of 2 in accounting
        assertApproxEqAbs(amountWithdrawn, expectedValue, 2);
        assertLt(amountWithdrawn, expectedValue);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: expectedValue - 2,
            aTokenBalance:  LIQUIDITY + 100 ether - (expectedValue - 2)
        });

        // Dust of 2 left after withdrawal
        _assertATokenState({
            scaledBalance:     2,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + 2,
            balance:           2,
            totalSupply:       expectedSupply - expectedValue + 2
        });

        // TODO: Expect this to change after rounding fix is made, dust shares remaining
        _assertConduitState({
            ilk1Shares:  1,
            totalShares: 1
        });
    }

}
