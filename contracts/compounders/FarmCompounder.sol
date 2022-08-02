// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './BaseCompounder.sol';
import '../interfaces/IWETH.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';


/// @author Sir Palamede
abstract contract Compounder is BaseCompounder {
    
    using SafeERC20 for IERC20;
    
    /// @dev The address for the contract which contains the logic for autocompounding and buy-back functionality.
    address immutable internal delegate;
    
    /// @dev This modifier is used for calls which interact with the plantation (e.g. Pancakeswap MasterChef).
    /// Many of these types of farming contracts send you your accumulated rewards whenever you deposit or withdraw.
    /// As a result we need to track the change in our reward balance before and after these calls.
    ///
    /// Additionally, due to this contract storing more than 1 farm, of which more than 1 could have the same reward token,
    /// we must keep track of how many rewards have been accumulated for a given farm. This is stored in the reserves[pid].reward.
    /// If the contract catered only for a single farm, we could simply have queries the balance of the reward token for
    /// this address to find the accumulated rewards. Alas...
    modifier trackRewards(uint _pid) {
        if (!emergency && farms[_pid].totalDeposited > 0) {
            uint addedRewards;
            if (farms[_pid].isRewardNative) {
                uint rewardsBefore = address(this).balance;
                _;
                addedRewards = address(this).balance - rewardsBefore;
                wrapNative(addedRewards); 
            } else {
                uint rewardsBefore = farms[_pid].rewardToken.balanceOf(address(this));
                _;
                addedRewards = farms[_pid].rewardToken.balanceOf(address(this)) - rewardsBefore;
            }
            reserves[_pid].rewards += addedRewards;
        }
    }

    /// @dev For ensuring that undesired calls are not made during emergencies.
    modifier notDuringEmergency() {
        require(!emergency, "Emergency is enabled.");
        _;
    }
    
    /// @dev For ensuring the caller is the singleton optimiser contract.
    modifier onlyOptimiser() {
        require(msg.sender == optimiser, "Can only be called by optimiser.");
        _;
    }
    
    /// @dev For ensuring the targeted farm is enabled before taking action.
    modifier onlyEnabled(uint _pid) {
        require(isEnabled[_pid], "This farm is not enabled.");
        _;
    }

    /// @dev See BaseCompounder for information on the parameters.
    constructor(
        address _optimiser, 
        address _plantation, 
        address _rwt,
        address _treasury,
        address _nativeToken,
        address _delegate
    ) {
        optimiser = _optimiser;
        plantation = _plantation;
        rwt = IERC20(_rwt);
        treasury = _treasury;
        nativeToken = IWETH(_nativeToken);
        delegate = _delegate;
    }
    
    /// @dev We need to allow this contract to accept the native chain token in case one of the farms rewards it.
    receive() external payable {}
    
    /// @dev Enable a new farm. this allows the compounder to accept deposit/withdraw calls for the farm with
    /// the given `_pid`. This method can be called even when a farm is already enabled, as an alternate way to update
    /// parameters collectively. Descriptions of the parameters can be found in the BaseCompounder.
    function enableFarm(
        uint _pid,
        bool[3] memory _toggles, // [isLPFarm, compoundOnInteraction, _isRewardNative]
        address[] memory _tokens, // [depositToken, rewardToken, lpToken0, lpToken1]
        uint[3] memory _feeParams, // [treasuryFee, buyBackRate, buyBackDelta]
        address[] memory _rewardToToken0Path,
        address[] memory _rewardToToken1Path,
        address[][] memory _rewardToRwtSwap,
        address _lpRouter
    ) external onlyOwner {

        bool _isLPFarm = _toggles[0];
        require(_tokens.length == (_isLPFarm ? 4 : 2), "Incorrect number of tokens");
        require(_feeParams[0] <= MAX_PERCENT, "Fee too high.");
        require(_feeParams[1] <= MAX_PERCENT, "Rate too high.");
        require(_rewardToRwtSwap[0].length == _rewardToRwtSwap.length - 1, "Invalid swap array.");

        isEnabled[_pid] = true;
        farms[_pid] = FarmInfo({
           depositToken: IERC20(_tokens[0]),
           rewardToken: IERC20(_tokens[1]),
           token0: IERC20(_isLPFarm ? _tokens[2] : address(0)),
           token1: IERC20(_isLPFarm ? _tokens[3] : address(0)),
           compoundOnInteraction: _toggles[1],
           rewardTokenIsDepositToken: (_tokens[0] == _tokens[1]),
           isLPFarm: _isLPFarm,
           isRewardNative: _toggles[2],
           treasuryFee: uint16(_feeParams[0]),
           buyBackRate: uint16(_feeParams[1]),
           buyBackDelta: _feeParams[2],
           totalDeposited: farms[_pid].totalDeposited, // in case we use this to change settings
           rewardToToken0Path: _rewardToToken0Path,
           rewardToToken1Path: _rewardToToken1Path,
           rewardToRwtSwap: _rewardToRwtSwap,
           lpRouter: _lpRouter
        });
    }
    
    /// @notice Retrieves the amount of tokens deposited in a farm.
    /// @param _pid the id of the farm.
    function totalDeposited(uint _pid) external view returns(uint) {
        return farms[_pid].totalDeposited;
    }

    /// @dev We return the deposited amount here in case the underlying farm has a deposit fee. In this case,
    /// we need a way to inform the optimiser how much was actually deposited for the user.
    ///
    /// @notice Deposits tokens to a farm. 
    /// @param _pid the id of the farm to deposit to.
    /// @param _amount the amount of tokens to deposit.
    /// @return depositedAmount the amount of tokens that were actually deposited into the farm.
    function deposit(uint _pid, uint _amount) external notDuringEmergency onlyOptimiser onlyEnabled(_pid) returns(uint depositedAmount) {
        FarmInfo storage farm = farms[_pid];

        harvestFarm(_pid);

        // If compounding is enabled on deposit/withdraw interactions, perform a compound
        if (farm.compoundOnInteraction) {
            _compound(_pid);
        }
        
        // Pull tokens from the optimiser
        farm.depositToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Deposit to the underlying farm
        _approveTokenAmount(address(farm.depositToken), plantation, _amount);
        depositedAmount = depositToFarm(_pid, _amount);
        farm.totalDeposited = _deposited(_pid);
    }

    /// @dev As with `deposit`, we need return the amount withdraw in case the underlying farm charges a withdrawal fee.
    /// We also need to add the user's share of the compound rewards to their amount to be withdrawn if `compoundOnInteraction`
    /// is enabled. Otherwise they are not being compensated properly for the time they've staked.
    ///
    /// @notice Withdraws tokens from a farm.
    /// @param _pid the id of the farm to withdraw from.
    /// @param _amount the amount of tokens to withdraw.
    /// @return withdrawnAmount the amount of tokens that were actually withdrawn from the farm.
    function withdraw(uint _pid, uint _amount) external onlyOptimiser onlyEnabled(_pid) returns(uint withdrawnAmount) {
        FarmInfo storage farm = farms[_pid];
        require(farm.totalDeposited >= _amount, 'Cannot withdraw more than total.');

        harvestFarm(_pid);
        
        // Don't compound if there's an emergency as rewards can't be withdrawn.
        uint extraFromCompound;
        if (farm.compoundOnInteraction && !emergency) {
            uint totalBefore = farm.totalDeposited;
            _compound(_pid);
            uint totalAfter = farm.totalDeposited;

            // Give correct % of the autocompounded rewards to the user withdrawing
            // I.e. the user should receive ((their staked amount) / (total staked amount)) * (compound rewards)
            extraFromCompound = ((totalAfter - totalBefore) * _amount) / totalBefore;
        }
        
        // Withdraw the `amount` plus any extra from the compound rewards
        withdrawnAmount = withdrawFromFarm(_pid, _amount + extraFromCompound);
        farm.totalDeposited = emergency ? farm.totalDeposited - withdrawnAmount : _deposited(_pid);

        // Send the withdrawn amount to the optimiser
        farm.depositToken.safeTransfer(msg.sender, withdrawnAmount);
    }
    
    /// @notice Perform a compound for a farm.
    /// @param _pid the id of the farm to compound.
    function compound(uint _pid) external notDuringEmergency onlyEnabled(_pid) {
        harvestFarm(_pid);
        _compound(_pid);
    }
    
    /// @dev Safely approve token transfer amounts.
    function _approveTokenAmount(address _token, address _spender, uint _amount) internal {
        if (IERC20(_token).allowance(address(this), _spender) < _amount) {
            IERC20(_token).safeApprove(_spender, type(uint).max);
        }
    }
    
    // Call the delegate to perform the compounding logic.
    // Harvest should likely have been called prior to this so that there's something to compound.
    function _compound(uint _pid) internal {
        
        // Don't compound if there's nothing to compound
        FarmInfo memory farm = farms[_pid];
        if (farm.totalDeposited == 0) return;
        
        // Call the DelegateCompounder to convert the accumulated reward tokens to the deposit token
        (bool success, bytes memory amountBytes) = delegate.delegatecall(abi.encodeWithSignature("compound(uint256)", _pid));
        require(success, "Delegate call failed.");

        // Deposit the tokens into the farm
        uint depositAmount = abi.decode(amountBytes, (uint));
        if (depositAmount > 0) {
            _approveTokenAmount(address(farm.depositToken), plantation, depositAmount);
            _deposit(_pid, depositAmount);
            farms[_pid].totalDeposited = _deposited(_pid);
            emit Compound(_pid, depositAmount);
        }
        
    }
    
    /// @dev Wrap the native chain token. Needed in case there's a farm which rewards, for example,
    /// BNB, but requires WBNB to create the LP token for depositing.
    function wrapNative(uint _amount) internal {
        if (_amount > 0) nativeToken.deposit{value: _amount}(); // BNB -> WBNB
    }
    
    /// @dev Wrapper around the raw `_deposit` method to track the amount deposited.
    function depositToFarm(uint _pid, uint _amount) internal returns(uint depositedAmount) {
        uint depositedBefore = _deposited(_pid);
        _deposit(_pid, _amount); 
        return _deposited(_pid) - depositedBefore;  
    }

    /// @dev Wrapper around the raw `_withdraw` method to track the amount withdrawn.
    function withdrawFromFarm(uint _pid, uint _amount) internal returns(uint withdrawnAmount) {
        if (emergency) return _emergencyWithdraw(_pid, _amount);
        uint balanceBefore = farms[_pid].depositToken.balanceOf(address(this));
        _withdraw(_pid, _amount);
        uint balanceAfter = farms[_pid].depositToken.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    /// @dev Wrapper around the raw `_harvest` method to track rewards.
    function harvestFarm(uint _pid) internal trackRewards(_pid) {
        _harvest(_pid);
    }
    
    /// @dev This method needs to be implemented for the specific plantation. All it needs to do
    /// is make the calls necessary to deposit the `_amount` into the farm with the correct `_pid`.
    function _deposit(uint _pid, uint _amount) internal virtual {}
    
    /// @dev This method needs to be implemented for the specific plantation. All it needs to do
    /// is make the calls necessary to withdraw the `_amount` into the farm with the correct `_pid`.
    function _withdraw(uint _pid, uint _amount) internal virtual {}
    
    /// @dev This method needs to be implemented for the specific plantation. All it needs to do
    /// is make the calls necessary to harvest rewards from the farm with the correct `_pid`.
    function _harvest(uint _pid) internal virtual {}

    /// @dev This method needs to be implemented for the specific plantation. Tt needs to
    /// make the calls necessary to emergency withdraw from the farm with the correct `_pid`.
    /// It also needs to return the amount that was withdraw for the user.
    function _emergencyWithdraw(uint _pid, uint _amount) internal virtual returns(uint) {}

    /// @dev This method needs to be implemented for the specific plantation. All it needs to do
    /// is return the correct amount that is currently deposited in the farm with the correct `_pid`.
    /// 
    /// This became necessary to allow for underlying farms which collect deposit or withdraw fees.
    function _deposited(uint _pid) internal virtual returns(uint amount) {}
    
    /// @notice Update the `treasuryFee` and `buyBackRate` for a set of farms.
    /// @param _pids list of id's for farms to update.
    /// @param _treasuryFee the new treasury fee.
    /// @param _buyBackRate the new buy-back rate. 
    /// @param _compoundOnInteraction whether or not to compound on interaction.
    /// @param _buyBackDelta the minimum number of blocks between buy-backs.
    function changeParamsInSet(uint[] memory _pids, uint16 _treasuryFee, uint16 _buyBackRate, bool _compoundOnInteraction, uint _buyBackDelta) external onlyOwner {
        (bool success, ) = delegate.delegatecall(
            abi.encodeWithSignature("changeParamsInSet(uint256[],uint16,uint16,bool,uint256)", _pids, _treasuryFee, _buyBackRate, _compoundOnInteraction, _buyBackDelta)
        );
        require(success, "Delegate call failed.");
    }
    
    /// @notice Update the treasury address.
    /// @param _treasury the new treasury address.
    /// @param _buyBackAddress the new buy-back address.
    /// @param _slippageFactor the new slippage factor.
    function changeGlobalParams(address _treasury, address _buyBackAddress, uint16 _slippageFactor) external onlyOwner {
        require(_slippageFactor <= MAX_PERCENT, "Slippage factor too high.");
        treasury = _treasury;
        buyBackAddress = _buyBackAddress;
        slippageFactor = _slippageFactor;
    }

    /// @notice Convert dust leftover from LP creation to rewards for a farm.
    /// @param _pid the id of the farm.
    function convertDustToRewards(uint _pid) external {
        (bool success, ) = delegate.delegatecall(abi.encodeWithSignature("convertDustToRewards(uint256)", _pid));
        require(success, "Delegate call failed.");
    }

    /// @notice Manually perform buy-back for a farm.
    /// @param _pid the id of the farm.
    function buyBack(uint _pid) external {
        (bool success, ) = delegate.delegatecall(abi.encodeWithSignature("buyBack(uint256)", _pid));
        require(success, "Delegate call failed.");
    }

    /// @notice Set the emergency state to true.
    /// @dev This cannot be undone, so be cautious with this.
    function triggerEmergency() external onlyOwner {
        emergency = true;
    }

    /// @notice Retrieves parameters for a farm
    /// @param _pid the id of the farm.
    function farmParams(uint _pid) external view returns(
        bool compoundOnInteraction,
        bool rewardTokenIsDepositToken, 
        bool isLPFarm, 
        bool isRewardNative, 
        uint16 treasuryFee, 
        uint16 buyBackRate, 
        uint buyBackDelta
    ) {
        FarmInfo memory farm = farms[_pid];
        return (
            farm.compoundOnInteraction,
            farm.rewardTokenIsDepositToken,
            farm.isLPFarm,
            farm.isRewardNative,
            farm.treasuryFee,
            farm.buyBackRate,
            farm.buyBackDelta
        );
    }

    /// @notice Retrieves address parameters for a farm
    /// @param _pid the id of the farm.
    function farmAddresses(uint _pid) external view returns(
        address depositToken, 
        address rewardToken, 
        address token0, 
        address token1, 
        address lpRouter, 
        address[] memory rewardToToken0Path, 
        address[] memory rewardToToken1Path, 
        address[][] memory rewardToRwtSwap
    ) {
        FarmInfo memory farm = farms[_pid];
        return (
            address(farm.depositToken), 
            address(farm.rewardToken), 
            address(farm.token0), 
            address(farm.token1),
            farm.lpRouter,
            farm.rewardToToken0Path,
            farm.rewardToToken1Path,
            farm.rewardToRwtSwap
        );
    }

    function globalInfo() external view returns(
        address _rwt,
        address _buyBackAddress,
        address _treasury,
        address _optimiser,
        address _plantation,
        address _nativeToken,
        address _delegate,
        bool _emergency,
        uint16 _slippageFactor
    ) {
        return (
            address(rwt),
            buyBackAddress,
            treasury,
            optimiser,
            plantation,
            address(nativeToken),
            delegate,
            emergency,
            slippageFactor
        );
    }
    
}