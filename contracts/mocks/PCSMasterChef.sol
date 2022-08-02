pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract DummyPancakeswapFarm {
    
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint amount;
        uint rewardDebt;
    }
    
    bool public rewardNative;
    address[] public depositTokens;
    IERC20 public rewardToken;
    mapping(uint => uint) public balances;
    mapping(uint => bool) public paidReward;
    mapping(uint => mapping(address => UserInfo)) public userInfo;
    bool public emergency;
    
    constructor(address[] memory _depositTokens, address _rewardToken, bool _rewardNative) {
        depositTokens = _depositTokens;
        rewardToken = IERC20(_rewardToken);
        rewardNative = _rewardNative;
    }
    
    function deposit(uint256 _pid, uint _amount) public {
        if (emergency) revert("Not enough rewards");
        balances[_pid] += _amount;
        userInfo[_pid][msg.sender].amount += _amount;
        IERC20(depositTokens[_pid]).safeTransferFrom(msg.sender, address(this), _amount);
        if (!paidReward[block.number]) {
            if (rewardNative) {
                payable(msg.sender).transfer(1e16);
            } else {
                rewardToken.safeTransfer(msg.sender, 10 * 1e18);
            }
        }
        paidReward[block.number] = true;
        // rewardToken.safeTransfer(msg.sender, 10 * 1e18);
    }
    
    function withdraw(uint256 _pid, uint _amount) public {
        if (emergency) revert("Not enough rewards");
        require(balances[_pid] >= _amount);
        balances[_pid] -= _amount;
        userInfo[_pid][msg.sender].amount -= _amount;
        IERC20(depositTokens[_pid]).safeTransfer(msg.sender, _amount);
        if (!paidReward[block.number]) {
            if (rewardNative) {
                payable(msg.sender).transfer(1e16);
            } else {
                rewardToken.safeTransfer(msg.sender, 10 * 1e18);
            }
        }
        paidReward[block.number] = true;
        // rewardToken.safeTransfer(msg.sender, 10 * 1e18);
    }

    function emergencyWithdraw(uint256 _pid) public {
        uint amount = userInfo[_pid][msg.sender].amount; 
        IERC20(depositTokens[_pid]).safeTransfer(msg.sender, amount);
        userInfo[_pid][msg.sender].amount = 0;
        balances[_pid] -= amount;
    }
    
    function enterStaking(uint256 _amount) external {
        deposit(0, _amount);
    }
    
    function leaveStaking(uint256 _amount) external {
        withdraw(0, _amount);
    }

    function setEmergency(bool _emergency) external {
        emergency = _emergency;
    }

    receive() external payable {}

}