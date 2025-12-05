// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ICollateralOracleFeed
/// @notice Interface for collateral oracle feeds (ZK or managed)
interface ICollateralOracleFeed {
  /// @notice Type of oracle feed
  enum FeedType {
    None,
    Managed,
    Zk
  }

  /// @notice Validator collateral data
  struct Validator {
    /// @dev Optimized packing
    // address addr;
    // bytes pubkey;
    // bool jailed;
    // bool bonded;
    uint256 collateral;
    uint256 collateralShares;
    uint256 extraVotingPower;
    uint256 votingPower;
  }

  /// @notice Collateral ownership data
  struct CollateralOwnership {
    /// @dev Optimized packing
    // address valAddr;
    // uint256 creationHeight;
    address owner;
    uint256 shares;
  }

  /// @notice Emitted when oracle feed is updated
  /// @param timestamp Feed timestamp
  /// @param validator Validator address
  /// @param ownershipCount Number of ownership entries
  /// @param metadata Additional metadata
  event FeedUpdated(
    uint48 indexed timestamp, address indexed validator, uint256 ownershipCount, bytes metadata
  );

  /// @notice Get feed type (Managed or ZK)
  /// @return Feed type
  function feedType() external pure returns (FeedType);

  /// @notice Get validator data at a specific timestamp
  /// @param timestamp Query timestamp
  /// @param validator Validator address
  /// @return Validator data
  function getValidator(
    uint48 timestamp,
    address validator
  ) external view returns (Validator memory);

  /// @notice Get collateral ownership for a specific owner at a timestamp
  /// @param timestamp Query timestamp
  /// @param validator Validator address
  /// @param owner Owner address
  /// @return Collateral ownership data
  function getCollateralOwnership(
    uint48 timestamp,
    address validator,
    address owner
  ) external view returns (CollateralOwnership memory);

  /// @notice Get all collateral ownerships for a validator at a timestamp
  /// @param timestamp Query timestamp
  /// @param validator Validator address
  /// @return Array of collateral ownerships
  function getCollateralOwnerships(
    uint48 timestamp,
    address validator
  ) external view returns (CollateralOwnership[] memory);

  /// @notice Get time-weighted average ownership for a specific owner
  /// @param startTime Start timestamp (inclusive)
  /// @param endTime End timestamp (exclusive)
  /// @param validator Validator address
  /// @param owner Owner address
  /// @return twab Time-weighted average balance
  function getCollateralOwnershipTWAB(
    uint48 startTime,
    uint48 endTime,
    address validator,
    address owner
  ) external view returns (uint256 twab);

  /// @notice Get all time-weighted average ownerships for a validator
  /// @param startTime Start timestamp (inclusive)
  /// @param endTime End timestamp (exclusive)
  /// @param validator Validator address
  /// @return Array of collateral ownerships with TWAB values
  function getCollateralOwnershipsTWAB(
    uint48 startTime,
    uint48 endTime,
    address validator
  ) external view returns (CollateralOwnership[] memory);

  /// @notice Get all historical owners for a validator
  /// @param validator Validator address
  /// @return Array of owner addresses
  function getHistoricalOwners(
    address validator
  ) external view returns (address[] memory);

  /// @notice Get count of historical owners for a validator
  /// @param validator Validator address
  /// @return Number of historical owners
  function getHistoricalOwnersCount(
    address validator
  ) external view returns (uint256);

  /// @notice Get total TWAB for a validator in a time range
  /// @param validator Validator address
  /// @param startTime Start timestamp (inclusive)
  /// @param endTime End timestamp (exclusive)
  /// @return totalTwab Total time-weighted average balance
  function getTotalTWAB(
    address validator,
    uint48 startTime,
    uint48 endTime
  ) external view returns (uint256 totalTwab);

  /// @notice Get the timestamp of the most recent feed update for a validator
  /// @param validator Validator address
  /// @return timestamp Last feed timestamp (0 if never fed)
  function getLastFeedTimestamp(
    address validator
  ) external view returns (uint48 timestamp);
}
