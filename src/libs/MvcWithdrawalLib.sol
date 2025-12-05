// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { WETH } from '@solady/tokens/WETH.sol';
import { SafeTransferLib } from '@solady/utils/SafeTransferLib.sol';

import { SafeCast } from '@oz/utils/math/SafeCast.sol';

import { IWithdrawalNFT } from '../interfaces/vaults/IWithdrawalNFT.sol';
import { Checkpoints } from './Checkpoints.sol';

/// @title MvcWithdrawalLib
/// @notice Library for mMITOc withdrawal logic
library MvcWithdrawalLib {
  using SafeCast for uint256;
  using Checkpoints for Checkpoints.History;

  error NoClaimableWithdrawals();
  error NotNFTOwner();
  error WithdrawalNotMatured();

  /// @notice Calculate claimable amount using historical exchange rates
  function calculateClaimableAmount(
    IWithdrawalNFT withdrawalNFT,
    Checkpoints.History storage exchangeRateHistory,
    uint256 tokenId
  ) internal view returns (uint256 claimable, uint256 requestedAmount) {
    IWithdrawalNFT.WithdrawalResponse memory request = withdrawalNFT.getWithdrawalRequest(tokenId);

    requestedAmount = request.assets;

    // Get checkpoint at withdrawal request time
    if (exchangeRateHistory.length() > 0) {
      // Convert shares to assets using historical exchange rate with decimalsOffset
      uint256 fairAmount = Checkpoints.convertToAssetsAt(
        exchangeRateHistory, request.shares, request.timestamp.toUint48()
      );
      // Cap at requested amount (can't get more than requested)
      claimable = fairAmount > request.assets ? request.assets : fairAmount;
    } else {
      // No checkpoints yet, use requested assets
      claimable = request.assets;
    }
  }

  /// @notice Process withdrawal claim
  /// @param tokenIds Array of withdrawal NFT token IDs to claim
  function processClaim(
    IWithdrawalNFT withdrawalNFT,
    Checkpoints.History storage exchangeRateHistory,
    WETH wmito,
    address user,
    uint32 withdrawalPeriod,
    uint256[] calldata tokenIds
  ) internal returns (uint256 totalClaimed, uint256 totalRequested) {
    uint256 currentTime = block.timestamp;

    for (uint256 i = 0; i < tokenIds.length; i++) {
      uint256 tokenId = tokenIds[i];

      // Get request details
      IWithdrawalNFT.WithdrawalResponse memory request = withdrawalNFT.getWithdrawalRequest(tokenId);

      // Check ownership
      if (request.owner != user) revert NotNFTOwner();

      // Check maturity
      if (currentTime < request.timestamp + withdrawalPeriod) revert WithdrawalNotMatured();

      // Calculate claimable amount
      (uint256 claimable, uint256 requested) =
        calculateClaimableAmount(withdrawalNFT, exchangeRateHistory, tokenId);

      totalClaimed += claimable;
      totalRequested += requested;

      // Burn NFT
      withdrawalNFT.burn(tokenId);
    }

    if (totalClaimed == 0) revert NoClaimableWithdrawals();

    // Transfer WMITO
    SafeTransferLib.safeTransfer(address(wmito), user, totalClaimed);
  }
}
