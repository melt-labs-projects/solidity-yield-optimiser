// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IMdexFarm {
    function userInfo(uint256 _pid, address _account) external view returns (uint amount, uint rewardDebt, uint multLpRewardDebt);
    function deposit(uint256 _pid, uint _amount) external;
    function withdraw(uint256 _pid, uint _amount) external;
    function emergencyWithdraw(uint _pid) external;
}