// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import "dss-test/DssTest.sol";

// Debug
import { AaveProtocolDataProvider } from "aave-v3-core/contracts/misc/AaveProtocolDataProvider.sol";
import { BorrowLogic }              from "aave-v3-core/contracts/protocol/libraries/logic/BorrowLogic.sol";
import { SupplyLogic }              from "aave-v3-core/contracts/protocol/libraries/logic/SupplyLogic.sol";
// Debug

import { IAToken }           from "aave-v3-core/contracts/interfaces/IAToken.sol";
import { IPoolConfigurator } from "aave-v3-core/contracts/interfaces/IPoolConfigurator.sol";
import { IPool }             from "aave-v3-core/contracts/interfaces/IPool.sol";

import { IVariableDebtToken as IDToken }
    from "aave-v3-core/contracts/interfaces/IVariableDebtToken.sol";

import { AllocatorRegistry } from "dss-allocator/AllocatorRegistry.sol";
import { AllocatorRoles }    from "dss-allocator/AllocatorRoles.sol";

import { IERC20 } from "erc20-helpers/interfaces/IERC20.sol";

import { UpgradeableProxy } from "upgradeable-proxy/UpgradeableProxy.sol";

import {  IInterestRateDataSource, PotLike, SparkConduit } from 'src/SparkConduit.sol';

import { DaiInterestRateStrategy, DataTypes } from 'src/DaiInterestRateStrategy.sol';

contract ConduitIntegrationTestBase is DssTest {

    // Debug
    AaveProtocolDataProvider data
        = AaveProtocolDataProvider(0xFc21d6d146E6086B8359705C8b28512a983db0cb);

    address DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address ADAI = 0x4DEDf26112B3Ec8eC46e7E31EA5e123490B05B8B;
    address DDAI = 0xf705d2B7e92B3F38e6ae7afaDAA2fEE110fE5914;
    address POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address POT  = 0x197E90f9FAD81970bA7976f33CbD77088E5D7cf7;

    address POOL_CONFIGURATOR = 0x542DBa469bdE58FAeE189ffB60C6b49CE60E0738;

    uint256 constant RBPS = RAY / 10_000;

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
    uint256 START;               // block.timestamp
    uint256 DSR_APR;             // Annualized pot.dsr()
    uint256 DSR;                 // pot.dsr()

    AllocatorRegistry       registry;
    AllocatorRoles          roles;
    DaiInterestRateStrategy interestStrategy;

    IERC20  dai    = IERC20(DAI);
    IERC20  weth   = IERC20(WETH);
    IERC20  dToken = IERC20(DDAI);
    IAToken aToken = IAToken(ADAI);
    IPool   pool   = IPool(POOL);

    SparkConduit conduit;

    function setUp() public virtual {
        vm.createSelectFork(getChain('mainnet').rpcUrl, 18_090_400);

        // Debug

        address borrowLogic = deployCode("BorrowLogic.sol:BorrowLogic", bytes(""));
        address supplyLogic = deployCode("SupplyLogic.sol:SupplyLogic", bytes(""));

        address deployedBorrowLogic = 0x5d834EAD0a80CF3b88c06FeeD6e8E0Fcae2daEE5;
        address deployedSupplyLogic = 0x39dF4b1329D41A9AE20e17BeFf39aAbd2f049128;

        vm.etch(deployedBorrowLogic, borrowLogic.code);
        vm.etch(deployedSupplyLogic, supplyLogic.code);

        // Debug

        // Starting state at block 18_090_400
        LIQUIDITY          = 3042.894995046294009693 ether;
        ADAI_SUPPLY        = 200_668_890.552846452355198767 ether;
        ADAI_SCALED_SUPPLY = 199_358_171.788361925857232792 ether;
        INDEX              = 1.006574692939479711169088718e27;
        START              = 1_694_160_383;
        DSR_APR            = 0.048790164207174267760128000e27;
        DSR                = 1.000000001547125957863212448e27;

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkConduit     impl  = new SparkConduit(POOL, POT);

        proxy.setImplementation(address(impl));

        conduit = SparkConduit(address(proxy));

        registry = new AllocatorRegistry();
        roles    = new AllocatorRoles();

        interestStrategy = new DaiInterestRateStrategy(
            address(dai),
            conduit,
            30 * RBPS,
            75_00 * RBPS
        );

        vm.prank(POOL_CONFIGURATOR);
        pool.setReserveInterestRateStrategyAddress(DAI, address(interestStrategy));

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
        conduit.setSubsidySpread(50 * RBPS);
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

        vm.warp(block.timestamp + 365 days);

        uint256 expectedValue1 = 100 ether;

        for (uint256 i; i < 86400 * 365; ++i) {
            expectedValue1 = expectedValue1 * DSR / 1e27;
        }

        uint256 expectedValue2 = 100 ether + 100 ether * DSR_APR / 1e27;

        // uint256 newIndex = pool.getReserveNormalizedIncome(DAI);

        // // +1 for rounding
        // uint256 expectedValue  = expectedScaledBalance * newIndex / 1e27 + 1;
        // uint256 expectedSupply = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * newIndex / 1e27 + 1;

        // // Show interest accrual
        // assertEq(expectedValue, 100.013366958918209602 ether);

        assertEq(expectedValue1, 1);
        assertEq(expectedValue2, 2);

        assertEq(expectedValue1 - expectedValue2, 6);

        // _assertInvariants();

        _assertATokenState({
            scaledBalance:     expectedScaledBalance,
            scaledTotalSupply: ADAI_SCALED_SUPPLY + expectedScaledBalance,
            balance:           3,
            totalSupply:       4
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

        // TODO: Warp time and show interest accrual
    }

}

contract ConduitRequestFundsE2ETests is ConduitIntegrationTestBase {

    // TODO: Update

    address borrower1 = makeAddr("borrower1");
    address borrower2 = makeAddr("borrower2");

    function test_requestFunds_e2e_scenario1() external {
        deal(DAI,  buffer1,   10_000_000 ether);
        deal(DAI,  buffer2,   10_000_000 ether);
        deal(WETH, borrower1, 10_000_000 ether);
        deal(WETH, borrower2, 10_000_000 ether);

        vm.warp(START + 1 days);

        /*************************************************/
        /*** 1. Recompute To Update Timestamp for Logs ***/
        /*************************************************/

        interestStrategy.recompute();  // Recompute to get timestamps set up

        /***************************************************************************/
        /*** 2. Clear out all DAI balance in aDAI to have a clean starting state ***/
        /***************************************************************************/

        vm.startPrank(borrower1);

        weth.approve(address(pool), 10_000_000 ether);
        pool.supply(WETH, 10_000_000 ether, borrower1, 0);
        pool.borrow(DAI, dai.balanceOf(ADAI), 2, 0, borrower1);

        vm.warp(block.timestamp + 1 days);

        vm.stopPrank();

        /*****************************/
        /*** 3. Log Starting State ***/
        /*****************************/

        _logAll("3. Log Starting State");

        _logConstantRateState();

        /******************************************************************************/
        /*** 4. Deposit 10m DAI from SparkDAO using the allocation system + conduit ***/
        /******************************************************************************/

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 10_000_000 ether);

        interestStrategy.recompute();

        _logAll("4. Deposit 10m DAI from ilk1 using the allocation system + conduit, also recompute to get correct debt ratio");

        /***********************************************************************************/
        /*** 5. Borrow the full 10m DAI as an external actor (borrower1) using SparkLend ***/
        /***********************************************************************************/

        vm.startPrank(borrower2);

        weth.approve(address(pool), 10_000_000 ether);
        pool.supply(WETH, 10_000_000 ether, borrower2, 0);
        pool.borrow(DAI, 10_000_000 ether, 2, 0, borrower2);

        vm.stopPrank();

        _logAll("5. Borrow the full 10m DAI as an external actor (borrower1) using SparkLend");

        /**********************************************************************************/
        /*** 6. Request 10m DAI back as the SubDAO, demonstrate no rate change in Spark ***/
        /**********************************************************************************/

        vm.prank(operator1);
        conduit.requestFunds(ILK1, DAI, 10_000_000 ether);

        _logAll("6. Request 10m DAI back as the SubDAO, demonstrate no rate change in Spark");

        /******************************************************************************/
        /*** 7. Recompute in interest strategy, demonstrate no rate change in Spark ***/
        /******************************************************************************/

        interestStrategy.recompute();

        _logAll("7. Recompute in interest strategy, demonstrate no rate change in Spark");

        /**************************************************************/
        /*** 8. Borrow again as borrower2, demonstrate state update ***/
        /**************************************************************/

        vm.warp(block.timestamp + 365 days);

        deal(DAI, ADAI, 1 ether);
        vm.prank(borrower1);
        pool.borrow(DAI, 1 ether, 2, 0, borrower1);

        _logAll("8. Borrow again as borrower2, demonstrate state update");

        /*******************************************************************/
        /*** 9. Repay 1/3 debt as borrower1, demo interest rate decrease ***/
        /*******************************************************************/

        uint256 debtOwed = dToken.balanceOf(address(borrower2));

        deal(DAI, borrower2, debtOwed);

        vm.startPrank(borrower2);
        dai.approve(address(pool), debtOwed / 3);
        pool.repay(DAI, debtOwed / 3, 2, borrower2);
        vm.stopPrank();

        _logAll("9. Repay 1/3 debt as borrower1, demo interest rate decrease");

        /***************************************************************************/
        /*** 10. Repay another 1/3 debt as borrower1, demo interest rate decrease ***/
        /***************************************************************************/

        vm.startPrank(borrower2);
        dai.approve(address(pool), debtOwed / 3);
        pool.repay(DAI, debtOwed / 3, 2, borrower2);
        vm.stopPrank();

        _logAll("10. Repay another 1/3 debt as borrower1, demo interest rate decrease");

        /**********************************************************************************/
        /*** 11. Repay all debt as borrower1, demo interest rate return to DSR + spread ***/
        /**********************************************************************************/

        vm.startPrank(borrower2);
        dai.approve(address(pool), debtOwed / 3);
        pool.repay(DAI, debtOwed / 3, 2, borrower2);
        vm.stopPrank();

        _logAll("11. Repay all debt as borrower1, demo interest rate return to DSR + spread");

        /****************************************************************/
        /*** 12. Withdraw 10m DAI + interest from conduit as SparkDAO ***/
        /****************************************************************/

        vm.prank(operator1);
        conduit.withdraw(ILK1, DAI, type(uint256).max);

        _logAll("12. Withdraw 10m DAI + interest from conduit as SparkDAO");
    }

    function _logExchangeRates() internal view {
        uint256 income = pool.getReserveNormalizedIncome(DAI);
        uint256 debt   = pool.getReserveNormalizedVariableDebt(DAI);

        _log("borrower exchangeRate", debt,   27);
        _log("lender exchangeRate  ", income, 27);
    }

    function _logPositionState() internal {
        console.log("----");
        console.log("Position State");
        console.log("----");

        _log("conduit shares     ", conduit.shares(DAI, ILK1));
        _log("conduit position   ", conduit.getDeposits(DAI, ILK1));
        _log("conduit aToken     ", aToken.balanceOf(address(conduit)));
        _log("borrower dToken    ", dToken.balanceOf(address(borrower2)));
        _log("borrower DAI       ", dai.balanceOf(address(borrower2)));
        _log("buffer DAI         ", dai.balanceOf(address(buffer1)));
        _log("Spark DAI liquidity", dai.balanceOf(ADAI));
    }

    function _logDebtInfoState() internal view {
        IInterestRateDataSource.InterestData memory conduitData = conduit.getInterestData(DAI);

        console.log("----");
        console.log("Conduit Rate State");
        console.log("----");

        _log("currentDebt", conduitData.currentDebt, 18);
        _log("targetDebt ", conduitData.targetDebt,  18);

        console.log("lastUpdate     ", (interestStrategy.getLastUpdateTimestamp() - START) / 84600);
    }

    function _logConstantRateState() internal view {
        console.log("----");
        console.log("Constant Conduit/Strategy Rate State");
        console.log("----");

        IInterestRateDataSource.InterestData memory conduitData = conduit.getInterestData(DAI);

        _log("baseRate      ", conduitData.baseRate,    27);
        _log("subsidyRate   ", conduitData.subsidyRate, 27);
        _log("spread        ", interestStrategy.spread(), 27);
        _log("baseBorrowRate", interestStrategy.getBaseBorrowRate(), 27);
    }

    function _logSparkRateState() internal {
        (
            ,
            ,
            ,
            ,
            ,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            ,
            ,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint256 lastUpdateTimestamp
        ) = data.getReserveData(DAI);

        uint256 income = pool.getReserveNormalizedIncome(DAI);
        uint256 debt   = pool.getReserveNormalizedVariableDebt(DAI);

        console.log("----");
        console.log("Spark Reserve State");
        console.log("----");

        _log("liquidityRate        ", liquidityRate,       27);
        _log("variableBorrowRate   ", variableBorrowRate,  27);
        _log("borrower exchangeRate", debt,                27);
        _log("variableBorrowIndex  ", variableBorrowIndex, 27);
        _log("liquidityIndex       ", liquidityIndex,      27);
        _log("lender exchangeRate  ", income,              27);

        console.log("lastUpdate           ", (lastUpdateTimestamp - START) / 86400);

        vm.warp(block.timestamp + 1 days);

        console.log("----");
        console.log("Exchange Rates after 1 day");
        console.log("----");

        _logExchangeRates();
    }

    function _logAll(string memory label) internal {
        console.log("");
        console.log("");
        console.log("");
        console.log("----");
        console.log(label);
        console.log("   Day:", (block.timestamp - START) / 86400);
        console.log("----");

        _logPositionState();
        _logDebtInfoState();
        _logSparkRateState();
    }

    function _log(string memory key, uint256 value, uint256 decimals)
        internal view
    {
        uint256 whole = value / 10 ** decimals;
        uint256 part;

        if (decimals > 4) {
            part = (value % 10 ** decimals) / 10 ** (decimals - 4);
        } else {
            part = (value % 10 ** decimals) * 10 ** (4 - decimals);
        }

        string memory wholeString = vm.toString(whole);
        string memory formattedWholeString = "";
        uint256 length = bytes(wholeString).length;

        for (uint256 i = 0; i < length; i++) {
            if (i > 0 && (length - i) % 3 == 0) {
                formattedWholeString = string(abi.encodePacked(formattedWholeString, ","));
            }
            bytes1 char = bytes(wholeString)[i];
            formattedWholeString
                = string(abi.encodePacked(formattedWholeString, string(abi.encodePacked(char))));
        }

        string memory partString = vm.toString(part);

        uint256 leadingZeros = 4 - bytes(partString).length;

        string memory zeros = "";
        for (uint256 i = 0; i < leadingZeros; i++) {
            zeros = string(abi.encodePacked(zeros, "0"));
        }

        console.log(key, string(abi.encodePacked(
            formattedWholeString,
            ".",
            zeros,
            partString
        )));
    }

    function _log(string memory key, uint256 value) internal view {
        _log(key, value, 18);
    }
}

contract ConduitWithdrawIntegrationTests is ConduitIntegrationTestBase {

    function test_withdraw_singleIlk_valueAccrual() external {
        deal(DAI, buffer1, 100 ether);

        vm.prank(operator1);
        conduit.deposit(ILK1, DAI, 100 ether);

        _assertInvariants();

        assertEq(dai.balanceOf(buffer1), 0);
        assertEq(dai.balanceOf(ADAI),    LIQUIDITY + 100 ether);

        uint256 expectedShares = 100 ether * 1e27 / INDEX;

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), expectedShares, 1);
        assertApproxEqAbs(conduit.shares(DAI, ILK1),                expectedShares, 1);
        assertApproxEqAbs(conduit.totalShares(DAI),                 expectedShares, 1);

        assertEq(aToken.balanceOf(address(conduit)), 100 ether);
        assertEq(aToken.totalSupply(),               ADAI_SUPPLY + 100 ether);

        vm.warp(block.timestamp + 1 days);

        _assertInvariants();

        uint256 newIndex = pool.getReserveNormalizedIncome(DAI);

        uint256 expectedValue  = expectedShares * newIndex / 1e27;
        uint256 expectedSupply = (ADAI_SUPPLY + 100 ether) * 1e27 / INDEX * newIndex / 1e27;

        // Show interest accrual
        assertEq(expectedValue, 100.013366958918209600 ether);

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), expectedShares, 1);
        assertApproxEqAbs(conduit.shares(DAI, ILK1),                expectedShares, 1);
        assertApproxEqAbs(conduit.totalShares(DAI),                 expectedShares, 1);

        assertApproxEqAbs(aToken.balanceOf(address(conduit)), expectedValue,  2);
        assertApproxEqAbs(aToken.totalSupply(),               expectedSupply, 1);

        vm.prank(operator1);
        uint256 amountWithdrawn = conduit.withdraw(ILK1, DAI, expectedValue);

        _assertInvariants();

        assertEq(amountWithdrawn, expectedValue);

        assertEq(dai.balanceOf(buffer1), expectedValue);
        assertEq(dai.balanceOf(ADAI),   LIQUIDITY + 100 ether - expectedValue);

        assertApproxEqAbs(aToken.scaledBalanceOf(address(conduit)), 0, 2);
        assertApproxEqAbs(aToken.balanceOf(address(conduit)),       0, 2);
        assertApproxEqAbs(conduit.shares(DAI, ILK1),                0, 2);
        assertApproxEqAbs(conduit.totalShares(DAI),                 0, 2);

        assertApproxEqAbs(aToken.totalSupply(), expectedSupply - expectedValue, 1);
    }

}
