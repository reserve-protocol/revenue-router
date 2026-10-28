// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {IRToken, IRevenueRouter} from "../../src/interfaces/IRevenueRouter.sol";

struct RevenueShare {
    uint16 rTokenDist;
    uint16 rsrDist;
}

struct RevenueTotals {
    uint24 rTokenTotal;
    uint24 rsrTotal;
}

interface IDistributor {
    function setDistributions(address[] calldata dests, RevenueShare[] calldata shares) external;

    function totals() external view returns (RevenueTotals memory);
}

interface IRevenueTrader {
    function distributeTokenToBuy() external;
}

interface IStRSR {
    function stake(uint256 rsrAmount) external;

    function delegate(address delegatee) external;
}

interface IGovernor {
    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId);

    function castVote(uint256 proposalId, uint8 support) external returns (uint256);

    function queue(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);

    function execute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external payable returns (uint256);

    function state(uint256 proposalId) external view returns (uint8);

    function proposalSnapshot(uint256 proposalId) external view returns (uint256);

    function proposalDeadline(uint256 proposalId) external view returns (uint256);

    function proposalEta(uint256 proposalId) external view returns (uint256);
}

interface IMainFull {
    function distributor() external view returns (IDistributor);

    function rTokenTrader() external view returns (IRevenueTrader);

    function rsr() external view returns (IERC20);

    function stRSR() external view returns (IStRSR);

    function grantRole(bytes32 role, address account) external;

    function freezeForever() external;

    function pauseTrading() external;

    function pauseIssuance() external;

    function frozen() external view returns (bool);

    function tradingPaused() external view returns (bool);

    function issuancePaused() external view returns (bool);
}

/// Fork tests against live eUSD. MAINNET_RPC_URL overrides the default public RPC.
contract RevenueRouterForkTest is Test {
    uint256 constant FORK_BLOCK = 26_290_000;
    IRToken constant EUSD = IRToken(0xA0d69E286B938e21CBf7E51D71F6A4c8918f482F);
    IGovernor constant GOVERNOR = IGovernor(0x96dC1C14D3D5e2dDAa52368aDfe6E6b20b976832);
    address constant TIMELOCK = 0xd979Cf15F7275a3DF838513aB911587d23b6D29e;
    IRevenueRouter constant DEPLOYED_ROUTER =
        IRevenueRouter(0xdfD0CF858afe6010C83238461C6d7142d1b5265d);
    address constant RSR_SLOW_WALLET = 0x6bab6EB87Aa5a1e4A8310C73bDAAA8A5dAAd81C1;
    address constant FURNACE = address(1);
    address constant ST_RSR = address(2);

    /// Half of the EIP-7825 per-transaction gas cap (2^24), leaving headroom for repricings
    uint256 constant GAS_BUDGET = 1 << 23;

    IMainFull main;
    RevenueRouter router;

    function setUp() public {
        string memory rpc =
            vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
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

    /// Placeholder destinations: real eUSD holders at FORK_BLOCK, not the planned list. Replace
    /// with the proposal's destinations once final.
    function _proposedDests() internal returns (IRevenueRouter.Destination[] memory d) {
        d = new IRevenueRouter.Destination[](3);
        // Base L1StandardBridge, holding the eUSD bridged to Base
        d[0] = IRevenueRouter.Destination(
            0x3154Cf16ccdb4C6d922629664174b904d80F2C35, makeAddr("recipient0"), 1e18
        );
        // Curve eUSD/FRAXBP pool
        d[1] = IRevenueRouter.Destination(
            0xAEda92e6A3B1028edc139A4ae56Ec881f3064D4F, makeAddr("recipient1"), 2e18
        );
        // Arbitrum L1ERC20Gateway, holding the eUSD bridged to Arbitrum
        d[2] = IRevenueRouter.Destination(
            0xa3A7B6F88361F48403514059F1F16C8E78d60EeC, makeAddr("recipient2"), 0.5e18
        );
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

    /// The planned proposal, built the way Register builds it (register#1146): one Governor
    /// proposal that sets the 80% eUSD / 20% RSR revenue split, then adds the router's
    /// destinations. Runs against the deployed router through eUSD's Governor, timelock,
    /// Distributor, and RevenueTrader.
    function test_governanceProposal() public {
        IDistributor distributor = main.distributor();
        assertEq(DEPLOYED_ROUTER.destinations().length, 0);
        IRevenueRouter.Destination[] memory d = _proposedDests();

        // Register zeroes the current externals, then sets the furnace, StRSR, and new externals
        address[] memory dests = new address[](5);
        RevenueShare[] memory shares = new RevenueShare[](5);
        (dests[0], shares[0]) = (0x12ec148a193BA7b3a141ce6d02AdE326883d28D9, RevenueShare(0, 0));
        (dests[1], shares[1]) = (0x2e3F334f9035aAB204347508415dEc785cd5075E, RevenueShare(0, 0));
        (dests[2], shares[2]) = (FURNACE, RevenueShare(0, 0));
        (dests[3], shares[3]) = (ST_RSR, RevenueShare(0, 2000));
        (dests[4], shares[4]) = (address(DEPLOYED_ROUTER), RevenueShare(8000, 0));

        address[] memory targets = new address[](2);
        bytes[] memory calldatas = new bytes[](2);
        (targets[0], calldatas[0]) =
        (address(distributor), abi.encodeCall(IDistributor.setDistributions, (dests, shares)));
        (targets[1], calldatas[1]) =
        (address(DEPLOYED_ROUTER), abi.encodeCall(IRevenueRouter.addDestinations, (d)));
        _passAndExecute(targets, calldatas);

        assertEq(abi.encode(DEPLOYED_ROUTER.destinations()), abi.encode(d));
        RevenueTotals memory totals = distributor.totals();
        assertEq(totals.rTokenTotal, 8000); // the router is the only eUSD destination
        assertEq(totals.rsrTotal, 2000); // StRSR is the only RSR destination

        // eUSD revenue takes the permissionless path: RevenueTrader -> Distributor -> router
        IRevenueTrader trader = main.rTokenTrader();
        uint256 amount = 100_000e18 + 7999;
        deal(address(EUSD), address(trader), amount);
        trader.distributeTokenToBuy();
        // The Distributor pays whole multiples of amount / rTokenTotal; the DAO fee is RSR-only
        uint256 received = (amount / 8000) * 8000;
        assertEq(EUSD.balanceOf(address(DEPLOYED_ROUTER)), received);

        uint256[] memory weights = new uint256[](d.length);
        uint256 total;
        for (uint256 i = 0; i < d.length; ++i) {
            weights[i] = Math.mulDiv(EUSD.balanceOf(d[i].holder), d[i].multiplier, 1e18);
            assertGt(weights[i], 0);
            total += weights[i];
        }

        DEPLOYED_ROUTER.poke();
        for (uint256 i = 0; i < d.length; ++i) {
            assertEq(EUSD.balanceOf(d[i].recipient), Math.mulDiv(received, weights[i], total));
        }
        assertLt(EUSD.balanceOf(address(DEPLOYED_ROUTER)), d.length);
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

    /// Pass and execute a proposal through eUSD's Governor and timelock. One fresh staker with
    /// twice the RSR already staked clears the proposal threshold and quorum alone.
    function _passAndExecute(address[] memory targets, bytes[] memory calldatas) internal {
        uint256[] memory values = new uint256[](targets.length);
        string memory description = "Route eUSD revenue through the RevenueRouter";
        bytes32 descriptionHash = keccak256(bytes(description));

        IERC20 rsr = main.rsr();
        IStRSR stRSR = main.stRSR();
        address voter = makeAddr("voter");
        uint256 rsrAmount = 2 * rsr.balanceOf(address(stRSR));
        // deal() on RSR makes thousands of RPC storage reads; transfer from Reserve's SlowWallet
        vm.prank(RSR_SLOW_WALLET);
        rsr.transfer(voter, rsrAmount);

        vm.startPrank(voter);
        rsr.approve(address(stRSR), rsrAmount);
        stRSR.stake(rsrAmount);
        stRSR.delegate(voter);
        vm.warp(block.timestamp + 1); // votes count from the next timestamp
        uint256 id = GOVERNOR.propose(targets, values, calldatas, description);
        vm.warp(GOVERNOR.proposalSnapshot(id) + 1);
        GOVERNOR.castVote(id, 1); // For
        vm.stopPrank();

        vm.warp(GOVERNOR.proposalDeadline(id) + 1);
        GOVERNOR.queue(targets, values, calldatas, descriptionHash);
        vm.warp(GOVERNOR.proposalEta(id));
        GOVERNOR.execute(targets, values, calldatas, descriptionHash);
        assertEq(GOVERNOR.state(id), 7); // Executed
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
