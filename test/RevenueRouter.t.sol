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

    function _dests(address a, address b) internal pure returns (address[] memory d) {
        d = new address[](2);
        d[0] = a;
        d[1] = b;
    }

    function _setDests(address[] memory d) internal {
        vm.prank(gov);
        router.setDestinations(d);
    }

    // === setDestinations ===

    function test_setDestinations() public {
        address[] memory d = _dests(alice, bob);
        vm.expectEmit(address(router));
        emit IRevenueRouter.DestinationsSet(d);
        _setDests(d);
        assertEq(router.destinations(), d);

        _setDests(new address[](0));
        assertEq(router.destinations().length, 0);
    }

    function test_setDestinations_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(IRevenueRouter.NotGovernance.selector);
        router.setDestinations(_dests(alice, bob));
    }

    function test_setDestinations_tooMany() public {
        uint256 n = router.MAX_DESTINATIONS() + 1;
        address[] memory d = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            d[i] = address(uint160(i + 1));
        }
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.TooManyDestinations.selector, n));
        router.setDestinations(d);
    }

    function test_setDestinations_invalid() public {
        address[3] memory bad = [address(0), address(router), address(eUSD)];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(gov);
            vm.expectRevert(
                abi.encodeWithSelector(IRevenueRouter.InvalidDestination.selector, bad[i])
            );
            router.setDestinations(_dests(alice, bad[i]));
        }
    }

    function test_setDestinations_duplicate() public {
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IRevenueRouter.DuplicateDestination.selector, alice));
        router.setDestinations(_dests(alice, alice));
    }

    // === poke ===

    function test_poke_proRata() public {
        address[] memory d = new address[](3);
        (d[0], d[1], d[2]) = (alice, bob, carol);
        _setDests(d);
        eUSD.mint(alice, 100e18);
        eUSD.mint(bob, 300e18);
        // carol holds nothing and receives nothing
        eUSD.mint(address(router), 1000e18);

        vm.expectEmit(address(router));
        emit IRevenueRouter.Poked(address(this), 1000e18);
        router.poke();

        assertEq(eUSD.balanceOf(alice), 100e18 + 250e18);
        assertEq(eUSD.balanceOf(bob), 300e18 + 750e18);
        assertEq(eUSD.balanceOf(carol), 0);
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
