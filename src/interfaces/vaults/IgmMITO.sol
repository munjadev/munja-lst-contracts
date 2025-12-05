// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IgmMITO
/// @notice ERC4626 vault interface for govMITO with claim and withdrawal queue functionality
interface IgmMITO {
  /// @notice Emitted when user staking rewards are claimed and converted to gmMITO
  /// @param validator Validator address
  /// @param owner Owner address
  /// @param recipient Recipient address
  /// @param govMitoAmount govMITO amount claimed
  /// @param gmMitoAmount gmMITO amount received
  event UserRewardsClaimed(
    address indexed validator,
    address indexed owner,
    address indexed recipient,
    uint256 govMitoAmount,
    uint256 gmMitoAmount
  );

  /// @notice Emitted when operator rewards are claimed and converted
  /// @param validator Validator address
  /// @param rewardManager Reward manager address
  /// @param recipient Recipient address
  /// @param govMitoAmount govMITO amount claimed
  /// @param gmMitoAmount gmMITO amount received
  event OperatorRewardsClaimed(
    address indexed validator,
    address indexed rewardManager,
    address indexed recipient,
    uint256 govMitoAmount,
    uint256 gmMitoAmount
  );

  /// @notice Emitted when account's reward are automatically staked into validatorStaking
  /// @param validator Validator address
  /// @param govMitoAmount govMITO amount compounded
  event RewardsStaked(address indexed validator, uint256 govMitoAmount);

  /// @notice Emitted when staking rewards are compounded back to staking
  /// @param validator Validator address
  /// @param govMitoAmount govMITO amount compounded
  event RewardsCompounded(address indexed validator, uint256 govMitoAmount);

  /// @notice Emitted when withdrawal is requested
  /// @param user User address
  /// @param assets Assets amount
  /// @param shares Shares amount
  /// @param tokenId Withdrawal NFT token ID
  event WithdrawalRequested(address indexed user, uint256 assets, uint256 shares, uint256 tokenId);

  /// @notice Emitted when withdrawal is claimed
  /// @param user User address
  /// @param totalClaimed Total amount claimed
  /// @param totalClaimedTokens Total number of tokens claimed
  /// @param tokenIds Array of token IDs claimed
  event WithdrawalClaimed(
    address indexed user, uint256 totalClaimed, uint256 totalClaimedTokens, uint256[] tokenIds
  );

  /// @notice Emitted when govMITO withdrawal is claimed
  /// @param amount Amount claimed
  event GovMitoWithdrawalClaimed(uint256 amount);

  /// @notice Emitted when withdrawal period is updated
  /// @param withdrawalPeriod New withdrawal period
  event WithdrawalPeriodSet(uint32 withdrawalPeriod);

  /// @notice Emitted when max claims per transaction is updated
  /// @param maxClaimsPerTx New max claims per transaction
  event MaxClaimsPerTxSet(uint16 maxClaimsPerTx);

  /// @notice Emitted when unstaked govMITO is claimed
  /// @param vault Vault address
  /// @param amount Amount claimed
  event UnstakeClaimed(address indexed vault, uint256 amount);

  /// @notice Emitted when unstake is requested from a validator
  /// @param validator Validator address
  /// @param amount Amount to unstake
  event UnstakeRequested(address indexed validator, uint256 amount);

  /// @notice Emitted when unstake is processed (claimed and converted to govMITO withdrawal)
  /// @param amount Amount processed
  event UnstakeProcessed(uint256 amount);

  error ZeroAddress();
  error ZeroAmount();
  error InvalidAmount();
  error MinStakingAmountNotMet();
  error MinUnstakingAmountNotMet();
  error AmountMismatch();
  error DepositNotSupported();
  error PeriodMustBeLongerThanGovMito();
  error Unauthorized();
  error NotApproved();
  error NoClaimableWithdrawals();
  error InsufficientGovMitoBalance();
  error ArrayOutOfBounds();
  error NoValidators();

  // Claim & convert functions (vault-specific)
  function userMint(
    address[] calldata validators,
    address recipient
  ) external returns (uint256 gmMitoAmount);
  function operatorMint(
    address[] calldata validators,
    address recipient
  ) external returns (uint256 gmMitoAmount);
  function compound() external returns (uint256 compounded);

  // Unstake processing
  function process() external returns (uint256 processed);

  // Withdrawal functions (vault-specific)
  function claimWithdraw(
    uint256[] calldata tokenIds
  ) external returns (uint256 claimed);
  function totalPendingWithdrawal() external view returns (uint256);
  function withdrawalPeriod() external view returns (uint32);
  function setWithdrawalPeriod(
    uint32 withdrawalPeriod_
  ) external;
  function maxClaimsPerTx() external view returns (uint16);
  function setMaxClaimsPerTx(
    uint16 maxClaimsPerTx_
  ) external;
}
