// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IRewardRouter
/// @notice Interface for routing validator rewards based on collateral ownership
interface IRewardRouter {
  /// @notice Distribution configuration for a validator
  /// @param targets Vaults that can claim directly (subject to commission fee)
  /// @param operator Address that can manage this validator's config
  /// @param defaultRecipient Address that receives rewards for non-target vaults
  /// @param feeRecipient Address that receives commission fees from targets
  /// @param commissionRate Commission rate in bps (10000 = 100%)
  struct DistributionConfig {
    address[] targets;
    address operator;
    address defaultRecipient;
    address feeRecipient;
    uint256 commissionRate;
  }

  /// @notice Emitted when rewards are distributed for a validator
  /// @param validator Validator address
  /// @param gmMitoAmount Amount of gmMito distributed
  event RewardDistributed(address indexed validator, uint256 gmMitoAmount);

  /// @notice Emitted when gmMito is transferred to a vault
  /// @param vault Vault address
  /// @param gmMitoAmount Amount of gmMito transferred
  event GmMitoTransferred(address indexed vault, uint256 gmMitoAmount);

  /// @notice Emitted when epoch rewards are finalized
  /// @param epoch Epoch number
  /// @param validator Validator address
  /// @param totalGmMito Total gmMito rewards for the epoch
  /// @param totalTWAB Total TWAB for the epoch
  event EpochRewardsFinalized(
    uint256 indexed epoch, address indexed validator, uint256 totalGmMito, uint256 totalTWAB
  );

  /// @notice Emitted when a vault claims its share of epoch rewards
  /// @param epoch Epoch number
  /// @param validator Validator address
  /// @param vault Vault address
  /// @param vaultTWAB Vault's TWAB
  /// @param gmMitoAmount Amount of gmMito claimed (net amount if fee taken)
  event VaultShareClaimed(
    uint256 indexed epoch,
    address indexed validator,
    address indexed vault,
    uint256 vaultTWAB,
    uint256 gmMitoAmount
  );

  /// @notice Emitted when distribution configuration is set
  /// @param validator Validator address
  /// @param startEpoch Epoch from which this config applies
  /// @param config The distribution configuration
  event DistributionConfigSet(
    address indexed validator, uint256 indexed startEpoch, DistributionConfig config
  );

  /// @notice Emitted when fee is taken from a vault's reward
  /// @param epoch Epoch number
  /// @param validator Validator address
  /// @param vault Vault address
  /// @param amount Fee amount deducted
  event FeeTaken(
    uint256 indexed epoch, address indexed validator, address indexed vault, uint256 amount
  );

  /// @notice Emitted when non-target rewards are claimed by default recipient
  /// @param epoch Epoch number
  /// @param validator Validator address
  /// @param vault Original vault address
  /// @param recipient Default recipient who received the rewards
  /// @param amount Amount claimed
  event NonTargetRewardsClaimed(
    uint256 indexed epoch,
    address indexed validator,
    address indexed vault,
    address recipient,
    uint256 amount
  );

  error ZeroAddress();
  error NoRewards();
  error ZeroAmount();
  error EpochAlreadyFinalized();
  error InvalidEpoch();
  error InvalidValidator();
  error InvalidVault();
  error InvalidCommissionRate(uint256 rate);
  error InvalidEpochOrder(uint256 startEpoch, uint256 lastConfigEpoch);
  error Unauthorized();
  error NotTarget();

  /// @notice Distribute rewards for a validator
  /// @param validator Validator to claim from
  /// @return gmMitoAmount Amount of gmMito received
  function distributeRewards(
    address validator
  ) external returns (uint256 gmMitoAmount);

  /// @notice Finalize epoch rewards (operator only)
  /// @dev Claims operator rewards from validator and stores them for vault claims
  /// @param epoch Epoch number
  /// @param validator Validator to claim from
  /// @return totalGmMito Total gmMito claimed
  function finalizeEpoch(
    uint256 epoch,
    address validator
  ) external returns (uint256 totalGmMito);

  /// @notice Claim vault's proportional rewards for multiple epochs
  /// @dev Called by vault contract (_msgSender() is vault address)
  /// @param validator Validator address
  /// @param fromEpoch Starting epoch (inclusive)
  /// @param toEpoch Ending epoch (inclusive)
  /// @return totalClaimed Total amount of gmMito claimed
  function claimRewards(
    address validator,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external returns (uint256 totalClaimed);

  /// @notice Claim proportional rewards for non-target vaults (operator/defaultRecipient only)
  /// @param validator Validator address
  /// @param vaults Array of non-target vaults to claim for
  /// @param fromEpoch Starting epoch (inclusive)
  /// @param toEpoch Ending epoch (inclusive)
  /// @return totalClaimed Total amount of gmMito claimed
  function claimForNonTargets(
    address validator,
    address[] calldata vaults,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external returns (uint256 totalClaimed);

  /// @notice Get claimable rewards for a vault across multiple epochs
  /// @param validator Validator address
  /// @param vault Vault address
  /// @param fromEpoch Starting epoch (inclusive)
  /// @param toEpoch Ending epoch (inclusive)
  /// @return totalClaimable Total amount of gmMito claimable
  function getClaimableRewards(
    address validator,
    address vault,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external view returns (uint256 totalClaimable);

  /// @notice Sets the distribution configuration for a validator (config.operator or ADMIN)
  /// @param validator The validator address
  /// @param startEpoch The epoch from which this config applies
  /// @param config The distribution configuration
  function setDistributionConfig(
    address validator,
    uint256 startEpoch,
    DistributionConfig calldata config
  ) external;

  /// @notice Get gmMito balance of this contract
  /// @return gmMito balance
  function gmMitoBalance() external view returns (uint256);

  /// @notice Get epoch reward info
  /// @param epoch Epoch number
  /// @param validator Validator address
  /// @return totalGmMito Total gmMito for the epoch
  /// @return totalTWAB Total TWAB for the epoch
  /// @return finalized Whether distribution is finalized
  function getEpochReward(
    uint256 epoch,
    address validator
  ) external view returns (uint256 totalGmMito, uint256 totalTWAB, bool finalized);

  /// @notice Check if vault has claimed for an epoch
  /// @param epoch Epoch number
  /// @param validator Validator address
  /// @param vault Vault address
  /// @return claimed Amount claimed (0 if not claimed)
  function getVaultClaimed(
    uint256 epoch,
    address validator,
    address vault
  ) external view returns (uint256);

  /// @notice Get current epoch
  /// @return Current epoch number
  function currentEpoch() external view returns (uint256);

  /// @notice Get last finalized epoch for a validator
  /// @param validator Validator address
  /// @return Last finalized epoch
  function getLastFinalizedEpoch(
    address validator
  ) external view returns (uint256);

  /// @notice Get distribution config for a validator and epoch
  /// @param validator Validator address
  /// @param epoch Epoch number
  /// @return config The distribution configuration
  function getDistributionConfig(
    address validator,
    uint256 epoch
  ) external view returns (DistributionConfig memory config);

  /// @notice Get the applicable distribution config for a validator at an epoch
  /// @dev Finds the most recent config that applies to the given epoch
  /// @param validator Validator address
  /// @param epoch Epoch number
  /// @return config The applicable distribution configuration
  function getApplicableConfig(
    address validator,
    uint256 epoch
  ) external view returns (DistributionConfig memory config);

  /// @notice Get config epochs for a validator within a range
  /// @param validator Validator address
  /// @param startIndex Starting index (inclusive)
  /// @param endIndex Ending index (exclusive, capped at array length)
  /// @return epochs Config epochs in the specified range
  function getConfigEpochsRange(
    address validator,
    uint256 startIndex,
    uint256 endIndex
  ) external view returns (uint256[] memory epochs);

  /// @notice Get the total count of config epochs for a validator
  /// @param validator Validator address
  /// @return count Total number of config epochs
  function getConfigEpochsCount(
    address validator
  ) external view returns (uint256 count);

  /// @notice Check if a vault is a target for a validator at a specific epoch
  /// @param validator Validator address
  /// @param vault Vault address
  /// @param epoch Epoch number
  /// @return isTarget Whether the vault is a target
  function isTarget(
    address validator,
    address vault,
    uint256 epoch
  ) external view returns (bool isTarget);
}
