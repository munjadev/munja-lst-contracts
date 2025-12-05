// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IWithdrawalNFT
/// @notice Interface for WithdrawalNFT contract representing pending withdrawal requests
interface IWithdrawalNFT {
  struct WithdrawalResponse {
    address authority;
    address owner;
    uint256 assets;
    uint256 shares;
    uint256 timestamp;
    address assetToken;
    address shareToken;
  }

  /// @notice Emitted when a withdrawal request NFT is minted
  /// @param authority Authority address
  /// @param owner NFT owner
  /// @param tokenId Token ID
  /// @param assets Assets amount
  /// @param shares Shares amount
  /// @param timestamp Request timestamp
  event WithdrawalRequestMinted(
    address indexed authority,
    address indexed owner,
    uint256 indexed tokenId,
    uint256 assets,
    uint256 shares,
    uint256 timestamp
  );

  /// @notice Emitted when a withdrawal request NFT is burned
  /// @param owner NFT owner
  /// @param tokenId Token ID
  event WithdrawalRequestBurned(address indexed owner, uint256 indexed tokenId);

  error ZeroAddress();
  error Unauthorized();
  error InvalidTokenId();
  error InvalidTokens();
  error InvalidAssets();
  error InvalidShares();
  error InvalidTimestamp();

  /// @notice Mint a new withdrawal NFT
  /// @param to Recipient address
  /// @param assets Assets amount requested
  /// @param shares Shares burned at request time
  /// @param timestamp Request timestamp
  /// @param assetToken Asset token address
  /// @param shareToken Share token address
  /// @return tokenId Minted token ID
  function mint(
    address to,
    uint256 assets,
    uint256 shares,
    uint256 timestamp,
    address assetToken,
    address shareToken
  ) external returns (uint256 tokenId);

  /// @notice Burn a withdrawal NFT
  /// @param tokenId Token ID to burn
  function burn(
    uint256 tokenId
  ) external;

  /// @notice Get withdrawal request details
  /// @param tokenId Token ID
  /// @return response Withdrawal request details
  function getWithdrawalRequest(
    uint256 tokenId
  ) external view returns (WithdrawalResponse memory);
}
