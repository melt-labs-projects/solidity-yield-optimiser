// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WETH is ERC20 {


    constructor(uint256 initialSupply) ERC20("WETH", "WETH") {
        _mint(msg.sender, initialSupply);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}