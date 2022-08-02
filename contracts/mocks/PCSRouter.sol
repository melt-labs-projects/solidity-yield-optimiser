// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract DummyRouter {
    
    using SafeERC20 for IERC20;
    
    IERC20 public lpToken;
    uint public divisor;
    
    constructor(address _token, uint _divisor) {
        lpToken = IERC20(_token);
        divisor = _divisor;
    }
    
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint, uint, uint) {
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountADesired / divisor);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBDesired / divisor);
        lpToken.safeTransfer(to, 1e18);
        return (amountADesired / divisor, amountBDesired / divisor, 1e18);
    }
    
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint, uint) {
        lpToken.safeTransferFrom(msg.sender, address(this), liquidity);
        IERC20(tokenA).safeTransfer(to, liquidity);
        IERC20(tokenB).safeTransfer(to, liquidity);
        return (liquidity, liquidity);
    }
    
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory) {
        IERC20 tokenA = IERC20(path[0]);
        IERC20 tokenB = IERC20(path[path.length - 1]);
        tokenA.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenB.safeTransfer(to, amountOutMin);
    }

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        amounts = new uint[](1);
        amounts[0] = amountIn;
    }
}