// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ItMITO
/// @notice Interface for tMITO (Option token)
interface ItMITO {
  function balanceOf(
    address account
  ) external view returns (uint256);
  function approve(
    address spender,
    uint256 amount
  ) external returns (bool);
  function transfer(
    address to,
    uint256 amount
  ) external returns (bool);
  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) external returns (bool);
}
