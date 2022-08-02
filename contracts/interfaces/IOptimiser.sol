// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IOptimiser {
    function depositTo(uint _sid, uint _pid, uint _amount, address _to) external;
    function withdrawFrom(uint _sid, uint _pid, uint _amount, address _from) external;
    function totalDeposited(uint _pid) external returns(uint);
    function depositToken(uint _sid, uint _pid) external returns(address);
}