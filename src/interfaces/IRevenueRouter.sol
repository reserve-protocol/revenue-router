// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMain {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IRToken is IERC20 {
    function main() external view returns (IMain);
}

interface IRevenueRouter {
    /// Revenue is weighted by `holder`'s eUSD balance times `multiplier` and paid to `recipient`
    struct Destination {
        address holder;
        address recipient;
        uint96 multiplier; // D18{1} 1e18 = 1x
    }

    event DestinationAdded(address indexed holder, address indexed recipient, uint96 multiplier);
    event DestinationRemoved(address indexed holder);
    event Distributed(address indexed holder, address indexed recipient, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error RevenueRouter__NotGovernance();
    error RevenueRouter__ZeroAddress();
    error RevenueRouter__TooManyDestinations(uint256 count);
    error RevenueRouter__InvalidDestination(address account);
    error RevenueRouter__InvalidMultiplier(address holder);
    error RevenueRouter__DuplicateHolder(address holder);
    error RevenueRouter__UnknownHolder(address holder);
    error RevenueRouter__ZeroHoldings();

    function eUSD() external view returns (IRToken);

    function main() external view returns (IMain);

    function destinations() external view returns (Destination[] memory);

    function addDestinations(Destination[] calldata dests) external;

    function removeDestinations(address[] calldata holders) external;

    function poke() external;

    function sweep(IERC20 token, address to, uint256 amount) external;
}
