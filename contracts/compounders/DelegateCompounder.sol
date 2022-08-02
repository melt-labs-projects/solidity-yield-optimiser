// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../interfaces/IPancakeRouter02.sol';
import './BaseCompounder.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @author Sir Palamede
contract DelegateCompounder is BaseCompounder {
    
    using SafeERC20 for IERC20;

    /// @notice Perform a manual buy-back.
    /// @param _pid the id for the farm.
    function buyBack(uint _pid) external {
        _buyBack(_pid, 0);
    }
    
    /// @notice Perform a compound.
    /// @param _pid the id for the farm.
    /// @return depositAmount the amount of `depositToken` created through the compound.
    function compound(uint _pid) external returns(uint depositAmount) {
        
        FarmInfo memory farm = farms[_pid];
        uint rewards = reserves[_pid].rewards;
        if (rewards < 1e9) return  0;
        
        // Buy back reward token (ignore if the reward token is LP)
        if (!farm.isLPFarm || !farm.rewardTokenIsDepositToken) {
            uint buyBackAmount = (reserves[_pid].rewards * farm.buyBackRate) / MAX_PERCENT;
            buyBackOnInteraction(_pid, buyBackAmount);
            rewards -= buyBackAmount;
        }
        
        // Send a cut to the treasury
        uint treasuryFeeAmount = (reserves[_pid].rewards * farm.treasuryFee) / MAX_PERCENT;
        farm.rewardToken.safeTransfer(treasury, treasuryFeeAmount);
        rewards -= treasuryFeeAmount;
        
        // IMPORTANT: this condition must go first so as to catch LP farms which also reward in LP
        //
        // We're assuming that if a farm rewards LP it will be the same LP as the one deposited.
        // Otherwise the compound procedure will fail.
        if (farm.rewardTokenIsDepositToken) {
            depositAmount = rewards;
        
        // Catch farm which require LP deposits but reward a non-LP token.
        } else if (farm.isLPFarm) {
            uint token0Amount = reserves[_pid].token0;
            uint token1Amount = reserves[_pid].token1;
            uint halfRewards = rewards / 2;
            
            // Increase router allowance for rewardToken
            _approveTokenAmount(address(farm.rewardToken), farm.lpRouter, rewards);
            
            // Perform token swaps if necessary
            token0Amount += (address(farm.token0) == address(farm.rewardToken)) ? 
                halfRewards : _swap(farm.lpRouter, halfRewards, farm.rewardToToken0Path, address(this));
            token1Amount += (address(farm.token1) == address(farm.rewardToken)) ? 
                halfRewards : _swap(farm.lpRouter, halfRewards, farm.rewardToToken1Path, address(this));
            
            if (token0Amount > 0 && token1Amount > 0) {
                
                // Increase allowance for tokens 0 and 1 and add liquidity
                _approveTokenAmount(address(farm.token0), farm.lpRouter, token0Amount);
                _approveTokenAmount(address(farm.token1), farm.lpRouter, token1Amount);
                (uint spent0, uint spent1, uint liquidity) = _addLiquidity(farm.lpRouter, _pid, token0Amount, token1Amount);

                // Update reserves with dust left from adding liquidity
                reserves[_pid].token0 = token0Amount - spent0;
                reserves[_pid].token1 = token1Amount - spent1;
                depositAmount = liquidity;
            }
        
        // For the case where both the deposit and reward tokens are non-LP
        } else {
            depositAmount = _swap(farm.lpRouter, rewards, farm.rewardToToken0Path, address(this));
        }
        
        // We always perform swapExactTokensForTokens... in the swaps, so there will be no rewards left.
        reserves[_pid].rewards = 0;
        
    }
    
    /// @dev Check and execute if it is time for the next buy-back for this farm.
    function buyBackOnInteraction(uint _id, uint _buyBackAmount) internal {
        if (_buyBackAmount == 0) {
            return;
        }
        FarmInfo memory farm = farms[_id];
        address rewardToken = address(farm.rewardToken);

        // Only call `buyBack` if enough blocks have past since the last buy-back
        // for the reward token for this farm.
        if (block.number >= buyBacks[rewardToken].last + farm.buyBackDelta) {
            _buyBack(_id, _buyBackAmount);
        } else {
            buyBacks[rewardToken].pending += _buyBackAmount;
        }
        
    }

    /// @dev Perform a buy-back and transfer the REWARD to the `buyBackAddress`.
    function _buyBack(uint _id, uint _extra) internal {
        FarmInfo memory farm = farms[_id];
        BuyBackInfo storage buyBackInfo = buyBacks[address(farm.rewardToken)];
        uint amount = buyBackInfo.pending + _extra;

        // Swap the reward token to REWARD
        if (address(farm.rewardToken) != address(rwt)) {
            amount = swapLoop(farm.rewardToRwtSwap, amount);
        }

        // Send the REWARD to the `buyBackAddress`
        rwt.safeTransfer(buyBackAddress, amount);

        // Update buy-back information
        buyBackInfo.pending = 0;
        buyBackInfo.last = block.number;
        emit BuyBack(_id, amount, buyBackAddress == BURN_ADDRESS);
    }

    /// @dev Perform a series of swaps for the specified routers and swap-paths.
    function swapLoop(address[][] memory _swapInfo, uint _amount) internal returns(uint outputAmount) {
        for(uint i = 1; i < _swapInfo.length; i++) {
            address swapRouter = _swapInfo[0][i-1];
            _approveTokenAmount(_swapInfo[i][0], swapRouter, _amount);
            _amount = _swap(swapRouter, _amount, _swapInfo[i], address(this));
        }
        outputAmount = _amount;
    }
    
    /// @dev Safely approve token transfer amounts.
    function _approveTokenAmount(address _token, address _spender, uint _amount) internal {
        if (IERC20(_token).allowance(address(this), _spender) < _amount) {
            IERC20(_token).safeApprove(_spender, type(uint).max);
        }
    }
    
    /// @dev Perform a single swap.
    function _swap(address _router, uint _amountIn, address[] memory _path, address _to) internal returns(uint) {
        uint[] memory amounts = IPancakeRouter02(_router).getAmountsOut(_amountIn, _path);
        uint amountOut = amounts[amounts.length - 1];
        IERC20 token = IERC20(_path[_path.length - 1]);
        uint tokenBalanceBefore = token.balanceOf(_to);
        IPancakeRouter02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            (amountOut * slippageFactor) / MAX_PERCENT,
            _path,
            _to,
            block.timestamp
        );
        return token.balanceOf(_to) - tokenBalanceBefore;
    }
    
    /// @dev Add liquidity to receive LP tokens.
    function _addLiquidity(address _router, uint _pid, uint _amount0, uint _amount1) internal returns (uint, uint, uint) {
        return IPancakeRouter02(_router).addLiquidity(
            address(farms[_pid].token0), 
            address(farms[_pid].token1), 
            _amount0, 
            _amount1, 
            0, 
            0, 
            address(this),  
            block.timestamp
        );
    }
    
    /// @dev Reverses an array of addresses.
    function reversePath(address[] memory _path) internal pure returns(address[] memory reversed) {
        uint pathLength = _path.length;
        reversed = new address[](pathLength);
        for (uint i = 0; i < pathLength; i++) {
            reversed[i] = _path[pathLength - i - 1];
        }
    }

    /// @notice Converts dust left over from adding liquidity to reward tokens for a farm.
    /// @param _pid the id for the farm.
    function convertDustToRewards(uint _pid) external {
        require(farms[_pid].isLPFarm, "Cannot convert dust for non-LP farms.");
        Reserve storage reserve = reserves[_pid];
        FarmInfo memory farm = farms[_pid];

        uint rewards = 0;
        if (reserve.token0 > 0) {
            _approveTokenAmount(address(farm.token0), farm.lpRouter, reserve.token0);
            address[] memory token0ToRewardsPath = reversePath(farm.rewardToToken0Path);

            // Swap token0 dust for rewards
            rewards += _swap(farm.lpRouter, reserve.token0, token0ToRewardsPath, address(this));
        }

        if (reserve.token1 > 0) {
            _approveTokenAmount(address(farm.token1), farm.lpRouter, reserve.token1);
            address[] memory token1ToRewardsPath = reversePath(farm.rewardToToken1Path);

            // Swap token1 dust for rewards
            rewards += _swap(farm.lpRouter, reserve.token0, token1ToRewardsPath, address(this));
        }

        // Update the reserve
        reserve.token0 = 0;
        reserve.token1 = 0;
        reserve.rewards += rewards;
    }

    /// @notice Update the `treasuryFee` and `buyBackRate` for a set of farms.
    /// @param _pids list of id's for farms to update.
    /// @param _treasuryFee the new treasury fee.
    /// @param _buyBackRate the new buy-back rate. 
    /// @param _compoundOnInteraction whether or not to compound on interaction.
    /// @param _buyBackDelta the minimum number of blocks between buy-backs.
    function changeParamsInSet(uint[] memory _pids, uint16 _treasuryFee, uint16 _buyBackRate, bool _compoundOnInteraction, uint _buyBackDelta) external {
        require(_treasuryFee <= MAX_PERCENT, "Fee too high.");
        require(_buyBackRate <= MAX_PERCENT, "Rate too high.");
        for (uint i = 0; i < _pids.length; i++) {
            if (isEnabled[_pids[i]]) {
                farms[_pids[i]].treasuryFee = _treasuryFee;
                farms[_pids[i]].buyBackRate = _buyBackRate;
                farms[_pids[i]].compoundOnInteraction = _compoundOnInteraction;
                farms[_pids[i]].buyBackDelta = _buyBackDelta;
            }
        }
    }
    
}