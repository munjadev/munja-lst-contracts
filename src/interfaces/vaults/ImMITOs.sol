// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ImMITOs
/// @notice Interface for mMITOs vault (tMITO staking strategy)
interface ImMITOs {
  event Staked(address indexed user, address indexed validator, uint256 amount);
  event UnstakeRequested(address indexed user, address indexed validator, uint256 amount);
  event WithdrawalClaimed(address indexed user, uint256 amount, uint256[] tokenIds);
  event RewardDistributed(uint256 amount, uint256 rewardPerShare);
  event RewardClaimed(address indexed user, uint256 amount);

  error ZeroAmount();
  error ZeroAddress();
  error InvalidAmount();
  error InvalidLength();
  error MinStakingAmountNotMet();
  error MinUnstakingAmountNotMet();
  error InvalidValidator();
  error InsufficientStake();
  error Unauthorized();
  error TransferFailed();
  error ApproveFailed();
  error WithdrawalNotMatured();
  error NotOwner();
  error NoShares();

  /*//////////////////////////////////////////////////////////////
                        STAKING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Stake tMITO to a validator
  /// @param validator Validator address
  /// @param amount Amount to stake
  function stake(
    address validator,
    uint256 amount
  ) external;

  /// @notice Request unstaking from a validator
  /// @param validator Validator address
  /// @param amount Amount to unstake
  /// @return tokenId WithdrawalNFT token ID
  function requestUnstake(
    address validator,
    uint256 amount
  ) external returns (uint256 tokenId);

  /// @notice Claim matured withdrawals
  /// @param tokenIds Array of WithdrawalNFT token IDs
  /// @param validator Validator to attempt claiming unstake from (address(0) to try all validators)
  /// @return totalClaimed Total amount claimed
  function claimWithdrawals(
    uint256[] calldata tokenIds,
    address validator
  ) external returns (uint256 totalClaimed);

  /// @notice Compound govMITO rewards to staking
  /// @param validator Validator address
  /// @param amount Amount to compound
  function compoundToStaking(
    address validator,
    uint256 amount
  ) external;

  /// @notice Get staked amount for a specific validator
  /// @param validator Validator address
  /// @return Staked amount
  function validatorStake(
    address validator
  ) external view returns (uint256);

  /// @notice Get total staked amount across all validators
  /// @return Total staked amount
  function totalStaked() external view returns (uint256);

  /*//////////////////////////////////////////////////////////////
                        REWARD FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claim govMITO rewards from validators
  /// @param validators Array of validator addresses
  /// @return totalClaimed Total govMITO claimed
  function claimRewards(
    address[] calldata validators
  ) external returns (uint256 totalClaimed);

  /// @notice Claim rewards and convert to gmMITO
  /// @param validators Array of validator addresses
  /// @return gmMitoReceived Amount of gmMITO received
  function claimAndConvertRewards(
    address[] calldata validators
  ) external returns (uint256 gmMitoReceived);

  /// @notice Distribute gmMITO rewards to all stakers (batch distribution)
  /// @param amount Amount of gmMITO to distribute
  function distributeRewards(
    uint256 amount
  ) external;

  /// @notice Claim accumulated gmMITO rewards
  /// @return Amount of gmMITO claimed
  function claimRewards() external returns (uint256);

  /// @notice Get earned rewards for an account (simulation)
  /// @param account Account address
  /// @return Earned rewards amount
  function earnedRewards(
    address account
  ) external view returns (uint256);

  /// @notice Get current reward per share
  /// @return Reward per share (scaled by 1e18)
  function rewardPerShare() external view returns (uint256);

  /// @notice Get current gmMITO balance of vault
  /// @return gmMITO balance
  function rewardBalance() external view returns (uint256);

  /*//////////////////////////////////////////////////////////////
                          CONFIG FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Get withdrawal period in seconds
  /// @return Withdrawal period
  function withdrawalPeriod() external view returns (uint32);

  /// @notice Get maximum claims per transaction
  /// @return Max claims per tx
  function maxClaimsPerTx() external view returns (uint16);

  /// @notice Get user's reward per share paid checkpoint
  /// @param account Account address
  /// @return User's reward per share paid
  function userRewardPerSharePaid(
    address account
  ) external view returns (uint256);
}
