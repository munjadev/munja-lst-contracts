// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { ERC4626 } from '@solady/tokens/ERC4626.sol';
import { WETH } from '@solady/tokens/WETH.sol';
import { FixedPointMathLib } from '@solady/utils/FixedPointMathLib.sol';
import { SafeTransferLib } from '@solady/utils/SafeTransferLib.sol';

import { IERC20 } from '@oz/token/ERC20/IERC20.sol';
import { Math } from '@oz/utils/math/Math.sol';
import { SafeCast } from '@oz/utils/math/SafeCast.sol';

import {
  AccessControlEnumerableUpgradeable
} from '@ozu/access/extensions/AccessControlEnumerableUpgradeable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';

import { IValidatorManager } from '@mitosis/interfaces/hub/validator/IValidatorManager.sol';

import { ICollateralOracleFeed } from '../interfaces/oracles/ICollateralOracleFeed.sol';
import { IRewardRouter } from '../interfaces/validator/IRewardRouter.sol';
import { IgmMITO } from '../interfaces/vaults/IgmMITO.sol';
import { ImMITOc } from '../interfaces/vaults/ImMITOc.sol';
import { IWithdrawalNFT } from '../interfaces/vaults/IWithdrawalNFT.sol';
import { Checkpoints } from '../libs/Checkpoints.sol';
import { CollateralOracleLib } from '../libs/CollateralOracleLib.sol';
import { MvcWithdrawalLib } from '../libs/MvcWithdrawalLib.sol';
import { Versioned } from '../libs/Versioned.sol';

/// @title mMITOc
/// @notice ERC4626 vault for MITO collateral with slashing exposure
contract mMITOc is
  ImMITOc,
  ERC4626,
  AccessControlEnumerableUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  using Math for uint256;
  using SafeCast for uint256;
  using Checkpoints for Checkpoints.History;
  using CollateralOracleLib for ICollateralOracleFeed;

  /// @custom:storage-location erc7201:munja.storage.mMITOc
  struct Storage {
    WithdrawalConfig withdrawalConfig;
    CollateralData collateralData;
    WithdrawalState withdrawalState;
    RewardState rewardState;
  }

  struct WithdrawalConfig {
    uint32 withdrawalPeriod;
    uint16 maxClaimsPerTx;
    uint208 _reserved;
  }

  struct CollateralData {
    uint256 totalCollateralDeposited;
    mapping(address validator => uint256) validatorCollateral;
    mapping(address validator => uint256) lastSyncedOracleValue;
  }

  struct WithdrawalState {
    uint256 pendingWithdrawals;
    uint256 totalPendingWithdrawal;
    Checkpoints.History exchangeRateHistory;
  }

  struct RewardState {
    uint256 rewardPerShareStored;
    mapping(address user => uint256) userRewardPerSharePaid;
    mapping(address user => uint256) rewards;
  }

  bytes32 private constant _STORAGE_SLOT =
    0x6b07ffc886efe9d230e1d814063a7ba84fa345fe62a3ce3cd22b17465f0ef300;

  // keccak256(abi.encodePacked("operator"))
  bytes32 public constant OPERATOR_ROLE =
    0x46a52cf33029de9f84853745a87af28464c80bf0346df1b32e205fc73319f622;

  // keccak256(abi.encodePacked("validator"))
  bytes32 public constant VALIDATOR_ROLE =
    0x7f11e8a47c8f6f2761361211fdf25db4167076f4c74d7c390a15f4211bc8c214;

  WETH public immutable WMITO;
  IgmMITO public immutable GM_MITO;
  ICollateralOracleFeed public immutable COLLATERAL_ORACLE;
  IValidatorManager public immutable VALIDATOR_MANAGER;
  IWithdrawalNFT public immutable WITHDRAWAL_NFT;
  IRewardRouter public immutable REWARD_ROUTER;

  constructor(
    address wmito,
    address gmMito,
    address collateralOracle,
    address validatorManager,
    address withdrawalNFT,
    address rewardRouter
  ) {
    require(wmito != address(0), ZeroAddress());
    require(gmMito != address(0), ZeroAddress());
    require(collateralOracle != address(0), ZeroAddress());
    require(validatorManager != address(0), ZeroAddress());
    require(withdrawalNFT != address(0), ZeroAddress());
    require(rewardRouter != address(0), ZeroAddress());

    _disableInitializers();

    WMITO = WETH(payable(wmito));
    GM_MITO = IgmMITO(gmMito);
    COLLATERAL_ORACLE = ICollateralOracleFeed(collateralOracle);
    VALIDATOR_MANAGER = IValidatorManager(validatorManager);
    WITHDRAWAL_NFT = IWithdrawalNFT(withdrawalNFT);
    REWARD_ROUTER = IRewardRouter(rewardRouter);
  }

  function initialize(
    address initialOwner,
    uint32 initialWithdrawalPeriod,
    uint16 initialMaxClaimsPerTx
  ) external initializer {
    require(initialOwner != address(0), ZeroAddress());
    require(initialMaxClaimsPerTx > 0, ZeroAmount());

    __AccessControlEnumerable_init();
    __UUPSUpgradeable_init();
    _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

    Storage storage $ = _getStorage();
    $.withdrawalConfig.withdrawalPeriod = initialWithdrawalPeriod;
    $.withdrawalConfig.maxClaimsPerTx = initialMaxClaimsPerTx;
    $.withdrawalState.exchangeRateHistory.decimalsOffset = _decimalsOffset();

    emit WithdrawalPeriodSet(initialWithdrawalPeriod);
    emit MaxClaimsPerTxSet(initialMaxClaimsPerTx);
  }

  receive() external payable {
    if (_msgSender() == address(WMITO)) return;

    Storage storage $ = _getStorage();
    $.withdrawalState.pendingWithdrawals += msg.value;
    WMITO.deposit{ value: msg.value }();
  }

  /*//////////////////////////////////////////////////////////////
                          ERC4626 OVERRIDES
  //////////////////////////////////////////////////////////////*/

  function name() public pure override returns (string memory) {
    return 'Munja MITO Collateral Vault';
  }

  function symbol() public pure override returns (string memory) {
    return 'mMITOc';
  }

  function asset() public view override returns (address) {
    return address(WMITO);
  }

  function totalAssets() public view override returns (uint256) {
    Storage storage $ = _getStorage();
    uint256 oracleCollateral = _getOracleCollateralTotal();
    uint256 idleBalance = WMITO.balanceOf(address(this));
    uint256 total = oracleCollateral + idleBalance;
    return total > $.withdrawalState.totalPendingWithdrawal
      ? total - $.withdrawalState.totalPendingWithdrawal
      : 0;
  }

  function deposit(
    uint256 assets,
    address receiver
  ) public override returns (uint256 shares) {
    require(assets > 0, ZeroAmount());
    require(receiver != address(0), ZeroAddress());
    shares = previewDeposit(assets);
    _processDeposit(assets, shares, receiver);
  }

  function mint(
    uint256 shares,
    address receiver
  ) public override returns (uint256 assets) {
    require(shares > 0, ZeroAmount());
    require(receiver != address(0), ZeroAddress());
    assets = previewMint(shares);
    _processDeposit(assets, shares, receiver);
  }

  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public override returns (uint256 shares) {
    require(assets > 0, ZeroAmount());

    // Sync all validators with oracle before withdrawal to prevent front-running
    // This ensures the exchange rate reflects the latest collateral values
    _syncAllValidators();

    shares = previewWithdraw(assets);
    _processWithdraw(assets, shares, receiver, owner);
  }

  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public override returns (uint256 assets) {
    require(shares > 0, ZeroAmount());

    // Sync all validators with oracle before redemption to prevent front-running
    _syncAllValidators();

    assets = previewRedeem(shares);
    _processWithdraw(assets, shares, receiver, owner);
  }

  /*//////////////////////////////////////////////////////////////
                      EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function claimWithdraw(
    uint256[] calldata tokenIds
  ) external returns (uint256 claimed) {
    Storage storage $ = _getStorage();
    WithdrawalConfig storage config = $.withdrawalConfig;
    WithdrawalState storage withdrawalState = $.withdrawalState;

    require(tokenIds.length > 0, ZeroAmount());
    require(tokenIds.length <= config.maxClaimsPerTx, 'Too many claims');

    uint256 requestedAmount;
    (claimed, requestedAmount) = MvcWithdrawalLib.processClaim(
      WITHDRAWAL_NFT,
      withdrawalState.exchangeRateHistory,
      WMITO,
      _msgSender(),
      config.withdrawalPeriod,
      tokenIds
    );

    withdrawalState.totalPendingWithdrawal -= requestedAmount;
    emit WithdrawalClaimed(_msgSender(), claimed, tokenIds);
  }

  function depositCollateral(
    address validator,
    uint256 amount
  ) external onlyRole(OPERATOR_ROLE) {
    _depositCollateralInternal(validator, amount);
  }

  function requestWithdrawCollateral(
    address validator,
    uint256 amount
  ) external payable onlyRole(OPERATOR_ROLE) {
    require(amount > 0, ZeroAmount());

    Storage storage $ = _getStorage();
    _syncCollateralWithOracle(validator);
    require($.collateralData.validatorCollateral[validator] >= amount, InsufficientCollateral());

    VALIDATOR_MANAGER.withdrawCollateral{ value: msg.value }(validator, address(this), amount);
    _updateCollateralAccounting(validator, amount, false);

    emit CollateralWithdrawalRequested(validator, amount);
  }

  function compoundToCollateral(
    address validator,
    uint256 amount
  ) external onlyRole(OPERATOR_ROLE) {
    _depositCollateralInternal(validator, amount);
  }

  function syncCollateral(
    address validator
  ) external {
    _syncCollateralWithOracle(validator);
  }

  function claimValidatorRewards(
    address validator,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external onlyRole(OPERATOR_ROLE) returns (uint256 gmMitoAmount) {
    gmMitoAmount = REWARD_ROUTER.claimRewards(validator, fromEpoch, toEpoch);

    if (gmMitoAmount > 0) {
      uint256 supply = totalSupply();
      require(supply > 0, 'No shares');

      RewardState storage rewardState = _getStorage().rewardState;
      uint256 newRewardPerShare =
        rewardState.rewardPerShareStored + FixedPointMathLib.fullMulDiv(gmMitoAmount, 1e18, supply);
      rewardState.rewardPerShareStored = newRewardPerShare;

      emit RewardDistributed(gmMitoAmount, newRewardPerShare);
    }
  }

  function getClaimableValidatorRewards(
    address validator,
    uint256 fromEpoch,
    uint256 toEpoch
  ) external view returns (uint256) {
    return REWARD_ROUTER.getClaimableRewards(validator, address(this), fromEpoch, toEpoch);
  }

  function claimRewards() external returns (uint256 reward) {
    _updateUserReward(_msgSender());

    RewardState storage rewardState = _getStorage().rewardState;
    reward = rewardState.rewards[_msgSender()];
    if (reward > 0) {
      rewardState.rewards[_msgSender()] = 0;
      SafeTransferLib.safeTransfer(address(GM_MITO), _msgSender(), reward);
      emit RewardClaimed(_msgSender(), reward);
    }
  }

  function setWithdrawalPeriod(
    uint32 period
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _getStorage().withdrawalConfig.withdrawalPeriod = period;
    emit WithdrawalPeriodSet(period);
  }

  function setMaxClaimsPerTx(
    uint16 max
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(max > 0, ZeroAmount());
    _getStorage().withdrawalConfig.maxClaimsPerTx = max;
    emit MaxClaimsPerTxSet(max);
  }

  /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function withdrawalPeriod() external view returns (uint32) {
    return _getStorage().withdrawalConfig.withdrawalPeriod;
  }

  function maxClaimsPerTx() external view returns (uint16) {
    return _getStorage().withdrawalConfig.maxClaimsPerTx;
  }

  function totalPendingWithdrawal() external view returns (uint256) {
    return _getStorage().withdrawalState.totalPendingWithdrawal;
  }

  function validatorCollateral(
    address validator
  ) external view returns (uint256) {
    return _getStorage().collateralData.validatorCollateral[validator];
  }

  function totalCollateralDeposited() external view returns (uint256) {
    return _getStorage().collateralData.totalCollateralDeposited;
  }

  function pendingWithdrawals() external view returns (uint256) {
    return _getStorage().withdrawalState.pendingWithdrawals;
  }

  function getTrackedValidators() external view returns (address[] memory) {
    return _getTrackedValidators();
  }

  function getOracleValidatorCollateral(
    address validator
  ) external view returns (ICollateralOracleFeed.Validator memory) {
    return COLLATERAL_ORACLE.getValidator(uint48(block.timestamp), validator);
  }

  function getOracleCollateralOwnership(
    address validator,
    address owner
  ) external view returns (ICollateralOracleFeed.CollateralOwnership memory) {
    return COLLATERAL_ORACLE.getCollateralOwnership(uint48(block.timestamp), validator, owner);
  }

  function getCollateralOwnershipTWAB(
    address validator,
    uint48 startTime,
    uint48 endTime
  ) external view returns (uint256) {
    return
      COLLATERAL_ORACLE.getCollateralOwnershipTWAB(startTime, endTime, validator, address(this));
  }

  function getTotalTWAB(
    address validator,
    uint48 startTime,
    uint48 endTime
  ) external view returns (uint256) {
    return COLLATERAL_ORACLE.getTotalTWAB(validator, startTime, endTime);
  }

  function earnedRewards(
    address account
  ) external view returns (uint256) {
    return _calculateEarnedRewards(account);
  }

  function rewardPerShare() external view returns (uint256) {
    return _getStorage().rewardState.rewardPerShareStored;
  }

  function rewardBalance() external view returns (uint256) {
    return IERC20(address(GM_MITO)).balanceOf(address(this));
  }

  function checkpointHistoryLength() external view returns (uint256) {
    return _getStorage().withdrawalState.exchangeRateHistory.length();
  }

  function latestCheckpoint() external view returns (Checkpoints.Checkpoint memory) {
    return _getStorage().withdrawalState.exchangeRateHistory.latest();
  }

  function getCheckpointAt(
    uint48 timestamp
  ) external view returns (Checkpoints.Checkpoint memory) {
    return _getStorage().withdrawalState.exchangeRateHistory.getAtTimestamp(timestamp);
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256
  ) internal override {
    if (from != address(0)) _updateUserReward(from);
    if (to != address(0) && to != from) _updateUserReward(to);
  }

  function _afterTokenTransfer(
    address,
    address,
    uint256
  ) internal override {
    _updateCheckpoint();
  }

  function _processDeposit(
    uint256 assets,
    uint256 shares,
    address receiver
  ) internal {
    SafeTransferLib.safeTransferFrom(address(WMITO), _msgSender(), address(this), assets);
    _mint(receiver, shares);
    emit Deposit(_msgSender(), receiver, assets, shares);
  }

  function _processWithdraw(
    uint256 assets,
    uint256 shares,
    address receiver,
    address owner
  ) internal {
    if (_msgSender() != owner) _spendAllowance(owner, _msgSender(), shares);
    _burn(owner, shares);
    _requestWithdraw(receiver, assets, shares);
    emit Withdraw(_msgSender(), receiver, owner, assets, shares);
  }

  function _requestWithdraw(
    address user,
    uint256 assets,
    uint256 shares
  ) internal returns (uint256 tokenId) {
    Storage storage $ = _getStorage();
    tokenId =
      WITHDRAWAL_NFT.mint(user, assets, shares, block.timestamp, address(WMITO), address(this));
    $.withdrawalState.totalPendingWithdrawal += assets;
    emit WithdrawalRequested(user, assets, shares, tokenId);
  }

  function _depositCollateralInternal(
    address validator,
    uint256 amount
  ) internal {
    require(amount > 0, ZeroAmount());
    require(VALIDATOR_MANAGER.isValidator(validator), InvalidValidator());
    require(hasRole(VALIDATOR_ROLE, validator), InvalidValidator());

    _syncCollateralWithOracle(validator);

    WMITO.withdraw(amount);
    VALIDATOR_MANAGER.depositCollateral{ value: amount }(validator);
    _updateCollateralAccounting(validator, amount, true);

    emit CollateralDeposited(validator, amount);
  }

  function _updateCollateralAccounting(
    address validator,
    uint256 amount,
    bool isDeposit
  ) internal {
    CollateralData storage collateralData = _getStorage().collateralData;

    if (isDeposit) {
      collateralData.validatorCollateral[validator] += amount;
      collateralData.totalCollateralDeposited += amount;
      collateralData.lastSyncedOracleValue[validator] += amount;
    } else {
      collateralData.validatorCollateral[validator] -= amount;
      collateralData.totalCollateralDeposited -= amount;
      collateralData.lastSyncedOracleValue[validator] -= amount;
    }
  }

  function _syncCollateralWithOracle(
    address validator
  ) internal {
    Storage storage $ = _getStorage();
    CollateralData storage collateralData = $.collateralData;

    uint256 oracleValue = _getOracleValidatorCollateral(validator);
    uint256 bookValue = collateralData.validatorCollateral[validator];

    if (oracleValue == bookValue) {
      collateralData.lastSyncedOracleValue[validator] = oracleValue;
      return;
    }

    uint256 oldTotal = collateralData.totalCollateralDeposited;
    uint256 newTotal = oldTotal - bookValue + oracleValue;
    collateralData.totalCollateralDeposited = newTotal;
    collateralData.validatorCollateral[validator] = oracleValue;
    collateralData.lastSyncedOracleValue[validator] = oracleValue;

    emit CollateralSynced(validator, bookValue, oracleValue);

    if (oracleValue < bookValue) {
      uint256 lossAmount = bookValue - oracleValue;

      WithdrawalState storage withdrawalState = $.withdrawalState;
      uint256 totalPending = withdrawalState.totalPendingWithdrawal;

      // Update pending withdrawals proportionally to reflect slashing
      if (totalPending > 0 && oldTotal > 0 && newTotal < oldTotal) {
        // Calculate new pending proportionally: pending * (newTotal / oldTotal)
        uint256 newPending = FixedPointMathLib.fullMulDiv(totalPending, newTotal, oldTotal);
        uint256 lostPending = totalPending - newPending;
        withdrawalState.totalPendingWithdrawal = newPending;

        emit PendingWithdrawalSlashed(validator, lostPending, newPending);
      }

      emit SlashingDetected(validator, lossAmount, oracleValue);
      _updateCheckpoint();
    }
  }

  function _updateUserReward(
    address account
  ) internal {
    RewardState storage rewardState = _getStorage().rewardState;
    uint256 userBalance = balanceOf(account);
    uint256 currentRewardPerShare = rewardState.rewardPerShareStored;
    uint256 rewardDelta =
      (userBalance * (currentRewardPerShare - rewardState.userRewardPerSharePaid[account])) / 1e18;
    rewardState.rewards[account] += rewardDelta;
    rewardState.userRewardPerSharePaid[account] = currentRewardPerShare;
  }

  function _calculateEarnedRewards(
    address account
  ) internal view returns (uint256) {
    RewardState storage rewardState = _getStorage().rewardState;
    uint256 userBalance = balanceOf(account);
    uint256 rewardDelta =
      (userBalance
          * (rewardState.rewardPerShareStored - rewardState.userRewardPerSharePaid[account])) / 1e18;
    return rewardState.rewards[account] + rewardDelta;
  }

  function _syncAllValidators() internal {
    address[] memory validators = _getTrackedValidators();
    for (uint256 i = 0; i < validators.length; i++) {
      _syncCollateralWithOracle(validators[i]);
    }
  }

  function _updateCheckpoint() internal {
    Storage storage $ = _getStorage();
    uint256 assets = totalAssets();
    uint256 shares = totalSupply();

    uint256 len = $.withdrawalState.exchangeRateHistory.length();
    if (len > 0) {
      Checkpoints.Checkpoint memory last = $.withdrawalState.exchangeRateHistory.latest();
      if (
        last.totalAssets == assets && last.totalShares == shares
          && block.timestamp - last.timestamp < 5 minutes
      ) return;
    }

    $.withdrawalState.exchangeRateHistory.push(assets, shares);
  }

  function _getOracleCollateralTotal() internal view returns (uint256) {
    address[] memory validators = _getTrackedValidators();
    return COLLATERAL_ORACLE.getTotalCollateral(validators, address(this), uint48(block.timestamp));
  }

  function _getTrackedValidators() internal view returns (address[] memory) {
    uint256 count = getRoleMemberCount(VALIDATOR_ROLE);
    address[] memory validators = new address[](count);

    for (uint256 i = 0; i < count; i++) {
      validators[i] = getRoleMember(VALIDATOR_ROLE, i);
    }

    return validators;
  }

  function _getOracleValidatorCollateral(
    address validator
  ) internal view returns (uint256) {
    return
      COLLATERAL_ORACLE.getValidatorCollateral(validator, address(this), uint48(block.timestamp));
  }

  function _getStorage() internal pure returns (Storage storage $) {
    assembly {
      $.slot := _STORAGE_SLOT
    }
  }

  function _authorizeUpgrade(
    address
  ) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
