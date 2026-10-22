// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMain, IRToken, IRevenueRouter} from "./interfaces/IRevenueRouter.sol";

/**
 * @title RevenueRouter
 * @notice A Distributor revenue destination for eUSD. Anyone can call poke() to forward the
 *   router's entire eUSD balance to a governed list of destinations. Each destination pairs a
 *   holder, whose spot eUSD balance times the destination's multiplier sets its weight, with a
 *   recipient, which receives its share.
 *
 *   Governance is any account holding the OWNER role on eUSD's Main (the eUSD governance
 *   timelock).
 *
 *   This contract ignores eUSD's paused and frozen states. Neither poke() nor sweep() checks
 *   them, and both keep working while eUSD is trading-paused, issuance-paused, or frozen.
 *
 *   Weights are spot balances read inside poke(). Destinations are a governance-approved
 *   whitelist, so a destination that games its balance around a poke can be removed.
 *
 *   Recipients receive a plain eUSD transfer and no callback.
 *
 *   Not upgradeable, and has no pause of its own. Governance can add and remove destinations and
 *   sweep any token.
 */
contract RevenueRouter is IRevenueRouter {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant OWNER = bytes32("OWNER");

    /// Max number of destinations. Bounds the worst-case gas of poke() and addDestinations();
    /// see the README for the derivation.
    uint256 public constant MAX_DESTINATIONS = 100;

    IRToken public immutable eUSD;
    IMain public immutable main; // eUSD's Main never changes

    /// Packed into one slot
    struct Payout {
        address recipient;
        uint96 multiplier; // D18{1}
    }

    EnumerableSet.AddressSet private _holders;
    mapping(address holder => Payout) private _payouts;

    modifier governance() {
        require(main.hasRole(OWNER, msg.sender), RevenueRouter__NotGovernance());
        _;
    }

    constructor(IRToken eUSD_) {
        eUSD = eUSD_;
        main = eUSD_.main();
    }

    function destinations() external view returns (Destination[] memory dests) {
        address[] memory holders = _holders.values();
        dests = new Destination[](holders.length);
        for (uint256 i = 0; i < holders.length; ++i) {
            Payout memory payout = _payouts[holders[i]];
            dests[i] = Destination(holders[i], payout.recipient, payout.multiplier);
        }
    }

    /// Add destinations to the list
    /// @param dests Holders must be new and distinct; recipients may repeat. Neither may be zero,
    ///   this router, or eUSD itself. Multipliers must be nonzero.
    function addDestinations(Destination[] calldata dests) external governance {
        for (uint256 i = 0; i < dests.length; ++i) {
            Destination calldata dest = dests[i];
            _checkAccount(dest.holder);
            _checkAccount(dest.recipient);
            require(dest.multiplier != 0, RevenueRouter__InvalidMultiplier(dest.holder));
            require(_holders.add(dest.holder), RevenueRouter__DuplicateHolder(dest.holder));

            _payouts[dest.holder] = Payout(dest.recipient, dest.multiplier);
            emit DestinationAdded(dest.holder, dest.recipient, dest.multiplier);
        }

        uint256 count = _holders.length();
        require(count <= MAX_DESTINATIONS, RevenueRouter__TooManyDestinations(count));
    }

    /// Remove destinations from the list
    /// @param holders Holders of existing destinations
    function removeDestinations(address[] calldata holders) external governance {
        for (uint256 i = 0; i < holders.length; ++i) {
            require(_holders.remove(holders[i]), RevenueRouter__UnknownHolder(holders[i]));

            delete _payouts[holders[i]];
            emit DestinationRemoved(holders[i]);
        }
    }

    /// Forward the router's whole eUSD balance to recipients, pro rata to their holders' eUSD
    /// balances times their multipliers. Rounding dust (< 1 wei per destination) stays in the
    /// router for the next poke. Ignores eUSD's paused and frozen states.
    function poke() external {
        uint256 amount = eUSD.balanceOf(address(this));

        address[] memory holders = _holders.values();
        uint256 len = holders.length;

        // Read every balance before transferring, so earlier transfers don't shift later weights
        uint256[] memory weights = new uint256[](len);
        uint256 total;
        for (uint256 i = 0; i < len; ++i) {
            // {qRTok} * D18{1}
            weights[i] = eUSD.balanceOf(holders[i]) * _payouts[holders[i]].multiplier;
            total += weights[i];
        }
        require(total != 0, RevenueRouter__ZeroHoldings());

        for (uint256 i = 0; i < len; ++i) {
            // {qRTok} = {qRTok} * ({qRTok} * D18{1}) / ({qRTok} * D18{1})
            uint256 share = Math.mulDiv(amount, weights[i], total);
            if (share == 0) {
                continue;
            }

            address recipient = _payouts[holders[i]].recipient;
            IERC20(eUSD).safeTransfer(recipient, share);
            emit Distributed(holders[i], recipient, share);
        }
    }

    /// Emergency transfer of any token held by the router, including eUSD.
    /// Handles tokens that return nothing on transfer (e.g. USDT).
    /// Ignores eUSD's paused and frozen states.
    function sweep(IERC20 token, address to, uint256 amount) external governance {
        require(to != address(0), RevenueRouter__ZeroAddress());

        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
    }

    function _checkAccount(address account) private view {
        require(
            account != address(0) && account != address(this) && account != address(eUSD),
            RevenueRouter__InvalidDestination(account)
        );
    }
}
