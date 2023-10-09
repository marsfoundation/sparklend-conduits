// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import 'dss-test/DssTest.sol';

import { MockERC20 } from 'erc20-helpers/MockERC20.sol';

import { UpgradeableProxy } from 'upgradeable-proxy/UpgradeableProxy.sol';

import { SparkConduit, IInterestRateDataSource } from '../src/SparkConduit.sol';

import { PoolMock, PotMock, RolesMock, RegistryMock } from "./mocks/Mocks.sol";

import { ATokenMock } from "./mocks/ATokenMock.sol";

// TODO: Add multiple buffers when multi ilk is used

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
    ATokenMock   atoken;

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

        token = new MockERC20('Token', 'TKN', 18);

        atoken = pool.atoken();

        atoken.setUnderlying(address(token));

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
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        vm.expectRevert("SparkConduit/no-deposit-with-requested-shares");
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

contract SparkConduitWithdrawTests is SparkConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);

        conduit.deposit(ILK, address(token), 100 ether);
    }

    // TODO: Add path-based testing once simplified logic is merged

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

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

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

        assertEq(conduit.shares(address(token), ILK), 48 ether - 1);  // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 48 ether - 1);  // Conservative rounding

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
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

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

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

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
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

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);

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

        assertEq(conduit.shares(address(token), ILK),  40 ether - 1);  // Conservative rounding
        assertEq(conduit.shares(address(token), ILK2), 40 ether);
        assertEq(conduit.totalShares(address(token)),  80 ether - 1);  // Conservative rounding

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);
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

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);

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

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);
    }

    function test_withdraw_singleIlk_requestFunds_partialFill() public {
        // Zero out liquidity so request can be made
        deal(address(token), address(atoken), 0);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        // Partially fill withdrawal order
        deal(address(token), address(atoken), 25 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 25 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 25 ether);
        conduit.withdraw(ILK, address(token), 25 ether);

        _assertTokenState({
            bufferBalance: 25 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     60 ether,
            scaledTotalSupply: 60 ether,
            balance:           75 ether,
            totalSupply:       75 ether
        });

        assertEq(conduit.shares(address(token), ILK), 60 ether - 1);  // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 60 ether - 1);  // Conservative rounding

        assertEq(conduit.requestedShares(address(token), ILK), 12 ether - 1);  // Conservative rounding
        assertEq(conduit.totalRequestedShares(address(token)), 12 ether - 1);  // Conservative rounding
    }

    function test_withdraw_singleIlk_requestFunds_completeFill() public {
        // Zero out liquidity so request can be made
        deal(address(token), address(atoken), 0);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        // Fill full withdrawal order
        deal(address(token), address(atoken), 60 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 60 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);  // Converted on request
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 60 ether);
        conduit.withdraw(ILK, address(token), 60 ether);

        _assertTokenState({
            bufferBalance: 60 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     32 ether,
            scaledTotalSupply: 32 ether,
            balance:           40 ether,
            totalSupply:       40 ether
        });

        assertEq(conduit.shares(address(token), ILK), 32 ether - 1);  // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 32 ether - 1);  // Conservative rounding

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
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

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

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

        assertEq(conduit.shares(address(token), ILK), 48 ether - 1);  // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 48 ether - 1);  // Conservative rounding

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

    function test_withdraw_multiIlk_increasingIndex() public {
        token.mint(buffer, 50 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        // NOTE: Excluding requestedShares assertions as they are proven not
        //       to change by the above tests.

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
        assertEq(conduit.shares(address(token), ILK2), 8.75 ether - 1); // Conservative rounding
        assertEq(conduit.totalShares(address(token)),  8.75 ether - 1); // Conservative rounding
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

        // NOTE: Excluding requestedShares assertions as they are proven not
        //       to change by the above tests.

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

    function test_withdraw_singleIlk_increasedIndexAfterRequest_completeWithdrawal() public {
        // Zero out liquidity so request can be made
        deal(address(token), address(atoken), 0);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        // Add more than enough liquidity to demonstrate how additional liquidity is handled
        deal(address(token), address(atoken), 200 ether);

        pool.setLiquidityIndex(160_00 * RBPS);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 200 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           128 ether,  // 80 * 1.6 = 128
            totalSupply:       128 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        // 40 asset requested at 1.25 index = 32 shares
        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 128 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 128 ether);

        _assertTokenState({
            bufferBalance: 128 ether,
            atokenBalance: 72 ether
        });

        _assertATokenState({
            scaledBalance:     0,
            scaledTotalSupply: 0,
            balance:           0,
            totalSupply:       0
        });

        assertEq(conduit.shares(address(token), ILK), 0);
        assertEq(conduit.totalShares(address(token)), 0);

        // 40 asset requested at 1.25 index = 32 shares
        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

    function test_withdraw_singleIlk_increasedIndexAfterRequest_requestedSharesRemaining() public {
        // Zero out liquidity so request can be made
        deal(address(token), address(atoken), 0);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        // Add exact amount
        deal(address(token), address(atoken), 40 ether);

        pool.setLiquidityIndex(160_00 * RBPS);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 40 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           128 ether,
            totalSupply:       128 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        // 40 asset requested at 1.25 index = 32 shares
        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 40 ether);
        assertEq(conduit.withdraw(ILK, address(token), type(uint256).max), 40 ether);

        _assertTokenState({
            bufferBalance: 40 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     55 ether,  // 80 - 40/1.6 = 55
            scaledTotalSupply: 55 ether,
            balance:           88 ether,  // 55 * 1.6 = 88
            totalSupply:       88 ether
        });

        assertEq(conduit.shares(address(token), ILK), 55 ether - 1);  // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 55 ether - 1);  // Conservative rounding

        // 40 ether at 1.6 index = 25 shares, 32 requested - 25 burned = 7 remaining
        assertEq(conduit.requestedShares(address(token), ILK), 7 ether - 1);  // Conservative rounding
        assertEq(conduit.totalRequestedShares(address(token)), 7 ether - 1);  // Conservative rounding
    }

}

contract SparkConduitWithdrawAndRequestFundsTests is SparkConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);

        conduit.deposit(ILK, address(token), 100 ether);
    }

    // TODO: Add path-based testing once simplified logic is merged

    function test_withdrawAndRequestFunds_noLiquidity() public {
        deal(address(token), address(atoken), 0);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 40 ether);
        ( uint256 amountWithdrawn, uint256 requestedFunds )
            = conduit.withdrawAndRequestFunds(ILK, address(token), 40 ether);

        assertEq(amountWithdrawn, 0);
        assertEq(requestedFunds,  40 ether);

        // No changes except requestedShares

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);
    }

    function test_withdrawAndRequestFunds_partialLiquidity() public {
        deal(address(token), address(atoken), 30 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 30 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 30 ether);
        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 10 ether);
        ( uint256 amountWithdrawn, uint256 requestedFunds )
            = conduit.withdrawAndRequestFunds(ILK, address(token), 40 ether);

        assertEq(amountWithdrawn, 30 ether);
        assertEq(requestedFunds,  10 ether);

        _assertTokenState({
            bufferBalance: 30 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     56 ether,  // 80 - 30 / 1.25
            scaledTotalSupply: 56 ether,
            balance:           70 ether,
            totalSupply:       70 ether
        });

        assertEq(conduit.shares(address(token), ILK), 56 ether - 1);  // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 56 ether - 1);  // Conservative rounding

        assertEq(conduit.requestedShares(address(token), ILK), 8 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 8 ether);
    }

    function test_withdrawAndRequestFunds_partialLiquidity_fullRequest() public {
        deal(address(token), address(atoken), 30 ether);

        _assertTokenState({
            bufferBalance: 0,
            atokenBalance: 30 ether
        });

        _assertATokenState({
            scaledBalance:     80 ether,
            scaledTotalSupply: 80 ether,
            balance:           100 ether,
            totalSupply:       100 ether
        });

        assertEq(conduit.shares(address(token), ILK), 80 ether);
        assertEq(conduit.totalShares(address(token)), 80 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 30 ether);
        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 70 ether - 2);  // Rounded down assets from rounded shares
        ( uint256 amountWithdrawn, uint256 requestedFunds )
            = conduit.withdrawAndRequestFunds(ILK, address(token), 100 ether);

        assertEq(amountWithdrawn, 30 ether);
        assertEq(requestedFunds,  70 ether);

        _assertTokenState({
            bufferBalance: 30 ether,
            atokenBalance: 0
        });

        _assertATokenState({
            scaledBalance:     56 ether,
            scaledTotalSupply: 56 ether,
            balance:           70 ether,
            totalSupply:       70 ether
        });

        assertEq(conduit.shares(address(token), ILK), 56 ether - 1);  // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 56 ether - 1);  // Conservative rounding

        assertEq(conduit.requestedShares(address(token), ILK), 56 ether - 1);  // Conservative rounding
        assertEq(conduit.totalRequestedShares(address(token)), 56 ether - 1);  // Conservative rounding
    }

    function test_withdrawAndRequestFunds_fullLiquidity_partialRequest() public {
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

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 30 ether);
        ( uint256 amountWithdrawn, uint256 requestedFunds )
            = conduit.withdrawAndRequestFunds(ILK, address(token), 30 ether);

        assertEq(amountWithdrawn, 30 ether);
        assertEq(requestedFunds,  0);

        _assertTokenState({
            bufferBalance: 30 ether,
            atokenBalance: 70 ether
        });

        _assertATokenState({
            scaledBalance:     56 ether,
            scaledTotalSupply: 56 ether,
            balance:           70 ether,
            totalSupply:       70 ether
        });

        assertEq(conduit.shares(address(token), ILK), 56 ether - 1); // Conservative rounding
        assertEq(conduit.totalShares(address(token)), 56 ether - 1); // Conservative rounding

        // No change in requestedShares
        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

    function test_withdrawAndRequestFunds_fullLiquidity_fullRequest() public {
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

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);

        vm.expectEmit();
        emit Withdraw(ILK, address(token), buffer, 100 ether);
        ( uint256 amountWithdrawn, uint256 requestedFunds )
            = conduit.withdrawAndRequestFunds(ILK, address(token), 100 ether);

        assertEq(amountWithdrawn, 100 ether);
        assertEq(requestedFunds,  0);

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

        // No change in requestedShares
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

    // TODO: Update liquidity index during test
    function test_requestFund_multiIlk() public {
        token.mint(buffer, 50 ether);  // For second deposit

        conduit.deposit(ILK, address(token),  100 ether);
        conduit.deposit(ILK2, address(token), 50 ether);

        deal(address(token), address(atoken), 0);

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);

        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 40 ether);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  32 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  32 ether);

        // Subsequent request should replace instead of be additive
        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 20 ether);
        requestedFunds = conduit.requestFunds(ILK, address(token), 20 ether);

        assertEq(requestedFunds, 20 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  16 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  16 ether);

        vm.expectEmit();
        emit RequestFunds(ILK2, address(token), 30 ether);
        requestedFunds = conduit.requestFunds(ILK2, address(token), 30 ether);

        assertEq(requestedFunds, 30 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  16 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 24 ether);
        assertEq(conduit.totalRequestedShares(address(token)),  40 ether);
    }

    function test_requestFunds_singleIlk_increaseIndex() public {
        conduit.deposit(ILK, address(token),  100 ether);

        deal(address(token), address(atoken), 0);

        assertEq(conduit.requestedShares(address(token), ILK),  0);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  0);

        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 40 ether);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  32 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  32 ether);

        pool.setLiquidityIndex(160_00 * RBPS);  // 100 / 160% = 62.5 shares for 100 asset deposit

        // "Refreshing" the request with the same amount
        // will reduce the amount of shares that will be requested
        vm.expectEmit();
        emit RequestFunds(ILK, address(token), 40 ether);
        requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        assertEq(conduit.requestedShares(address(token), ILK),  25 ether);
        assertEq(conduit.requestedShares(address(token), ILK2), 0);
        assertEq(conduit.totalRequestedShares(address(token)),  25 ether);
    }

}

contract SparkConduitCancelFundRequestTests is SparkConduitTestBase {

    function setUp() public override {
        super.setUp();
        token.mint(buffer, 100 ether);
    }

    function test_cancelFundRequest_revert_noActiveRequest() public {
        conduit.deposit(ILK, address(token),  100 ether);
        deal(address(token), address(atoken), 0);

        vm.expectRevert("SparkConduit/no-active-fund-requests");
        conduit.cancelFundRequest(ILK2, address(token));
    }

    function test_cancelFundRequest() public {
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(atoken), 0);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        assertEq(conduit.requestedShares(address(token), ILK), 32 ether);
        assertEq(conduit.totalRequestedShares(address(token)), 32 ether);

        vm.expectEmit();
        emit CancelFundRequest(ILK, address(token));
        conduit.cancelFundRequest(ILK, address(token));

        assertEq(conduit.requestedShares(address(token), ILK), 0);
        assertEq(conduit.totalRequestedShares(address(token)), 0);
    }

}

contract SparkConduitGetInterestDataTests is SparkConduitTestBase {

    uint256 MAX_RATE   = 500_00 * RBPS;
    uint256 MAX_AMOUNT = 1e45;

    function test_getInterestData() public {
        conduit.setSubsidySpread(50 * RBPS);
        pot.setDSR((350 * RBPS) / SECONDS_PER_YEAR + RAY);
        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);
        deal(address(token), address(atoken), 0);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFunds, 40 ether);

        IInterestRateDataSource.InterestData memory data = conduit.getInterestData(address(token));

        // TODO: Investigate reducing diff
        assertApproxEqAbs(data.baseRate,    400 * RBPS, 1e9);
        assertApproxEqAbs(data.subsidyRate, 350 * RBPS, 1e9);

        assertEq(data.currentDebt, 100 ether);
        assertEq(data.targetDebt,  60 ether);
    }

    function testFuzz_getInterestData(
        uint256 subsidySpread,
        uint256 dsrAnnualRate,
        uint256 depositAmount,
        uint256 requestAmount
    )
        external
    {
        subsidySpread = _bound(subsidySpread, 0, 500_00 * RBPS);
        dsrAnnualRate = _bound(dsrAnnualRate, 0, 500_00 * RBPS);
        depositAmount = _bound(depositAmount, 0, 1e32);
        requestAmount = _bound(requestAmount, 0, depositAmount);

        conduit.setSubsidySpread(subsidySpread);
        pot.setDSR(dsrAnnualRate / SECONDS_PER_YEAR + RAY);

        token.mint(buffer, depositAmount);
        conduit.deposit(ILK, address(token), depositAmount);
        deal(address(token), address(atoken), 0);
        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), requestAmount);

        assertEq(requestedFunds, requestAmount);

        IInterestRateDataSource.InterestData memory data = conduit.getInterestData(address(token));

        // TODO: Investigate reducing diff
        assertApproxEqAbs(data.baseRate,    dsrAnnualRate + subsidySpread, 1e9);
        assertApproxEqAbs(data.subsidyRate, dsrAnnualRate,                 1e9);

        assertApproxEqAbs(data.currentDebt, depositAmount,                 1);
        assertApproxEqAbs(data.targetDebt,  depositAmount - requestAmount, 1);
    }

}

contract SparkConduitGetPositionTests is SparkConduitTestBase {

    function test_getPosition() external {
        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        deal(address(token), address(atoken), 0);

        uint256 requestedFundsFromFunction = conduit.requestFunds(ILK, address(token), 40 ether);

        assertEq(requestedFundsFromFunction, 40 ether);

        ( uint256 deposits, uint256 requestedFunds ) = conduit.getPosition(address(token), ILK);

        assertEq(deposits,       100 ether);
        assertEq(requestedFunds, 40 ether);

        pool.setLiquidityIndex(160_00 * RBPS);

        ( deposits, requestedFunds ) = conduit.getPosition(address(token), ILK);

        assertEq(deposits,       128 ether);   // 100 @ 1.25 = 80, 80 @ 1.6 = 128
        assertEq(requestedFunds, 51.2 ether);  // 40 @ 1.25  = 32, 32 @ 1.6 = 51.2
    }

    function testFuzz_getPosition(
        uint256 index1,
        uint256 index2,
        uint256 depositAmount,
        uint256 requestAmount
    )
        external
    {
        index1        = bound(index1,        1 * RBPS, 500_00 * RBPS);
        index2        = bound(index2,        1 * RBPS, 500_00 * RBPS);
        depositAmount = bound(depositAmount, 0,        1e32);
        requestAmount = bound(requestAmount, 0,        depositAmount);

        pool.setLiquidityIndex(index1);

        token.mint(buffer, depositAmount);
        conduit.deposit(ILK, address(token), depositAmount);

        deal(address(token), address(atoken), 0);

        uint256 requestedFundsFromFunction
            = conduit.requestFunds(ILK, address(token), requestAmount);

        assertEq(requestedFundsFromFunction, requestAmount);

        ( uint256 deposits, uint256 requestedFunds ) = conduit.getPosition(address(token), ILK);

        assertApproxEqAbs(deposits,       depositAmount, 10);
        assertApproxEqAbs(requestedFunds, requestAmount, 10);

        pool.setLiquidityIndex(index2);

        ( deposits, requestedFunds ) = conduit.getPosition(address(token), ILK);

        uint256 expectedDeposit = depositAmount * 1e27 / index1 * index2 / 1e27;
        uint256 expectedFunds   = requestAmount * 1e27 / index1 * index2 / 1e27;

        assertApproxEqAbs(deposits,       expectedDeposit, 10);
        assertApproxEqAbs(requestedFunds, expectedFunds,   10);
    }

}

contract SparkConduitGetTotalDepositsTests is SparkConduitTestBase {

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

contract SparkConduitGetDepositsTests is SparkConduitTestBase {

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

contract SparkConduitGetTotalRequestedFundsTests is SparkConduitTestBase {

    function test_getTotalRequestedFunds() external {
        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        deal(address(token), address(atoken), 0);

        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 100 ether);

        assertEq(requestedFunds, 100 ether);

        assertEq(conduit.getTotalRequestedFunds(address(token)), 100 ether);

        pool.setLiquidityIndex(160_00 * RBPS);

        // 100 @ 1.25 = 80, 80 @ 1.6 = 128
        assertEq(conduit.getTotalRequestedFunds(address(token)), 128 ether);
    }

    function testFuzz_getTotalRequestedFunds(
        uint256 index1,
        uint256 index2,
        uint256 requestAmount
    )
        external
    {
        index1        = bound(index1,        1 * RBPS, 500_00 * RBPS);
        index2        = bound(index2,        1 * RBPS, 500_00 * RBPS);
        requestAmount = bound(requestAmount, 0,        1e32);

        pool.setLiquidityIndex(index1);

        token.mint(buffer, requestAmount);
        conduit.deposit(ILK, address(token), requestAmount);

        deal(address(token), address(atoken), 0);

        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), requestAmount);

        assertEq(requestedFunds, requestAmount);

        assertApproxEqAbs(conduit.getTotalRequestedFunds(address(token)), requestAmount, 10);

        pool.setLiquidityIndex(index2);

        uint256 expectedRequest = requestAmount * 1e27 / index1 * index2 / 1e27;

        assertApproxEqAbs(conduit.getTotalRequestedFunds(address(token)), expectedRequest, 10);
    }

}

contract SparkConduitGetRequestedFundsTests is SparkConduitTestBase {

    function test_getRequestedFunds() external {
        token.mint(buffer, 100 ether);
        conduit.deposit(ILK, address(token), 100 ether);

        deal(address(token), address(atoken), 0);

        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), 100 ether);

        assertEq(requestedFunds, 100 ether);

        assertEq(conduit.getRequestedFunds(address(token), ILK), 100 ether);

        pool.setLiquidityIndex(160_00 * RBPS);

        // 100 @ 1.25 = 80, 80 @ 1.6 = 128
        assertEq(conduit.getRequestedFunds(address(token), ILK), 128 ether);
    }

    function testFuzz_getRequestedFunds(
        uint256 index1,
        uint256 index2,
        uint256 requestAmount
    )
        external
    {
        index1        = bound(index1,        1 * RBPS, 500_00 * RBPS);
        index2        = bound(index2,        1 * RBPS, 500_00 * RBPS);
        requestAmount = bound(requestAmount, 0,        1e32);

        pool.setLiquidityIndex(index1);

        token.mint(buffer, requestAmount);
        conduit.deposit(ILK, address(token), requestAmount);

        deal(address(token), address(atoken), 0);

        uint256 requestedFunds = conduit.requestFunds(ILK, address(token), requestAmount);

        assertEq(requestedFunds, requestAmount);

        assertApproxEqAbs(conduit.getRequestedFunds(address(token), ILK), requestAmount, 10);

        pool.setLiquidityIndex(index2);

        uint256 expectedRequest = requestAmount * 1e27 / index1 * index2 / 1e27;

        assertApproxEqAbs(conduit.getRequestedFunds(address(token), ILK), expectedRequest, 10);
    }

}

contract SparkConduitGetAvailableLiquidityTests is SparkConduitTestBase {

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

        assertEq(enabled,                         false);
        assertEq(conduit.enabled(address(token)), false);

        assertEq(token.allowance(address(conduit), address(pool)), 0);

        vm.expectEmit();
        emit SetAssetEnabled(address(token), true);
        conduit.setAssetEnabled(address(token), true);

        (enabled,,) = conduit.getAssetData(address(token));

        assertEq(enabled,                         true);
        assertEq(conduit.enabled(address(token)), true);

        assertEq(token.allowance(address(conduit), address(pool)), type(uint256).max);

        vm.expectEmit();
        emit SetAssetEnabled(address(token), false);
        conduit.setAssetEnabled(address(token), false);

        (enabled,,) = conduit.getAssetData(address(token));

        assertEq(enabled,                         false);
        assertEq(conduit.enabled(address(token)), false);

        assertEq(token.allowance(address(conduit), address(pool)), 0);
    }

}
