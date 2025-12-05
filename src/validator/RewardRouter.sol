// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;
import { WETH } from '@solady/tokens/WETH.sol';
import { FixedPointMathLib } from '@solady/utils/FixedPointMathLib.sol';
import { SafeTransferLib } from '@solady/utils/SafeTransferLib.sol';

import { IERC20 } from '@oz/token/ERC20/IERC20.sol';
import { Math } from '@oz/utils/math/Math.sol';

import {
  AccessControlEnumerableUpgradeable
} from '@ozu/access/extensions/AccessControlEnumerableUpgradeable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';

import { IGovMITO } from '@mitosis/interfaces/hub/IGovMITO.sol';
import { IEpochFeeder } from '@mitosis/interfaces/hub/validator/IEpochFeeder.sol';
import { IValidatorManager } from '@mitosis/interfaces/hub/validator/IValidatorManager.sol';
import {
  IValidatorRewardDistributor
} from '@mitosis/interfaces/hub/validator/IValidatorRewardDistributor.sol';

import { ICollateralOracleFeed } from '../interfaces/oracles/ICollateralOracleFeed.sol';
import { IRewardRouter } from '../interfaces/validator/IRewardRouter.sol';
import { IgmMITO } from '../interfaces/vaults/IgmMITO.sol';
import { Versioned } from '../libs/Versioned.sol';

/// @title RewardRouter
/// @notice Routes validator rewards based on collateral ownership via oracle feed
/// @dev Supports multi-collateral ownership and distributes rewards proportionally
contract RewardRouter is
  IRewardRouter,
  AccessControlEnumerableUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  using Math for uint256;

  uint256 private constant MAX_BPS = 10000;

  struct EpochReward {
    uint256 totalGmMito; // Total gmMito rewards for this epoch
    uint256 totalTWAB; // Total TWAB for this epoch (cached)
    bool finalized; // Whether epoch is finalized
  }

  /// @custom:storage-location erc7201:munja.storage.RewardRouter
  struct Storage {
    // validator => epoch => EpochReward
    mapping(address => mapping(uint256 => EpochReward)) epochRewards;
    // validator => vault => epoch => claimed amount (0 = not claimed)
    mapping(address => mapping(address => mapping(uint256 => uint256))) vaultClaimed;
    // validator => last finalized epoch
    mapping(address => uint256) lastFinalizedEpoch;
    // validator => epoch => distribution config (stored as packed struct)
    mapping(address => mapping(uint256 => DistributionConfig)) distributionConfigs;
    // validator => sorted array of epochs where config was set
    mapping(address => uint256[]) configEpochs;
    // DEPRECATED: Previously feeRecipient (address) - reserved for future use
    bytes32 __deprecated_slot;
  }

  // keccak256(abi.encode(uint256(keccak256("munja.storage.RewardRouter")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _STORAGE_SLOT =
    0xfa2183a4b9e35594495ef24f5060c5bba566c21a062a2b524b653f03c859a700;

  function _getStorage() internal pure returns (Storage storage $) {
    assembly {
      $.slot := _STORAGE_SLOT
    }
  }

  // keccak256(abi.encodePacked("operator"))
  bytes32 public constant OPERATOR_ROLE =
    0x46a52cf33029de9f84853745a87af28464c80bf0346df1b32e205fc73319f622;

  IGovMITO public immutable GMITO;
  IgmMITO public immutable GM_MITO;
  WETH public immutable WMITO;
  ICollateralOracleFeed public immutable COLLATERAL_ORACLE;
  IValidatorRewardDistributor public immutable REWARD_DISTRIBUTOR;
  IEpochFeeder public immutable EPOCH_FEEDER;
  IValidatorManager public immutable VALIDATOR_MANAGER;

  constructor(
    address wmito,
    address gmMito,
    address collateralOracle,
    address epochFeeder,
    address rewardDistributor,
    address validatorManager
  ) {
    require(wmito != address(0), ZeroAddress());
    require(gmMito != address(0), ZeroAddress());
    require(collateralOracle != address(0), ZeroAddress());
    require(epochFeeder != address(0), ZeroAddress());
    require(rewardDistributor != address(0), ZeroAddress());
    require(validatorManager != address(0), ZeroAddress());

    WMITO = WETH(payable(wmito));
    GM_MITO = IgmMITO(gmMito);
    COLLATERAL_ORACLE = ICollateralOracleFeed(collateralOracle);
    EPOCH_FEEDER = IEpochFeeder(epochFeeder);
    REWARD_DISTRIBUTOR = IValidatorRewardDistributor(rewardDistributor);
    VALIDATOR_MANAGER = IValidatorManager(validatorManager);

    // Get GMITO from reward distributor
    GMITO = REWARD_DISTRIBUTOR.govMITOEmission().govMITO();

    _disableInitializers();
  }

  function initialize(
    address initialOwner
  ) external initializer {
    require(initialOwner != address(0), ZeroAddress());

    __AccessControlEnumerable_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
  }

  receive() external payable {
    if (_msgSender() != address(WMITO)) WMITO.deposit{ value: msg.value }();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // OPERATOR_ROLE Functions (Global Operator)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @inheritdoc IRewardRouter
  function distributeRewards(
    address validator
  ) external onlyRole(OPERATOR_ROLE) returns (uint256 gmMitoAmount) {
    require(validator != address(0), ZeroAddress());

    address[] memory validators = new address[](1);
    validators[0] = validator;
    gmMitoAmount = GM_MITO.operatorMint(validators, address(this));
    require(gmMitoAmount > 0, NoRewards());

    emit RewardDistributed(validator, gmMitoAmount);
  }

  /// @inheritdoc IRewardRouter
  function finalizeEpoch(
    uint256 epoch,
    address validator
  ) external onlyRole(OPERATOR_ROLE) returns (uint256 totalGmMito) {
    require(validator != address(0), ZeroAddress());
    require(epoch > 0, InvalidEpoch());

    Storage storage $ = _getStorage();
    EpochReward storage reward = $.epochRewards[validator][epoch];

    require(!reward.finalized, EpochAlreadyFinalized());

    uint256 lastFinalized = $.lastFinalizedEpoch[validator];
    require(epoch == lastFinalized + 1 || lastFinalized == 0, InvalidEpoch());

    uint48 epochStartTime = EPOCH_FEEDER.timeAt(epoch);
    uint48 epochEndTime = EPOCH_FEEDER.timeAt(epoch + 1);

    address[] memory validators = new address[](1);
    validators[0] = validator;
    totalGmMito = GM_MITO.operatorMint(validators, address(this));
    require(totalGmMito > 0, NoRewards());

    uint256 totalTWAB = COLLATERAL_ORACLE.getTotalTWAB(validator, epochStartTime, epochEndTime);
    require(totalTWAB > 0, NoRewards());

    reward.totalGmMito = totalGmMito;
    reward.totalTWAB = totalTWAB;
    reward.finalized = true;
    $.lastFinalizedEpoch[validator] = epoch;

    emit EpochRewardsFinalized(epoch, validator, totalGmMito, totalTWAB);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Config Operator Functions (Per-Validator Operator)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @dev Check if msg.sender is authorized to manage config for the validator
  function _checkConfigAuthorization(
    Storage storage $,
    address validator,
    uint256 epoch
  ) internal view {
    // 1. Check if ADMIN
    if (hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) return;

    // 2. Check if current config operator
    DistributionConfig storage currentConfig = _getApplicableConfigStorage($, validator, epoch);
    if (currentConfig.operator == _msgSender()) return;

    // 3. Check if actual validator operator (from ValidatorManager)
    // This allows the true operator (ValidatorController) to take control even if config is not set
    address actualOperator = VALIDATOR_MANAGER.validatorInfo(validator).operator;
    if (actualOperator == _msgSender()) return;

    revert Unauthorized();
  }

  /// @inheritdoc IRewardRouter
  function setDistributionConfig(
    address validator,
    uint256 startEpoch,
    DistributionConfig calldata config
  ) external {
    require(validator != address(0), ZeroAddress());
    require(config.commissionRate <= MAX_BPS, InvalidCommissionRate(config.commissionRate));

    Storage storage $ = _getStorage();

    _checkConfigAuthorization($, validator, startEpoch);

    // Validate epoch order
    uint256[] storage epochs = $.configEpochs[validator];
    if (epochs.length > 0) {
      require(
        startEpoch >= epochs[epochs.length - 1],
        InvalidEpochOrder(startEpoch, epochs[epochs.length - 1])
      );
    }

    // Store config
    DistributionConfig storage configStorage = $.distributionConfigs[validator][startEpoch];
    configStorage.operator = config.operator;
    configStorage.defaultRecipient = config.defaultRecipient;
    configStorage.feeRecipient = config.feeRecipient;
    configStorage.commissionRate = config.commissionRate;

    // Copy targets array (clear existing and push new)
    delete configStorage.targets;
    for (uint256 i = 0; i < config.targets.length; i++) {
      configStorage.targets.push(config.targets[i]);
    }

    // Add to configEpochs if not exists
    if (epochs.length == 0 || epochs[epochs.length - 1] != startEpoch) epochs.push(startEpoch);

    emit DistributionConfigSet(validator, startEpoch, config);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Claim Functions
  // ═══════════════════════════════════════════════════════════════════════════

  /// @inheritdoc IRewardRouter
  /// @dev For target vaults: vault calls directly
  function claimRewards(
    address validator,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external returns (uint256 totalClaimed) {
    require(validator != address(0), ZeroAddress());
    require(fromEpoch > 0 && toEpoch >= fromEpoch, InvalidEpoch());

    address vault = _msgSender();
    Storage storage $ = _getStorage();

    for (uint256 epoch = fromEpoch; epoch <= toEpoch; epoch++) {
      // Check if vault is a target for this epoch
      DistributionConfig storage config = _getApplicableConfigStorage($, validator, epoch);
      require(_isVaultTarget(config.targets, vault), NotTarget());
      totalClaimed += _claimSingleEpoch($, epoch, validator, vault);
    }

    if (totalClaimed > 0) SafeTransferLib.safeTransfer(address(GM_MITO), vault, totalClaimed);
  }

  /// @inheritdoc IRewardRouter
  /// @dev For non-target vaults: config.operator or defaultRecipient claims
  /// @dev Rewards are sent to each epoch's defaultRecipient (per-epoch transfer)
  function claimForNonTargets(
    address validator,
    address[] calldata vaults,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external returns (uint256 totalClaimed) {
    require(validator != address(0), ZeroAddress());
    require(fromEpoch > 0 && toEpoch >= fromEpoch, InvalidEpoch());

    Storage storage $ = _getStorage();
    address caller = _msgSender();

    // Check global operator first
    bool isGlobalOperator = hasRole(OPERATOR_ROLE, caller);

    for (uint256 epoch = fromEpoch; epoch <= toEpoch; epoch++) {
      totalClaimed += _claimNonTargetsForEpoch(
        $, validator, vaults, epoch, caller, isGlobalOperator
      );
    }
  }

  /// @dev Internal helper to claim non-targets for a single epoch
  /// @dev Transfers rewards directly to epoch's defaultRecipient
  function _claimNonTargetsForEpoch(
    Storage storage $,
    address validator,
    address[] calldata vaults,
    uint256 epoch,
    address caller,
    bool isGlobalOperator
  ) private returns (uint256 epochClaimed) {
    DistributionConfig storage config = _getApplicableConfigStorage($, validator, epoch);

    // Caller must be config.operator or defaultRecipient OR global operator
    require(
      isGlobalOperator || caller == config.operator || caller == config.defaultRecipient,
      Unauthorized()
    );

    address recipient = config.defaultRecipient;

    for (uint256 i = 0; i < vaults.length; i++) {
      // Skip targets - they should claim directly
      if (_isVaultTarget(config.targets, vaults[i])) continue;
      epochClaimed += _claimSingleEpochForNonTarget($, epoch, validator, vaults[i], recipient);
    }

    // Transfer rewards for this epoch to its recipient
    if (epochClaimed > 0) {
      SafeTransferLib.safeTransfer(address(GM_MITO), recipient, epochClaimed);
    }
  }

  /// @notice Internal function to claim a single epoch for target vault
  function _claimSingleEpoch(
    Storage storage $,
    uint256 epoch,
    address validator,
    address vault
  ) internal returns (uint256 gmMitoAmount) {
    if (!$.epochRewards[validator][epoch].finalized || $.vaultClaimed[validator][vault][epoch] > 0) return 0;

    uint256 vaultTWAB = COLLATERAL_ORACLE.getCollateralOwnershipTWAB(
      EPOCH_FEEDER.timeAt(epoch), EPOCH_FEEDER.timeAt(epoch + 1), validator, vault
    );

    if (vaultTWAB == 0) return 0;

    uint256 grossShare;
    {
      EpochReward storage reward = $.epochRewards[validator][epoch];
      grossShare = FixedPointMathLib.fullMulDiv(reward.totalGmMito, vaultTWAB, reward.totalTWAB);
    }

    gmMitoAmount = grossShare;

    if (grossShare > 0) {
      $.vaultClaimed[validator][vault][epoch] = grossShare;
      gmMitoAmount -= _processFee($, validator, epoch, vault, grossShare);
      emit VaultShareClaimed(epoch, validator, vault, vaultTWAB, gmMitoAmount);
    }
  }

  /// @notice Internal function to claim a single epoch for non-target vault
  function _claimSingleEpochForNonTarget(
    Storage storage $,
    uint256 epoch,
    address validator,
    address vault,
    address recipient
  ) internal returns (uint256 gmMitoAmount) {
    if (!$.epochRewards[validator][epoch].finalized || $.vaultClaimed[validator][vault][epoch] > 0) return 0;

    uint256 vaultTWAB = COLLATERAL_ORACLE.getCollateralOwnershipTWAB(
      EPOCH_FEEDER.timeAt(epoch), EPOCH_FEEDER.timeAt(epoch + 1), validator, vault
    );

    if (vaultTWAB == 0) return 0;

    EpochReward storage reward = $.epochRewards[validator][epoch];
    gmMitoAmount = FixedPointMathLib.fullMulDiv(reward.totalGmMito, vaultTWAB, reward.totalTWAB);

    if (gmMitoAmount > 0) {
      $.vaultClaimed[validator][vault][epoch] = gmMitoAmount;
      // No fee for non-target vaults - full amount goes to defaultRecipient
      emit NonTargetRewardsClaimed(epoch, validator, vault, recipient, gmMitoAmount);
    }
  }

  /// @notice Internal function to calculate and process fee
  function _processFee(
    Storage storage $,
    address validator,
    uint256 epoch,
    address vault,
    uint256 grossShare
  ) private returns (uint256 fee) {
    DistributionConfig storage config = _getApplicableConfigStorage($, validator, epoch);
    address recipient = config.feeRecipient;

    if (recipient == address(0) || config.commissionRate == 0) return 0;

    fee = FixedPointMathLib.fullMulDiv(grossShare, config.commissionRate, MAX_BPS);

    if (fee > 0) {
      SafeTransferLib.safeTransfer(address(GM_MITO), recipient, fee);
      emit FeeTaken(epoch, validator, vault, fee);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // View Functions
  // ═══════════════════════════════════════════════════════════════════════════

  /// @inheritdoc IRewardRouter
  function getClaimableRewards(
    address validator,
    address vault,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external view returns (uint256 totalClaimable) {
    require(validator != address(0), ZeroAddress());
    require(vault != address(0), ZeroAddress());
    require(fromEpoch > 0 && toEpoch >= fromEpoch, InvalidEpoch());
    Storage storage $ = _getStorage();

    for (uint256 epoch = fromEpoch; epoch <= toEpoch; epoch++) {
      totalClaimable += _calculateClaimableForEpoch($, validator, vault, epoch);
    }
  }

  function _calculateClaimableForEpoch(
    Storage storage $,
    address validator,
    address vault,
    uint256 epoch
  ) internal view returns (uint256) {
    // Already claimed
    if ($.vaultClaimed[validator][vault][epoch] > 0) return 0;

    // Check vaultTWAB first - if 0, no rewards regardless of finalization
    uint256 vaultTWAB = COLLATERAL_ORACLE.getCollateralOwnershipTWAB(
      EPOCH_FEEDER.timeAt(epoch), EPOCH_FEEDER.timeAt(epoch + 1), validator, vault
    );
    if (vaultTWAB == 0) return 0;

    // For non-zero TWAB, need finalization to calculate actual rewards
    EpochReward storage reward = $.epochRewards[validator][epoch];
    if (!reward.finalized) return 0;

    uint256 share = FixedPointMathLib.fullMulDiv(reward.totalGmMito, vaultTWAB, reward.totalTWAB);

    // Apply fee only for target vaults
    DistributionConfig storage config = _getApplicableConfigStorage($, validator, epoch);
    if (_isVaultTarget(config.targets, vault)) {
      if (config.feeRecipient != address(0) && config.commissionRate > 0) {
        uint256 fee = FixedPointMathLib.fullMulDiv(share, config.commissionRate, MAX_BPS);
        share -= fee;
      }
    }
    return share;
  }

  /// @inheritdoc IRewardRouter
  function gmMitoBalance() external view returns (uint256) {
    return IERC20(address(GM_MITO)).balanceOf(address(this));
  }

  /// @inheritdoc IRewardRouter
  function getEpochReward(
    uint256 epoch,
    address validator
  ) external view returns (uint256 totalGmMito, uint256 totalTWAB, bool finalized) {
    EpochReward storage reward = _getStorage().epochRewards[validator][epoch];
    return (reward.totalGmMito, reward.totalTWAB, reward.finalized);
  }

  /// @inheritdoc IRewardRouter
  function getVaultClaimed(
    uint256 epoch,
    address validator,
    address vault
  ) external view returns (uint256) {
    return _getStorage().vaultClaimed[validator][vault][epoch];
  }

  /// @inheritdoc IRewardRouter
  function currentEpoch() external view returns (uint256) {
    return EPOCH_FEEDER.epoch();
  }

  /// @inheritdoc IRewardRouter
  function getLastFinalizedEpoch(
    address validator
  ) external view returns (uint256) {
    return _getStorage().lastFinalizedEpoch[validator];
  }

  /// @inheritdoc IRewardRouter
  function getDistributionConfig(
    address validator,
    uint256 epoch
  ) external view returns (DistributionConfig memory config) {
    Storage storage $ = _getStorage();
    DistributionConfig storage configStorage = $.distributionConfigs[validator][epoch];
    config.targets = configStorage.targets;
    config.operator = configStorage.operator;
    config.defaultRecipient = configStorage.defaultRecipient;
    config.feeRecipient = configStorage.feeRecipient;
    config.commissionRate = configStorage.commissionRate;
  }

  /// @inheritdoc IRewardRouter
  function getApplicableConfig(
    address validator,
    uint256 epoch
  ) external view returns (DistributionConfig memory config) {
    Storage storage $ = _getStorage();
    DistributionConfig storage configStorage = _getApplicableConfigStorage($, validator, epoch);
    config.targets = configStorage.targets;
    config.operator = configStorage.operator;
    config.defaultRecipient = configStorage.defaultRecipient;
    config.feeRecipient = configStorage.feeRecipient;
    config.commissionRate = configStorage.commissionRate;
  }

  /// @inheritdoc IRewardRouter
  function getConfigEpochsRange(
    address validator,
    uint256 startIndex,
    uint256 endIndex
  ) external view returns (uint256[] memory epochs) {
    uint256[] storage allEpochs = _getStorage().configEpochs[validator];
    uint256 length = allEpochs.length;

    if (startIndex >= length) return new uint256[](0);
    if (endIndex > length) endIndex = length;
    if (endIndex <= startIndex) return new uint256[](0);

    uint256 rangeLength = endIndex - startIndex;
    epochs = new uint256[](rangeLength);

    for (uint256 i = 0; i < rangeLength; i++) {
      epochs[i] = allEpochs[startIndex + i];
    }
  }

  /// @inheritdoc IRewardRouter
  function getConfigEpochsCount(
    address validator
  ) external view returns (uint256) {
    return _getStorage().configEpochs[validator].length;
  }

  /// @inheritdoc IRewardRouter
  function isTarget(
    address validator,
    address vault,
    uint256 epoch
  ) external view returns (bool) {
    Storage storage $ = _getStorage();
    DistributionConfig storage config = _getApplicableConfigStorage($, validator, epoch);
    return _isVaultTarget(config.targets, vault);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Find the applicable config storage for an epoch
  function _getApplicableConfigStorage(
    Storage storage $,
    address validator,
    uint256 epoch
  ) internal view returns (DistributionConfig storage) {
    uint256 configEpoch = _findApplicableEpoch($, validator, epoch);
    return $.distributionConfigs[validator][configEpoch];
  }

  /// @notice Find the applicable epoch index using binary search
  function _findApplicableEpochIndex(
    Storage storage $,
    address validator,
    uint256 epoch
  ) internal view returns (uint256) {
    uint256[] storage epochs = $.configEpochs[validator];
    if (epochs.length == 0) return 0;
    if (epochs[0] > epoch) return 0;

    uint256 low = 0;
    uint256 high = epochs.length;

    while (low < high) {
      uint256 mid = Math.average(low, high);
      if (epochs[mid] > epoch) high = mid;
      else low = mid + 1;
    }

    return low;
  }

  /// @notice Find the applicable epoch number
  function _findApplicableEpoch(
    Storage storage $,
    address validator,
    uint256 epoch
  ) internal view returns (uint256) {
    uint256[] storage epochs = $.configEpochs[validator];
    if (epochs.length == 0) return 0;
    if (epochs[0] > epoch) return 0;

    uint256 idx = _findApplicableEpochIndex($, validator, epoch);
    return idx > 0 ? epochs[idx - 1] : 0;
  }

  /// @notice Check if vault is in targets array for the applicable epoch
  function _isVaultTarget(
    address[] storage targets,
    address vault
  ) private view returns (bool) {
    uint256 len = targets.length;
    for (uint256 i = 0; i < len; ++i) {
      if (targets[i] == vault) return true;
    }
    return false;
  }

  function _authorizeUpgrade(
    address
  ) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}

