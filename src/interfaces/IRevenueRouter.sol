// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMain {
    function hasRole(bytes32 role, address account) external view returns (bool);

    function tradingPausedOrFrozen() external view returns (bool);
}

interface IRToken is IERC20 {
    function main() external view returns (IMain);
}

interface IRevenueRouter {
    event DestinationsSet(address[] destinations);
    event Poked(address indexed caller, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error NotGovernance();
    error ZeroAddress();
    error TooManyDestinations(uint256 count);
    error InvalidDestination(address destination);
    error DuplicateDestination(address destination);
    error TradingPausedOrFrozen();
    error BelowMinimum(uint256 amount);
    error NoHoldings();

    function eUSD() external view returns (IRToken);

    function main() external view returns (IMain);

    function destinations() external view returns (address[] memory);

    function setDestinations(address[] calldata dests) external;

    function poke() external;

    function sweep(IERC20 token, address to, uint256 amount) external;
}
