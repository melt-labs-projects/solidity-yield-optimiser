// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../../FarmCompounder.sol';

interface IStakingRewards {
    function lastTimeRewardApplicable() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function getRewardForDuration() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function exit() external;
}

interface IStakingRewardsFactory {
    function stakingRewardsInfoByStakingToken(address _token) external view returns(address farm, uint rewardAmount, uint duration);
}

interface IDragonLair {
    function balanceOf(address account) external view returns (uint256);
    function leave(uint256 _dQuickAmount) external;
}

contract QuickswapCompounder is Compounder {

    IStakingRewardsFactory public stakingFactory = IStakingRewardsFactory(0x8aAA5e259F74c8114e0a471d9f2ADFc66Bfe09ed);
    IDragonLair public dQuick = IDragonLair(0xf28164A485B0B2C90639E47b0f377b4a438a16B1);

    constructor(address _optimiser, address _plantation, address _rwt, address _vault, address _native, address _delegate) 
        Compounder(_optimiser, _plantation, _rwt, _vault, _native, _delegate) {}
    
    function _deposit(uint _pid, uint _amount) internal override {
        (address farm,,) = stakingFactory.stakingRewardsInfoByStakingToken(address(farms[_pid].depositToken));
        _approveTokenAmount(address(farms[_pid].depositToken), farm, _amount);
        IStakingRewards(farm).stake(_amount);
    }
    
    function _withdraw(uint _pid, uint _amount) internal override {
        (address farm,,) = stakingFactory.stakingRewardsInfoByStakingToken(address(farms[_pid].depositToken));
        IStakingRewards(farm).withdraw(_amount);
    }

    function _harvest(uint _pid) internal override {
        (address farm,,) = stakingFactory.stakingRewardsInfoByStakingToken(address(farms[_pid].depositToken));
        IStakingRewards(farm).getReward();
        dQuick.leave(dQuick.balanceOf(address(this)));
    }

    function _deposited(uint _pid) internal view override returns(uint amount) {
        (address farm,,) = stakingFactory.stakingRewardsInfoByStakingToken(address(farms[_pid].depositToken));
        return IStakingRewards(farm).balanceOf(address(this));
    }
    
}


