// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {IRToken, IRevenueRouter} from "../src/interfaces/IRevenueRouter.sol";
import {MockMain, MockRToken, MockNoReturnToken, MockFalseToken} from "./mocks/Mocks.sol";

contract RevenueRouterTest is Test {
    MockMain main;
    MockRToken eUSD;
    RevenueRouter router;

    address gov = makeAddr("gov");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        main = new MockMain();
        main.grantRole(bytes32("OWNER"), gov);
        eUSD = new MockRToken(main);
        router = new RevenueRouter(IRToken(address(eUSD)));
    }

    /// Destinations that are their own recipients
    function _dests(address a, address b)
        internal
        pure
        returns (IRevenueRouter.Destination[] memory d)
    {
        d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(a, a);
        d[1] = IRevenueRouter.Destination(b, b);
    }

    function _setDests(IRevenueRouter.Destination[] memory d) internal {
        vm.prank(gov);
        router.setDestinations(d);
    }

    function _assertDests(
        IRevenueRouter.Destination[] memory a,
        IRevenueRouter.Destination[] memory b
    ) internal pure {
        assertEq(a.length, b.length);
        for (uint256 i = 0; i < a.length; ++i) {
            assertEq(a[i].holder, b[i].holder);
            assertEq(a[i].recipient, b[i].recipient);
        }
    }

    // === setDestinations ===

    function test_setDestinations() public {
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(alice, carol);
        d[1] = IRevenueRouter.Destination(bob, carol); // recipients may repeat
        vm.expectEmit(address(router));
        emit IRevenueRouter.DestinationsSet(d);
        _setDests(d);
        _assertDests(router.destinations(), d);

        // Replacing with a shorter list drops the old entries
        d = new IRevenueRouter.Destination[](1);
        d[0] = IRevenueRouter.Destination(bob, alice);
        _setDests(d);
        _assertDests(router.destinations(), d);

        _setDests(new IRevenueRouter.Destination[](0));
        assertEq(router.destinations().length, 0);
    }

    function test_setDestinations_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(IRevenueRouter.NotGovernance.selector);
        router.setDestinations(_dests(alice, bob));
    }

    function test_setDestinations_tooMany() public {
        uint256 n = router.MAX_DESTINATIONS() + 1;
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](n);
        for (uint256 i = 0; i < n; ++i) {
            address a = address(uint160(i + 1));
            d[i] = IRevenueRouter.Destination(a, a);
        }
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.TooManyDestinations.selector, n));
        router.setDestinations(d);
    }

    function test_setDestinations_invalid() public {
        address[3] memory bad = [address(0), address(router), address(eUSD)];
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](1);
        for (uint256 i = 0; i < bad.length; ++i) {
            for (uint256 asHolder = 0; asHolder < 2; ++asHolder) {
                d[0] = asHolder == 1
                    ? IRevenueRouter.Destination(bad[i], alice)
                    : IRevenueRouter.Destination(alice, bad[i]);
                vm.prank(gov);
                vm.expectRevert(
                    abi.encodeWithSelector(IRevenueRouter.InvalidDestination.selector, bad[i])
                );
                router.setDestinations(d);
            }
        }
    }

    function test_setDestinations_duplicateHolder() public {
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(alice, bob);
        d[1] = IRevenueRouter.Destination(alice, carol);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.DuplicateHolder.selector, alice));
        router.setDestinations(d);
    }

    // === poke ===

    function test_poke_proRata() public {
        address dave = makeAddr("dave");
        address erin = makeAddr("erin");
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](3);
        d[0] = IRevenueRouter.Destination(alice, dave);
        d[1] = IRevenueRouter.Destination(bob, erin);
        d[2] = IRevenueRouter.Destination(carol, dave);
        _setDests(d);
        eUSD.mint(alice, 100e18);
        eUSD.mint(bob, 300e18);
        // carol holds nothing, so earns nothing
        eUSD.mint(address(router), 1000e18);

        vm.expectEmit(address(router));
        emit IRevenueRouter.Distributed(alice, dave, 250e18);
        vm.expectEmit(address(router));
        emit IRevenueRouter.Distributed(bob, erin, 750e18);
        vm.expectEmit(address(router));
        emit IRevenueRouter.Poked(address(this), 1000e18);
        router.poke();

        // Holders keep their balances; recipients get paid
        assertEq(eUSD.balanceOf(alice), 100e18);
        assertEq(eUSD.balanceOf(bob), 300e18);
        assertEq(eUSD.balanceOf(dave), 250e18);
        assertEq(eUSD.balanceOf(erin), 750e18);
        assertEq(eUSD.balanceOf(address(router)), 0);
    }

    function test_poke_dustStays() public {
        _setDests(_dests(alice, bob));
        eUSD.mint(alice, 1);
        eUSD.mint(bob, 2);
        uint256 amount = router.MIN_POKE_AMOUNT() + 1; // not divisible by 3
        eUSD.mint(address(router), amount);

        router.poke();

        assertEq(eUSD.balanceOf(alice), 1 + amount / 3);
        assertEq(eUSD.balanceOf(bob), 2 + (amount * 2) / 3);
        assertEq(eUSD.balanceOf(address(router)), amount - amount / 3 - (amount * 2) / 3);
    }

    function test_poke_belowMinimum() public {
        _setDests(_dests(alice, bob));
        eUSD.mint(alice, 1e18);
        uint256 amount = router.MIN_POKE_AMOUNT() - 1;
        eUSD.mint(address(router), amount);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.BelowMinimum.selector, amount));
        router.poke();
    }

    function test_poke_noHoldings() public {
        eUSD.mint(address(router), router.MIN_POKE_AMOUNT());
        vm.expectRevert(IRevenueRouter.NoHoldings.selector);
        router.poke(); // no destinations

        _setDests(_dests(alice, bob));
        vm.expectRevert(IRevenueRouter.NoHoldings.selector);
        router.poke(); // destinations hold nothing
    }

    function test_poke_tradingPausedOrFrozen() public {
        _setDests(_dests(alice, bob));
        eUSD.mint(alice, 1e18);
        eUSD.mint(address(router), 1e18);
        main.setTradingPausedOrFrozen(true);
        vm.expectRevert(IRevenueRouter.TradingPausedOrFrozen.selector);
        router.poke();

        main.setTradingPausedOrFrozen(false);
        router.poke();
        assertEq(eUSD.balanceOf(alice), 2e18);
    }

    function testFuzz_poke_neverOverspends(uint96 a, uint96 b, uint128 amount) public {
        vm.assume(uint256(a) + b > 0);
        amount = uint128(bound(amount, router.MIN_POKE_AMOUNT(), type(uint128).max));
        _setDests(_dests(alice, bob));
        eUSD.mint(alice, a);
        eUSD.mint(bob, b);
        eUSD.mint(address(router), amount);

        router.poke();

        uint256 left = eUSD.balanceOf(address(router));
        assertLt(left, 2); // < 1 wei of dust per destination
        assertEq(eUSD.balanceOf(alice) + eUSD.balanceOf(bob) + left, uint256(a) + b + amount);
    }

    // === sweep ===

    function test_sweep() public {
        eUSD.mint(address(router), 5e18);
        vm.expectEmit(address(router));
        emit IRevenueRouter.Swept(address(eUSD), carol, 5e18);
        vm.prank(gov);
        router.sweep(IERC20(address(eUSD)), carol, 5e18);
        assertEq(eUSD.balanceOf(carol), 5e18);
    }

    function test_sweep_noReturnToken() public {
        MockNoReturnToken token = new MockNoReturnToken();
        token.mint(address(router), 7);
        vm.prank(gov);
        router.sweep(IERC20(address(token)), carol, 7);
        assertEq(token.balanceOf(carol), 7);
    }

    function test_sweep_failures() public {
        address falseToken = address(new MockFalseToken());
        vm.startPrank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, falseToken)
        );
        router.sweep(IERC20(falseToken), carol, 1);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, eoa));
        router.sweep(IERC20(eoa), carol, 1);
        vm.expectRevert(IRevenueRouter.ZeroAddress.selector);
        router.sweep(IERC20(address(eUSD)), address(0), 1);
        vm.stopPrank();
    }

    function test_sweep_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(IRevenueRouter.NotGovernance.selector);
        router.sweep(IERC20(address(eUSD)), alice, 1);
    }

    function test_constructor_zeroAddress() public {
        vm.expectRevert(IRevenueRouter.ZeroAddress.selector);
        new RevenueRouter(IRToken(address(0)));
    }
}
