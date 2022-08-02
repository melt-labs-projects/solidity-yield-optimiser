// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './interfaces/IPancakeRouter02.sol';
import './interfaces/IOptimiser.sol';
import './interfaces/IWETH.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

/// @author Sir Palamede
contract Gate is Ownable, ReentrancyGuard {
    
    using SafeERC20 for IERC20;
    
    IWETH constant WETH = IWETH(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IOptimiser immutable public optimiser;
    uint constant public SLIPPAGE_CAP = 10000;

    // Used to set the slippage for swaps
    uint public slippageFactor = 9500;

    modifier validSwap(address[][] memory _swap) {
        require(_swap.length >= 2 && _swap[0].length == _swap.length - 1, "Invalid swap array.");
        _;
    }
    
    constructor(address _optimiser) {
        optimiser = IOptimiser(_optimiser);
    }
    
    /// @notice Function to deposit token of your choice to farm.
    /// @dev Converts the desired input token to the token required for the specified farm.
    /// @param _code identifier for how to convert input token to output.
    /// @param _sid identifier for the compounding contract for the dex the farm belongs to.
    /// @param _pid identifier for the farm.
    /// @param _swap0 information for performing swaps.
    /// @param _swap1 information for performing swaps.
    /// @param _lpRouter router to use for adding/remove LP tokens.
    function deposit(
        uint _code,
        uint _sid, 
        uint _pid, 
        uint _amount,
        address[][] calldata _swap0, 
        address[][] calldata _swap1,
        address _lpRouter
    ) external payable {
        
        require(_code <= 3, "Invalid code.");
        require(_amount > 0, "Amount must be positive");
        
        address inputToken = getInputToken(_swap0);
        transferFromUser(inputToken, _amount);
        
        if (_code == 0) {
            // This is for non-LP farms.
            // Swaps _amount of the inputToken for the depositToken using path0.
            // Deposits to farm.
            swapAndDeposit(_sid, _pid, _amount, _swap0);

        } else if (_code == 1) {
            // This is for LP farms.
            // Swaps half the _amount of the inputToken (token0) for token1 using path0.
            // Creates LP from token0 and token1.
            // Deposits to farm.
            swapOneAndDepositLP(_sid, _pid, _amount, _lpRouter, _swap0);

        } else if (_code == 2) {
            // This is for LP farms.
            // Swaps half the _amount of the inputToken for token0 using path0.
            // Swaps half the _amount of the inputToken for token1 using path1.
            // Creates LP from token0 and token1.
            // Deposits to farm.
            swapTwoAndDepositLP(_sid, _pid, _amount, _lpRouter, _swap0, _swap1);

        } else {
            depositWrapped(_sid, _pid, _amount);
        }
        
    }

    function depositWrapped(uint _sid, uint _pid, uint _amount) internal {
        optimiser.depositTo(_sid, _pid, _amount, msg.sender);
    }
    
    /// Takes in an amount of token X and:
    /// 1. swaps half to token0 of the desired LP token.
    /// 2. swaps half to token1 of the desired LP token.
    /// 3. creates LP tokens from the resulting amounts of token0 and token1 .
    /// 4. deposits the LP tokens into the optimiser for the user.
    function swapTwoAndDepositLP(
        uint _sid, 
        uint _pid, 
        uint _amount, 
        address _lpRouter, 
        address[][] calldata _swap0,
        address[][] calldata _swap1
    ) internal validSwap(_swap0) validSwap(_swap1) {
        
        // Swap half to token0 and half to token1
        uint token0Amount = swapLoop(_swap0, _amount / 2);
        uint token1Amount = swapLoop(_swap1, _amount / 2);
        
        // Create LP tokens
        (,,uint liquidity) = addLiquidity(_lpRouter, getOutputToken(_swap0), getOutputToken(_swap1), token0Amount, token1Amount);
        
        // Deposit LP tokens to optimiser
        address depositToken = optimiser.depositToken(_sid, _pid);
        approveTokenAmount(depositToken, address(optimiser), liquidity);
        optimiser.depositTo(_sid, _pid, liquidity, msg.sender);
        
    }
    
    /// Takes in an amount of token0 and:
    /// 1. swaps half to token1 of the desired LP token.
    /// 2. creates LP tokens from the resulting amounts of token0 and token1 .
    /// 3. deposits the LP tokens into the optimiser for the user.
    function swapOneAndDepositLP(
        uint _sid, 
        uint _pid, 
        uint _amount,
        address _lpRouter,
        address[][] calldata _swap0
    ) internal validSwap(_swap0) {
        uint halfAmount = _amount / 2;
        
        // Swap half the amount of token0 to token1.
        uint token0Amount = halfAmount;
        uint token1Amount = swapLoop(_swap0, halfAmount);
        
        // Create LP tokens
        address token0 = getInputToken(_swap0);
        address token1 = getOutputToken(_swap0);
        (,,uint liquidity) = addLiquidity(_lpRouter, token0, token1, token0Amount, token1Amount);
        
        // Deposit LP tokens to optimiser
        address depositToken = optimiser.depositToken(_sid, _pid);
        approveTokenAmount(depositToken, address(optimiser), liquidity);
        optimiser.depositTo(_sid, _pid, liquidity, msg.sender);
    }
    
    /// Takes in an amount of token X and:
    /// 1. swaps all of it to token Y.
    /// 2. deposits the resulting amount of token Y to the optimiser for the user.
    function swapAndDeposit(
        uint _sid, 
        uint _pid, 
        uint _amount,
        address[][] calldata _swap0
    ) internal validSwap(_swap0) {
        
        // Swap input tokens for output tokens
        uint depositAmount = swapLoop(_swap0, _amount);
        
        // Deposit to optimiser
        address depositToken = optimiser.depositToken(_sid, _pid);
        approveTokenAmount(depositToken, address(optimiser), depositAmount);
        optimiser.depositTo(_sid, _pid, depositAmount, msg.sender);
        
    }
    
    /// @notice Function to withdraw token of your choice from farm.
    /// @dev Converts the token for the specified farm to the desired output token.
    /// @dev The account whose funds are being withdrawn must have already approved the withdrawal.
    /// @param _code identifier for how to convert tokens.
    /// @param _sid identifier for the compounding contract for the dex the farm belongs to.
    /// @param _pid identifier for the farm.
    /// @param _swap0 information for performing swaps.
    /// @param _swap1 information for performing swaps.
    /// @param _lpRouter router to use for adding/remove LP tokens.
    function withdraw(
        uint _code,
        uint _sid, 
        uint _pid, 
        uint _amount,
        address[][] calldata _swap0, 
        address[][] calldata _swap1,
        address _lpRouter
    ) external nonReentrant {

        require(_code <= 4, "Invalid code.");
        require(_amount > 0, "Amount must be positive");
        
        optimiser.withdrawFrom(_sid, _pid, _amount, msg.sender);
        address depositToken = optimiser.depositToken(_sid, _pid);

        // Use the balance as the amount withdrawn may not have been the full
        // `_amount` due to withdrawal fees.
        _amount = IERC20(depositToken).balanceOf(address(this));
        
        if (_code == 0) {
            // This is for non-LP farms.
            // Withdraw _amount of tokens from farm.
            // Swap _amount of tokens for desired token using path0.
            // Send resulting amount of desired token to user.
            swapAndWithdraw(_amount, _swap0);

        } else if (_code == 1) {
            // This is for LP farms.
            // Remove _amount of liquidity.
            // Swap token1 amount for more of token0 using path0.
            // Send resulting amount of token0 to the user.
            swapOneAndWithdraw(_lpRouter, depositToken, _amount, _swap0);
            
        } else if (_code == 2) {
            // This is for LP farms.
            // Remove _amount of liquidity.
            // Swap token0 amount for desired token using path0.
            // Swap token1 amount for desired token using path1.
            // Send resulting amount of desired token to user.
            swapBothAndWithdraw(_lpRouter, depositToken, _amount, _swap0, _swap1);

        } else if (_code == 3) {
            // This is for LP farms.
            // Remove _amount of liquidity.
            // Send amounts of token0 and token1 to the user.
            withdrawBoth(_lpRouter, depositToken, _amount);

        } else {
            transferToUser(depositToken);
        }
        
    }
    
    /// Takes in an amount of LP and:
    /// 1. removes the liquidity.
    /// 2. sends the resulting amounts of token0 and token1 to the user.
    function withdrawBoth(
        address _lpRouter,
        address _lpToken,
        uint _amount
    ) internal {
        
        // Remove liquidity
        IUniswapV2Pair pair = IUniswapV2Pair(_lpToken);
        address token0 = pair.token0();
        address token1 = pair.token1();
        removeLiquidity(_lpRouter, _lpToken, token0, token1, _amount);
        
        // Send tokens to user
        transferToUser(token0);
        transferToUser(token1);
    }
    
    /// Takes in an amount of token X and:
    /// 1. swaps token X for the desired output token.
    /// 2. sends the resulting amount of the desired output token to the user.
    function swapAndWithdraw(
        uint _amount,
        address[][] calldata _swap0
    ) internal validSwap(_swap0) {
        
        // Swap to desired token
        swapLoop(_swap0, _amount);
        
        // Send desired token to user
        address outputToken = getOutputToken(_swap0);
        transferToUser(outputToken);
    }
    
    /// Takes in an amount of LP and:
    /// 1. removes the liquidity.
    /// 2. swaps amount of token0 for more of token1.
    /// 3. sends the resulting amount of token1 to the user.
    function swapOneAndWithdraw(
        address _lpRouter,
        address _lpToken,
        uint _amount,
        address[][] calldata _swap0
    ) internal validSwap(_swap0) {

        // Remove liquidity
        IUniswapV2Pair pair = IUniswapV2Pair(_lpToken);
        address token0 = pair.token0();
        address token1 = pair.token1();
        (uint token0Amount, uint token1Amount) = removeLiquidity(_lpRouter, _lpToken, token0, token1, _amount);
        
        // Swap token0 for token1
        address inputToken = getInputToken(_swap0);
        uint inputAmount = inputToken == token0 ? token0Amount : token1Amount;
        swapLoop(_swap0, inputAmount);
        
        // Sends tokens to user
        address outputToken = getOutputToken(_swap0);
        transferToUser(outputToken);
    }
    
    /// Takes in an amount of LP and:
    /// 1. removes the liquidity.
    /// 2. swaps amount of token0 for the desired output token.
    /// 2. swaps amount of token1 for the desired output token.
    /// 3. sends the resulting amount of desired output token to the user.
    function swapBothAndWithdraw(
        address _lpRouter,
        address _lpToken,
        uint _amount,
        address[][] calldata _swap0,
        address[][] calldata _swap1
    ) internal validSwap(_swap0) validSwap(_swap1) {
        address outputToken = getOutputToken(_swap0);
        require(outputToken == getOutputToken(_swap1), "Output tokens for swaps don't match.");
        
        // Remove liquidity
        IUniswapV2Pair pair = IUniswapV2Pair(_lpToken);
        (uint token0Amount, uint token1Amount) = removeLiquidity(_lpRouter, _lpToken, pair.token0(), pair.token1(), _amount);
        
        // Swap token0 and token1 to desired token
        swapLoop(_swap0, token0Amount);
        swapLoop(_swap1, token1Amount);
        
        // Send resulting amount of desired token to user
        transferToUser(outputToken);
    }
    
    /// @dev Perform a series of swaps for the specified routers and swap-paths.
    function swapLoop(address[][] calldata _swap, uint _amount) internal returns(uint outputAmount) {
        for(uint i = 1; i < _swap.length; i++) {
            address swapRouter = _swap[0][i-1];
            approveTokenAmount(_swap[i][0], swapRouter, _amount);
            _amount = swap(swapRouter, _amount, _swap[i], address(this));
        }
        outputAmount = _amount;
    }
    
    /// @dev Retrieve the input token for a swap.
    function getInputToken(address[][] calldata _swap) internal pure returns(address) {
        return _swap[1][0];
    }
    
    /// @dev Retireve the final output token for a series of swaps.
    function getOutputToken(address[][] calldata _swap) internal pure returns(address) {
        uint numSwaps = _swap.length - 1;
        uint lastPathLength = _swap[numSwaps].length;
        return _swap[numSwaps][lastPathLength - 1];
    }
    
    /// @dev Allow spender to use specified amount of this contracts tokens.
    function approveTokenAmount(address _token, address _spender, uint _amount) internal {
        if (IERC20(_token).allowance(address(this), _spender) < _amount) {
            IERC20(_token).safeApprove(_spender, type(uint).max);
        }
    }
    
    /// @dev Perform a single swap.
    function swap(
        address _router, 
        uint _amountIn, 
        address[] memory _path,
        address _to
    ) internal returns(uint) {
        uint[] memory amounts = IPancakeRouter02(_router).getAmountsOut(_amountIn, _path);
        uint amountOut = amounts[amounts.length - 1];
        IERC20 tokenOut = IERC20(_path[_path.length - 1]);
        uint balanceBefore = tokenOut.balanceOf(address(this));
        IPancakeRouter02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            (amountOut * slippageFactor) / SLIPPAGE_CAP,
            _path,
            _to,
            block.timestamp
        );
        return tokenOut.balanceOf(address(this)) - balanceBefore;
    }
    
    /// @dev Add liquidity to receive LP tokens.
    function addLiquidity(
        address _router,
        address _token0,
        address _token1,
        uint _amount0, 
        uint _amount1
    ) internal returns (uint, uint, uint) {
        approveTokenAmount(_token0, _router, _amount0);
        approveTokenAmount(_token1, _router, _amount1);
        return IPancakeRouter02(_router).addLiquidity(
            _token0, 
            _token1, 
            _amount0, 
            _amount1, 
            0, 
            0, 
            address(this),  
            block.timestamp
        );
    }
    
    /// @dev Remove liquidity to retrieve the constituent amounts of the tokens which make the liquidity.
    function removeLiquidity(
        address _router,
        address _lpToken,
        address _token0,
        address _token1,
        uint _amount
    ) internal returns (uint, uint) {
        approveTokenAmount(_lpToken, _router, _amount);
        return IPancakeRouter02(_router).removeLiquidity(
            _token0, 
            _token1, 
            _amount,
            0, 
            0, 
            address(this),  
            block.timestamp
        );
    }
    
    /// @dev change the slippage factor for the swaps performed by this contract.
    /// @param _slippageFactor the new slippage factor.
    function setSlippageFactor(uint _slippageFactor) external onlyOwner {
        slippageFactor = _slippageFactor;
    }

    receive() external payable {
        require(msg.sender == address(WETH));
    }

    function transferToUser(address _token) internal {
        uint amount = IERC20(_token).balanceOf(address(this));
        if (_token == address(WETH)) {
            WETH.withdraw(amount);
            (bool success,) = payable(msg.sender).call{value: amount}(new bytes(0));
            require(success, 'BNB transfer failed.');
        } else {
            IERC20(_token).safeTransfer(msg.sender, amount);
        }
    }

    function transferFromUser(address _token, uint _amount) internal {
        if (_token == address(WETH)) {
            require(msg.value == _amount, "Incorrect amount of BNB sent.");
            WETH.deposit{value: _amount}();
        } else {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }
        
    }
    
}
