// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
 *   poke() reverts while eUSD trading is paused or eUSD is frozen. It ignores issuance-paused.
 *   sweep() ignores all of eUSD's paused and frozen states.
 *
 *   Weights are spot balances read inside poke(). Destinations are a governance-approved
 *   whitelist, so a destination that games its balance around a poke can be removed.
 *
 *   Recipients receive a plain eUSD transfer and no callback.
 *
 *   Not upgradeable, no pause. Governance can replace the destination list and sweep any token.
 */
contract RevenueRouter is IRevenueRouter {
    using SafeERC20 for IERC20;

    bytes32 public constant OWNER = bytes32("OWNER");

    /// Max number of destinations. Bounds the worst-case gas of poke() and setDestinations();
    /// see the README for the derivation.
    uint256 public constant MAX_DESTINATIONS = 100;

    /// {qRTok} poke() reverts below this eUSD balance: 1 wei per destination slot
    uint256 public constant MIN_POKE_AMOUNT = MAX_DESTINATIONS;

    IRToken public immutable eUSD;
    IMain public immutable main; // eUSD's Main never changes

    Destination[] private _destinations;

    modifier governance() {
        if (!main.hasRole(OWNER, msg.sender)) revert NotGovernance();
        _;
    }

    constructor(IRToken eUSD_) {
        if (address(eUSD_) == address(0)) revert ZeroAddress();
        eUSD = eUSD_;
        main = eUSD_.main();
    }

    function destinations() external view returns (Destination[] memory) {
        return _destinations;
    }

    /// Replace the destination list
    /// @param dests Holders must be distinct; recipients may repeat. Neither may be zero, this
    ///   router, or eUSD itself.
    function setDestinations(Destination[] calldata dests) external governance {
        uint256 len = dests.length;
        if (len > MAX_DESTINATIONS) revert TooManyDestinations(len);

        delete _destinations;
        for (uint256 i = 0; i < len; ++i) {
            Destination calldata dest = dests[i];
            _checkAccount(dest.holder);
            _checkAccount(dest.recipient);
            for (uint256 j = 0; j < i; ++j) {
                if (dests[j].holder == dest.holder) revert DuplicateHolder(dest.holder);
            }
            _destinations.push(dest);
        }

        emit DestinationsSet(dests);
    }

    /// Forward the router's whole eUSD balance to recipients, pro rata to their holders' eUSD
    /// balances. Rounding dust (< 1 wei per destination) stays in the router for the next poke.
    /// Reverts while eUSD trading is paused or eUSD is frozen; ignores issuance-paused.
    function poke() external {
        if (main.tradingPausedOrFrozen()) revert TradingPausedOrFrozen();

        uint256 amount = eUSD.balanceOf(address(this));
        if (amount < MIN_POKE_AMOUNT) revert BelowMinimum(amount);

        Destination[] memory dests = _destinations;
        uint256 len = dests.length;

        // Read every balance before transferring, so earlier transfers don't shift later weights
        uint256[] memory balances = new uint256[](len);
        uint256 total;
        for (uint256 i = 0; i < len; ++i) {
            balances[i] = eUSD.balanceOf(dests[i].holder);
            total += balances[i];
        }
        if (total == 0) revert NoHoldings();

        uint256 distributed;
        for (uint256 i = 0; i < len; ++i) {
            // {qRTok} = {qRTok} * {qRTok} / {qRTok}
            uint256 share = (amount * balances[i]) / total;
            if (share == 0) continue;

            distributed += share;
            IERC20(eUSD).safeTransfer(dests[i].recipient, share);
            emit Distributed(dests[i].holder, dests[i].recipient, share);
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
