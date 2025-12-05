// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { FixedPointMathLib } from '@solady/utils/FixedPointMathLib.sol';

import { ICollateralOracleFeed } from '../interfaces/oracles/ICollateralOracleFeed.sol';

/// @title CollateralOracleLib
/// @notice Library for collateral oracle interactions and calculations
library CollateralOracleLib {
  /// @notice Get oracle-reported collateral amount for a specific validator
  /// @dev Converts shares to actual collateral amount
  /// @dev Returns 0 if no ownership data exists (e.g., before first oracle update)
  /// @param oracle The collateral oracle feed
  /// @param validator Validator address
  /// @param owner Collateral owner address
  /// @param timestamp Timestamp to query
  /// @return Actual collateral amount (reflects slashing)
  function getValidatorCollateral(
    ICollateralOracleFeed oracle,
    address validator,
    address owner,
    uint48 timestamp
  ) internal view returns (uint256) {
    // Try to get ownership data - returns 0 if not found (first deposit case)
    try oracle.getCollateralOwnership(timestamp, validator, owner) returns (
      ICollateralOracleFeed.CollateralOwnership memory ownership
    ) {
      ICollateralOracleFeed.Validator memory validatorInfo =
        oracle.getValidator(timestamp, validator);

      if (validatorInfo.collateralShares == 0) return 0;

      // Convert shares to actual collateral: (our_shares / total_shares) * validator_collateral
      return FixedPointMathLib.fullMulDiv(
        ownership.shares, validatorInfo.collateral, validatorInfo.collateralShares
      );
    } catch {
      // No ownership data found - return 0 (happens on first deposit before oracle update)
      return 0;
    }
  }

  /// @notice Get total collateral across multiple validators
  /// @param oracle The collateral oracle feed
  /// @param validators Array of validator addresses
  /// @param owner Collateral owner address
  /// @param timestamp Timestamp to query
  /// @return total Total collateral amount
  function getTotalCollateral(
    ICollateralOracleFeed oracle,
    address[] memory validators,
    address owner,
    uint48 timestamp
  ) internal view returns (uint256 total) {
    for (uint256 i = 0; i < validators.length; i++) {
      total += getValidatorCollateral(oracle, validators[i], owner, timestamp);
    }
  }
}
