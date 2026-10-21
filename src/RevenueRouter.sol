// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

interface IMain {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IRToken is IERC20 {
    function main() external view returns (IMain);
}

/**
 * @title RevenueRouter
 * @notice A Distributor revenue destination for eUSD. Anyone can call poke() to forward the
 *   router's entire eUSD balance to a governed list of destinations, pro rata to each
 *   destination's spot eUSD balance.
 *
 *   Governance is any account holding the OWNER role on eUSD's Main (the eUSD governance
 *   timelock), read from eUSD.main() on every governed call.
 *
 *   This contract ignores eUSD's paused and frozen states. Neither poke() nor sweep() checks
 *   them, and both keep working while eUSD is trading-paused, issuance-paused, or frozen,
 *   because eUSD transfers do.
 *
 *   Weights are spot balances read inside poke(). Anyone who can temporarily raise a
 *   destination's eUSD balance within one transaction (e.g. deposit into a vault destination,
 *   poke, withdraw) can steer that poke's revenue toward it. Only list destinations whose
 *   eUSD balance can't be cheaply moved in and out within one transaction.
 *
 *   Destinations receive a plain eUSD transfer and no callback.
 *
 *   Not upgradeable, no pause. Governance can replace the destination list and sweep any token.
 */
contract RevenueRouter {
    bytes32 public constant OWNER = bytes32("OWNER");

    /// Max number of destinations. Bounds the worst-case gas of poke() and setDestinations();
    /// see the README for the derivation.
    uint256 public constant MAX_DESTINATIONS = 160;

    /// {qRTok} poke() reverts below this eUSD balance: 1 eUSD per destination slot
    uint256 public constant MIN_POKE_AMOUNT = MAX_DESTINATIONS * 1e18;

    IRToken public immutable eUSD;

    address[] private _destinations;

    event DestinationsSet(address[] destinations);
    event Poked(address indexed caller, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error NotGovernance();
    error ZeroAddress();
    error TooManyDestinations(uint256 count);
    error InvalidDestination(address destination);
    error DuplicateDestination(address destination);
    error BelowMinimum(uint256 amount);
    error NoHoldings();
    error TransferFailed();

    modifier governance() {
        if (!eUSD.main().hasRole(OWNER, msg.sender)) revert NotGovernance();
        _;
    }

    constructor(IRToken eUSD_) {
        if (address(eUSD_) == address(0)) revert ZeroAddress();
        eUSD = eUSD_;
    }

    function destinations() external view returns (address[] memory) {
        return _destinations;
    }

    /// Replace the destination list
    /// @param dests Distinct addresses; not zero, this router, or eUSD itself
    /// @custom:governance
    function setDestinations(address[] calldata dests) external governance {
        uint256 len = dests.length;
        if (len > MAX_DESTINATIONS) revert TooManyDestinations(len);

        for (uint256 i = 0; i < len; ++i) {
            address dest = dests[i];
            if (dest == address(0) || dest == address(this) || dest == address(eUSD)) {
                revert InvalidDestination(dest);
            }
            for (uint256 j = 0; j < i; ++j) {
                if (dests[j] == dest) revert DuplicateDestination(dest);
            }
        }

        _destinations = dests;
        emit DestinationsSet(dests);
    }

    /// Forward the router's whole eUSD balance to destinations, pro rata to their eUSD balances.
    /// Rounding dust (< 1 wei per destination) stays in the router for the next poke.
    /// Does not check eUSD's paused or frozen states.
    /// @custom:interaction
    function poke() external {
        uint256 amount = eUSD.balanceOf(address(this));
        if (amount < MIN_POKE_AMOUNT) revert BelowMinimum(amount);

        address[] memory dests = _destinations;
        uint256 len = dests.length;

        // Read every balance before transferring, so earlier transfers don't shift later weights
        uint256[] memory balances = new uint256[](len);
        uint256 total;
        for (uint256 i = 0; i < len; ++i) {
            balances[i] = eUSD.balanceOf(dests[i]);
            total += balances[i];
        }
        if (total == 0) revert NoHoldings();

        uint256 distributed;
        for (uint256 i = 0; i < len; ++i) {
            // {qRTok} = {qRTok} * {qRTok} / {qRTok}
            uint256 share = (amount * balances[i]) / total;
            if (share == 0) continue;

            distributed += share;
            if (!eUSD.transfer(dests[i], share)) revert TransferFailed();
        }

        emit Poked(msg.sender, distributed);
    }

    /// Emergency transfer of any token held by the router, including eUSD.
    /// Does not check eUSD's paused or frozen states.
    /// @custom:governance
    function sweep(address token, address to, uint256 amount) external governance {
        if (to == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert TransferFailed();

        // Accept tokens that return nothing on transfer (e.g. USDT)
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();

        emit Swept(token, to, amount);
    }
}
