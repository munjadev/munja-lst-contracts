// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { FixedPointMathLib } from '@solady/utils/FixedPointMathLib.sol';

import {
  IValidatorContributionFeed
} from '@mitosis/interfaces/hub/validator/IValidatorContributionFeed.sol';

import { RewardRouter } from '../RewardRouter.sol';

/// @title RewardRouterRecovery
/// @notice One-shot migration to fix the epoch 13 reward dump incident.
///         After recovery, upgrade back to the clean RewardRouter implementation.
/// @dev Flow: upgrade → recover() → upgrade back to RewardRouter
contract RewardRouterRecovery is RewardRouter {
  event EpochRewardsRedistributed(
    address indexed validator,
    uint256 sourceEpoch,
    uint256 fromEpoch,
    uint256 toEpoch,
    uint256 totalRedistributed
  );

  struct RecoveryData {
    uint256[] weights;
    uint256[] twabs;
    uint256 totalWeight;
  }

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

  /// @notice Redistribute rewards that were incorrectly dumped into a single epoch
  /// @param validator Validator address
  /// @param sourceEpoch The epoch holding all rewards (e.g. 13)
  /// @param fromEpoch Start of redistribution range (inclusive)
  /// @param toEpoch End of redistribution range (inclusive)
  function recover(
    address validator,
    uint256 sourceEpoch,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 totalRedistributed) {
    require(validator != address(0), ZeroAddress());
    require(fromEpoch > 0 && toEpoch >= fromEpoch, InvalidEpoch());
    require(sourceEpoch >= fromEpoch && sourceEpoch <= toEpoch, InvalidEpoch());

    Storage storage $ = _getStorage();

    EpochReward storage source = $.epochRewards[validator][sourceEpoch];
    require(source.finalized && source.totalGmMito > 0, NoRewards());

    totalRedistributed = source.totalGmMito;
    uint256 rangeLen = toEpoch - fromEpoch + 1;

    RecoveryData memory data = _collectRecoveryData(fromEpoch, rangeLen, validator);
    require(data.totalWeight > 0, NoRewards());

    _applyRecovery($, fromEpoch, rangeLen, validator, totalRedistributed, data);

    emit EpochRewardsRedistributed(validator, sourceEpoch, fromEpoch, toEpoch, totalRedistributed);
  }

  function _collectRecoveryData(
    uint256 fromEpoch,
    uint256 rangeLen,
    address validator
  ) private view returns (RecoveryData memory data) {
    IValidatorContributionFeed feed = REWARD_DISTRIBUTOR.validatorContributionFeed();
    data.weights = new uint256[](rangeLen);
    data.twabs = new uint256[](rangeLen);

    for (uint256 i = 0; i < rangeLen; i++) {
      uint256 ep = fromEpoch + i;

      uint256 twab = _safeGetTotalTWAB(validator, ep);
      if (twab == 0) continue;

      (IValidatorContributionFeed.ValidatorWeight memory w, bool found) =
        feed.weightOf(ep, validator);
      if (!found || w.weight == 0) continue;

      data.weights[i] = uint256(w.weight);
      data.twabs[i] = twab;
      data.totalWeight += uint256(w.weight);
    }
  }

  function _applyRecovery(
    Storage storage $,
    uint256 fromEpoch,
    uint256 rangeLen,
    address validator,
    uint256 totalGmMito,
    RecoveryData memory data
  ) private {
    uint256 distributed;
    uint256 lastValidEpoch;

    for (uint256 i = 0; i < rangeLen; i++) {
      uint256 ep = fromEpoch + i;

      if (data.weights[i] == 0) {
        if (!$.epochRewards[validator][ep].finalized) {
          $.epochRewards[validator][ep].finalized = true;
          $.lastFinalizedEpoch[validator] = ep;
          emit EpochSkipped(ep, validator);
        }
        continue;
      }

      uint256 epochGmMito =
        FixedPointMathLib.fullMulDiv(totalGmMito, data.weights[i], data.totalWeight);

      EpochReward storage reward = $.epochRewards[validator][ep];
      reward.totalGmMito = epochGmMito;
      reward.totalTWAB = data.twabs[i];
      reward.finalized = true;
      $.lastFinalizedEpoch[validator] = ep;

      distributed += epochGmMito;
      lastValidEpoch = ep;

      emit EpochRewardsFinalized(ep, validator, epochGmMito, data.twabs[i]);
    }

    if (distributed < totalGmMito && lastValidEpoch > 0) {
      $.epochRewards[validator][lastValidEpoch].totalGmMito += totalGmMito - distributed;
    }
  }

  function _safeGetTotalTWAB(
    address validator,
    uint256 ep
  ) private view returns (uint256) {
    try COLLATERAL_ORACLE.getTotalTWAB(
      validator, EPOCH_FEEDER.timeAt(ep), EPOCH_FEEDER.timeAt(ep + 1)
    ) returns (
      uint256 twab
    ) {
      return twab;
    } catch {
      return 0;
    }
  }
}
