// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { FixedPointMathLib } from '@solady/utils/FixedPointMathLib.sol';

import { SafeCast } from '@oz/utils/math/SafeCast.sol';
import { Checkpoints } from '@oz/utils/structs/Checkpoints.sol';
import { EnumerableSet } from '@oz/utils/structs/EnumerableSet.sol';

import { ERC7201Utils } from '@mitosis/lib/ERC7201Utils.sol';

import { ICollateralOracleFeed } from '../interfaces/oracles/ICollateralOracleFeed.sol';

contract CollateralOracleStorage {
  using SafeCast for uint256;
  using Checkpoints for Checkpoints.Trace208;
  using ERC7201Utils for string;
  using EnumerableSet for EnumerableSet.AddressSet;

  struct ValidatorInner {
    // slot 0
    uint96 collateral; // 12 bytes
    uint96 collateralShares; // 12 bytes
    uint64 _reservedA; // 8 bytes
    // slot 1
    uint96 extraVotingPower; // 12 bytes
    uint96 votingPower; // 12 bytes
    // NOTICE: skipped bonded / failed flags
    uint64 _reservedB; // 8 bytes
  }

  struct CollateralOwnershipInner {
    // slot 0
    address owner; // 20 bytes
    uint96 shares; // 12 bytes
  }

  struct TwabSnapshot {
    uint256 cumulativeShares; // Cumulative (shares * duration)
    uint48 lastUpdateTime; // Last update timestamp
    uint208 _reserved;
  }

  struct FeedStorage {
    Checkpoints.Trace208 indexByTime;
    mapping(uint256 idx => ValidatorInner) validators;
    mapping(uint256 idx => CollateralOwnershipInner[]) ownerships;
    mapping(uint256 idx => mapping(address owner => uint256)) ownershipIndexByOwner;
    // TWAB tracking
    mapping(address owner => TwabSnapshot) twabSnapshots;
    // Historical owners tracking (all owners that ever had shares)
    EnumerableSet.AddressSet historicalOwners;
    // Validator total TWAB (sum of all owners)
    TwabSnapshot totalTwabSnapshot;
  }

  /// @custom:storage-location erc7201:munja.storage.oracles.CollateralOracleStorage
  struct OracleStorage {
    EnumerableSet.AddressSet valAddrs;
    mapping(uint48 => bytes32) appHashes;
    mapping(address val => FeedStorage) feeds;
  }

  error FeedNotFound();
  error CollateralOwnershipFeedNotFound();
  error FeedTargetOutdated(uint48 timestamp, uint48 lastTimestamp);
  error InvalidTimeRange();
  error NoDataInRange();

  // keccak256(abi.encode(uint256(keccak256("munja.storage.oracles.CollateralOracleStorage")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _ORACLE_STORAGE_SLOT =
    0x88785c098aef98cf22acd5c5c09ab37e1ee6507973d121390c77e8b365477100;

  function _getOracleStorage() internal pure returns (OracleStorage storage $) {
    assembly {
      $.slot := _ORACLE_STORAGE_SLOT
    }
  }

  function _getValidator(
    OracleStorage storage $,
    uint48 timestamp,
    address valAddr
  ) internal view returns (ICollateralOracleFeed.Validator memory) {
    FeedStorage storage feed$ = $.feeds[valAddr];

    uint208 index = feed$.indexByTime.upperLookupRecent(timestamp);
    require(index > 0, FeedNotFound());

    return _fromStorageData(feed$.validators[index]);
  }

  function _getValidatorAddressCount(
    OracleStorage storage $
  ) internal view returns (uint256) {
    return $.valAddrs.length();
  }

  function _getValidatorAddressByIndex(
    OracleStorage storage $,
    uint256 index
  ) internal view returns (address) {
    return $.valAddrs.at(index);
  }

  function _getCollateralOwnership(
    OracleStorage storage $,
    uint48 timestamp,
    address valAddr,
    address owner
  ) internal view returns (ICollateralOracleFeed.CollateralOwnership memory) {
    FeedStorage storage feed$ = $.feeds[valAddr];

    uint208 index = feed$.indexByTime.upperLookupRecent(timestamp);
    require(index > 0, FeedNotFound());

    uint256 ownershipIndex = feed$.ownershipIndexByOwner[index][owner];
    require(ownershipIndex > 0, CollateralOwnershipFeedNotFound());

    return _fromStorageData(feed$.ownerships[index][ownershipIndex]);
  }

  function _getCollateralOwnerships(
    OracleStorage storage $,
    uint48 timestamp,
    address valAddr
  ) internal view returns (ICollateralOracleFeed.CollateralOwnership[] memory) {
    FeedStorage storage feed$ = $.feeds[valAddr];

    uint208 index = feed$.indexByTime.upperLookupRecent(timestamp);
    require(index > 0, FeedNotFound());

    return _fromStorageData(feed$.ownerships[index]);
  }

  /// @notice Get Time-Weighted Average Balance (TWAB) for a specific owner
  /// @dev Uses pre-calculated cumulative values from feed updates
  /// @param $ Oracle storage
  /// @param startTime Start of the time range
  /// @param endTime End of the time range (must be <= last feed time)
  /// @param valAddr Validator address
  /// @param owner Owner address (vault address)
  /// @return twab Time-weighted average shares
  function _getCollateralOwnershipTWAB(
    OracleStorage storage $,
    uint48 startTime,
    uint48 endTime,
    address valAddr,
    address owner
  ) internal view returns (uint256 twab) {
    require(startTime < endTime, InvalidTimeRange());

    FeedStorage storage feed$ = $.feeds[valAddr];
    TwabSnapshot storage snapshot = feed$.twabSnapshots[owner];

    require(snapshot.lastUpdateTime > 0, FeedNotFound());
    require(endTime <= snapshot.lastUpdateTime, NoDataInRange());

    // Get cumulative values at start and end
    uint256 cumulativeAtEnd = _getCumulativeSharesAt(feed$, owner, endTime);
    uint256 cumulativeAtStart = _getCumulativeSharesAt(feed$, owner, startTime);

    uint256 weightedShares = cumulativeAtEnd - cumulativeAtStart;
    uint256 duration = endTime - startTime;

    require(duration > 0, InvalidTimeRange());
    twab = FixedPointMathLib.fullMulDiv(weightedShares, 1, duration);
  }

  /// @notice Get cumulative shares at a specific time (for TWAB calculation)
  function _getCumulativeSharesAt(
    FeedStorage storage feed$,
    address owner,
    uint48 timestamp
  ) internal view returns (uint256) {
    TwabSnapshot storage snapshot = feed$.twabSnapshots[owner];

    // If timestamp is at the last update, return cumulative directly
    if (timestamp == snapshot.lastUpdateTime) return snapshot.cumulativeShares;

    // Find shares at the requested timestamp
    Checkpoints.Trace208 storage trace = feed$.indexByTime;
    uint208 index = trace.upperLookupRecent(timestamp);
    require(index > 0, FeedNotFound());

    uint256 shares = _getOwnerShares(feed$, index, owner);

    // Calculate cumulative at target timestamp:
    // cumulative(target) = cumulative(last) - shares * (lastUpdate - target)
    uint256 cumulative = snapshot.cumulativeShares;
    if (snapshot.lastUpdateTime > timestamp) {
      uint256 backDuration = snapshot.lastUpdateTime - timestamp;
      uint256 subtraction = FixedPointMathLib.fullMulDiv(shares, backDuration, 1);

      // Prevent underflow: if subtraction > cumulative, data is inconsistent
      // This can happen if oracle feeds are missing or irregular
      if (subtraction > cumulative) {
        // Return 0 instead of reverting - safer for view functions
        // Protocol should handle this gracefully in reward distribution
        return 0;
      }

      cumulative -= subtraction;
    }

    return cumulative;
  }

  /// @notice Calculate TWAB for all historical owners of a validator
  /// @dev Only includes owners with non-zero TWAB in the given period
  /// @param $ Oracle storage
  /// @param startTime Start of the time range
  /// @param endTime End of the time range
  /// @param valAddr Validator address
  /// @return ownerships Array of ownership data with TWAB shares (excludes zero TWAB)
  function _getCollateralOwnershipsTWAB(
    OracleStorage storage $,
    uint48 startTime,
    uint48 endTime,
    address valAddr
  ) internal view returns (ICollateralOracleFeed.CollateralOwnership[] memory ownerships) {
    require(startTime < endTime, InvalidTimeRange());

    FeedStorage storage feed$ = $.feeds[valAddr];

    // Use historical owners set to capture all past participants
    uint256 historicalCount = feed$.historicalOwners.length();

    // First pass: count non-zero TWAB owners
    uint256 nonZeroCount = 0;
    uint256[] memory twabs = new uint256[](historicalCount);

    for (uint256 i = 0; i < historicalCount; i++) {
      address owner = feed$.historicalOwners.at(i);

      // Skip if owner has no snapshot (never had shares in this validator)
      if (feed$.twabSnapshots[owner].lastUpdateTime == 0) continue;

      // Calculate TWAB for this owner
      uint256 twab = _getCollateralOwnershipTWAB($, startTime, endTime, valAddr, owner);
      twabs[i] = twab;

      if (twab > 0) nonZeroCount++;
    }

    // Second pass: collect non-zero TWAB owners
    ownerships = new ICollateralOracleFeed.CollateralOwnership[](nonZeroCount);
    uint256 idx = 0;

    for (uint256 i = 0; i < historicalCount; i++) {
      if (twabs[i] > 0) {
        address owner = feed$.historicalOwners.at(i);
        ownerships[idx] =
          ICollateralOracleFeed.CollateralOwnership({ owner: owner, shares: twabs[i] });
        idx++;
      }
    }
  }

  /// @notice Get all historical owners for a validator
  /// @dev Returns all owners that ever had shares, regardless of current status
  /// @param $ Oracle storage
  /// @param valAddr Validator address
  /// @return owners Array of historical owner addresses
  function _getHistoricalOwners(
    OracleStorage storage $,
    address valAddr
  ) internal view returns (address[] memory owners) {
    FeedStorage storage feed$ = $.feeds[valAddr];
    uint256 length = feed$.historicalOwners.length();
    owners = new address[](length);

    for (uint256 i = 0; i < length; i++) {
      owners[i] = feed$.historicalOwners.at(i);
    }
  }

  /// @notice Get historical owners count for a validator
  /// @param $ Oracle storage
  /// @param valAddr Validator address
  /// @return count Number of historical owners
  function _getHistoricalOwnersCount(
    OracleStorage storage $,
    address valAddr
  ) internal view returns (uint256) {
    return $.feeds[valAddr].historicalOwners.length();
  }

  /// @notice Get total TWAB (sum of all owners) for a validator in a time range
  /// @dev Returns the time-weighted average total shares across all owners
  /// @param $ Oracle storage
  /// @param startTime Start timestamp (inclusive)
  /// @param endTime End timestamp (exclusive)
  /// @param valAddr Validator address
  /// @return totalTwab Total TWAB across all owners
  function _getTotalTWAB(
    OracleStorage storage $,
    uint48 startTime,
    uint48 endTime,
    address valAddr
  ) internal view returns (uint256 totalTwab) {
    require(startTime < endTime, InvalidTimeRange());

    FeedStorage storage feed$ = $.feeds[valAddr];
    TwabSnapshot storage totalSnapshot = feed$.totalTwabSnapshot;

    // If validator never had any data, return 0
    if (totalSnapshot.lastUpdateTime == 0) return 0;

    // Get cumulative shares at start and end times
    uint256 cumulativeAtStart = _getCumulativeTotalSharesAt(feed$, startTime);
    uint256 cumulativeAtEnd = _getCumulativeTotalSharesAt(feed$, endTime);

    // TWAB = (cumulative at end - cumulative at start) / duration
    totalTwab = cumulativeAtEnd - cumulativeAtStart;
  }

  /// @notice Get cumulative total shares at a specific timestamp
  /// @dev Helper function for total TWAB calculation
  function _getCumulativeTotalSharesAt(
    FeedStorage storage feed$,
    uint48 timestamp
  ) internal view returns (uint256) {
    TwabSnapshot storage totalSnapshot = feed$.totalTwabSnapshot;

    // If timestamp is at or after last update, return stored cumulative value
    if (timestamp >= totalSnapshot.lastUpdateTime) return totalSnapshot.cumulativeShares;

    // Need to find the shares at this timestamp and calculate backwards
    Checkpoints.Trace208 storage trace = feed$.indexByTime;
    uint256 length = trace.length();

    if (length == 0) return 0;

    // Find the index at or before timestamp
    uint256 idx = _findCheckpointIndex(trace, timestamp, length);

    // Get total shares at this index
    CollateralOwnershipInner[] storage ownerships = feed$.ownerships[uint208(idx + 1)];
    uint256 totalSharesAtIndex = 0;
    for (uint256 i = 0; i < ownerships.length; i++) {
      totalSharesAtIndex += ownerships[i].shares;
    }

    // Calculate: stored cumulative - (shares * duration from timestamp to last update)
    uint256 durationFromTimestamp = totalSnapshot.lastUpdateTime - timestamp;
    return totalSnapshot.cumulativeShares
      - FixedPointMathLib.fullMulDiv(totalSharesAtIndex, durationFromTimestamp, 1);
  }

  /// @notice Helper to find checkpoint index for a given time
  function _findCheckpointIndex(
    Checkpoints.Trace208 storage trace,
    uint48 timestamp,
    uint256 length
  ) internal view returns (uint256) {
    // Binary search would be more efficient, but linear is simpler for now
    for (uint256 i = 0; i < length; i++) {
      Checkpoints.Checkpoint208 memory checkpoint = trace.at(uint32(i));
      if (checkpoint._key >= timestamp) return i > 0 ? i - 1 : 0;
    }
    return length - 1;
  }

  /// @notice Helper to get owner's shares at a specific index
  function _getOwnerShares(
    FeedStorage storage feed$,
    uint208 index,
    address owner
  ) internal view returns (uint256) {
    uint256 ownershipIndex = feed$.ownershipIndexByOwner[index][owner];
    if (ownershipIndex == 0) return 0;
    return feed$.ownerships[index][ownershipIndex - 1].shares;
  }

  /// @notice Get the timestamp of the most recent feed update for a validator
  /// @param $ Oracle storage
  /// @param valAddr Validator address
  /// @return timestamp Last feed timestamp (0 if never fed)
  function _getLastFeedTimestamp(
    OracleStorage storage $,
    address valAddr
  ) internal view returns (uint48 timestamp) {
    FeedStorage storage feed$ = $.feeds[valAddr];
    (bool exists, uint48 ts,) = feed$.indexByTime.latestCheckpoint();
    return exists ? ts : 0;
  }

  function _storeFeedData(
    OracleStorage storage $,
    uint48 timestamp,
    address valAddr,
    ValidatorInner memory validator,
    CollateralOwnershipInner[] memory ownerships
  ) internal {
    FeedStorage storage feed_ = $.feeds[valAddr];

    if (!$.valAddrs.contains(valAddr)) {
      $.valAddrs.add(valAddr);
      // make index zero empty
      feed_.indexByTime.push(timestamp - 1, 0);
    }

    // exists must be true
    (bool exists, uint48 latestTimestamp, uint208 latestIndex) =
      feed_.indexByTime.latestCheckpoint();

    // timestamp must be incremented
    require(exists && latestTimestamp < timestamp, FeedTargetOutdated(timestamp, latestTimestamp));

    uint256 nextIndex = latestIndex + 1;

    // Update TWAB for all owners before storing new data
    if (exists && latestTimestamp > 0) {
      _updateTwabSnapshots(feed_, latestTimestamp, timestamp, latestIndex);
    }

    // push feed data to storage
    feed_.indexByTime.push(timestamp, nextIndex.toUint208());
    feed_.validators[nextIndex] = validator;
    for (uint256 i = 0; i < ownerships.length; i++) {
      address owner = ownerships[i].owner;
      feed_.ownerships[nextIndex].push(ownerships[i]);
      feed_.ownershipIndexByOwner[nextIndex][owner] = i + 1;

      // Initialize TWAB snapshot for new owners
      if (feed_.twabSnapshots[owner].lastUpdateTime == 0) {
        feed_.twabSnapshots[owner].lastUpdateTime = timestamp;
      }

      // Add to historical owners set (never removed)
      if (!feed_.historicalOwners.contains(owner)) feed_.historicalOwners.add(owner);
    }
  }

  /// @notice Update TWAB snapshots when new feed data arrives
  /// @dev Accumulates (shares * duration) for each owner and validator total
  function _updateTwabSnapshots(
    FeedStorage storage feed_,
    uint48 lastTimestamp,
    uint48 newTimestamp,
    uint208 lastIndex
  ) internal {
    uint256 duration = newTimestamp - lastTimestamp;
    CollateralOwnershipInner[] storage lastOwnerships = feed_.ownerships[lastIndex];

    uint256 totalShares = 0;

    for (uint256 i = 0; i < lastOwnerships.length; i++) {
      address owner = lastOwnerships[i].owner;
      uint256 shares = lastOwnerships[i].shares;

      TwabSnapshot storage snapshot = feed_.twabSnapshots[owner];

      // Accumulate: cumulativeShares += shares * duration
      snapshot.cumulativeShares += FixedPointMathLib.fullMulDiv(shares, duration, 1);
      snapshot.lastUpdateTime = newTimestamp;

      // Sum for total
      totalShares += shares;
    }

    // Update validator total TWAB
    TwabSnapshot storage totalSnapshot = feed_.totalTwabSnapshot;
    totalSnapshot.cumulativeShares += FixedPointMathLib.fullMulDiv(totalShares, duration, 1);
    totalSnapshot.lastUpdateTime = newTimestamp;
  }

  function _toStorageData(
    ICollateralOracleFeed.Validator calldata validator
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
    ICollateralOracleFeed.CollateralOwnership[] calldata ownerships
  ) internal pure returns (CollateralOwnershipInner[] memory o) {
    o = new CollateralOwnershipInner[](ownerships.length);
    for (uint256 i = 0; i < ownerships.length; i++) {
      o[i] = _toStorageData(ownerships[i]);
    }
  }

  function _toStorageData(
    ICollateralOracleFeed.CollateralOwnership calldata ownership
  ) internal pure returns (CollateralOwnershipInner memory) {
    return
      CollateralOwnershipInner({
        owner: ownership.owner, //
        shares: ownership.shares.toUint96()
      });
  }

  function _fromStorageData(
    ValidatorInner memory validator
  ) internal pure returns (ICollateralOracleFeed.Validator memory) {
    return ICollateralOracleFeed.Validator({
      collateral: validator.collateral,
      collateralShares: validator.collateralShares,
      extraVotingPower: validator.extraVotingPower,
      votingPower: validator.votingPower
    });
  }

  function _fromStorageData(
    CollateralOwnershipInner memory ownership
  ) internal pure returns (ICollateralOracleFeed.CollateralOwnership memory) {
    return ICollateralOracleFeed.CollateralOwnership({
      owner: ownership.owner, //
      shares: ownership.shares
    });
  }

  function _fromStorageData(
    CollateralOwnershipInner[] memory ownerships
  ) internal pure returns (ICollateralOracleFeed.CollateralOwnership[] memory o) {
    o = new ICollateralOracleFeed.CollateralOwnership[](ownerships.length);
    for (uint256 i = 0; i < ownerships.length; i++) {
      o[i] = _fromStorageData(ownerships[i]);
    }
  }
}
