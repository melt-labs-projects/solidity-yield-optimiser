// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../interfaces/IWETH.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

/// @author Sir Palamede
abstract contract BaseCompounder is Ownable, ReentrancyGuard {
    
    /// @dev This struct is used to store the tokens amounts which belong to the contract.
    struct Reserve {

        /// @dev Amount of the accumulated reward token.
        uint rewards;

        /// @dev Amount of the token0 from an LP (applies only to LP farms).
        uint token0;

        /// @dev Amount of the token1 from an LP (applies only to LP farms).
        uint token1;

    }
    
    /// @dev Stores all necessary information about a farm.
    struct FarmInfo {

        /// @dev The token which can be deposited into the farm.
        IERC20 depositToken;

        /// @dev The token which is rewarded by the farm.
        IERC20 rewardToken;

        /// @dev If the `depositToken` is an LP, then this is token0 of that LP.
        IERC20 token0;

        /// @dev If the `depositToken` is an LP, then this is token1 of that LP.
        IERC20 token1;

        /// @dev If this is true, a compound will be performed for this farm whenever
        /// funds are deposited or withdraw.
        bool compoundOnInteraction;

        /// @dev Useful variable to know whether the `rewardToken` and the `depositToken` are the same.
        bool rewardTokenIsDepositToken;

        /// @dev Whether or not the `depositToken` is an LP.
        bool isLPFarm;
        
        /// @dev Whether or not the farm rewards in the native chain token, i.e. BNB, ETH, MATIC...
        bool isRewardNative;
        
        /// @dev The treasury fee charged on the accumulated rewards on each compound.
        uint16 treasuryFee;
        
        /// @dev The rate used to find how much of the accumulated rewards on each compound are used for buy-back.
        uint16 buyBackRate;

        /// @dev The minimum amount of blocks which must occur between automatic buy-backs.
        /// NOTE: A manual buy-back can be triggered at any time.
        uint buyBackDelta;

        /// @dev The total amount of the `depositToken` currently deposited in the farm from this contract.
        uint totalDeposited; 

        /// @dev The swap path used for swapping the `rewardToken` to `token0`. Only required for LP farms.
        /// NOTE: This swap will use the `lpRouter` for this farm.
        address[] rewardToToken0Path;

        /// @dev The swap path used for swapping the `rewardToken` to `token1`. Only required for LP farms.
        /// NOTE: This swap will use the `lpRouter` for this farm.
        address[] rewardToToken1Path;

        /// @dev The swap information used to swap the `rewardToken` to REWARD for buy-back.
        address[][] rewardToRwtSwap;
        
        /// @dev The default router used to create LP for this farm. Only required for LP farms.
        address lpRouter;
    
    }

    /// @dev Stores information about buy-back for a given token.
    struct BuyBackInfo {

        /// @dev The block number of the most recent buy-back.
        uint last;

        /// @dev The amount of tokens waiting to be used for the next buy-back.
        uint pending;

    }
    
    /// @dev The wrapped native chain token.
    IWETH internal nativeToken;

    /// @dev The default address for burning tokens.
    address constant internal BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev The maximum percentage used for rate, fee and slippage factor.
    /// 10,000 corresponds to 100%. Thus, 100 corresponds to 1%.
    uint constant internal MAX_PERCENT = 10_000;

    /// @dev The slippage factor is used to calculate the minimum amount of tokens to accept 
    /// when performing a swap with a router. 9,500 = 95% means that if the swap results in any
    /// less than 95% of what we expected to receive, then revert the transaction.
    uint16 internal slippageFactor = 9_500;

    /// @dev The REWARD token.
    IERC20 internal rwt;

    /// @dev The address to send REWARD buy-back to.
    address internal buyBackAddress = BURN_ADDRESS;

    /// @dev The KingDefi treasury.
    address internal treasury;
    
    /// @dev The FarmOptimiser singleton address.
    address internal optimiser;

    /// @dev The address of the farms contract that this contract deposits to and withdraws from.
    /// An example of a valid plantation is the Pancakeswap MasterChef contract.
    address internal plantation;
    
    /// @dev Contains the buy-back information for each reward token.
    mapping(address => BuyBackInfo) public buyBacks;

    /// @dev Reports whether or not a farm with a given `pid` is enabled or not.
    mapping(uint => bool) public isEnabled;

    /// @dev Contains the tokens reserves for each farm with a given `pid`.
    mapping(uint => Reserve) public reserves;

    /// @dev Contains parameter information about a farm with a given `pid`.
    mapping(uint => FarmInfo) internal farms;

    /// @dev Indicator that there is something wrong with the plantation and
    /// that funds may need to be withdraw using emergencyWithdraw or some similar mechanism.
    bool internal emergency;

    /// @dev Event emitted whenever a manual or automatic buy-back occurs.
    /// @param pid The id of the farm which was compounded.
    /// @param amount The amount bought-back.
    /// @param burned Whether or not the `amount` was burned.
    event BuyBack(uint indexed pid, uint amount, bool burned);

    /// @dev Event emitted whenever a manual or automatic buy-back occurs.
    /// @param pid The id of the farm which was compounded.
    /// @param amount The amount of deposit tokens added as a result of the compound.
    event Compound(uint indexed pid, uint amount);
    
}