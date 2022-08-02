// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ICompounder {
    function deposit(uint _pid, uint _amount) external returns(uint);
    function withdraw(uint _pid, uint _amount) external returns(uint);
    function totalDeposited(uint _pid) external view returns(uint);
}