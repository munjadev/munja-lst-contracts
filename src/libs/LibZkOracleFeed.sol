// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { ISP1Verifier } from '@sp1/ISP1Verifier.sol';

library LibZkOracleFeed {
  struct Validator {
    address addr;
    bytes pubkey;
    uint256 collateral;
    uint256 collateralShares;
    uint256 extraVotingPower;
    uint256 votingPower;
    bool jailed;
    bool bonded;
  }

  struct CollateralOwnership {
    address valAddr;
    address owner;
    uint256 shares;
    uint256 creationHeight;
  }

  struct PublicData {
    bytes32 appHash;
    Validator validator;
    CollateralOwnership[] ownerships;
  }

  error AppHashMismatch();

  function verify(
    ISP1Verifier verifier,
    bytes32 programVKey,
    bytes32 appHash,
    bytes memory proof,
    PublicData memory publicData
  ) internal view {
    require(publicData.appHash == appHash, AppHashMismatch());
    verifier.verifyProof(programVKey, abi.encode(publicData), proof);
  }
}
