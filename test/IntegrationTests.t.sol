// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import "dss-test/DssTest.sol";

import { IPool }   from "aave-v3-core/contracts/interfaces/IPool.sol";
import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";

import { AllocatorRegistry } from "dss-allocator/AllocatorRegistry.sol";
import { AllocatorRoles }    from "dss-allocator/AllocatorRoles.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { UpgradeableProxy } from "upgradeable-proxy/UpgradeableProxy.sol";

import { SparkLendConduit } from 'src/SparkLendConduit.sol';

contract ConduitIntegrationTestBase is DssTest {

    address DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address ADAI = 0x4DEDf26112B3Ec8eC46e7E31EA5e123490B05B8B;
    address POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;

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

    SparkLendConduit conduit;

    function setUp() public virtual {
        vm.createSelectFork(getChain('mainnet').rpcUrl, 18_090_400);

        // Starting state at block 18_090_400
        LIQUIDITY          = 3042.894995046294009693 ether;
        ADAI_SUPPLY        = 200_668_890.552846452355198767 ether;
        ADAI_SCALED_SUPPLY = 199_358_171.788361925857232792 ether;
        INDEX              = 1.006574692939479711169088718e27;

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkLendConduit impl  = new SparkLendConduit(POOL);

        proxy.setImplementation(address(impl));

        conduit = SparkLendConduit(address(proxy));

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
    }

    function _assertInvariants() internal {
        assertEq(
            conduit.totalShares(DAI),
            conduit.shares(DAI, ILK1) + conduit.shares(DAI, ILK2),
            "Invariant A"
        );

        // NOTE: 1 error because 2 ilks, rounding error scales with number of ilks
        assertApproxEqAbs(
            conduit.getTotalDeposits(DAI),
            conduit.getDeposits(DAI, ILK1) + conduit.getDeposits(DAI, ILK2),
            1,
            "Invariant B"
        );

        assertApproxEqAbs(
            conduit.totalShares(DAI),
            aToken.scaledBalanceOf(address(conduit)),
            2,
            "Invariant C"
        );

        assertApproxEqAbs(
            conduit.getTotalDeposits(DAI),
            aToken.balanceOf(address(conduit)),
            2,
            "Invariant D"
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

    function test_deposit_zeroAddressBuffer() external {
        deal(DAI, buffer1, 100 ether);

        registry.file(ILK1, "buffer", address(0));

        vm.prank(operator1);
        vm.expectRevert("SparkLendConduit/no-buffer-registered");
        conduit.deposit(ILK1, DAI, 100 ether);

        registry.file(ILK1, "buffer", buffer1);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);
    }

    function test_deposit_ilkNotRegistered() external {
        bytes32 ILK3 = "ilk3";
        address operator3 = makeAddr("operator3");
        address buffer3   = makeAddr("buffer3");

        vm.prank(buffer3);
        IERC20(DAI).approve(address(conduit), type(uint256).max);

        _setupOperatorRole(ILK3, operator3);

        deal(DAI, buffer3, 100 ether);

        // Same error, but because buffer was never initialized to begin with
        vm.prank(operator3);
        vm.expectRevert("SparkLendConduit/no-buffer-registered");
        conduit.deposit(ILK3, DAI, 100 ether);

        registry.file(ILK3, "buffer", buffer3);

        vm.prank(operator3);
        conduit.deposit(ILK3, DAI, 100 ether);
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

    function test_withdraw_noBufferRegistered() external {
        deal(DAI, buffer1, 100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        registry.file(ILK1, "buffer", address(0));

        vm.prank(operator1);
        vm.expectRevert("SparkLendConduit/no-buffer-registered");
        conduit.withdraw(ILK1, DAI, 100 ether);

        registry.file(ILK1, "buffer", buffer1);

        vm.prank(operator1);
        conduit.withdraw(ILK1, DAI, 100 ether);
    }

    function test_withdraw_singleIlk_valueAccrual() external {
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

        _assertConduitState({
            ilk1Shares:  0,
            totalShares: 0
        });
    }

    function test_withdraw_multiIlk_valueAccrual() external {
        // Intentionally using same values for both ilks to show differences in interest accrual
        deal(DAI, buffer1, 100 ether);
        deal(DAI, buffer2, 100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        vm.warp(block.timestamp + 1 days);

        vm.prank(operator2);
        conduit.deposit(ILK2, DAI, 100 ether);

        // Need new index because time has passed
        uint256 index1 = pool.getReserveNormalizedIncome(DAI);

        uint256 expectedIlk1Shares    = 100 ether * 1e27 / INDEX;
        uint256 expectedIlk2Shares    = 100 ether * 1e27 / index1;
        uint256 expectedScaledBalance = expectedIlk1Shares + expectedIlk2Shares + 1; // +1 for rounding

        // Warp time to show interest accrual for both ilks
        vm.warp(block.timestamp + 10 days);

        // Need new index because time has passed
        uint256 index2 = pool.getReserveNormalizedIncome(DAI);

        uint256 expectedIlk1Value = expectedIlk1Shares * index2 / 1e27 + 1;  // +1 for rounding
        uint256 expectedIlk2Value = expectedIlk2Shares * index2 / 1e27 + 1;  // +1 for rounding

        uint256 poolValue1 = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * index1 / 1e27;

        // Value accrued for whole pool between deposits plus all new value accrued
        uint256 expectedSupply = (poolValue1 + 100 ether) * 1e27 / index1 * index2 / 1e27 + 1; // +1 for rounding

        // Show that ilk1 has more interest accrued than ilk2 because it has been in
        // the pool for longer.
        assertEq(expectedIlk1Value, 100.147054349327300547 ether);
        assertEq(expectedIlk2Value, 100.133669522858884231 ether);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: 0,
            buffer2Balance: 0,
            aTokenBalance:  LIQUIDITY + 100 ether + 100 ether
        });

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           expectedIlk1Value + expectedIlk2Value,
            totalSupply:       expectedSupply
        });

        _assertConduitState({
            ilk1Shares:  expectedIlk1Shares,
            ilk2Shares:  expectedIlk2Shares,
            totalShares: expectedIlk1Shares + expectedIlk2Shares
        });

        vm.prank(operator1);
        uint256 amountWithdrawn = conduit.withdraw(ILK1, DAI, expectedIlk1Value);

        // Slightly less funds received than withdrawn, causing dust of 1 in accounting
        assertApproxEqAbs(amountWithdrawn, expectedIlk1Value, 1);
        assertLt(amountWithdrawn, expectedIlk1Value);

        _assertInvariants();

        uint256 combinedDeposits = 100 ether + 100 ether;

        _assertDaiState({
            buffer1Balance: expectedIlk1Value - 1,
            buffer2Balance: 0,
            aTokenBalance:  LIQUIDITY + combinedDeposits - (expectedIlk1Value - 1)
        });

        // Dust of 1 left after withdrawal
        _assertATokenState({
            scaledBalance:     1 + expectedIlk2Shares,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + 1 + expectedIlk2Shares,
            balance:           1 + expectedIlk2Value,
            totalSupply:       expectedSupply - expectedIlk1Value + 1
        });

        _assertConduitState({
            ilk1Shares:  0,
            ilk2Shares:  expectedIlk2Shares,
            totalShares: expectedIlk2Shares
        });

        vm.warp(block.timestamp + 1 days);

        // Need new index because time has passed
        uint256 index3 = pool.getReserveNormalizedIncome(DAI);

        expectedIlk2Value = expectedIlk2Shares * index3 / 1e27 + 1;  // +1 for rounding

        vm.prank(operator2);
        amountWithdrawn = conduit.withdraw(ILK2, DAI, expectedIlk2Value);

        // Slightly less funds received than withdrawn, causing dust of 1 in accounting
        assertApproxEqAbs(amountWithdrawn, expectedIlk2Value, 1);
        assertLt(amountWithdrawn, expectedIlk2Value);

        _assertInvariants();

        _assertDaiState({
            buffer1Balance: expectedIlk1Value - 1,
            buffer2Balance: expectedIlk2Value - 1,
            aTokenBalance:  LIQUIDITY + combinedDeposits - (expectedIlk1Value - 1) - (expectedIlk2Value - 1)
        });

        // Value accrued for whole pool between withdrawals
        expectedSupply = (expectedSupply - (expectedIlk1Value - 1)) * 1e27 / index2 * index3 / 1e27 + 1; // +1 for rounding

        // Dust of 1 left after withdrawal
        _assertATokenState({
            scaledBalance:     2,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + 2,
            balance:           2,
            totalSupply:       expectedSupply - (expectedIlk2Value - 1)  // Does not need to subtract ilk1
        });

        _assertConduitState({
            ilk1Shares:  0,
            ilk2Shares:  0,
            totalShares: 0
        });

    }

}
