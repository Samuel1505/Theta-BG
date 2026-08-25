// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WETH9-compatible mock for deterministic testnet-free tests.
contract MockWETH is ERC20 {
    constructor() ERC20("Mock Wrapped Ether", "mWETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
