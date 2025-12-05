// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;
import { OwnableUpgradeable } from '@ozu/access/OwnableUpgradeable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';

import { IValidatorManager } from '@mitosis/interfaces/hub/validator/IValidatorManager.sol';

import { IRewardRouter } from '../interfaces/validator/IRewardRouter.sol';
import { IValidatorController } from '../interfaces/validator/IValidatorController.sol';
import { Versioned } from '../libs/Versioned.sol';

contract ValidatorController is
  IValidatorController,
  OwnableUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  /// @custom:storage-location erc7201:munja.storage.ValidatorController
  struct ValidatorControllerStorage {
    address valAddr;
    ContractStatus status;
  }

  // keccak256(abi.encode(uint256(keccak256("munja.storage.ValidatorController")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _STORAGE_SLOT =
    0xdc8da22dbeabcde1ac8b88d797c47c6fc49f10c300356e0f23ffb2ee3f00fc00;

  function _getStorage() internal pure returns (ValidatorControllerStorage storage $) {
    assembly {
      $.slot := _STORAGE_SLOT
    }
  }

  address public immutable REWARD_MANAGER;
  IValidatorManager public immutable VALIDATOR_MANAGER;

  modifier onlyEntered() {
    _onlyEntered();
    _;
  }

  constructor(
    address rewardManager_,
    address validatorManager_
  ) {
    _disableInitializers();

    REWARD_MANAGER = rewardManager_;
    VALIDATOR_MANAGER = IValidatorManager(validatorManager_);
  }

  function initialize(
    address valAddr,
    address initialOwner
  ) external initializer {
    __Ownable_init(initialOwner);
    __UUPSUpgradeable_init();

    ValidatorControllerStorage storage $ = _getStorage();

    $.valAddr = valAddr;
    $.status = ContractStatus.Initialized;

    emit Initialized(valAddr, initialOwner);
  }

  function _authorizeUpgrade(
    address
  ) internal override onlyOwner { }

  function _onlyEntered() internal view {
    require(_getStorage().status == ContractStatus.Entered, NotEntered());
  }

  function validator() external view returns (address) {
    return _getStorage().valAddr;
  }

  function contractStatus() external view returns (ContractStatus) {
    return _getStorage().status;
  }

  function rewardManager() external view returns (address) {
    return REWARD_MANAGER;
  }

  function validatorManager() external view returns (address) {
    return address(VALIDATOR_MANAGER);
  }

  /// @dev Ensure operator transferred authority to this contract before calling
  function enter(
    address[] calldata initialTargets,
    address defaultRecipient,
    address feeRecipient
  ) external onlyOwner {
    ValidatorControllerStorage storage $ = _getStorage();
    require($.status == ContractStatus.Initialized, InvalidStatus());

    address valAddr = $.valAddr;
    address operator = VALIDATOR_MANAGER.validatorInfo(valAddr).operator;
    require(operator == address(this), Unauthorized());

    VALIDATOR_MANAGER.updateRewardManager(valAddr, REWARD_MANAGER);

    // Initialize Distribution Config in RewardRouter
    IRewardRouter.DistributionConfig memory config = IRewardRouter.DistributionConfig({
      targets: initialTargets,
      operator: address(this), // This contract becomes the config operator
      defaultRecipient: defaultRecipient,
      feeRecipient: feeRecipient,
      commissionRate: 0 // Initial commission rate is 0
    });

    IRewardRouter(REWARD_MANAGER)
      .setDistributionConfig(valAddr, IRewardRouter(REWARD_MANAGER).currentEpoch(), config);

    $.status = ContractStatus.Entered;
    emit Entered(valAddr);
  }

  /// @dev Exit authority to original owner
  /// @notice RewardManager is NOT changed on exit - it remains forced to REWARD_MANAGER
  function exit(
    address to
  ) external onlyOwner onlyEntered {
    ValidatorControllerStorage storage $ = _getStorage();
    address valAddr = $.valAddr;

    VALIDATOR_MANAGER.updateOperator(valAddr, to);
    // Note: RewardManager remains forced to immutable REWARD_MANAGER
    // This prevents operators from changing reward distribution

    $.status = ContractStatus.Exited;
    emit Exited(valAddr, to, REWARD_MANAGER);
  }

  function unjail() external payable onlyOwner onlyEntered {
    address valAddr = _getStorage().valAddr;
    VALIDATOR_MANAGER.unjailValidator{ value: msg.value }(valAddr);
  }

  /// @notice Update validator metadata
  /// @dev Only owner can update metadata
  function updateMetadata(
    bytes calldata metadata
  ) external onlyOwner onlyEntered {
    address valAddr = _getStorage().valAddr;
    VALIDATOR_MANAGER.updateMetadata(valAddr, metadata);
  }

  /// @notice Update validator reward configuration
  /// @dev Only owner can update reward config
  function updateRewardConfig(
    IValidatorManager.UpdateRewardConfigRequest calldata request
  ) external onlyOwner onlyEntered {
    address valAddr = _getStorage().valAddr;
    VALIDATOR_MANAGER.updateRewardConfig(valAddr, request);
  }

  /// @notice Set permitted collateral owner
  /// @dev Only owner can manage collateral owner permissions
  function setPermittedCollateralOwner(
    address collateralOwner,
    bool isPermitted
  ) external onlyOwner onlyEntered {
    address valAddr = _getStorage().valAddr;
    VALIDATOR_MANAGER.setPermittedCollateralOwner(valAddr, collateralOwner, isPermitted);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RewardRouter Config Management (Forwarding)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @inheritdoc IValidatorController
  function setRewardDistributionConfig(
    uint256 startEpoch,
    IRewardRouter.DistributionConfig calldata config
  ) external onlyOwner onlyEntered {
    // Force operator to be this contract to maintain control
    require(config.operator == address(this), InvalidOperator());
    IRewardRouter(REWARD_MANAGER).setDistributionConfig(_getStorage().valAddr, startEpoch, config);
  }
}
