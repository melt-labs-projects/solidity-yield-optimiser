// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LPToken is ERC20 {

    address public token0;
    address public token1;

    constructor(uint256 initialSupply, address _token0, address _token1) ERC20("LPToken", "LPTKN") {
        _mint(msg.sender, initialSupply);
        token0 = _token0;
        token1 = _token1;
    }
}