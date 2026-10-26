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
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        main = IMainFull(address(EUSD.main()));
        router = new RevenueRouter(EUSD);
    }

    /// Holder i holds (i + 1) eUSD; every recipient is a fresh address holding none
    function _fundedDests(uint256 n) internal returns (IRevenueRouter.Destination[] memory d) {
        d = new IRevenueRouter.Destination[](n);
        for (uint256 i = 0; i < n; ++i) {
            d[i].holder = address(uint160(uint256(keccak256(abi.encode("holder", i)))));
            d[i].recipient = address(uint160(uint256(keccak256(abi.encode("recipient", i)))));
            d[i].multiplier = 1e18;
            deal(address(EUSD), d[i].holder, (i + 1) * 1e18);
        }
    }

    function test_timelockIsOwner() public {
        IRevenueRouter.Destination[] memory d = _fundedDests(2);
        vm.prank(TIMELOCK);
        router.addDestinations(d);
        assertEq(router.destinations().length, 2);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(IRevenueRouter.RevenueRouter__NotGovernance.selector);
        router.addDestinations(d);
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

        IRevenueRouter.Destination[] memory d = _fundedDests(2); // holdings 1 : 2
        vm.prank(TIMELOCK);
        router.addDestinations(d);

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
        assertEq(EUSD.balanceOf(d[0].recipient), (received * 1e18) / 3e18);
        assertEq(EUSD.balanceOf(d[1].recipient), (received * 2e18) / 3e18);
        assertLt(EUSD.balanceOf(address(router)), 2);
    }

    /// poke() and sweep() ignore eUSD's paused and frozen states
    function test_ignoresPausedAndFrozen() public {
        IRevenueRouter.Destination[] memory d = _fundedDests(2);
        vm.startPrank(TIMELOCK);
        router.addDestinations(d);
        main.grantRole(bytes32("PAUSER"), TIMELOCK);
        main.pauseTrading();
        main.pauseIssuance();
        main.freezeForever();
        vm.stopPrank();
        assertTrue(main.tradingPaused() && main.issuancePaused() && main.frozen());

        deal(address(EUSD), address(router), 3e18);
        router.poke();
        assertEq(EUSD.balanceOf(d[0].recipient), 1e18);
        assertEq(EUSD.balanceOf(d[1].recipient), 2e18);

        deal(address(EUSD), address(router), 1e18);
        vm.prank(TIMELOCK);
        router.sweep(IERC20(address(EUSD)), TIMELOCK, 1e18);
        assertEq(EUSD.balanceOf(address(router)), 0);
    }

    /// Worst-case gas at MAX_DESTINATIONS: every holder holds eUSD, every recipient holds none,
    /// and all state is cold
    function test_gas_maxDestinations() public {
        uint256 n = router.MAX_DESTINATIONS();
        IRevenueRouter.Destination[] memory d = _fundedDests(n);
        deal(address(EUSD), address(router), 1_000_000e18);

        _cool(d);
        vm.prank(TIMELOCK);
        uint256 g = gasleft();
        router.addDestinations(d);
        uint256 addGas = g - gasleft();

        _cool(d);
        g = gasleft();
        router.poke();
        uint256 pokeGas = g - gasleft();

        console.log("destinations", n);
        console.log("addDestinations gas", addGas);
        console.log("poke gas", pokeGas);
        console.log("poke gas per destination", pokeGas / n);
        assertLt(addGas, GAS_BUDGET);
        assertLt(pokeGas, GAS_BUDGET);
    }

    function _cool(IRevenueRouter.Destination[] memory d) internal {
        vm.cool(address(router));
        vm.cool(address(EUSD));
        vm.cool(address(main));
        // eUSD and Main are EIP-1967 proxies; cool their implementations too
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        vm.cool(address(uint160(uint256(vm.load(address(EUSD), implSlot)))));
        vm.cool(address(uint160(uint256(vm.load(address(main), implSlot)))));
        for (uint256 i = 0; i < d.length; ++i) {
            vm.cool(d[i].holder);
            vm.cool(d[i].recipient);
        }
    }
}
