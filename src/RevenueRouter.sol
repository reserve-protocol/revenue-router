// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMain, IRToken, IRevenueRouter} from "./interfaces/IRevenueRouter.sol";

/**
 * @title RevenueRouter
 * @notice A Distributor revenue destination for eUSD. Anyone can call poke() to forward the
 *   router's entire eUSD balance to a governed list of destinations. Each destination pairs a
 *   holder, whose spot eUSD balance sets its weight, with a recipient, which receives its share.
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
 *   Not upgradeable, and has no pause of its own. Governance can replace the destination list and sweep any token.
 */
contract RevenueRouter is IRevenueRouter {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant OWNER = bytes32("OWNER");

    /// Max number of destinations. Bounds the worst-case gas of poke() and setDestinations();
    /// see the README for the derivation.
    uint256 public constant MAX_DESTINATIONS = 100;

    /// {qRTok} poke() reverts below this eUSD balance: 1 wei per destination slot
    uint256 public constant MIN_POKE_AMOUNT = MAX_DESTINATIONS;

    IRToken public immutable eUSD;
    IMain public immutable main; // eUSD's Main never changes

    EnumerableSet.AddressSet private _holders;
    mapping(address holder => address recipient) private _recipients;

    modifier governance() {
        if (!main.hasRole(OWNER, msg.sender)) revert NotGovernance();
        _;
    }

    constructor(IRToken eUSD_) {
        if (address(eUSD_) == address(0)) revert ZeroAddress();
        eUSD = eUSD_;
        main = eUSD_.main();
    }

    function destinations() external view returns (Destination[] memory dests) {
        address[] memory holders = _holders.values();
        dests = new Destination[](holders.length);
        for (uint256 i = 0; i < holders.length; ++i) {
            dests[i] = Destination(holders[i], _recipients[holders[i]]);
        }
    }

    /// Replace the destination list
    /// @param dests Holders must be distinct; recipients may repeat. Neither may be zero, this
    ///   router, or eUSD itself.
    function setDestinations(Destination[] calldata dests) external governance {
        uint256 len = dests.length;
        if (len > MAX_DESTINATIONS) revert TooManyDestinations(len);

        address[] memory oldHolders = _holders.values();
        for (uint256 i = 0; i < oldHolders.length; ++i) {
            delete _recipients[oldHolders[i]];
        }
        _holders.clear();

        for (uint256 i = 0; i < len; ++i) {
            Destination calldata dest = dests[i];
            _checkAccount(dest.holder);
            _checkAccount(dest.recipient);
            if (!_holders.add(dest.holder)) revert DuplicateHolder(dest.holder);
            _recipients[dest.holder] = dest.recipient;
        }

        emit DestinationsSet(dests);
    }

    /// Forward the router's whole eUSD balance to recipients, pro rata to their holders' eUSD
    /// balances. Rounding dust (< 1 wei per destination) stays in the router for the next poke.
    /// Ignores eUSD's paused and frozen states.
    function poke() external {
        uint256 amount = eUSD.balanceOf(address(this));
        if (amount < MIN_POKE_AMOUNT) revert BelowMinimum(amount);

        address[] memory holders = _holders.values();
        uint256 len = holders.length;

        // Read every balance before transferring, so earlier transfers don't shift later weights
        uint256[] memory balances = new uint256[](len);
        uint256 total;
        for (uint256 i = 0; i < len; ++i) {
            balances[i] = eUSD.balanceOf(holders[i]);
            total += balances[i];
        }
        if (total == 0) revert NoHoldings();

        uint256 distributed;
        for (uint256 i = 0; i < len; ++i) {
            // {qRTok} = {qRTok} * {qRTok} / {qRTok}
            uint256 share = (amount * balances[i]) / total;
            if (share == 0) continue;

            distributed += share;
            address recipient = _recipients[holders[i]];
            IERC20(eUSD).safeTransfer(recipient, share);
            emit Distributed(holders[i], recipient, share);
        }

        emit Poked(msg.sender, distributed);
    }

    /// Emergency transfer of any token held by the router, including eUSD.
    /// Handles tokens that return nothing on transfer (e.g. USDT).
    /// Ignores eUSD's paused and frozen states.
    function sweep(IERC20 token, address to, uint256 amount) external governance {
        if (to == address(0)) revert ZeroAddress();

        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
    }

    function _checkAccount(address account) private view {
        if (account == address(0) || account == address(this) || account == address(eUSD)) {
            revert InvalidDestination(account);
        }
    }
}
