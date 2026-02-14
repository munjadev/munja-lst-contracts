// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {
  AccessControlEnumerableUpgradeable
} from '@ozu/access/extensions/AccessControlEnumerableUpgradeable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';

import { SafeCast } from '@oz/utils/math/SafeCast.sol';
import { Checkpoints } from '@oz/utils/structs/Checkpoints.sol';
import { EnumerableSet } from '@oz/utils/structs/EnumerableSet.sol';
import { Time } from '@oz/utils/types/Time.sol';

import { ISP1Verifier } from '@sp1/ISP1Verifier.sol';

import { LibString } from '@solady/utils/LibString.sol';

import { ICollateralOracleFeed } from '../interfaces/oracles/ICollateralOracleFeed.sol';
import { LibZkOracleFeed } from '../libs/LibZkOracleFeed.sol';
import { Versioned } from '../libs/Versioned.sol';
import { CollateralOracleStorage } from './CollateralOracleStorage.sol';

contract ZkOracleFeed is
  ICollateralOracleFeed,
  CollateralOracleStorage,
  AccessControlEnumerableUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  using SafeCast for uint256;
  using LibString for uint256;
  using Checkpoints for Checkpoints.Trace208;
  using EnumerableSet for EnumerableSet.AddressSet;

  error AppHashMismatch();
  error EIP4788Timeout();
  error ZeroAddress();
  error ZeroVKey();

  event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
  event ProgramVKeyUpdated(bytes32 indexed oldVKey, bytes32 indexed newVKey);

  /// @dev keccak256('feeder');
  bytes32 public constant FEEDER_ROLE =
    0xe6e69a693a749cd395954f571a1f928763ac28c5ebd853c3b42503bef838bfd1;

  uint256 public constant EIP4788_TIMEOUT = 1 days / 2;
  address public constant EIP4788 = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;

  /// @custom:storage-location erc7201:munja.storage.oracles.ZkOracleFeedConfig
  struct ZkOracleConfig {
    ISP1Verifier verifier;
    bytes32 programVKey;
  }

  // keccak256(abi.encode(uint256(keccak256("munja.storage.oracles.ZkOracleFeedConfig")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _ZK_CONFIG_SLOT =
    0x5c59d1aa0ea093fc04b8ee9e6658cc8f04d8ff9a372e945475492f2c87191000;

  function _getZkConfig() private pure returns (ZkOracleConfig storage $) {
    assembly {
      $.slot := _ZK_CONFIG_SLOT
    }
  }

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address initialOwner,
    address _verifier,
    bytes32 _programVKey
  ) external initializer {
    __AccessControl_init();
    __AccessControlEnumerable_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    _setVerifier(_verifier);
    _setProgramVKey(_programVKey);
  }

  /// @notice Reinitializer for upgrading existing proxies from V1 (immutable) to V2 (storage)
  function initializeV2(
    address _verifier,
    bytes32 _programVKey
  ) external reinitializer(2) {
    _setVerifier(_verifier);
    _setProgramVKey(_programVKey);
  }

  function _authorizeUpgrade(
    address
  ) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

  function verifier() external view returns (ISP1Verifier) {
    return _getZkConfig().verifier;
  }

  function programVKey() external view returns (bytes32) {
    return _getZkConfig().programVKey;
  }

  function setVerifier(
    address _verifier
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setVerifier(_verifier);
  }

  function setProgramVKey(
    bytes32 _programVKey
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setProgramVKey(_programVKey);
  }

  function feedType() external pure override returns (FeedType) {
    return FeedType.Zk;
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
    bytes calldata proof,
    LibZkOracleFeed.PublicData calldata publicData
  ) external onlyRole(FEEDER_ROLE) {
    OracleStorage storage $ = _getOracleStorage();

    (bytes32 appHash, bool isCached) = _getAppHash($, targetTimestamp);
    if (!isCached) $.appHashes[targetTimestamp] = appHash;

    ZkOracleConfig storage config = _getZkConfig();
    LibZkOracleFeed.verify(config.verifier, config.programVKey, appHash, proof, publicData);

    // 03. Save the public data
    _storeFeedData(
      $,
      targetTimestamp,
      publicData.validator.addr,
      _toStorageData(publicData.validator),
      _toStorageData(publicData.ownerships)
    );

    emit FeedUpdated(
      targetTimestamp,
      publicData.validator.addr,
      publicData.ownerships.length,
      bytes(string.concat('{"type":"zk","appHash":"', uint256(appHash).toHexString(), '"}'))
    );
  }

  function _setVerifier(
    address _verifier
  ) internal {
    require(_verifier != address(0), ZeroAddress());
    ZkOracleConfig storage config = _getZkConfig();
    address old = address(config.verifier);
    config.verifier = ISP1Verifier(_verifier);
    emit VerifierUpdated(old, _verifier);
  }

  function _setProgramVKey(
    bytes32 _programVKey
  ) internal {
    require(_programVKey != bytes32(0), ZeroVKey());
    ZkOracleConfig storage config = _getZkConfig();
    bytes32 old = config.programVKey;
    config.programVKey = _programVKey;
    emit ProgramVKeyUpdated(old, _programVKey);
  }

  function _getAppHash(
    OracleStorage storage $,
    uint48 targetTimestamp
  ) internal view returns (bytes32, bool) {
    if (EIP4788_TIMEOUT < Time.timestamp() - targetTimestamp) {
      bytes32 cached = $.appHashes[targetTimestamp];
      require(cached != bytes32(0), EIP4788Timeout());
      return (cached, true);
    }

    (bool ok, bytes memory data) = EIP4788.staticcall(abi.encode(targetTimestamp));
    if (!ok) {
      // revert with the returndata in case of failure
      // memory-safe assembly
      assembly {
        revert(add(data, 32), mload(data))
      }
    }

    return (abi.decode(data, (bytes32)), false);
  }

  function _toStorageData(
    LibZkOracleFeed.Validator calldata validator
  ) internal pure returns (ValidatorInner memory) {
    return ValidatorInner({
      collateral: validator.collateral.toUint96(),
      collateralShares: validator.collateralShares.toUint96(),
      extraVotingPower: validator.extraVotingPower.toUint96(),
      votingPower: validator.votingPower.toUint96(),
      _reservedA: 0,
      _reservedB: 0
    });
  }

  function _toStorageData(
    LibZkOracleFeed.CollateralOwnership[] calldata ownerships
  ) internal pure returns (CollateralOwnershipInner[] memory o) {
    o = new CollateralOwnershipInner[](ownerships.length);
    for (uint256 i = 0; i < ownerships.length; i++) {
      o[i] = _toStorageData(ownerships[i]);
    }
  }

  function _toStorageData(
    LibZkOracleFeed.CollateralOwnership calldata ownership
  ) internal pure returns (CollateralOwnershipInner memory) {
    return
      CollateralOwnershipInner({
        owner: ownership.owner, //
        shares: ownership.shares.toUint96()
      });
  }
}
