// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.35;

import {IMain} from "../../src/interfaces/IRevenueRouter.sol";

contract MockMain is IMain {
    mapping(bytes32 => mapping(address => bool)) public hasRole;

    function grantRole(bytes32 role, address account) external {
        hasRole[role][account] = true;
    }
}

/// Minimal ERC20 with an RToken-style main()
contract MockRToken {
    IMain public immutable main;
    mapping(address => uint256) public balanceOf;

    constructor(IMain main_) {
        main = main_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(this), "RToken transfer to self");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// USDT-style token: transfer returns nothing
contract MockNoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// Token whose transfer returns false instead of reverting
contract MockFalseToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
