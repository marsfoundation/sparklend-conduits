// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import 'dss-test/DssTest.sol';

import { MockERC20 } from 'erc20-helpers/MockERC20.sol';

import { UpgradeableProxy } from 'upgradeable-proxy/UpgradeableProxy.sol';

import { SparkConduit, IInterestRateDataSource } from '../src/SparkConduit.sol';

import { PoolMock, PotMock, RolesMock, RegistryMock } from "./Mocks.sol";

// TODO: Show how requested shares/shares are handled during an increase in exchange rate

contract SparkConduitTestBase is DssTest {

    uint256 constant RBPS             = RAY / 10_000;
    uint256 constant WBPS             = WAD / 10_000;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    bytes32 constant ILK  = 'some-ilk';
    bytes32 constant ILK2 = 'some-ilk2';

    address buffer = makeAddr("buffer");

    PoolMock     pool;
    PotMock      pot;
    RolesMock    roles;
    RegistryMock registry;
    MockERC20    token;
    MockERC20    atoken;

    SparkConduit conduit;

    event Deposit(bytes32 indexed ilk, address indexed asset, address origin, uint256 amount);
    event Withdraw(bytes32 indexed ilk, address indexed asset, address destination, uint256 amount);
    event RequestFunds(bytes32 indexed ilk, address indexed asset, uint256 amount);
    event CancelFundRequest(bytes32 indexed ilk, address indexed asset);
    event SetRoles(address roles);
    event SetRegistry(address registry);
    event SetSubsidySpread(uint256 subsidySpread);
    event SetAssetEnabled(address indexed asset, bool enabled);

    function setUp() public virtual {
        pool     = new PoolMock(vm);
        pot      = new PotMock();
        roles    = new RolesMock();
        registry = new RegistryMock();

        registry.setBuffer(buffer);  // TODO: Update this, make buffer per ilk

        token  = new MockERC20('Token', 'TKN', 18);
        atoken = pool.atoken();

        UpgradeableProxy proxy = new UpgradeableProxy();
        SparkConduit     impl  = new SparkConduit(address(pool),address(pot));

        proxy.setImplementation(address(impl));

        conduit = SparkConduit(address(proxy));

        conduit.setRoles(address(roles));
        conduit.setRegistry(address(registry));
        conduit.setAssetEnabled(address(token), true);

        vm.prank(buffer);
        token.approve(address(conduit), type(uint256).max);

        // Set default liquidity index to be greater than 1:1
        // 100 / 125% = 80 shares for 100 asset deposit
        pool.setLiquidityIndex(125_00 * RBPS);
    }

}

contract SparkConduitConstructorTests is SparkConduitTestBase {

    function test_constructor() public {
        assertEq(conduit.pool(),               address(pool));
        assertEq(conduit.pot(),                address(pot));
        assertEq(conduit.wards(address(this)), 1);
    }

}

contract SparkConduitModifierTests is SparkConduitTestBase {

    function test_authModifiers() public {
        UpgradeableProxy(address(conduit)).deny(address(this));

        checkModifier(address(conduit), "SparkConduit/not-authorized", [
            SparkConduit.setRoles.selector,
            SparkConduit.setRegistry.selector,
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

}

contract SparkConduitDepositTests is SparkConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);
    }

    function test_deposit_revert_notEnabled() public {
        conduit.setAssetEnabled(address(token), false);
        vm.expectRevert("SparkConduit/asset-disabled");
        conduit.deposit(ILK, address(token), 100 ether);
    }

    function test_deposit_revert_pendingRequest() public {
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(atoken), 0);
        conduit.requestFunds(ILK, address(token), 40 ether);

        vm.expectRevert("SparkConduit/no-deposit-with-requested-shares");
        conduit.deposit(ILK, address(token), 100 ether);
    }

    // TODO: Multi-ilk deposit
    function test_deposit() public {

        assertEq(token.balanceOf(buffer),          100 ether);
        assertEq(token.balanceOf(address(atoken)), 0);

        assertEq(atoken.balanceOf(address(conduit)), 0);
        assertEq(atoken.totalSupply(),               0);

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);

        vm.expectEmit();
        emit Deposit(ILK, address(token), buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        assertEq(token.balanceOf(buffer),           0);
        assertEq(token.balanceOf(address(atoken)),  100 ether);

        assertEq(atoken.balanceOf(address(conduit)), 80 ether);
        assertEq(atoken.totalSupply(),               80 ether);

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);
    }

}

contract SparkConduitWithdrawTests is SparkConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);

        conduit.deposit(ILK, address(token), 100 ether);
    }

    function test_withdraw_singleIlk_exactWithdraw() public {
        assertEq(token.balanceOf(buffer),          0);
        assertEq(token.balanceOf(address(atoken)), 100 ether);

        assertEq(atoken.balanceOf(address(conduit)), 80 ether);
        assertEq(atoken.totalSupply(),               80 ether);

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 40 ether);
        assertEq(conduit.withdraw(ILK, address(token), 40 ether), 40 ether);

        assertEq(token.balanceOf(buffer),          40 ether);
        assertEq(token.balanceOf(address(atoken)), 60 ether);

        assertEq(atoken.balanceOf(address(conduit)), 48 ether);  // 40 / 1.25 = 32
        assertEq(atoken.totalSupply(),               48 ether);

        assertEq(conduit.shares(address(token), ILK), 48 ether);
        assertEq(conduit.totalShares(address(token)), 48 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

    function test_withdraw_singleIlk_maxUint() public {
        assertEq(token.balanceOf(buffer),           0);
        assertEq(token.balanceOf(address(atoken)),  100 ether);

        assertEq(atoken.balanceOf(address(conduit)), 80 ether);
        assertEq(atoken.totalSupply(),               80 ether);

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        assertEq(token.balanceOf(buffer),          100 ether);
        assertEq(token.balanceOf(address(atoken)), 0);

        assertEq(atoken.balanceOf(address(conduit)), 0);
        assertEq(atoken.totalSupply(),               0);

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

    function test_withdraw_multiIlk_exactWithdraw() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        assertEq(token.balanceOf(buffer),          0);
        assertEq(token.balanceOf(address(atoken)), 150 ether);

        assertEq(atoken.balanceOf(address(conduit)), 120 ether);
        assertEq(atoken.totalSupply(),               120 ether);

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 50 ether);
        assertEq(conduit.withdraw(ILK, address(token), 50 ether), 50 ether);

        assertEq(token.balanceOf(buffer),          50 ether);
        assertEq(token.balanceOf(address(atoken)), 100 ether);

        assertEq(atoken.balanceOf(address(conduit)), 80 ether);
        assertEq(atoken.totalSupply(),               80 ether);

        assertEq(conduit.shares(address(token), ILK),  40 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  80 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);
    }

    // TODO: Partial liquidity
    function test_withdraw_multiIlk_maxUint() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        assertEq(token.balanceOf(buffer),          0);
        assertEq(token.balanceOf(address(atoken)), 150 ether);

        assertEq(atoken.balanceOf(address(conduit)), 120 ether);
        assertEq(atoken.totalSupply(),               120 ether);

        assertEq(conduit.shares(address(token), ILK),  80 ether);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  120 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 100 ether);

        assertEq(token.balanceOf(buffer),          100 ether);
        assertEq(token.balanceOf(address(atoken)), 50 ether);

        assertEq(atoken.balanceOf(address(conduit)), 40 ether);
        assertEq(atoken.totalSupply(),               40 ether);

        assertEq(conduit.shares(address(token), ILK),  0);
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  40 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);
    }

    function test_withdraw_singleIlk_requestFunds_partialFill() public {
        // Zero out liquidity so request can be made
        deal(address(token), address(atoken), 0);
        conduit.requestFunds(ILK, address(token), 40 ether);

        // Partially fill withdrawal order
        deal(address(token), address(atoken), 25 ether);

        assertEq(token.balanceOf(buffer),          0);
        assertEq(token.balanceOf(address(atoken)), 25 ether);

        assertEq(atoken.balanceOf(address(conduit)), 80 ether);
        assertEq(atoken.totalSupply(),               80 ether);

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 25 ether);
        conduit.withdraw(ILK, address(token), 25 ether);

        assertEq(token.balanceOf(buffer),          25 ether);
        assertEq(token.balanceOf(address(atoken)), 0);

        assertEq(atoken.balanceOf(address(conduit)), 60 ether);
        assertEq(atoken.totalSupply(),               60 ether);

        assertEq(conduit.shares(address(token), ILK), 60 ether);
        assertEq(conduit.totalShares(address(token)), 60 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 12 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 12 ether);
    }

    function test_withdraw_singleIlk_requestFunds_completeFill() public {
        // Zero out liquidity so request can be made
        deal(address(token), address(atoken), 0);
        conduit.requestFunds(ILK, address(token), 40 ether);

        // Fill full withdrawal order
        deal(address(token), address(atoken), 60 ether);

        assertEq(token.balanceOf(buffer),           0);
        assertEq(token.balanceOf(address(atoken)),  60 ether);

        assertEq(atoken.balanceOf(address(conduit)), 80 ether);
        assertEq(atoken.totalSupply(),               80 ether);

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);  // Converted on request
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 60 ether);
        conduit.withdraw(ILK, address(token), 60 ether);

        assertEq(token.balanceOf(buffer),          60 ether);
        assertEq(token.balanceOf(address(atoken)), 0);

        assertEq(atoken.balanceOf(address(conduit)), 32 ether);
        assertEq(atoken.totalSupply(),               32 ether);

        assertEq(conduit.shares(address(token), ILK), 32 ether);
        assertEq(conduit.totalShares(address(token)), 32 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

    function test_withdraw_singleIlk_maxUint_partialLiquidity() public {
        deal(address(token), address(atoken), 40 ether);

        assertEq(token.balanceOf(buffer),          0);
        assertEq(token.balanceOf(address(atoken)), 40 ether);

        assertEq(atoken.balanceOf(address(conduit)), 80 ether);
        assertEq(atoken.totalSupply(),               80 ether);

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 40 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 40 ether);

        assertEq(token.balanceOf(buffer),          40 ether);
        assertEq(token.balanceOf(address(atoken)), 0);

        assertEq(atoken.balanceOf(address(conduit)), 48 ether);
        assertEq(atoken.totalSupply(),               48 ether);

        assertEq(conduit.shares(address(token), ILK), 48 ether);
        assertEq(conduit.totalShares(address(token)), 48 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

}

contract SparkConduitMaxViewFunctionTests is SparkConduitTestBase {

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

contract SparkConduitRequestFundsTests is SparkConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);
    }

    function test_requestFunds_revert_nonZeroLiquidity() public {
        conduit.deposit(ILK, address(token), 100 ether);

        vm.expectRevert("SparkConduit/non-zero-liquidity");
        conduit.requestFunds(ILK, address(token), 40 ether);
    }

    // TODO: Boundary condition
    function test_requestFunds_revert_amountTooLarge() public {
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(atoken), 0);

        vm.expectRevert("SparkConduit/amount-too-large");
        conduit.requestFunds(ILK, address(token), 150 ether);
    }

    // TODO: Update liquidity index during test
    function test_requestFunds() public {
        token.mint(buffer, 50 ether);  // For second deposit

        conduit.deposit(ILK, address(token),  100 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        deal(address(token), address(atoken), 0);

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);

        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 40 ether);
        conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  32 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  32 ether);

        // Subsequent request should replace instead of be additive
        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 20 ether);
        conduit.requestFunds(ILK, address(token), 20 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  16 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  16 ether);

        vm.expectEmit();
        emit RequestFunds(ILK2, address(token), 30 ether);
        conduit.requestFunds(ILK2, address(token), 30 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  16 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 24 ether);
        assertEq(conduit.totalRequestedShares(address(token)),  40 ether);
    }

}

contract SparkConduitCancelFundRequestTests is SparkConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);
    }

    function test_cancelFundRequest_revert_noActiveRequest() public {
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(atoken), 0);

        vm.expectRevert("SparkConduit/no-active-fund-requests");
        conduit.cancelFundRequest(ILK2, address(token));
    }

    function test_cancelFundRequest() public {
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(atoken), 0);
        conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit CancelFundRequest(ILK, address(token));
        conduit.cancelFundRequest(ILK, address(token));

        assertEq(conduit.getRequestedFunds(ILK, address(token)), 0);
        assertEq(conduit.getTotalRequestedFunds(address(token)), 0);
    }

}

contract SparkConduitGettersTests is SparkConduitTestBase {

    function test_getInterestData() public {
        conduit.setSubsidySpread(50 * RBPS);
        pot.setDSR((350 * RBPS) / SECONDS_PER_YEAR + RAY);
        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(atoken), 0);
        conduit.requestFunds(ILK, address(token), 40 ether);

        IInterestRateDataSource.InterestData memory data = conduit.getInterestData(address(token));

        assertApproxEqRel(data.baseRate,    400 * RBPS, WBPS);
        assertApproxEqRel(data.subsidyRate, 350 * RBPS, WBPS);

        assertEq(data.currentDebt, 100 ether);
        assertEq(data.targetDebt,  60 ether);
    }

}

contract SparkConduitAdminSetterTests is SparkConduitTestBase {

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

    function test_setSubsidySpread() public {
        assertEq(conduit.subsidySpread(), 0);

        vm.expectEmit();
        emit SetSubsidySpread(50 * RBPS);
        conduit.setSubsidySpread(50 * RBPS);

        assertEq(conduit.subsidySpread(), 50 * RBPS);
    }

    function test_setAssetEnabled() public {
        // Starting state
        conduit.setAssetEnabled(address(token), false);

        (bool enabled,,) = conduit.getAssetData(address(token));

        assertEq(enabled,                                false);
        assertEq(conduit.isAssetEnabled(address(token)), false);

        assertEq(token.allowance(address(conduit), address(pool)), 0);

        vm.expectEmit();
        emit SetAssetEnabled(address(token), true);
        conduit.setAssetEnabled(address(token), true);

        (enabled,,) = conduit.getAssetData(address(token));

        assertEq(enabled,                                true);
        assertEq(conduit.isAssetEnabled(address(token)), true);

        assertEq(token.allowance(address(conduit), address(pool)), type(uint256).max);

        vm.expectEmit();
        emit SetAssetEnabled(address(token), false);
        conduit.setAssetEnabled(address(token), false);

        (enabled,,) = conduit.getAssetData(address(token));

        assertEq(enabled,                                false);
        assertEq(conduit.isAssetEnabled(address(token)), false);

        assertEq(token.allowance(address(conduit), address(pool)), 0);
    }

}
