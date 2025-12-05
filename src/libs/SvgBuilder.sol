// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { Base64 } from '@solady/utils/Base64.sol';
import { LibString } from '@solady/utils/LibString.sol';

/// @title SvgBuilder
/// @notice Ultra-optimized SVG builder using assembly
library SvgBuilder {
  using LibString for uint256;

  struct SvgParams {
    uint256 tokenId;
    uint256 amount;
    uint256 shares;
    string amountSymbol;
    string sharesSymbol;
  }

  /// @notice Generate complete SVG with base64 encoding - assembly optimized
  function buildSvg(
    SvgParams memory params
  ) internal pure returns (string memory) {
    // Pre-compute strings to avoid stack too deep
    string memory tokenIdStr = params.tokenId.toString();
    string memory amountStr = formatAmount(params.amount);
    string memory sharesStr = formatAmount(params.shares);

    // Build SVG using abi.encodePacked (compiler optimizes this well)
    bytes memory svg = abi.encodePacked(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
      '<rect width="400" height="400" fill="#000000"/>',
      '<rect x="10" y="10" width="380" height="380" fill="none" stroke="#ffffff" stroke-width="3"/>',
      '<text x="30" y="60" fill="#ffffff" font-size="32" font-family="monospace" font-weight="300">',
      'withdrawal #',
      tokenIdStr,
      '</text>',
      '<text x="200" y="230" text-anchor="middle" fill="#ffffff" font-size="64" font-family="monospace" font-weight="bold">&lt; &#9889; &gt;</text>'
    );

    // Second part
    svg = abi.encodePacked(
      svg,
      '<text x="30" y="340" fill="#ffffff" font-size="20" font-family="monospace" font-weight="300">',
      'Assets | ',
      amountStr,
      ' ',
      params.amountSymbol,
      '</text>',
      '<text x="30" y="370" fill="#ffffff" font-size="20" font-family="monospace" font-weight="300">',
      'Shares | ',
      sharesStr,
      ' ',
      params.sharesSymbol,
      '</text></svg>'
    );

    return _encodeDataUri(svg);
  }

  /// @notice Encode SVG to base64 data URI using assembly
  function _encodeDataUri(
    bytes memory svg
  ) private pure returns (string memory result) {
    bytes memory encoded = bytes(Base64.encode(svg));
    bytes memory prefix = 'data:image/svg+xml;base64,';

    assembly {
      let prefixLen := mload(prefix)
      let encodedLen := mload(encoded)
      let totalLen := add(prefixLen, encodedLen)

      // Allocate result
      result := mload(0x40)
      mstore(result, totalLen)

      let dst := add(result, 0x20)

      // Copy prefix
      let src := add(prefix, 0x20)
      let end := add(src, prefixLen)
      for { } lt(src, end) {
        src := add(src, 0x20)
        dst := add(dst, 0x20)
      } { mstore(dst, mload(src)) }

      // Copy encoded (adjust dst if prefix wasn't multiple of 32)
      dst := add(add(result, 0x20), prefixLen)
      src := add(encoded, 0x20)
      end := add(src, encodedLen)
      for { } lt(src, end) {
        src := add(src, 0x20)
        dst := add(dst, 0x20)
      } { mstore(dst, mload(src)) }

      // Update free memory pointer
      mstore(0x40, add(add(result, 0x20), totalLen))
    }
  }

  /// @notice Format wei/shares to readable format with 6 decimals
  function formatAmount(
    uint256 value
  ) internal pure returns (string memory) {
    unchecked {
      uint256 whole = value / 1e18;
      uint256 decimals = (value % 1e18) / 1e12;
      return string(abi.encodePacked(whole.toString(), '.', _pad6Digits(decimals)));
    }
  }

  /// @notice Pad number to 6 digits using assembly
  function _pad6Digits(
    uint256 num
  ) private pure returns (string memory result) {
    assembly {
      result := mload(0x40)
      mstore(result, 6) // length = 6

      let ptr := add(result, 0x26) // Start from the end (0x20 + 6)

      // Fill from right to left
      for { let i := 0 } lt(i, 6) { i := add(i, 1) } {
        ptr := sub(ptr, 1)
        mstore8(ptr, add(48, mod(num, 10))) // '0' = 48
        num := div(num, 10)
      }

      // Update free memory pointer (6 bytes + 32 byte length = 38, round up to 64)
      mstore(0x40, add(result, 0x40))
    }
  }
}
