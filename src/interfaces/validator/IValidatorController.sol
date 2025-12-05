// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;
import { IValidatorManager } from '@mitosis/interfaces/hub/validator/IValidatorManager.sol';

import { IRewardRouter } from './IRewardRouter.sol';

/// @title IValidatorController
/// @notice Interface for controlling validator operations and managing authority
interface IValidatorController {
  enum ContractStatus {
    None,
    Initialized,
    Entered,
    Exited
  }

  /// @notice Emitted when the controller is initialized
  /// @param valAddr Validator address
  /// @param owner Owner address
  event Initialized(address indexed valAddr, address indexed owner);

  /// @notice Emitted when authority is entered
  /// @param valAddr Validator address
  event Entered(address indexed valAddr);

  /// @notice Emitted when authority is exited
  /// @param valAddr Validator address
  /// @param to New operator address
  /// @param rewardManager Reward manager address
  event Exited(address indexed valAddr, address indexed to, address indexed rewardManager);

  error NonOperator();
  error NotFinalized();
  error Unauthorized();
  error NotEntered();
  error AlreadyEntered();
  error InvalidStatus();
  error InvalidOperator();

  /// @notice Get reward manager address
  /// @return Reward manager address
  function rewardManager() external view returns (address);

  /// @notice Get validator manager address
  /// @return Validator manager address
  function validatorManager() external view returns (address);

  /// @notice Enter authority, set reward manager, and initialize distribution config
  /// @param initialTargets Initial target vaults
  /// @param defaultRecipient Initial default recipient
  /// @param feeRecipient Initial fee recipient for commission
  function enter(
    address[] calldata initialTargets,
    address defaultRecipient,
    address feeRecipient
  ) external;

  /// @notice Exit authority to original owner
  /// @param to Address to transfer operator to
  function exit(
    address to
  ) external;

  /// @notice Unjail the validator
  function unjail() external payable;

  /// @notice Update validator metadata
  /// @param metadata New metadata
  function updateMetadata(
    bytes calldata metadata
  ) external;

  /// @notice Update validator reward configuration
  /// @param request Reward config request
  function updateRewardConfig(
    IValidatorManager.UpdateRewardConfigRequest calldata request
  ) external;

  /// @notice Set permitted collateral owner
  /// @param collateralOwner Collateral owner address
  /// @param isPermitted Whether the owner is permitted
  function setPermittedCollateralOwner(
    address collateralOwner,
    bool isPermitted
  ) external;

  /// @notice Set reward distribution configuration in RewardRouter
  /// @param startEpoch The epoch from which this config applies
  /// @param config The distribution configuration
  function setRewardDistributionConfig(
    uint256 startEpoch,
    IRewardRouter.DistributionConfig calldata config
  ) external;

  /// @notice Get validator address
  /// @return Validator address
  function validator() external view returns (address);

  /// @notice Get contract status
  /// @return Current status
  function contractStatus() external view returns (ContractStatus);
}
