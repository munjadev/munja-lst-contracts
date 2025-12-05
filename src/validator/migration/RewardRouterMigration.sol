// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { RewardRouter } from '../RewardRouter.sol';

/// @title RewardRouterMigration
/// @notice Migration contract for upgrading RewardRouter to V2
/// @dev Handles data migration and config initialization
contract RewardRouterMigration is RewardRouter {
  constructor(
    address wmito,
    address gmMito,
    address collateralOracle,
    address epochFeeder,
    address rewardDistributor,
    address validatorManager
  )
    RewardRouter(wmito, gmMito, collateralOracle, epochFeeder, rewardDistributor, validatorManager)
  { }

  error LengthMismatch();
  error NoEpochs();

  /// @notice Migrate validator configurations
  /// @dev Updates existing configs or creates new one if none exists
  /// @param validators Array of validator addresses to migrate
  /// @param newOperators Array of new operator addresses (one per validator)
  /// @param newDefaultRecipients Array of default recipient addresses (one per validator)
  /// @param newFeeRecipients Array of fee recipient addresses (one per validator)
  function migrate(
    address[] calldata validators,
    address[] calldata newOperators,
    address[] calldata newDefaultRecipients,
    address[] calldata newFeeRecipients
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(validators.length == newOperators.length, LengthMismatch());
    require(validators.length == newDefaultRecipients.length, LengthMismatch());
    require(validators.length == newFeeRecipients.length, LengthMismatch());

    LegacyStorage storage $legacy = _getLegacyStorage();
    Storage storage $ = _getStorage();

    for (uint256 i = 0; i < validators.length; i++) {
      address validator = validators[i];
      address newOperator = newOperators[i];
      address newDefaultRecipient = newDefaultRecipients[i];
      address newFeeRecipient = newFeeRecipients[i];

      uint256[] storage epochs = $legacy.configEpochs[validator];
      require(epochs.length > 0, NoEpochs());

      // Update existing configs
      for (uint256 j = 0; j < epochs.length; j++) {
        uint256 epoch = epochs[j];
        LegacyDistributionConfig storage legacyConfig =
          $legacy.distributionConfigs[validator][epoch];

        DistributionConfig storage newConfig = $.distributionConfigs[validator][epoch];
        newConfig.operator = newOperator;
        newConfig.defaultRecipient = newDefaultRecipient;
        newConfig.feeRecipient = newFeeRecipient;
        newConfig.commissionRate = legacyConfig.commissionRate;

        // Copy targets from legacy config
        delete newConfig.targets;
        for (uint256 k = 0; k < legacyConfig.targets.length; k++) {
          newConfig.targets.push(legacyConfig.targets[k]);
        }
      }
    }
  }

  // === Legacy Storage Access ===

  struct LegacyEpochReward {
    uint256 totalGmMito;
    uint256 totalTWAB;
    bool finalized;
  }

  struct LegacyDistributionConfig {
    address[] targets;
    uint256 commissionRate;
  }

  /// @custom:storage-location erc7201:munja.storage.RewardRouter
  struct LegacyStorage {
    mapping(address => mapping(uint256 => LegacyEpochReward)) epochRewards;
    mapping(address => mapping(address => mapping(uint256 => uint256))) vaultClaimed;
    mapping(address => uint256) lastFinalizedEpoch;
    mapping(address => mapping(uint256 => LegacyDistributionConfig)) distributionConfigs;
    mapping(address => uint256[]) configEpochs;
    bytes32 __deprecated_slot;
  }

  // Use same slot as main storage to access data
  bytes32 private constant _LEGACY_STORAGE_SLOT =
    0xfa2183a4b9e35594495ef24f5060c5bba566c21a062a2b524b653f03c859a700;

  function _getLegacyStorage() internal pure returns (LegacyStorage storage $) {
    assembly {
      $.slot := _LEGACY_STORAGE_SLOT
    }
  }
}
