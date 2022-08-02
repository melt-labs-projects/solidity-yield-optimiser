// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../../FarmCompounder.sol';
import '../interfaces/IPancakeswapFarm.sol';

contract ApeswapCompounder is Compounder {

    constructor(address _optimiser, address _vault, address _delegate) 
        Compounder(
            _optimiser, 
            0x5c8D727b265DBAfaba67E050f2f739cAeEB4A6F9, 
            0x1446f3CEdf4d86a9399E49f7937766E6De2A3AAB, 
            _vault, 
            0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, 
            _delegate
        ) {}
    
    function _deposit(uint _pid, uint _amount) internal override {
        if (_pid == 0) {
            IPancakeswapFarm(plantation).enterStaking(_amount);
        } else {
            IPancakeswapFarm(plantation).deposit(_pid, _amount);
        }
    }
    
    function _withdraw(uint _pid, uint _amount) internal override {
        if (_pid == 0) {
            IPancakeswapFarm(plantation).leaveStaking(_amount);
        } else {
            IPancakeswapFarm(plantation).withdraw(_pid, _amount);
        }
    }

    function _harvest(uint _pid) internal override {
        _withdraw(_pid, 0);
    }

    function _emergencyWithdraw(uint _pid, uint _amount) internal override returns(uint) {
        if (_deposited(_pid) > 0) IPancakeswapFarm(plantation).emergencyWithdraw(_pid);
        return _amount;
    }

    function _deposited(uint _pid) internal view override returns(uint amount) {
        (amount, ) = IPancakeswapFarm(plantation).userInfo(_pid, address(this));
    }
    
}