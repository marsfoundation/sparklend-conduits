// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "dss-test/DssTest.sol";
import { MockERC20 } from 'mock-erc20/src/MockERC20.sol';

import {
    SparkConduit,
    ISparkConduit,
    IAuth,
    IPool,
    IInterestRateDataSource,
    IERC20,
    DataTypes
} from "../src/SparkConduit.sol";

contract PoolMock {

    MockERC20 public aToken;
    uint256 public liquidityIndex = 10 ** 27;
    Vm vm;

    constructor(Vm _vm) {
        vm = _vm;
        aToken = new MockERC20('aToken', 'aTKN', 18);
    }

    function supply(
        address asset,
        uint256 amount,
        address,
        uint16
    ) external {
        IERC20(asset).transferFrom(msg.sender, address(aToken), amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        uint256 liquidityAvailable = IERC20(asset).balanceOf(address(aToken));
        if (amount > liquidityAvailable) {
            amount = liquidityAvailable;
        }
        vm.prank(address(aToken)); IERC20(asset).transfer(to, amount);
        return amount;
    }

    function getReserveData(address) external view returns (DataTypes.ReserveData memory) {
        return DataTypes.ReserveData({
            configuration: DataTypes.ReserveConfigurationMap(0),
            liquidityIndex: uint128(liquidityIndex),
            currentLiquidityRate: 0,
            variableBorrowIndex: 0,
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: 0,
            id: 0,
            aTokenAddress: address(aToken),
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }

    function setLiquidityIndex(uint256 _liquidityIndex) external {
        liquidityIndex = _liquidityIndex;
    }

}

contract PotMock {

    uint256 public dsr;

    function setDSR(uint256 _dsr) external {
        dsr = _dsr;
    }

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
    uint256 constant WBPS = WAD / 10000;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    bytes32 constant ILK = 'some-ilk';
    bytes32 constant ILK2 = 'some-ilk2';

    PoolMock  pool;
    PotMock   pot;
    RolesMock roles;
    MockERC20 token;

    SparkConduit conduit;

    event Deposit(bytes32 indexed ilk, address indexed asset, uint256 amount);
    event Withdraw(bytes32 indexed ilk, address indexed asset, address destination, uint256 amount);
    event RequestFunds(bytes32 indexed ilk, address indexed asset, uint256 amount);
    event CancelFundRequest(bytes32 indexed ilk, address indexed asset);
    event SetSubsidySpread(uint256 subsidySpread);
    event SetAssetEnabled(address indexed asset, bool enabled);

    function setUp() public {
        pool  = new PoolMock(vm);
        pot   = new PotMock();
        roles = new RolesMock();
        token = new MockERC20('Token', 'TKN', 18);

        vm.expectEmit();
        emit Rely(address(this));
        conduit = new SparkConduit(
            IPool(address(pool)),
            address(pot),
            address(roles)
        );

        // Mint us some of the token and approve the conduit
        token.mint(address(this), 1000 ether);
        token.approve(address(conduit), type(uint256).max);
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

    function test_ilkAuthModifiers() public {
        roles.setCanCall(false);

        checkModifier(address(conduit), "SparkConduit/ilk-not-authorized", [
            SparkConduit.deposit.selector,
            SparkConduit.withdraw.selector,
            SparkConduit.requestFunds.selector,
            SparkConduit.cancelFundRequest.selector
        ]);
    }

    function test_deposit() public {
        conduit.setAssetEnabled(address(token), true);
        pool.setLiquidityIndex(101_00 * RBPS);  // Induce a slight rounding error

        assertEq(token.balanceOf(address(pool.aToken())), 0);
        assertEq(conduit.getDeposits(ILK, address(token)), 0);
        assertEq(conduit.getTotalDeposits(address(token)), 0);

        vm.expectEmit();
        emit Deposit(ILK, address(token), 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(token.balanceOf(address(pool.aToken())), 100 ether);
        assertApproxEqAbs(conduit.getDeposits(ILK, address(token)), 100 ether, 1);
        assertApproxEqAbs(conduit.getTotalDeposits(address(token)), 100 ether, 1);
    }

    function test_deposit_revert_not_enabled() public {
        vm.expectRevert("SparkConduit/asset-disabled");
        conduit.deposit(ILK, address(token), 100 ether);
    }

    function test_deposit_revert_pending_withdrawal() public {
        conduit.setAssetEnabled(address(token), true);
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(pool.aToken()), 0);     // Zero out the liquidity so we can request funds
        conduit.requestFunds(ILK, address(token), 50 ether);

        vm.expectRevert("SparkConduit/no-deposit-with-pending-withdrawals");
        conduit.deposit(ILK, address(token), 100 ether);
    }

    function test_withdraw_liquidity_available() public {
        conduit.setAssetEnabled(address(token), true);
        pool.setLiquidityIndex(200_00 * RBPS);  // 200% is a more round number to avoid having to deal with rounding errors
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(token.balanceOf(address(pool.aToken())), 100 ether);
        assertEq(token.balanceOf(TEST_ADDRESS), 0);
        assertEq(conduit.getDeposits(ILK, address(token)), 100 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 100 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), TEST_ADDRESS, 50 ether);
        conduit.withdraw(ILK, address(token), TEST_ADDRESS, 50 ether);

        assertEq(token.balanceOf(address(pool.aToken())), 50 ether);
        assertEq(token.balanceOf(TEST_ADDRESS), 50 ether);
        assertEq(conduit.getDeposits(ILK, address(token)), 50 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 50 ether);
    }

    function test_withdraw_pending_withdrawal_partial_fill() public {
        conduit.setAssetEnabled(address(token), true);
        pool.setLiquidityIndex(200_00 * RBPS);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(conduit.getDeposits(ILK, address(token)), 100 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 100 ether);
        assertEq(conduit.getWithdrawals(ILK, address(token)), 0);
        assertEq(conduit.getTotalWithdrawals(address(token)), 0);

        deal(address(token), address(pool.aToken()), 0);
        conduit.requestFunds(ILK, address(token), 50 ether);

        assertEq(conduit.getDeposits(ILK, address(token)), 100 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 100 ether);
        assertEq(conduit.getWithdrawals(ILK, address(token)), 50 ether);
        assertEq(conduit.getTotalWithdrawals(address(token)), 50 ether);

        // This should fill part of the withdrawal order
        deal(address(token), address(pool.aToken()), 25 ether);
        vm.expectEmit();
        emit Withdraw(ILK, address(token), TEST_ADDRESS, 25 ether);
        conduit.withdraw(ILK, address(token), TEST_ADDRESS, 25 ether);

        assertEq(conduit.getDeposits(ILK, address(token)), 75 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 75 ether);
        assertEq(conduit.getWithdrawals(ILK, address(token)), 25 ether);
        assertEq(conduit.getTotalWithdrawals(address(token)), 25 ether);
    }

    function test_withdraw_pending_withdrawal_complete_fill() public {
        conduit.setAssetEnabled(address(token), true);
        pool.setLiquidityIndex(200_00 * RBPS);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(conduit.getDeposits(ILK, address(token)), 100 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 100 ether);
        assertEq(conduit.getWithdrawals(ILK, address(token)), 0);
        assertEq(conduit.getTotalWithdrawals(address(token)), 0);

        deal(address(token), address(pool.aToken()), 0);
        conduit.requestFunds(ILK, address(token), 50 ether);

        assertEq(conduit.getDeposits(ILK, address(token)), 100 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 100 ether);
        assertEq(conduit.getWithdrawals(ILK, address(token)), 50 ether);
        assertEq(conduit.getTotalWithdrawals(address(token)), 50 ether);

        // This should fill part of the withdrawal order
        deal(address(token), address(pool.aToken()), 60 ether);
        vm.expectEmit();
        emit Withdraw(ILK, address(token), TEST_ADDRESS, 60 ether);
        conduit.withdraw(ILK, address(token), TEST_ADDRESS, 60 ether);

        assertEq(conduit.getDeposits(ILK, address(token)), 40 ether);
        assertEq(conduit.getTotalDeposits(address(token)), 40 ether);
        assertEq(conduit.getWithdrawals(ILK, address(token)), 0 ether);
        assertEq(conduit.getTotalWithdrawals(address(token)), 0 ether);
    }

    function test_maxDeposit() public {
        assertEq(conduit.maxDeposit(ILK, address(token)), type(uint256).max);
    }

    function test_maxWithdraw() public {
        conduit.setAssetEnabled(address(token), true);
        pool.setLiquidityIndex(200_00 * RBPS);

        assertEq(conduit.maxWithdraw(ILK, address(token)), 0);

        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(conduit.maxWithdraw(ILK, address(token)), 100 ether);

        deal(address(token), address(pool.aToken()), 50 ether);

        assertEq(conduit.maxWithdraw(ILK, address(token)), 50 ether);
    }

    function test_requestFunds() public {
        conduit.setAssetEnabled(address(token), true);
        pool.setLiquidityIndex(200_00 * RBPS);
        conduit.deposit(ILK, address(token), 100 ether);
        conduit.deposit(ILK2, address(token), 100 ether);
        deal(address(token), address(pool.aToken()), 0);

        assertEq(conduit.getWithdrawals(ILK, address(token)), 0);
        assertEq(conduit.getWithdrawals(ILK2, address(token)), 0);
        assertEq(conduit.getTotalWithdrawals(address(token)), 0);

        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 50 ether);
        conduit.requestFunds(ILK, address(token), 50 ether);

        assertEq(conduit.getWithdrawals(ILK, address(token)), 50 ether);
        assertEq(conduit.getWithdrawals(ILK2, address(token)), 0);
        assertEq(conduit.getTotalWithdrawals(address(token)), 50 ether);

        vm.expectEmit();
        emit RequestFunds(ILK2, address(token), 25 ether);
        conduit.requestFunds(ILK2, address(token), 25 ether);

        assertEq(conduit.getWithdrawals(ILK, address(token)), 50 ether);
        assertEq(conduit.getWithdrawals(ILK2, address(token)), 25 ether);
        assertEq(conduit.getTotalWithdrawals(address(token)), 75 ether);

        // This should override instead of stack
        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 10 ether);
        conduit.requestFunds(ILK, address(token), 10 ether);

        assertEq(conduit.getWithdrawals(ILK, address(token)), 10 ether);
        assertEq(conduit.getWithdrawals(ILK2, address(token)), 25 ether);
        assertEq(conduit.getTotalWithdrawals(address(token)), 35 ether);
    }

    function test_getInterestData() public {
        conduit.setSubsidySpread(50 * RBPS);
        pot.setDSR((350 * RBPS) / SECONDS_PER_YEAR + RAY);
        conduit.setAssetEnabled(address(token), true);
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(pool.aToken()), 0);
        conduit.requestFunds(ILK, address(token), 50 ether);

        IInterestRateDataSource.InterestData memory data = conduit.getInterestData(address(token));

        assertApproxEqRel(data.baseRate, 400 * RBPS, WBPS);
        assertApproxEqRel(data.subsidyRate, 350 * RBPS, WBPS);
        assertEq(data.currentDebt, 100 ether);
        assertEq(data.targetDebt, 50 ether);
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
        assertEq(token.allowance(address(conduit), address(pool)), 0);
        vm.expectEmit();
        emit SetAssetEnabled(address(token), true);
        conduit.setAssetEnabled(address(token), true);
        (enabled,,) = conduit.getAssetData(address(token));
        assertEq(enabled, true);
        assertEq(token.allowance(address(conduit), address(pool)), type(uint256).max);
        vm.expectEmit();
        emit SetAssetEnabled(address(token), false);
        conduit.setAssetEnabled(address(token), false);
        (enabled,,) = conduit.getAssetData(address(token));
        assertEq(enabled, false);
        assertEq(token.allowance(address(conduit), address(pool)), 0);
    }

}
