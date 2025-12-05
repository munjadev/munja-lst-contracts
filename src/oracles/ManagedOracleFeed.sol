// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {
  AccessControlEnumerableUpgradeable
} from '@ozu/access/extensions/AccessControlEnumerableUpgradeable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';

import { SafeCast } from '@oz/utils/math/SafeCast.sol';
import { Checkpoints } from '@oz/utils/structs/Checkpoints.sol';
import { EnumerableSet } from '@oz/utils/structs/EnumerableSet.sol';

import { ERC7201Utils } from '@mitosis/lib/ERC7201Utils.sol';

import { ICollateralOracleFeed } from '../interfaces/oracles/ICollateralOracleFeed.sol';
import { Versioned } from '../libs/Versioned.sol';
import { CollateralOracleStorage } from './CollateralOracleStorage.sol';

contract ManagedOracleFeed is
  ICollateralOracleFeed,
  CollateralOracleStorage,
  AccessControlEnumerableUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  using SafeCast for uint256;
  using Checkpoints for Checkpoints.Trace208;
  using ERC7201Utils for string;
  using EnumerableSet for EnumerableSet.AddressSet;

  constructor() {
    _disableInitializers();
  }

  /// @dev keccak256('feeder');
  bytes32 public constant FEEDER_ROLE =
    0xe6e69a693a749cd395954f571a1f928763ac28c5ebd853c3b42503bef838bfd1;

  function initialize(
    address initialOwner
  ) external initializer {
    __AccessControl_init();
    __AccessControlEnumerable_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
  }

  function _authorizeUpgrade(
    address
  ) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

  function feedType() external pure override returns (FeedType) {
    return FeedType.Managed;
  }

  function getValidator(
    uint48 timestamp,
    address validator
  ) external view returns (Validator memory) {
    return _getValidator(_getOracleStorage(), timestamp, validator);
  }

  function getValidatorAddressCount() external view returns (uint256) {
    return _getValidatorAddressCount(_getOracleStorage());
  }

  function getValidatorAddressByIndex(
    uint256 index
  ) external view returns (address) {
    return _getValidatorAddressByIndex(_getOracleStorage(), index);
  }

  function getCollateralOwnership(
    uint48 timestamp,
    address validator,
    address owner
  ) external view returns (CollateralOwnership memory) {
    return _getCollateralOwnership(_getOracleStorage(), timestamp, validator, owner);
  }

  function getCollateralOwnerships(
    uint48 timestamp,
    address validator
  ) external view returns (CollateralOwnership[] memory) {
    return _getCollateralOwnerships(_getOracleStorage(), timestamp, validator);
  }

  function getCollateralOwnershipTWAB(
    uint48 startTime,
    uint48 endTime,
    address validator,
    address owner
  ) external view returns (uint256) {
    return _getCollateralOwnershipTWAB(_getOracleStorage(), startTime, endTime, validator, owner);
  }

  function getCollateralOwnershipsTWAB(
    uint48 startTime,
    uint48 endTime,
    address validator
  ) external view returns (CollateralOwnership[] memory) {
    return _getCollateralOwnershipsTWAB(_getOracleStorage(), startTime, endTime, validator);
  }

  function getHistoricalOwners(
    address validator
  ) external view returns (address[] memory) {
    return _getHistoricalOwners(_getOracleStorage(), validator);
  }

  function getHistoricalOwnersCount(
    address validator
  ) external view returns (uint256) {
    return _getHistoricalOwnersCount(_getOracleStorage(), validator);
  }

  function getTotalTWAB(
    address validator,
    uint48 startTime,
    uint48 endTime
  ) external view returns (uint256) {
    return _getTotalTWAB(_getOracleStorage(), startTime, endTime, validator);
  }

  function getLastFeedTimestamp(
    address validator
  ) external view returns (uint48) {
    return _getLastFeedTimestamp(_getOracleStorage(), validator);
  }

  function feed(
    uint48 targetTimestamp,
    address valAddr,
    Validator calldata validator,
    CollateralOwnership[] calldata ownerships
  ) external onlyRole(FEEDER_ROLE) {
    _storeFeedData(
      _getOracleStorage(),
      targetTimestamp,
      valAddr,
      _toStorageData(validator),
      _toStorageData(ownerships)
    );

    emit FeedUpdated(targetTimestamp, valAddr, ownerships.length, '{"type":"managed"}');
  }
}
