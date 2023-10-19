// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import 'dss-test/DssTest.sol';

import { MockERC20 } from 'erc20-helpers/MockERC20.sol';

import { UpgradeableProxy } from 'upgradeable-proxy/UpgradeableProxy.sol';

import { SparkLendConduit } from '../src/SparkLendConduit.sol';

import { SparkLendConduitHarness } from './harnesses/SparkLendConduitHarness.sol';

import { PoolMock, RolesMock, RegistryMock } from "./mocks/Mocks.sol";

import { ATokenMock } from "./mocks/ATokenMock.sol";

// TODO: Add multiple buffers when multi ilk is used

contract SparkLendConduitTestBase is DssTest {

    uint256 constant RBPS             = RAY / 10_000;
    uint256 constant WBPS             = WAD / 10_000;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    bytes32 constant ILK  = 'some-ilk';
    bytes32 constant ILK2 = 'some-ilk2';

    address buffer = makeAddr("buffer");

    PoolMock     pool;
    RolesMock    roles;
    RegistryMock registry;
    MockERC20    token;
    ATokenMock   atoken;

    SparkLendConduit conduit;

    event Deposit(bytes32 indexed ilk, address indexed asset, address origin, uint256 amount);
    event Withdraw(bytes32 indexed ilk, address indexed asset, address destination, uint256 amount);
    event SetRoles(address roles);
    event SetRegistry(address registry);
    event SetAssetEnabled(address indexed asset, bool enabled);

    function setUp() public virtual {
        pool     = new PoolMock(vm);
        roles    = new RolesMock();
        registry = new RegistryMock();

        registry.setBuffer(buffer);  // TODO: Update this, make buffer per ilk

        token = new MockERC20('Token', 'TKN', 18);

        atoken = pool.atoken();

        atoken.setUnderlying(address(token));

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkLendConduit impl  = new SparkLendConduit(address(pool));

        proxy.setImplementation(address(impl));

        conduit = SparkLendConduit(address(proxy));

        conduit.setRoles(address(roles));
        conduit.setRegistry(address(registry));
        conduit.setAssetEnabled(address(token), true);

        vm.prank(buffer);
        token.approve(address(conduit), type(uint256).max);

        // Set default liquidity index to be greater than 1:1
        // 100 / 125% = 80 shares for 100 asset deposit
        pool.setLiquidityIndex(125_00 * RBPS);
    }

    function _assertATokenState(
        uint256 scaledBalance,
        uint256 scaledTotalSupply,
        uint256 balance,
        uint256 totalSupply
    ) internal {
        assertEq(atoken.scaledBalanceOf(address(conduit)), scaledBalance);
        assertEq(atoken.scaledTotalSupply(),               scaledTotalSupply);
        assertEq(atoken.balanceOf(address(conduit)),       balance);
        assertEq(atoken.totalSupply(),                     totalSupply);
    }

    function _assertTokenState(uint256 bufferBalance, uint256 atokenBalance) internal {
        assertEq(token.balanceOf(buffer),          bufferBalance);
        assertEq(token.balanceOf(address(atoken)), atokenBalance);
    }

}

contract SparkLendConduitConstructorTests is SparkLendConduitTestBase {

    function test_constructor() public {
        assertEq(conduit.pool(),               address(pool));
        assertEq(conduit.wards(address(this)), 1);
    }

}

contract SparkLendConduitModifierTests is SparkLendConduitTestBase {

    function test_authModifiers() public {
        UpgradeableProxy(address(conduit)).deny(address(this));

        checkModifier(address(conduit), "SparkLendConduit/not-authorized", [
            SparkLendConduit.setRoles.selector,
            SparkLendConduit.setRegistry.selector,
            SparkLendConduit.setAssetEnabled.selector
        ]);
    }

    function test_ilkAuthModifiers() public {
        roles.setCanCall(false);

        checkModifier(address(conduit), "SparkLendConduit/ilk-not-authorized", [
            SparkLendConduit.deposit.selector,
            SparkLendConduit.withdraw.selector
        ]);
    }

}

contract SparkLendConduitDepositTests is SparkLendConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);
    }

    function test_deposit_revert_notEnabled() public {
        conduit.setAssetEnabled(address(token), false);
        vm.expectRevert("SparkLendConduit/asset-disabled");
        conduit.deposit(ILK, address(token), 100 ether);
    }

    function test_deposit() public {
        _assertTokenState({
            bufferBalance: 100 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     0,
            scaledTotalSupply: 0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);

        vm.expectEmit();
        emit Deposit(ILK, address(token), buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 100 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);
    }

    function test_deposit_multiIlk_increasingIndex() public {
        _assertTokenState({
            bufferBalance: 100 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     0,
            scaledTotalSupply: 0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);

        vm.expectEmit();
        emit Deposit(ILK, address(token), buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 100 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        pool.setLiquidityIndex(160_00 * RBPS);  // 50 / 160% = 31.25 shares for 50 asset deposit

        token.mint(buffer, 50 ether);  // For second deposit

        vm.expectEmit();
        emit Deposit(ILK2, address(token), buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 150 ether
        });

        _assertATokenState({
            scaledBalance:     111.25 ether,  // 80 + 31.25
            scaledTotalSupply: 111.25 ether,
            balance:           178 ether,  // 80 * 1.6 + 50 = 178
            totalSupply:       178 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 31.25 ether);
        assertEq(conduit.totalShares(address(token)),  111.25 ether);
    }

}

contract SparkLendConduitWithdrawTests is SparkLendConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);

        conduit.deposit(ILK, address(token), 100 ether);
    }

    // Assert that one wei can't be withdrawn without burning one share
    function test_withdraw_sharesRounding() public {
        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 100 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 1);
        assertEq(conduit.withdraw(ILK, address(token), 1), 1);

        _assertTokenState({
            bufferBalance: 1,
            atokenBalance: 100 ether - 1
        });

        // NOTE: SparkLend state doesn't have rounding logic, just conduit state.
        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether - 1);
        assertEq(conduit.totalShares(address(token)), 80 ether - 1);
    }

    function test_withdraw_singleIlk_exactPartialWithdraw() public {
        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 100 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 40 ether);
        assertEq(conduit.withdraw(ILK, address(token), 40 ether), 40 ether);

        _assertTokenState({
            bufferBalance: 40 ether,
            atokenBalance: 60 ether
        });

        _assertATokenState({
            scaledBalance:     48 ether,
            scaledTotalSupply: 48 ether,
            balance:           60 ether,
            totalSupply:       60 ether
        });

        assertEq(conduit.shares(address(token), ILK), 48 ether);
        assertEq(conduit.totalShares(address(token)), 48 ether);
    }

    function test_withdraw_singleIlk_maxUint() public {
        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 100 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        _assertTokenState({
            bufferBalance: 100 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     0,
            scaledTotalSupply: 0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);
    }

    function test_withdraw_multiIlk_exactPartialWithdraw() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 150 ether
        });

        _assertATokenState({
            scaledBalance:     120 ether,
            scaledTotalSupply: 120 ether,
            balance:           150 ether,
            totalSupply:       150 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 50 ether);
        assertEq(conduit.withdraw(ILK, address(token), 50 ether), 50 ether);

        _assertTokenState({
            bufferBalance: 50 ether,
            atokenBalance: 100 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK),  40 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  80 ether);
    }

    // TODO: Partial liquidity
    function test_withdraw_multiIlk_maxUint() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 150 ether
        });

        _assertATokenState({
            scaledBalance:     120 ether,
            scaledTotalSupply: 120 ether,
            balance:           150 ether,
            totalSupply:       150 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        _assertTokenState({
            bufferBalance: 100 ether,
            atokenBalance: 50 ether
        });

        _assertATokenState({
            scaledBalance:     40 ether,
            scaledTotalSupply: 40 ether,
            balance:           50 ether,
            totalSupply:       50 ether
        });

        assertEq(conduit.shares(address(token), ILK),  0);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  40 ether);
    }

    function test_withdraw_singleIlk_maxUint_partialLiquidity() public {
        deal(address(token), address(atoken), 40 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 40 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 40 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 40 ether);

        _assertTokenState({
            bufferBalance: 40 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     48 ether,
            scaledTotalSupply: 48 ether,
            balance:           60 ether,
            totalSupply:       60 ether
        });

        assertEq(conduit.shares(address(token), ILK), 48 ether);
        assertEq(conduit.totalShares(address(token)), 48 ether);
    }

    function test_withdraw_multiIlk_increasingIndex() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 150 ether
        });

        _assertATokenState({
            scaledBalance:     120 ether,
            scaledTotalSupply: 120 ether,
            balance:           150 ether,
            totalSupply:       150 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        // type(uint256).max yields the same underlying funds because of same index
        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        _assertTokenState({
            bufferBalance: 100 ether,
            atokenBalance: 50 ether
        });

        _assertATokenState({
            scaledBalance:     40 ether,
            scaledTotalSupply: 40 ether,
            balance:           50 ether,
            totalSupply:       50 ether
        });

        assertEq(conduit.shares(address(token), ILK),  0);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  40 ether);

        // This mimics interest being earned in the pool. However since the liquidity hasn't
        // changed, ilk2 will not be able to withdraw the full amount of funds they are entitled to.
        // This means that they will instead just burn less shares in order to get their initial
        // deposit back.
        pool.setLiquidityIndex(160_00 * RBPS);  // 100 / 160% = 62.5 shares for 100 asset deposit

        assertEq(conduit.withdraw(ILK2, address(token), type(uint256).max), 50 ether);

        _assertTokenState({
            bufferBalance: 150 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     8.75 ether,  // 40 - (50 / 1.6) = 8.75
            scaledTotalSupply: 8.75 ether,
            balance:           14 ether,    // Interest earned by ilk2
            totalSupply:       14 ether
        });

        assertEq(conduit.shares(address(token), ILK),  0);
        assertEq(conduit.shares(address(token), ILK2), 8.75 ether);
        assertEq(conduit.totalShares(address(token)),  8.75 ether);
    }

    function test_withdraw_multiIlk_decreasingIndex() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 150 ether
        });

        _assertATokenState({
            scaledBalance:     120 ether,
            scaledTotalSupply: 120 ether,
            balance:           150 ether,
            totalSupply:       150 ether
        });

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        // type(uint256).max yields the same underlying funds because of same index
        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        _assertTokenState({
            bufferBalance: 100 ether,
            atokenBalance: 50 ether
        });

        _assertATokenState({
            scaledBalance:     40 ether,
            scaledTotalSupply: 40 ether,
            balance:           50 ether,
            totalSupply:       50 ether
        });

        assertEq(conduit.shares(address(token), ILK),  0);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  40 ether);

        // This mimics a loss in the pool. Since the liquidity hasn't changed, this means that the
        // 40 shares that ilk2 has will not be able to withdraw the full amount of funds they
        // originally deposited.
        pool.setLiquidityIndex(80_00 * RBPS);  // 100 / 80% = 125 shares for 100 asset deposit

        assertEq(conduit.withdraw(ILK2, address(token), type(uint256).max), 32 ether);

        _assertTokenState({
            bufferBalance: 132 ether,
            atokenBalance: 18 ether
        });

        _assertATokenState({
            scaledBalance:     0,
            scaledTotalSupply: 0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK),  0);
        assertEq(conduit.shares(address(token), ILK2), 0);
        assertEq(conduit.totalShares(address(token)),  0);
    }

}

contract SparkLendConduitMaxViewFunctionTests is SparkLendConduitTestBase {

    function test_maxDeposit() public {
        assertEq(conduit.maxDeposit(ILK, address(token)), type(uint256).max);
    }

    function test_maxDeposit_unsupportedAsset() public {
        assertEq(conduit.maxDeposit(ILK, makeAddr("some-addr")), 0);
    }

    function test_maxWithdraw() public {
        assertEq(conduit.maxWithdraw(ILK, address(token)), 0);

        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(conduit.maxWithdraw(ILK, address(token)), 100 ether);

        deal(address(token), address(atoken), 40 ether);

        assertEq(conduit.maxWithdraw(ILK, address(token)), 40 ether);
    }

}

contract SparkLendConduitGetTotalDepositsTests is SparkLendConduitTestBase {

    function test_getTotalDeposits() external {
        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(conduit.getTotalDeposits(address(token)), 100 ether);

        pool.setLiquidityIndex(160_00 * RBPS);

        // 100 @ 1.25 = 80, 80 @ 1.6 = 128
        assertEq(conduit.getTotalDeposits(address(token)), 128 ether);
    }

    function testFuzz_getTotalDeposits(
        uint256 index1,
        uint256 index2,
        uint256 depositAmount
    )
        external
    {
        index1        = bound(index1,        1 * RBPS, 500_00 * RBPS);
        index2        = bound(index2,        1 * RBPS, 500_00 * RBPS);
        depositAmount = bound(depositAmount, 0,        1e32);

        pool.setLiquidityIndex(index1);

        token.mint(buffer, depositAmount);
        conduit.deposit(ILK, address(token), depositAmount);

        assertApproxEqAbs(conduit.getTotalDeposits(address(token)), depositAmount, 10);

        pool.setLiquidityIndex(index2);

        uint256 expectedDeposit = depositAmount * 1e27 / index1 * index2 / 1e27;

        assertApproxEqAbs(conduit.getTotalDeposits(address(token)), expectedDeposit, 10);
    }

}

contract SparkLendConduitGetDepositsTests is SparkLendConduitTestBase {

    function test_getDeposits() external {
        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(conduit.getDeposits(address(token), ILK), 100 ether);

        pool.setLiquidityIndex(160_00 * RBPS);

        // 100 @ 1.25 = 80, 80 @ 1.6 = 128
        assertEq(conduit.getDeposits(address(token), ILK), 128 ether);
    }

    function testFuzz_getDeposits(
        uint256 index1,
        uint256 index2,
        uint256 depositAmount
    )
        external
    {
        index1        = bound(index1,        1 * RBPS, 500_00 * RBPS);
        index2        = bound(index2,        1 * RBPS, 500_00 * RBPS);
        depositAmount = bound(depositAmount, 0,        1e32);

        pool.setLiquidityIndex(index1);

        token.mint(buffer, depositAmount);
        conduit.deposit(ILK, address(token), depositAmount);

        assertApproxEqAbs(conduit.getDeposits(address(token), ILK), depositAmount, 10);

        pool.setLiquidityIndex(index2);

        uint256 expectedDeposit = depositAmount * 1e27 / index1 * index2 / 1e27;

        assertApproxEqAbs(conduit.getDeposits(address(token), ILK), expectedDeposit, 10);
    }

}

contract SparkLendConduitGetAvailableLiquidityTests is SparkLendConduitTestBase {

    function test_getAvailableLiquidity() external {
        assertEq(conduit.getAvailableLiquidity(address(token)), 0);

        deal(address(token), address(atoken), 100 ether);

        assertEq(conduit.getAvailableLiquidity(address(token)), 100 ether);
    }

    function testFuzz_getAvailableLiquidity(uint256 dealAmount) external {
        assertEq(conduit.getAvailableLiquidity(address(token)), 0);

        deal(address(token), address(atoken), dealAmount);

        assertEq(conduit.getAvailableLiquidity(address(token)), dealAmount);
    }

}

contract SparkLendConduitAdminSetterTests is SparkLendConduitTestBase {

    address SET_ADDRESS = makeAddr("set-address");

    function test_setRoles() public {
        assertEq(conduit.roles(), address(roles));

        vm.expectEmit();
        emit SetRoles(SET_ADDRESS);
        conduit.setRoles(SET_ADDRESS);

        assertEq(conduit.roles(), SET_ADDRESS);
    }

    function test_setRegistry() public {
        assertEq(conduit.registry(), address(registry));

        vm.expectEmit();
        emit SetRegistry(SET_ADDRESS);
        conduit.setRegistry(SET_ADDRESS);

        assertEq(conduit.registry(), SET_ADDRESS);
    }

    function test_setAssetEnabled() public {
        // Starting state
        conduit.setAssetEnabled(address(token), false);

        assertEq(conduit.enabled(address(token)), false);

        assertEq(token.allowance(address(conduit), address(pool)), 0);

        vm.expectEmit();
        emit SetAssetEnabled(address(token), true);
        conduit.setAssetEnabled(address(token), true);

        assertEq(conduit.enabled(address(token)), true);

        assertEq(token.allowance(address(conduit), address(pool)), type(uint256).max);

        vm.expectEmit();
        emit SetAssetEnabled(address(token), false);
        conduit.setAssetEnabled(address(token), false);

        assertEq(conduit.enabled(address(token)), false);

        assertEq(token.allowance(address(conduit), address(pool)), 0);
    }

}

contract SparkLendConduitHarnessDivUpTests is SparkLendConduitTestBase {

    SparkLendConduitHarness conduitHarness;

    function setUp() public override {
        super.setUp();

        SparkLendConduitHarness impl = new SparkLendConduitHarness(address(pool));

        UpgradeableProxy(address(conduit)).setImplementation(address(impl));

        conduitHarness = SparkLendConduitHarness(address(conduit));
    }

    function test_divUp() public {
        // Divide by zero
        vm.expectRevert(stdError.divisionError);
        conduitHarness.divUp(1, 0);

        // Small numbers
        assertEq(conduitHarness.divUp(0, 1), 0);
        assertEq(conduitHarness.divUp(1, 1), 1);
        assertEq(conduitHarness.divUp(2, 1), 2);
        assertEq(conduitHarness.divUp(3, 1), 3);
        assertEq(conduitHarness.divUp(4, 1), 4);

        assertEq(conduitHarness.divUp(0, 2), 0);
        assertEq(conduitHarness.divUp(1, 2), 1);
        assertEq(conduitHarness.divUp(2, 2), 1);
        assertEq(conduitHarness.divUp(3, 2), 2);
        assertEq(conduitHarness.divUp(4, 2), 2);

        assertEq(conduitHarness.divUp(0, 3), 0);
        assertEq(conduitHarness.divUp(1, 3), 1);
        assertEq(conduitHarness.divUp(2, 3), 1);
        assertEq(conduitHarness.divUp(3, 3), 1);
        assertEq(conduitHarness.divUp(4, 3), 2);
        assertEq(conduitHarness.divUp(5, 3), 2);
        assertEq(conduitHarness.divUp(6, 3), 2);

        // Large numbers
        assertEq(conduitHarness.divUp(0, 1e27), 0);
        assertEq(conduitHarness.divUp(1, 1e27), 1);

        assertEq(conduitHarness.divUp(1e27,     1e27 + 1), 1);
        assertEq(conduitHarness.divUp(1e27 + 1, 1e27 + 1), 1);
        assertEq(conduitHarness.divUp(1e27 + 1, 1e27),     2);
    }

}
