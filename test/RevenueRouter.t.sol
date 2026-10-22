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

    /// Destinations that are their own recipients, at 1x
    function _dests(address a, address b)
        internal
        pure
        returns (IRevenueRouter.Destination[] memory d)
    {
        d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(a, a, 1e18);
        d[1] = IRevenueRouter.Destination(b, b, 1e18);
    }

    function _one(address holder, address recipient, uint96 multiplier)
        internal
        pure
        returns (IRevenueRouter.Destination[] memory d)
    {
        d = new IRevenueRouter.Destination[](1);
        d[0] = IRevenueRouter.Destination(holder, recipient, multiplier);
    }

    function _addDests(IRevenueRouter.Destination[] memory d) internal {
        vm.prank(gov);
        router.addDestinations(d);
    }

    function _removeDest(address holder) internal {
        address[] memory h = new address[](1);
        h[0] = holder;
        vm.prank(gov);
        router.removeDestinations(h);
    }

    function _assertDests(
        IRevenueRouter.Destination[] memory a,
        IRevenueRouter.Destination[] memory b
    ) internal pure {
        assertEq(a.length, b.length);
        for (uint256 i = 0; i < a.length; ++i) {
            assertEq(a[i].holder, b[i].holder);
            assertEq(a[i].recipient, b[i].recipient);
            assertEq(a[i].multiplier, b[i].multiplier);
        }
    }

    // === addDestinations / removeDestinations ===

    function test_addAndRemoveDestinations() public {
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](3);
        d[0] = IRevenueRouter.Destination(alice, carol, 1e18);
        d[1] = IRevenueRouter.Destination(bob, carol, 2e18); // recipients may repeat
        d[2] = IRevenueRouter.Destination(carol, alice, 5e17);
        for (uint256 i = 0; i < d.length; ++i) {
            vm.expectEmit(address(router));
            emit IRevenueRouter.DestinationAdded(d[i].holder, d[i].recipient, d[i].multiplier);
        }
        _addDests(d);
        _assertDests(router.destinations(), d);

        // Removal leaves the other entries intact
        vm.expectEmit(address(router));
        emit IRevenueRouter.DestinationRemoved(alice);
        _removeDest(alice);
        IRevenueRouter.Destination[] memory left = new IRevenueRouter.Destination[](2);
        left[0] = d[2]; // EnumerableSet moves the last entry into the removed slot
        left[1] = d[1];
        _assertDests(router.destinations(), left);

        // A removed holder can be re-added with a new recipient and multiplier
        _addDests(_one(alice, bob, 3e18));
        IRevenueRouter.Destination[] memory all = new IRevenueRouter.Destination[](3);
        (all[0], all[1], all[2]) = (left[0], left[1], _one(alice, bob, 3e18)[0]);
        _assertDests(router.destinations(), all);

        _removeDest(alice);
        _removeDest(bob);
        _removeDest(carol);
        assertEq(router.destinations().length, 0);
    }

    function test_destinations_onlyGovernance() public {
        vm.startPrank(alice);
        vm.expectRevert(IRevenueRouter.NotGovernance.selector);
        router.addDestinations(_dests(alice, bob));
        vm.expectRevert(IRevenueRouter.NotGovernance.selector);
        router.removeDestinations(new address[](0));
        vm.stopPrank();
    }

    function test_addDestinations_tooMany() public {
        uint256 n = router.MAX_DESTINATIONS();
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](n);
        for (uint256 i = 0; i < n; ++i) {
            address a = address(uint160(i + 1));
            d[i] = IRevenueRouter.Destination(a, a, 1e18);
        }
        _addDests(d);

        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.TooManyDestinations.selector, n + 1));
        router.addDestinations(_one(alice, alice, 1e18));

        // Removing one makes room again
        _removeDest(d[0].holder);
        _addDests(_one(alice, alice, 1e18));
        assertEq(router.destinations().length, n);
    }

    function test_addDestinations_invalid() public {
        address[3] memory bad = [address(0), address(router), address(eUSD)];
        for (uint256 i = 0; i < bad.length; ++i) {
            for (uint256 asHolder = 0; asHolder < 2; ++asHolder) {
                vm.prank(gov);
                vm.expectRevert(
                    abi.encodeWithSelector(IRevenueRouter.InvalidDestination.selector, bad[i])
                );
                router.addDestinations(
                    asHolder == 1 ? _one(bad[i], alice, 1e18) : _one(alice, bad[i], 1e18)
                );
            }
        }

        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.InvalidMultiplier.selector, alice));
        router.addDestinations(_one(alice, bob, 0));
    }

    function test_addDestinations_duplicateHolder() public {
        // Within one call
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(alice, bob, 1e18);
        d[1] = IRevenueRouter.Destination(alice, carol, 1e18);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.DuplicateHolder.selector, alice));
        router.addDestinations(d);

        // Against an existing destination
        _addDests(_one(alice, bob, 1e18));
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.DuplicateHolder.selector, alice));
        router.addDestinations(_one(alice, carol, 2e18));
    }

    function test_removeDestinations_unknownHolder() public {
        _addDests(_one(alice, bob, 1e18));
        address[] memory h = new address[](2);
        h[0] = alice;
        h[1] = alice; // already removed by the first entry
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.UnknownHolder.selector, alice));
        router.removeDestinations(h);
    }

    // === poke ===

    function test_poke_proRata() public {
        address dave = makeAddr("dave");
        address erin = makeAddr("erin");
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](3);
        d[0] = IRevenueRouter.Destination(alice, dave, 1e18);
        d[1] = IRevenueRouter.Destination(bob, erin, 1e18);
        d[2] = IRevenueRouter.Destination(carol, dave, 1e18);
        _addDests(d);
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

    /// Weight is balance times multiplier: 100 * 2x = 200 vs 300 * 0.5x = 150
    function test_poke_multipliers() public {
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(alice, alice, 2e18);
        d[1] = IRevenueRouter.Destination(bob, bob, 5e17);
        _addDests(d);
        eUSD.mint(alice, 100e18);
        eUSD.mint(bob, 300e18);
        eUSD.mint(address(router), 700e18);

        router.poke();

        assertEq(eUSD.balanceOf(alice), 100e18 + 400e18);
        assertEq(eUSD.balanceOf(bob), 300e18 + 300e18);
        assertEq(eUSD.balanceOf(address(router)), 0);
    }

    /// Each holder's payout lands on the other holder; weights must use pre-transfer balances
    function test_poke_crossedRecipients() public {
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(alice, bob, 1e18);
        d[1] = IRevenueRouter.Destination(bob, alice, 1e18);
        _addDests(d);
        eUSD.mint(alice, 100e18);
        eUSD.mint(bob, 300e18);
        eUSD.mint(address(router), 1000e18);

        router.poke();

        assertEq(eUSD.balanceOf(alice), 100e18 + 750e18);
        assertEq(eUSD.balanceOf(bob), 300e18 + 250e18);
        assertEq(eUSD.balanceOf(address(router)), 0);
    }

    /// amount * balance overflows uint256 even though the share fits
    function test_poke_largeAmounts() public {
        _addDests(_dests(alice, bob));
        eUSD.mint(alice, 2 ** 128);
        eUSD.mint(address(router), 2 ** 128);

        router.poke();

        assertEq(eUSD.balanceOf(alice), 2 ** 129);
        assertEq(eUSD.balanceOf(address(router)), 0);
    }

    function test_poke_dustStays() public {
        _addDests(_dests(alice, bob));
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
        _addDests(_dests(alice, bob));
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

        _addDests(_dests(alice, bob));
        vm.expectRevert(IRevenueRouter.NoHoldings.selector);
        router.poke(); // destinations hold nothing
    }

    function testFuzz_poke_neverOverspends(
        uint128 a,
        uint128 b,
        uint96 ma,
        uint96 mb,
        uint256 amount
    ) public {
        vm.assume(uint256(a) + b > 0);
        ma = uint96(bound(ma, 1, type(uint96).max));
        mb = uint96(bound(mb, 1, type(uint96).max));
        // Wide enough that amount * weight overflows uint256
        amount = bound(amount, router.MIN_POKE_AMOUNT(), type(uint256).max / 2);
        IRevenueRouter.Destination[] memory d = new IRevenueRouter.Destination[](2);
        d[0] = IRevenueRouter.Destination(alice, alice, ma);
        d[1] = IRevenueRouter.Destination(bob, bob, mb);
        _addDests(d);
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
