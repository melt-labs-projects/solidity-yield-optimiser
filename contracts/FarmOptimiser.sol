// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './interfaces/IPancakeRouter02.sol';
import './interfaces/ICompounder.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';

/// @author Sir Palamede
contract Optimiser is Ownable, ReentrancyGuard, Pausable {
    
    using SafeERC20 for IERC20;
    
    /// @dev Contains information a user's stake in a farm.
    struct UserInfo {

        /// @dev The number of shares which belong to this user.
        uint shares;

        /// @dev Used to calculate the REWARD rewards for this user.
        /// Every time the user deposits or withdraws, their current rewards are added to the `pastPending`.
        /// The `rewardDebt` is then calculated by multiplying the `accRewardsPerShare` for the farm and the 
        /// `shares` for the user.
        ///
        /// Using this approach we can store how much the user's shares would have theoretically accumulated in rewards
        /// if they had been in the farm from the beginning up until this point. This allows us to calculate the amount of rewards
        /// the user earns in between now and the next time they deposit to or withdraw from this farm. 
        /// At that point, we will be able to calculate how much the user's shares would have theoretically accumulated in rewards
        /// if they had been in the farm from the beginning. From this we can subtract the user's `rewardDebt` in order to find out how
        /// much the user has earned in rewards since their last deposit or withdraw.
        ///
        /// Make sense?
        uint rewardDebt;

        /// @dev The amount of REWARD rewards the user's stake has accumulated up until the last deposit or withdraw.
        /// If the users harvest (and successfully withdraws their rewards), this value will be zeroed.
        uint pastRewards;

    }
    
    /// @dev Contains information a farm.
    struct FarmInfo {

        /// @dev The token needed for depositing into this farm.
        IERC20 token;

        /// @dev The total number of shares currently issued for this farm.
        uint totalShares;

        /// @dev Used to figure out how much of the total REWARD emission (`rewardsPerBlock`) are allocated to this farm.
        uint allocPoints;

        /// @dev The last block for which rewards were distributed. Updated when anyone calls 
        /// deposit/withdraw/harvest on this farm.
        uint lastRewardBlock;

        /// @dev The accumulated REWARD rewards per share starting from when the farm was first enabled.
        uint accRewardsPerShare;

        /// @dev The deposit fee taken when depositing to this farm. Fee is sent to the `vault`.
        uint16 depositFee;

        /// @dev The withdraw fee taken when withdrawing from this farm. Fee is sent to the `vault`.
        uint16 withdrawFee;

        /// @dev Whether or not the farm is paused. Depositing and updating is disable while the farm is paused.
        /// Withdrawing and harvest are still possible.
        bool paused;

    }
    
    /// @dev Useful constant for reward calculations.
    uint constant private ONE_ETHER = 1 ether;

    /// @dev The maximum fee. 
    /// 10,000 corresponds to 100%. Thus, 100 corresponds to 1%.
    uint16 constant public MAX_FEE = 10000;
    
    /// @dev The REWARD token.
    IERC20 immutable public rwt;

    /// @dev KingDefi vault for deposit/withdraw fees.
    address public vault;

    /// @dev Total allocation points across all farms.
    uint public totalAllocPoints;

    /// @dev Total REWARD emissions per block for this contract.
    uint public rewardsPerBlock;
    
    /// @dev The number of compounders configured.
    uint public compounderCount;

    /// @dev Mapping from compounder id to the compounder's address.
    mapping(uint => ICompounder) public compounders;

    /// @dev Retrieves whether a farm for a given (compounder id, farm id) is enabled.
    mapping(uint => mapping(uint => bool)) public isEnabled;

    /// @dev Retrieves farm information for a given (compounder id, farm id).
    mapping(uint => mapping(uint => FarmInfo)) public farms;

    /// @dev Retrieves user stake information for a given (compounder id, farm id, user address).
    mapping(uint => mapping(uint => mapping(address => UserInfo))) public users;

    /// @dev allowances[sid][pid][account][spender] dictates how much the spender can withdraw from account's funds
    mapping(uint => mapping(uint => mapping(address => mapping(address => uint)))) public allowances;
    
    /// @dev Event for when a user deposits.
    /// @param user the address of the user depositing.
    /// @param pid the id of the farm deposited to.
    /// @param amount the amount deposited.
    event Deposit(address indexed user, uint indexed pid, uint amount);

    /// @dev Event for when a user withdraws.
    /// @param user the address of the user withdrawing.
    /// @param pid the id of the farm withdrawn from.
    /// @param amount the amount withdrawn.
    event Withdraw(address indexed user, uint indexed pid, uint amount);

    /// @dev Event for when a user harvests.
    /// @param user the address of the user harvesting.
    /// @param pid the id of the farm harvested.
    /// @param amount the amount harvestd.
    event Claim(address indexed user, uint pid, uint amount);

    /// @dev For ensuring the targeted farm is enabled before taking action.
    modifier onlyEnabled(uint _sid, uint _pid) {
        require(isEnabled[_sid][_pid], "This farm is not enabled.");
        _;
    }

    constructor(address _rwt, address _vault, uint _rewardsPerBlock) {
        rwt = IERC20(_rwt);
        vault = _vault;
        rewardsPerBlock = _rewardsPerBlock;
    }
    
    /// @notice Configure a compounder.
    /// @param _compounder the compounder to configure.
    function addCompounder(address _compounder) external onlyOwner {
        compounders[compounderCount] = ICompounder(_compounder);
        compounderCount += 1;
    }
    
    /// @dev Enable a new farm. this allows the compounder to accept deposit/withdraw/harvest calls for the farm with
    /// the given `_sid` and `_pid`. This method can be called even when a farm is already enabled, as an alternate way to update
    /// parameters collectively.
    function enableFarm(
        uint _sid,
        uint _pid,
        address _token,
        uint _allocPoints,
        uint16 _depositFee,
        uint16 _withdrawFee
    ) external onlyOwner {

        // Remove old allocation points from the total
        totalAllocPoints -= farms[_sid][_pid].allocPoints;

        isEnabled[_sid][_pid] = true;
        farms[_sid][_pid] = FarmInfo({
            token: IERC20(_token),
            totalShares: farms[_sid][_pid].totalShares,
            allocPoints: _allocPoints,
            lastRewardBlock: block.number,
            accRewardsPerShare: farms[_sid][_pid].accRewardsPerShare,
            depositFee: _depositFee,
            withdrawFee: _withdrawFee,
            paused: farms[_sid][_pid].paused
        });

        // Add new allocation points from the total
        totalAllocPoints += _allocPoints;
    }
    
    /// @notice Deposit funds to a farm from the caller.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _amount amount to deposit.
    function deposit(uint _sid, uint _pid, uint _amount) external nonReentrant {
        _deposit(_sid, _pid, _amount, msg.sender);
    }
    
    /// @notice Deposit funds to a farm for a specific address.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _amount amount to deposit.
    /// @param _to address to deposit for.
    function depositTo(uint _sid, uint _pid, uint _amount, address _to) external nonReentrant {
        _deposit(_sid, _pid, _amount, _to);
    }
    
    /// @notice Withdraw funds to a farm from the caller.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _amount amount to withdraw.
    function withdraw(uint _sid, uint _pid, uint _amount) external nonReentrant onlyEnabled(_sid, _pid) {
        require(_amount > 0, "Withdraw amount must be non-zero.");
        require(_amount <= getUserAmount(_sid, _pid, msg.sender), "Cannot withdraw more than what is yours.");
        _withdraw(_sid, _pid, _amount, msg.sender);
    }
    
    /// @notice Withdraw funds to a farm for a specific address.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _amount amount to deposit.
    /// @param _from address to withdraw for.
    function withdrawFrom(uint _sid, uint _pid, uint _amount, address _from) external nonReentrant onlyEnabled(_sid, _pid) {
        require(_amount > 0, "Withdraw amount must be non-zero.");
        require(allowances[_sid][_pid][_from][msg.sender] >= _amount, "Not allowed to withdraw this amount.");
        require(_amount <= getUserAmount(_sid, _pid, _from), "Cannot withdraw more than what is yours.");
        allowances[_sid][_pid][_from][msg.sender] -= _amount;
        _withdraw(_sid, _pid, _amount, _from);
    }
    
    /// @notice Harvest rewards from farm for sender.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    function harvest(uint _sid, uint _pid) external nonReentrant onlyEnabled(_sid, _pid) {
        _harvest(_sid, _pid);
    }
    
    /// @notice Allow another address to withdraw sender's funds
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _amount amount to allow for withdrawal.
    /// @param _account spender to approve.
    function approve(uint _sid, uint _pid, uint _amount, address _account) external {
        allowances[_sid][_pid][msg.sender][_account] += _amount;
    }

    /// @notice Update a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    function update(uint _sid, uint _pid) external onlyEnabled(_sid, _pid) {
        _update(_sid, _pid);
    }
    
    /// @dev General method for charging fees.
    function chargeFee(uint _sid, uint _pid, uint16 _fee, uint _amount) internal returns(uint) {
        if (_fee != 0) {
            uint feeAmount = (_amount * _fee) / MAX_FEE;
            farms[_sid][_pid].token.safeTransfer(vault, feeAmount);
            return feeAmount;
        }
        return 0;
    }
    
    /// @notice Retrieve a user's pending rewards for a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _account the user's address.
    function pending(uint _sid, uint _pid, address _account) public view returns(uint) {
        UserInfo memory user = users[_sid][_pid][_account];
        return user.pastRewards + ((user.shares * farms[_sid][_pid].accRewardsPerShare) / ONE_ETHER) - user.rewardDebt;
    }
    
    /// @dev Deposit funds.
    function _deposit(uint _sid, uint _pid, uint _amount, address _to) internal whenNotPaused onlyEnabled(_sid, _pid) {
        require(_amount >= MAX_FEE, "Deposit too small.");
        FarmInfo storage farm = farms[_sid][_pid];
        require(!farm.paused, "Farm is paused.");
        _update(_sid, _pid);
        UserInfo storage user = users[_sid][_pid][_to];
        
        // Pull `_amount` of funds from caller.
        farm.token.safeTransferFrom(msg.sender, address(this), _amount);
        
        // Charge deposit fee
        _amount -= chargeFee(_sid, _pid, farm.depositFee, _amount);
        
        // Deposit to strategy
        _approveTokenAmount(farm.token, address(compounders[_sid]), _amount);
        uint amountDeposited = compounders[_sid].deposit(_pid, _amount);

        // Calling deposit on the compounder could cause a compound which adds to the total deposited.
        // To ensure this user doesn't reap the rewards from that compound, we need to include the 
        // amount added from the compound in the total deposited, but we need to remove the amount just
        // deposited by the user. Otherwise we would be calculating the shares added, but assuming that the
        // users funds are already deposited, which they aren't... yet.
        uint totalDepositedBefore = compounders[_sid].totalDeposited(_pid) - amountDeposited;
        uint newShares = amountToShares(_sid, _pid, amountDeposited, totalDepositedBefore);
        farm.totalShares += newShares;

        // Be careful here to remove the `shares` and `rewardDebt` after calling pending as
        // the pending method uses both of theses variables in its calculation.
        user.pastRewards = pending(_sid, _pid, _to);
        user.shares += newShares;
        user.rewardDebt = (farm.accRewardsPerShare * user.shares) / ONE_ETHER;
        
    }
    
    /// @dev Withdraw funds.
    function _withdraw(uint _sid, uint _pid, uint _amount, address _from) internal {
        _update(_sid, _pid);
        FarmInfo storage farm = farms[_sid][_pid];
        UserInfo storage user = users[_sid][_pid][_from];

        // Withdraw from strategy
        uint totalDeposited = compounders[_sid].totalDeposited(_pid);
        uint sharesToRemove = min(amountToShares(_sid, _pid, _amount, totalDeposited), user.shares);
        require(farm.totalShares >= sharesToRemove, "Not enough shares.");
        farm.totalShares = zeroSaturatedSub(farm.totalShares, sharesToRemove);

        // Be careful here to remove the `shares` and `rewardDebt` after calling pending as
        // the pending method uses both of theses variables in its calculation.
        user.pastRewards = pending(_sid, _pid, _from);
        user.shares -= sharesToRemove;
        user.rewardDebt = (farm.accRewardsPerShare * user.shares) / ONE_ETHER;

        // Withdraw funds
        uint amountWithdrawn = compounders[_sid].withdraw(_pid, _amount);

        // Charge withdraw fee and transfer to user
        amountWithdrawn -= chargeFee(_sid, _pid, farm.withdrawFee, amountWithdrawn);
        farm.token.safeTransfer(msg.sender, amountWithdrawn);
        
    }

    /// @dev Harvest rewards for the sender.
    function _harvest(uint _sid, uint _pid) internal {
        _update(_sid, _pid);

        FarmInfo memory farm = farms[_sid][_pid];
        UserInfo storage user = users[_sid][_pid][msg.sender];

        // Transfer the user their pending REWARD rewards
        uint rewards = pending(_sid, _pid, msg.sender);
        
        // Reset the rewards
        user.pastRewards = 0;
        user.rewardDebt = (farm.accRewardsPerShare * user.shares) / ONE_ETHER;

        rwt.safeTransfer(msg.sender, rewards);
    }
    
    /// @dev Update a farm. 
    function _update(uint _sid, uint _pid) internal {
        FarmInfo storage farm = farms[_sid][_pid];
        if (farm.allocPoints != 0 && farm.totalShares != 0 && !farm.paused && !paused()) {
            uint rewardsToDeliver = ((rewardsPerBlock * farm.allocPoints) / totalAllocPoints) * zeroSaturatedSub(block.number, farm.lastRewardBlock);
            farm.accRewardsPerShare += (rewardsToDeliver * ONE_ETHER) / farm.totalShares;
        }
        farm.lastRewardBlock = block.number;
    }
    
    /// @dev Calculate the number of shares `_amount` represents for a farm.
    function amountToShares(uint _sid, uint _pid, uint _amount, uint _totalDeposited) internal view returns(uint) {
        if (farms[_sid][_pid].totalShares == 0 || _totalDeposited == 0) {
            return _amount;
        }
        return (_amount * farms[_sid][_pid].totalShares) / _totalDeposited;
    }
    
    /// @notice Update the withdraw fee for a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _fee the new withdraw fee.
    function changeWithdrawFee(uint _sid, uint _pid, uint16 _fee) external onlyOwner onlyEnabled(_sid, _pid) {
        require(_fee <= MAX_FEE, "fee is too large.");
        farms[_sid][_pid].withdrawFee = _fee;
    }
    
    /// @notice Update the deposit fee for a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _fee the new deposit fee.
    function changeDepositFee(uint _sid, uint _pid, uint16 _fee) external onlyOwner onlyEnabled(_sid, _pid) {
        require(_fee <= MAX_FEE, "fee is too large.");
        farms[_sid][_pid].depositFee = _fee;
    }
    
    /// @notice Update the allocation points for a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _allocPoints the new allocation points.
    function changeAllocPoints(uint _sid, uint _pid, uint _allocPoints) external onlyOwner onlyEnabled(_sid, _pid) {
        totalAllocPoints -= farms[_sid][_pid].allocPoints;
        totalAllocPoints += _allocPoints;
        farms[_sid][_pid].allocPoints = _allocPoints;
    }

    /// @notice Update the paused status for a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _paused the new paused status.
    function changePaused(uint _sid, uint _pid, bool _paused) external onlyEnabled(_sid, _pid) onlyOwner {
        farms[_sid][_pid].paused = _paused;
    }
    
    /// @notice Change the REWARD emission per block
    /// @param _rewardsPerBlock the new emission per block.
    function changeRewardsPerBlock(uint _rewardsPerBlock) external onlyOwner {
        rewardsPerBlock = _rewardsPerBlock;
    }
    
    /// @notice Change the vault.
    /// @param _vault the new vault.
    function changeVault(address _vault) external onlyOwner {
        vault = _vault;
    }
    
    /// @notice Get the deposit token for a given farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @return the deposit token.
    function depositToken(uint _sid, uint _pid) external view onlyEnabled(_sid, _pid) returns(address) {
        return address(farms[_sid][_pid].token);
    }

    /// @dev Safely approve token transfer amounts.
    function _approveTokenAmount(IERC20 _token, address _spender, uint _amount) internal {
        if (_token.allowance(address(this), _spender) < _amount) {
            _token.safeApprove(_spender, type(uint).max);
        }
    }
    
    /// @dev Utility so we don't revert if we underflow on subtraction.
    function zeroSaturatedSub(uint a, uint b) internal pure returns(uint) {
        return a < b ? 0 : a - b;
    }
    
    /// @dev Utility for minimum of two uints
    function min(uint a, uint b) internal pure returns(uint) {
        return a < b ? a : b;
    }

    /// @notice pause the contract.
    /// This prevents depositing and updating for all farms.
    function pause() external onlyOwner{
        _pause();
    }

    /// @notice unpause the contract.
    function unpause() external onlyOwner{
        _unpause();
    }


    /// @notice Get amount of deposit tokens a user has in a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    /// @param _account the user.
    /// @return the amount of deposit token.
    function getUserAmount(uint _sid, uint _pid, address _account) public view returns(uint) {
        FarmInfo memory farm = farms[_sid][_pid];
        if (farm.totalShares == 0) {
            return 0;
        }
        UserInfo memory user = users[_sid][_pid][_account];
        return (user.shares * compounders[_sid].totalDeposited(_pid)) / farm.totalShares;
    }

    /// @notice Get amount of deposit tokens in a farm.
    /// @param _sid the id of the compounder the farm belongs to.
    /// @param _pid the id of the farm.
    function getTotalDeposited(uint _sid, uint _pid) external view returns(uint) {
        return compounders[_sid].totalDeposited(_pid);
    }
    
}

