// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { FixedPointMathLib } from '@solady/utils/FixedPointMathLib.sol';

/// @title Checkpoints
/// @notice Library for managing historical exchange rate checkpoints
/// @dev Uses binary search for efficient historical lookups
library Checkpoints {
  /// @notice Exchange rate checkpoint stored in a single slot
  /// @dev uint48 timestamp + uint104 totalAssets + uint104 totalShares = 256 bits
  struct Checkpoint {
    uint48 timestamp;
    uint104 totalAssets;
    uint104 totalShares;
  }

  /// @notice Array of checkpoints with decimals offset for inflation attack mitigation
  struct History {
    Checkpoint[] _checkpoints;
    uint8 decimalsOffset;
  }

  error InvalidTimestamp();
  error CheckpointNotFound();

  /// @notice Push a new checkpoint
  /// @dev Only pushes if values changed or enough time passed
  function push(
    History storage self,
    uint256 totalAssets,
    uint256 totalShares
  ) internal {
    uint48 timestamp = uint48(block.timestamp);

    // Check if values fit in uint104
    require(totalAssets <= type(uint104).max, 'Assets overflow');
    require(totalShares <= type(uint104).max, 'Shares overflow');

    uint256 pos = self._checkpoints.length;

    // If this is not the first checkpoint, check if we should update or create new
    if (pos > 0) {
      Checkpoint storage last = self._checkpoints[pos - 1];

      // If same block, update the last checkpoint
      if (last.timestamp == timestamp) {
        last.totalAssets = uint104(totalAssets);
        last.totalShares = uint104(totalShares);
        return;
      }

      // Skip if values haven't changed (save gas)
      if (last.totalAssets == totalAssets && last.totalShares == totalShares) return;
    }

    // Push new checkpoint
    self._checkpoints
      .push(
        Checkpoint({
          timestamp: timestamp, totalAssets: uint104(totalAssets), totalShares: uint104(totalShares)
        })
      );
  }

  /// @notice Get checkpoint at a specific timestamp
  /// @dev Uses binary search to find the checkpoint
  /// @param self History storage
  /// @param timestamp Timestamp to query
  /// @return checkpoint The checkpoint at or before the timestamp
  function getAtTimestamp(
    History storage self,
    uint48 timestamp
  ) internal view returns (Checkpoint memory checkpoint) {
    uint256 len = self._checkpoints.length;
    require(len > 0, CheckpointNotFound());

    // Binary search
    uint256 low = 0;
    uint256 high = len;

    while (low < high) {
      uint256 mid = (low + high) / 2;
      if (self._checkpoints[mid].timestamp > timestamp) high = mid;
      else low = mid + 1;
    }

    // low is the index of the first checkpoint after timestamp
    // So we want low - 1 (the last checkpoint before or at timestamp)
    require(low > 0, CheckpointNotFound());
    return self._checkpoints[low - 1];
  }

  /// @notice Get the latest checkpoint
  function latest(
    History storage self
  ) internal view returns (Checkpoint memory checkpoint) {
    uint256 pos = self._checkpoints.length;
    require(pos > 0, CheckpointNotFound());
    return self._checkpoints[pos - 1];
  }

  /// @notice Get the length of checkpoints
  function length(
    History storage self
  ) internal view returns (uint256) {
    return self._checkpoints.length;
  }

  /// @notice Calculate exchange rate from checkpoint
  /// @dev Returns assets per share scaled by 1e18
  /// @param checkpoint The checkpoint to calculate exchange rate from
  /// @param decimalsOffset Decimals offset for inflation attack mitigation (0 for no offset)
  function exchangeRate(
    Checkpoint memory checkpoint,
    uint8 decimalsOffset
  ) internal pure returns (uint256) {
    uint256 totalShares = uint256(checkpoint.totalShares);
    uint256 totalAssets = uint256(checkpoint.totalAssets);

    if (totalShares == 0) return 1e18; // 1:1 if no shares

    // Apply inflation attack mitigation with virtual shares
    if (decimalsOffset == 0) {
      return FixedPointMathLib.fullMulDiv(totalAssets + 1, 1e18, totalShares + 1);
    }
    uint256 offset = 10 ** decimalsOffset;
    return FixedPointMathLib.fullMulDiv(totalAssets + 1, 1e18, totalShares + offset);
  }

  /// @notice Convert shares to assets using checkpoint
  /// @param checkpoint The checkpoint to use for conversion
  /// @param shares Amount of shares to convert
  /// @param decimalsOffset Decimals offset for inflation attack mitigation (0 for no offset)
  function convertToAssets(
    Checkpoint memory checkpoint,
    uint256 shares,
    uint8 decimalsOffset
  ) internal pure returns (uint256) {
    uint256 totalShares = uint256(checkpoint.totalShares);
    uint256 totalAssets = uint256(checkpoint.totalAssets);

    if (totalShares == 0) return shares; // 1:1 if no shares

    // Apply inflation attack mitigation with virtual shares
    if (decimalsOffset == 0) {
      return FixedPointMathLib.fullMulDiv(shares, totalAssets + 1, totalShares + 1);
    }
    uint256 offset = 10 ** decimalsOffset;
    return FixedPointMathLib.fullMulDiv(shares, totalAssets + 1, totalShares + offset);
  }

  /// @notice Convert assets to shares using checkpoint
  /// @param checkpoint The checkpoint to use for conversion
  /// @param assets Amount of assets to convert
  /// @param decimalsOffset Decimals offset for inflation attack mitigation (0 for no offset)
  function convertToShares(
    Checkpoint memory checkpoint,
    uint256 assets,
    uint8 decimalsOffset
  ) internal pure returns (uint256) {
    uint256 totalAssets = uint256(checkpoint.totalAssets);
    uint256 totalShares = uint256(checkpoint.totalShares);

    if (totalAssets == 0) return assets; // 1:1 if no assets

    // Apply inflation attack mitigation with virtual shares
    if (decimalsOffset == 0) {
      return FixedPointMathLib.fullMulDiv(assets, totalShares + 1, totalAssets + 1);
    }
    uint256 offset = 10 ** decimalsOffset;
    return FixedPointMathLib.fullMulDiv(assets, totalShares + offset, totalAssets + 1);
  }

  /// @notice Helper: Get exchange rate from History using stored decimalsOffset
  function exchangeRate(
    History storage self
  ) internal view returns (uint256) {
    Checkpoint memory checkpoint = latest(self);
    return exchangeRate(checkpoint, self.decimalsOffset);
  }

  /// @notice Helper: Get exchange rate from History using stored decimalsOffset at a specific timestamp
  function exchangeRateAtTimestamp(
    History storage self,
    uint48 timestamp
  ) internal view returns (uint256) {
    Checkpoint memory checkpoint = getAtTimestamp(self, timestamp);
    return exchangeRate(checkpoint, self.decimalsOffset);
  }

  /// @notice Helper: Convert shares to assets using History's latest checkpoint and decimalsOffset
  function convertToAssets(
    History storage self,
    uint256 shares
  ) internal view returns (uint256) {
    Checkpoint memory checkpoint = latest(self);
    return convertToAssets(checkpoint, shares, self.decimalsOffset);
  }

  /// @notice Helper: Convert shares to assets using History's checkpoint at a specific timestamp and decimalsOffset
  function convertToAssetsAt(
    History storage self,
    uint256 shares,
    uint48 timestamp
  ) internal view returns (uint256) {
    Checkpoint memory checkpoint = getAtTimestamp(self, timestamp);
    return convertToAssets(checkpoint, shares, self.decimalsOffset);
  }

  /// @notice Helper: Convert assets to shares using History's latest checkpoint and decimalsOffset
  function convertToShares(
    History storage self,
    uint256 assets
  ) internal view returns (uint256) {
    Checkpoint memory checkpoint = latest(self);
    return convertToShares(checkpoint, assets, self.decimalsOffset);
  }

  /// @notice Helper: Convert assets to shares using History's checkpoint at a specific timestamp and decimalsOffset
  function convertToSharesAt(
    History storage self,
    uint256 assets,
    uint48 timestamp
  ) internal view returns (uint256) {
    Checkpoint memory checkpoint = getAtTimestamp(self, timestamp);
    return convertToShares(checkpoint, assets, self.decimalsOffset);
  }
}
