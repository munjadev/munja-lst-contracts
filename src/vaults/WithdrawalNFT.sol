// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {
  AccessControlEnumerableUpgradeable
} from '@ozu/access/extensions/AccessControlEnumerableUpgradeable.sol';
import { Initializable } from '@ozu/proxy/utils/Initializable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';
import { ERC721Upgradeable } from '@ozu/token/ERC721/ERC721Upgradeable.sol';

import { LibString } from '@solady/utils/LibString.sol';

import { IERC20Metadata } from '@oz/token/ERC20/extensions/IERC20Metadata.sol';
import { SafeCast } from '@oz/utils/math/SafeCast.sol';

import { IWithdrawalNFT } from '../interfaces/vaults/IWithdrawalNFT.sol';
import { SvgBuilder } from '../libs/SvgBuilder.sol';
import { Versioned } from '../libs/Versioned.sol';

/// @title WithdrawalNFT
/// @notice ERC721 NFT representing pending withdrawal requests - Ultra-optimized
/// @dev Assembly-optimized with namespaced storage (ERC7201) and access control
contract WithdrawalNFT is
  IWithdrawalNFT,
  Initializable,
  ERC721Upgradeable,
  AccessControlEnumerableUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  using SafeCast for uint256;
  using LibString for uint256;

  /// @custom:storage-location erc7201:munja.storage.WithdrawalNFT
  struct Storage {
    mapping(uint256 tokenId => WithdrawalRequest) withdrawalRequests;
    uint256 nextTokenId;
  }

  struct WithdrawalRequest {
    address authority; // 160
    uint48 timestamp; // 48
    uint48 _reserved; // 48
    uint128 assets;
    uint128 shares;
    address assetToken;
    address shareToken;
  }

  // keccak256(abi.encode(uint256(keccak256("munja.storage.WithdrawalNFT")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_LOCATION =
    0xe6646f2669f59cd2beeb461afb5aac084df6ed909d84d061da0de4f5937be200;

  bytes32 public constant VAULT_ROLE = keccak256('VAULT_ROLE');

  function _getStorage() private pure returns (Storage storage $) {
    assembly {
      $.slot := STORAGE_LOCATION
    }
  }

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address initialOwner
  ) external initializer {
    require(initialOwner != address(0), 'Invalid owner');

    __ERC721_init('Munja Withdrawal Request', 'mWR');
    __AccessControlEnumerable_init();
    __UUPSUpgradeable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
  }

  /// @inheritdoc IWithdrawalNFT
  function mint(
    address to,
    uint256 assets,
    uint256 shares,
    uint256 timestamp,
    address assetToken,
    address shareToken
  ) external onlyRole(VAULT_ROLE) returns (uint256 tokenId) {
    require(to != address(0), ZeroAddress());
    require(assetToken != address(0) && shareToken != address(0), InvalidTokens());
    require(assets > 0, InvalidAssets());
    require(shares > 0, InvalidShares());

    Storage storage $ = _getStorage();
    tokenId = $.nextTokenId++;

    $.withdrawalRequests[tokenId] = WithdrawalRequest({
      authority: _msgSender(),
      timestamp: timestamp.toUint48(),
      assets: assets.toUint128(),
      shares: shares.toUint128(),
      assetToken: assetToken,
      shareToken: shareToken,
      _reserved: 0
    });

    _mint(to, tokenId);

    emit WithdrawalRequestMinted(_msgSender(), to, tokenId, assets, shares, timestamp);
  }

  /// @inheritdoc IWithdrawalNFT
  function burn(
    uint256 tokenId
  ) external onlyRole(VAULT_ROLE) {
    Storage storage $ = _getStorage();
    WithdrawalRequest memory req = $.withdrawalRequests[tokenId];

    require(req.authority == _msgSender(), Unauthorized());

    delete $.withdrawalRequests[tokenId];
    _burn(tokenId);

    emit WithdrawalRequestBurned(_msgSender(), tokenId);
  }

  /// @inheritdoc IWithdrawalNFT
  function getWithdrawalRequest(
    uint256 tokenId
  ) external view returns (WithdrawalResponse memory response) {
    Storage storage $ = _getStorage();
    WithdrawalRequest memory req = $.withdrawalRequests[tokenId];
    require(req.timestamp > 0, InvalidTokenId());

    return WithdrawalResponse({
      authority: req.authority,
      owner: _ownerOf(tokenId),
      assets: req.assets,
      shares: req.shares,
      timestamp: req.timestamp,
      assetToken: req.assetToken,
      shareToken: req.shareToken
    });
  }

  /// @inheritdoc ERC721Upgradeable
  function tokenURI(
    uint256 tokenId
  ) public view virtual override returns (string memory result) {
    Storage storage $ = _getStorage();
    WithdrawalRequest memory req = $.withdrawalRequests[tokenId];
    require(req.timestamp > 0, InvalidTokenId());

    // Cache symbols from the request's token addresses
    string memory assetSym;
    string memory shareSym;
    {
      assetSym = IERC20Metadata(req.assetToken).symbol();
      shareSym = IERC20Metadata(req.shareToken).symbol();
    }

    // Build JSON with assembly
    bytes memory json;
    {
      bytes memory svg = bytes(_buildSvg(tokenId, req, assetSym, shareSym));
      bytes memory attrs = bytes(_buildAttributes(req));

      // Build JSON parts
      json = abi.encodePacked(
        '{"name":"Withdrawal Request #',
        tokenId.toString(),
        '","description":"Pending withdrawal of ',
        SvgBuilder.formatAmount(uint256(req.assets)),
        ' ',
        assetSym,
        ' (shares: ',
        uint256(req.shares).toString(),
        ' ',
        shareSym,
        ')","image":"',
        svg,
        '","attributes":',
        attrs,
        '}'
      );
    }

    // Efficient assembly concatenation
    bytes memory prefix = 'data:application/json;utf8,';
    assembly {
      let pl := mload(prefix)
      let jl := mload(json)
      result := mload(0x40)
      mstore(result, add(pl, jl))

      let dst := add(result, 0x20)
      let src := add(prefix, 0x20)
      let end := add(src, pl)
      for { } lt(src, end) {
        src := add(src, 0x20)
        dst := add(dst, 0x20)
      } { mstore(dst, mload(src)) }

      dst := add(add(result, 0x20), pl)
      src := add(json, 0x20)
      end := add(src, jl)
      for { } lt(src, end) {
        src := add(src, 0x20)
        dst := add(dst, 0x20)
      } { mstore(dst, mload(src)) }

      mstore(0x40, add(add(result, 0x20), add(pl, jl)))
    }
  }

  /// @notice Build SVG - separated to avoid stack too deep
  function _buildSvg(
    uint256 tokenId,
    WithdrawalRequest memory req,
    string memory assetSym,
    string memory shareSym
  ) private pure returns (string memory) {
    return SvgBuilder.buildSvg(
      SvgBuilder.SvgParams({
        tokenId: tokenId,
        amount: uint256(req.assets),
        shares: uint256(req.shares),
        amountSymbol: assetSym,
        sharesSymbol: shareSym
      })
    );
  }

  /// @notice Build attributes JSON
  function _buildAttributes(
    WithdrawalRequest memory req
  ) private pure returns (string memory) {
    return string(
      abi.encodePacked(
        '[{"trait_type":"Assets","value":"',
        uint256(req.assets).toString(),
        '","display_type":"number"},',
        '{"trait_type":"Shares","value":"',
        uint256(req.shares).toString(),
        '","display_type":"number"},',
        '{"trait_type":"Timestamp","value":"',
        uint256(req.timestamp).toString(),
        '","display_type":"date"}]'
      )
    );
  }

  /// @notice UUPS upgrade authorization
  function _authorizeUpgrade(
    address newImplementation
  ) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

  /// @dev See {IERC165-supportsInterface}.
  function supportsInterface(
    bytes4 interfaceId
  )
    public
    view
    virtual
    override(ERC721Upgradeable, AccessControlEnumerableUpgradeable)
    returns (bool)
  {
    return super.supportsInterface(interfaceId);
  }
}
