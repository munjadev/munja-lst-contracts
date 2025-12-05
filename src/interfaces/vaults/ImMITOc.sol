// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ImMITOc
/// @notice Interface for mMITOc vault (MITO collateral strategy with slashing exposure)
interface ImMITOc {
  /// @notice Emitted when collateral is deposited
  /// @param validator Validator address
  /// @param amount Amount deposited
  event CollateralDeposited(address indexed validator, uint256 amount);

  /// @notice Emitted when collateral withdrawal is requested
  /// @param validator Validator address
  /// @param amount Amount requested
  event CollateralWithdrawalRequested(address indexed validator, uint256 amount);

  /// @notice Emitted when collateral is synced with oracle
  /// @param validator Validator address
  /// @param oldValue Old collateral value
  /// @param newValue New collateral value
  event CollateralSynced(address indexed validator, uint256 oldValue, uint256 newValue);

  /// @notice Emitted when slashing is detected
  /// @param validator Validator address
  /// @param lossAmount Amount lost to slashing
  /// @param newCollateral New collateral amount
  event SlashingDetected(address indexed validator, uint256 lossAmount, uint256 newCollateral);

  /// @notice Emitted when withdrawal is requested
  /// @param user User address
  /// @param assets Assets amount
  /// @param shares Shares amount
  /// @param tokenId Withdrawal NFT token ID
  event WithdrawalRequested(address indexed user, uint256 assets, uint256 shares, uint256 tokenId);

  /// @notice Emitted when withdrawal is claimed
  /// @param user User address
  /// @param assets Assets claimed
  /// @param tokenIds Array of claimed token IDs
  event WithdrawalClaimed(address indexed user, uint256 assets, uint256[] tokenIds);

  /// @notice Emitted when withdrawal period is updated
  /// @param withdrawalPeriod New withdrawal period
  event WithdrawalPeriodSet(uint32 withdrawalPeriod);

  /// @notice Emitted when max claims per transaction is updated
  /// @param maxClaimsPerTx New max claims per transaction
  event MaxClaimsPerTxSet(uint16 maxClaimsPerTx);

  /// @notice Emitted when gmMITO rewards are distributed
  /// @param amount Amount of rewards distributed
  /// @param rewardPerShare New reward per share value
  event RewardDistributed(uint256 amount, uint256 rewardPerShare);

  /// @notice Emitted when a user claims gmMITO rewards
  /// @param user User address
  /// @param amount Amount of rewards claimed
  event RewardClaimed(address indexed user, uint256 amount);

  /// @notice Emitted when pending withdrawals are reduced due to slashing
  /// @param validator Validator address
  /// @param lostAmount Amount of pending withdrawals lost
  /// @param newTotal New total pending withdrawal amount
  event PendingWithdrawalSlashed(address indexed validator, uint256 lostAmount, uint256 newTotal);

  error ZeroAmount();
  error ZeroAddress();
  error InvalidValidator();
  error Unauthorized();
  error NoClaimableWithdrawals();
  error DepositNotSupported();
  error InsufficientCollateral();

  /*//////////////////////////////////////////////////////////////
                      WITHDRAWAL NFT FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claim matured withdrawal requests
  /// @param tokenIds Array of withdrawal NFT token IDs to claim
  /// @return claimed Amount of assets claimed
  function claimWithdraw(
    uint256[] calldata tokenIds
  ) external returns (uint256 claimed);

  /// @notice Get total pending withdrawal amount
  /// @return Total assets pending withdrawal
  function totalPendingWithdrawal() external view returns (uint256);

  /// @notice Get withdrawal period in seconds
  /// @return Withdrawal period
  function withdrawalPeriod() external view returns (uint32);

  /// @notice Set withdrawal period (admin only)
  /// @param period New withdrawal period in seconds
  function setWithdrawalPeriod(
    uint32 period
  ) external;

  /// @notice Get maximum claims per transaction
  /// @return Maximum claims per transaction
  function maxClaimsPerTx() external view returns (uint16);

  /// @notice Set maximum claims per transaction (admin only)
  /// @param maxClaimsPerTx_ New maximum claims per transaction
  function setMaxClaimsPerTx(
    uint16 maxClaimsPerTx_
  ) external;

  /*//////////////////////////////////////////////////////////////
                    COLLATERAL MANAGEMENT FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Deposit MITO collateral to a validator
  /// @param validator Validator address
  /// @param amount Amount to deposit
  function depositCollateral(
    address validator,
    uint256 amount
  ) external;

  /// @notice Request withdrawal of collateral from a validator
  /// @param validator Validator address
  /// @param amount Amount to withdraw
  function requestWithdrawCollateral(
    address validator,
    uint256 amount
  ) external payable;

  /// @notice Compound govMITO rewards to collateral
  /// @param validator Validator address
  /// @param amount Amount to compound
  function compoundToCollateral(
    address validator,
    uint256 amount
  ) external;

  /// @notice Sync collateral with oracle data
  /// @param validator Validator address
  function syncCollateral(
    address validator
  ) external;

  /// @notice Get collateral amount for a validator
  /// @param validator Validator address
  /// @return Collateral amount
  function validatorCollateral(
    address validator
  ) external view returns (uint256);

  /// @notice Get total collateral deposited across all validators
  /// @return Total collateral deposited
  function totalCollateralDeposited() external view returns (uint256);

  /// @notice Get total pending withdrawals
  /// @return Total pending withdrawal amount
  function pendingWithdrawals() external view returns (uint256);

  /// @notice Get all tracked validator addresses
  /// @return Array of validator addresses
  function getTrackedValidators() external view returns (address[] memory);

  /*//////////////////////////////////////////////////////////////
                        ORACLE FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Get time-weighted average collateral ownership for a validator
  /// @param validator Validator address
  /// @param startTime Start timestamp (inclusive)
  /// @param endTime End timestamp (exclusive)
  /// @return Time-weighted average ownership
  function getCollateralOwnershipTWAB(
    address validator,
    uint48 startTime,
    uint48 endTime
  ) external view returns (uint256);

  /// @notice Get total time-weighted average balance for a validator
  /// @param validator Validator address
  /// @param startTime Start timestamp (inclusive)
  /// @param endTime End timestamp (exclusive)
  /// @return Total time-weighted average balance
  function getTotalTWAB(
    address validator,
    uint48 startTime,
    uint48 endTime
  ) external view returns (uint256);

  /*//////////////////////////////////////////////////////////////
                      GMMITO REWARD FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claim validator rewards from RewardRouter and distribute to stakers
  /// @param validator Validator address
  /// @param fromEpoch Starting epoch (inclusive)
  /// @param toEpoch Ending epoch (inclusive)
  /// @return gmMitoAmount Amount of gmMITO claimed and distributed
  function claimValidatorRewards(
    address validator,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external returns (uint256 gmMitoAmount);

  /// @notice Get claimable validator rewards from RewardRouter
  /// @param validator Validator address
  /// @param fromEpoch Starting epoch (inclusive)
  /// @param toEpoch Ending epoch (inclusive)
  /// @return Claimable gmMITO amount
  function getClaimableValidatorRewards(
    address validator,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external view returns (uint256);

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

  /// @notice Get contract's gmMITO balance
  /// @return gmMITO balance
  function rewardBalance() external view returns (uint256);
}
