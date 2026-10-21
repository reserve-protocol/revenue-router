// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {IRToken, IRevenueRouter} from "../../src/interfaces/IRevenueRouter.sol";

struct RevenueShare {
    uint16 rTokenDist;
    uint16 rsrDist;
}

interface IDistributor {
    function setDistributions(address[] calldata dests, RevenueShare[] calldata shares) external;

    function distribute(address erc20, uint256 amount) external;
}

interface IMainFull {
    function distributor() external view returns (IDistributor);

    function rTokenTrader() external view returns (address);

    function grantRole(bytes32 role, address account) external;

    function freezeForever() external;

    function pauseTrading() external;

    function pauseIssuance() external;

    function frozen() external view returns (bool);

    function tradingPaused() external view returns (bool);

    function issuancePaused() external view returns (bool);
}

interface IApprove {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// Fork tests against live eUSD. Skipped unless MAINNET_RPC_URL is set.
contract RevenueRouterForkTest is Test {
    uint256 constant FORK_BLOCK = 26_243_013;
    IRToken constant EUSD = IRToken(0xA0d69E286B938e21CBf7E51D71F6A4c8918f482F);
    address constant TIMELOCK = 0xd979Cf15F7275a3DF838513aB911587d23b6D29e;
    address constant FURNACE = address(1);
    address constant ST_RSR = address(2);

    /// Half of the EIP-7825 per-transaction gas cap (2^24), leaving headroom for repricings
    uint256 constant GAS_BUDGET = 1 << 23;

    IMainFull main;
    RevenueRouter router;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, FORK_BLOCK);

        main = IMainFull(address(EUSD.main()));
        router = new RevenueRouter(EUSD);
    }

    function _fundedDests(uint256 n) internal returns (address[] memory d) {
        d = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            d[i] = address(uint160(uint256(keccak256(abi.encode("dest", i)))));
            deal(address(EUSD), d[i], (i + 1) * 1e18);
        }
    }

    function test_timelockIsOwner() public {
        address[] memory d = _fundedDests(2);
        vm.prank(TIMELOCK);
        router.setDestinations(d);
        assertEq(router.destinations(), d);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(IRevenueRouter.NotGovernance.selector);
        router.setDestinations(d);
    }

    /// Distributor -> router -> destinations, with the planned 80% eUSD / 20% RSR split
    function test_distributorToDestinations() public {
        address[] memory dests = new address[](3);
        RevenueShare[] memory shares = new RevenueShare[](3);
        (dests[0], shares[0]) = (FURNACE, RevenueShare(0, 0));
        (dests[1], shares[1]) = (ST_RSR, RevenueShare(0, 2000));
        (dests[2], shares[2]) = (address(router), RevenueShare(8000, 0));
        IDistributor distributor = main.distributor();
        vm.prank(TIMELOCK);
        distributor.setDistributions(dests, shares);

        address[] memory d = _fundedDests(2); // holdings 1 : 2
        vm.prank(TIMELOCK);
        router.setDestinations(d);

        address trader = main.rTokenTrader();
        uint256 amount = 3000e18;
        deal(address(EUSD), trader, amount);
        vm.startPrank(trader);
        IApprove(address(EUSD)).approve(address(distributor), amount);
        distributor.distribute(address(EUSD), amount);
        vm.stopPrank();

        uint256 received = EUSD.balanceOf(address(router));
        assertGt(received, 0);
        assertLe(received, amount);

        router.poke();
        assertEq(EUSD.balanceOf(d[0]), 1e18 + (received * 1e18) / 3e18);
        assertEq(EUSD.balanceOf(d[1]), 2e18 + (received * 2e18) / 3e18);
        assertLt(EUSD.balanceOf(address(router)), 2);
    }

    /// poke() reverts while trading is paused; sweep() still works
    function test_tradingPaused() public {
        address[] memory d = _fundedDests(2);
        vm.startPrank(TIMELOCK);
        router.setDestinations(d);
        main.grantRole(bytes32("PAUSER"), TIMELOCK);
        main.pauseTrading();
        vm.stopPrank();

        deal(address(EUSD), address(router), 1e18);
        vm.expectRevert(IRevenueRouter.TradingPausedOrFrozen.selector);
        router.poke();

        vm.prank(TIMELOCK);
        router.sweep(IERC20(address(EUSD)), TIMELOCK, 1e18);
        assertEq(EUSD.balanceOf(address(router)), 0);
    }

    /// poke() ignores issuance-paused and reverts while frozen; sweep() still works
    function test_issuancePausedAndFrozen() public {
        address[] memory d = _fundedDests(2);
        vm.startPrank(TIMELOCK);
        router.setDestinations(d);
        main.grantRole(bytes32("PAUSER"), TIMELOCK);
        main.pauseIssuance();
        vm.stopPrank();

        deal(address(EUSD), address(router), 1e18);
        router.poke();
        assertLt(EUSD.balanceOf(address(router)), 2);

        vm.prank(TIMELOCK);
        main.freezeForever();
        assertTrue(main.frozen() && !main.tradingPaused());

        deal(address(EUSD), address(router), 1e18);
        vm.expectRevert(IRevenueRouter.TradingPausedOrFrozen.selector);
        router.poke();

        vm.prank(TIMELOCK);
        router.sweep(IERC20(address(EUSD)), TIMELOCK, 1e18);
        assertEq(EUSD.balanceOf(address(router)), 0);
    }

    /// Worst-case gas at MAX_DESTINATIONS: every destination holds eUSD and all state is cold
    function test_gas_maxDestinations() public {
        uint256 n = router.MAX_DESTINATIONS();
        address[] memory d = _fundedDests(n);
        deal(address(EUSD), address(router), 1_000_000e18);

        _cool(d);
        vm.prank(TIMELOCK);
        uint256 g = gasleft();
        router.setDestinations(d);
        uint256 setGas = g - gasleft();

        _cool(d);
        g = gasleft();
        router.poke();
        uint256 pokeGas = g - gasleft();

        console.log("destinations", n);
        console.log("setDestinations gas", setGas);
        console.log("poke gas", pokeGas);
        console.log("poke gas per destination", pokeGas / n);
        assertLt(setGas, GAS_BUDGET);
        assertLt(pokeGas, GAS_BUDGET);
    }

    function _cool(address[] memory d) internal {
        vm.cool(address(router));
        vm.cool(address(EUSD));
        vm.cool(address(main));
        // eUSD and Main are EIP-1967 proxies; cool their implementations too
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        vm.cool(address(uint160(uint256(vm.load(address(EUSD), implSlot)))));
        vm.cool(address(uint160(uint256(vm.load(address(main), implSlot)))));
        for (uint256 i = 0; i < d.length; ++i) {
            vm.cool(d[i]);
        }
    }
}
