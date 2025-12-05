// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { ERC20 } from '@solady/tokens/ERC20.sol';
import { WETH } from '@solady/tokens/WETH.sol';
import { FixedPointMathLib } from '@solady/utils/FixedPointMathLib.sol';
import { SafeTransferLib } from '@solady/utils/SafeTransferLib.sol';

import { IERC20 } from '@oz/token/ERC20/IERC20.sol';
import { Math } from '@oz/utils/math/Math.sol';

import {
  AccessControlEnumerableUpgradeable
} from '@ozu/access/extensions/AccessControlEnumerableUpgradeable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';
import {
  ReentrancyGuardTransientUpgradeable
} from '@ozu/utils/ReentrancyGuardTransientUpgradeable.sol';

import { IValidatorManager } from '@mitosis/interfaces/hub/validator/IValidatorManager.sol';
import {
  IValidatorRewardDistributor
} from '@mitosis/interfaces/hub/validator/IValidatorRewardDistributor.sol';
import { IValidatorStaking } from '@mitosis/interfaces/hub/validator/IValidatorStaking.sol';

import { IgmMITO } from '../interfaces/vaults/IgmMITO.sol';
import { ImMITOs } from '../interfaces/vaults/ImMITOs.sol';
import { ItMITO } from '../interfaces/vaults/ItMITO.sol';
import { IWithdrawalNFT } from '../interfaces/vaults/IWithdrawalNFT.sol';
import { Versioned } from '../libs/Versioned.sol';

/// @title mMITOs
/// @notice tMITO staking strategy vault (1:1 with tMITO)
contract mMITOs is
  ImMITOs,
  ERC20,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardTransientUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  using Math for uint256;

  /// @custom:storage-location erc7201:munja.storage.mMITOs
  struct Storage {
    uint32 withdrawalPeriod;
    uint16 maxClaimsPerTx;
    StakingState stakingState;
    RewardState rewardState;
  }

  struct StakingState {
    uint256 totalStaked;
    mapping(address validator => uint256) validatorStake;
  }

  struct RewardState {
    uint256 rewardPerShareStored;
    mapping(address user => uint256) userRewardPerSharePaid;
    mapping(address user => uint256) rewards;
  }

  bytes32 private constant _STORAGE_SLOT =
    0x3b5beb8fd5438e0ef1cfd74239cc665848b29ad98eb2b1f1c941d9191a1b4700;

  // keccak256(abi.encodePacked("operator"))
  bytes32 public constant OPERATOR_ROLE =
    0x46a52cf33029de9f84853745a87af28464c80bf0346df1b32e205fc73319f622;

  // keccak256(abi.encodePacked("validator"))
  bytes32 public constant VALIDATOR_ROLE =
    0x7f11e8a47c8f6f2761361211fdf25db4167076f4c74d7c390a15f4211bc8c214;

  ItMITO public immutable TMITO;
  WETH public immutable WMITO;
  IgmMITO public immutable GM_MITO;
  IValidatorManager public immutable VALIDATOR_MANAGER;
  IValidatorStaking public immutable TMITO_STAKING;
  IValidatorRewardDistributor public immutable REWARD_DISTRIBUTOR;
  IWithdrawalNFT public immutable WITHDRAWAL_NFT;

  constructor(
    address tmito,
    address wmito,
    address gmMito,
    address validatorManager,
    address tmitoStaking,
    address rewardDistributor,
    address withdrawalNFT
  ) {
    require(tmito != address(0), ZeroAddress());
    require(wmito != address(0), ZeroAddress());
    require(gmMito != address(0), ZeroAddress());
    require(validatorManager != address(0), ZeroAddress());
    require(tmitoStaking != address(0), ZeroAddress());
    require(rewardDistributor != address(0), ZeroAddress());
    require(withdrawalNFT != address(0), ZeroAddress());

    _disableInitializers();

    TMITO = ItMITO(payable(tmito));
    WMITO = WETH(payable(wmito));
    GM_MITO = IgmMITO(gmMito);
    VALIDATOR_MANAGER = IValidatorManager(validatorManager);
    TMITO_STAKING = IValidatorStaking(tmitoStaking);
    REWARD_DISTRIBUTOR = IValidatorRewardDistributor(rewardDistributor);
    WITHDRAWAL_NFT = IWithdrawalNFT(withdrawalNFT);
  }

  function initialize(
    address initialOwner,
    uint32 initialWithdrawalPeriod,
    uint16 initialMaxClaimsPerTx
  ) external initializer {
    require(initialOwner != address(0), ZeroAddress());
    require(initialMaxClaimsPerTx > 0, ZeroAmount());

    __AccessControlEnumerable_init();
    __ReentrancyGuardTransient_init();
    __UUPSUpgradeable_init();
    _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

    Storage storage $ = _getStorage();
    $.withdrawalPeriod = initialWithdrawalPeriod;
    $.maxClaimsPerTx = initialMaxClaimsPerTx;
  }

  /*//////////////////////////////////////////////////////////////
                          ERC20 OVERRIDES
  //////////////////////////////////////////////////////////////*/

  function name() public pure override returns (string memory) {
    return 'Munja tMITO Staking Vault';
  }

  function symbol() public pure override returns (string memory) {
    return 'mMITOs';
  }

  function decimals() public pure override returns (uint8) {
    return 18;
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256
  ) internal override {
    if (from != address(0)) _updateUserReward(from);
    if (to != address(0) && to != from) _updateUserReward(to);
  }

  /*//////////////////////////////////////////////////////////////
                        STAKING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Stake tMITO with a validator and receive mMITOs
  /// @param validator Validator address
  /// @param amount Amount to stake
  function stake(
    address validator,
    uint256 amount
  ) external {
    require(amount > 0, ZeroAmount());

    _processStake(validator, amount);
    _mint(_msgSender(), amount);
    emit Staked(_msgSender(), validator, amount);
  }

  /// @notice Request unstake from a validator and burn mMITOs
  /// @param validator Validator address
  /// @param amount Amount to unstake
  /// @return tokenId WithdrawalNFT token ID
  function requestUnstake(
    address validator,
    uint256 amount
  ) external returns (uint256 tokenId) {
    require(amount > 0, ZeroAmount());

    uint256 minUnstaking = TMITO_STAKING.minUnstakingAmount();
    require(amount >= minUnstaking, MinUnstakingAmountNotMet());

    StakingState storage stakingState = _getStorage().stakingState;
    require(stakingState.validatorStake[validator] >= amount, InsufficientStake());

    _burn(_msgSender(), amount);
    TMITO_STAKING.requestUnstake(validator, address(this), amount);

    stakingState.validatorStake[validator] -= amount;
    stakingState.totalStaked -= amount;

    // Mint WithdrawalNFT
    tokenId = WITHDRAWAL_NFT.mint(
      _msgSender(), amount, amount, block.timestamp, address(TMITO), address(this)
    );

    emit UnstakeRequested(_msgSender(), validator, amount);
  }

  /// @notice Claim matured withdrawals (supports single or batch)
  /// @param tokenIds Array of WithdrawalNFT token IDs
  /// @param validator Validator to attempt claiming unstake from (address(0) to skip auto-claim)
  /// @return totalClaimed Total amount claimed
  function claimWithdrawals(
    uint256[] calldata tokenIds,
    address validator
  ) external nonReentrant returns (uint256 totalClaimed) {
    Storage storage $ = _getStorage();
    uint256 length = tokenIds.length;
    require(length > 0 && length <= $.maxClaimsPerTx, InvalidLength());

    uint256 currentTime = block.timestamp;
    uint32 period = $.withdrawalPeriod;
    address user = _msgSender();

    for (uint256 i = 0; i < length; ++i) {
      uint256 tokenId = tokenIds[i];
      IWithdrawalNFT.WithdrawalResponse memory request =
        WITHDRAWAL_NFT.getWithdrawalRequest(tokenId);

      require(currentTime >= request.timestamp + period, WithdrawalNotMatured());
      require(request.owner == user, NotOwner());

      WITHDRAWAL_NFT.burn(tokenId);
      totalClaimed += request.assets;
    }

    require(totalClaimed > 0, ZeroAmount());

    // Auto-claim from validator staking
    if (validator != address(0)) {
      // Specific validator provided
      _tryClaimFromValidator(validator);
    } else {
      // Try all authorized validators
      address[] memory validators = _getAuthorizedValidators();
      for (uint256 i = 0; i < validators.length; ++i) {
        _tryClaimFromValidator(validators[i]);
      }
    }

    SafeTransferLib.safeTransfer(address(TMITO), user, totalClaimed);
    emit WithdrawalClaimed(user, totalClaimed, tokenIds);
  }

  /// @notice Compound rewards by restaking tMITO
  /// @param validator Validator address
  /// @param amount Amount to compound
  function compoundToStaking(
    address validator,
    uint256 amount
  ) external onlyRole(OPERATOR_ROLE) {
    require(hasRole(VALIDATOR_ROLE, validator), InvalidValidator());

    uint256 minStaking = TMITO_STAKING.minStakingAmount();
    require(amount >= minStaking, MinStakingAmountNotMet());

    StakingState storage stakingState = _getStorage().stakingState;

    SafeTransferLib.safeTransferFrom(address(TMITO), _msgSender(), address(this), amount);

    require(TMITO.approve(address(TMITO_STAKING), amount), ApproveFailed());
    TMITO_STAKING.stake(validator, address(this), amount);

    // Update tracking
    stakingState.validatorStake[validator] += amount;
    stakingState.totalStaked += amount;

    emit Staked(address(this), validator, amount);
  }

  /*//////////////////////////////////////////////////////////////
                        REWARD FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claim govMITO rewards from validators
  /// @param validators Validator addresses
  /// @return totalClaimed Total claimed
  function claimRewards(
    address[] calldata validators
  ) external onlyRole(OPERATOR_ROLE) returns (uint256 totalClaimed) {
    uint256 length = validators.length;
    for (uint256 i = 0; i < length; ++i) {
      totalClaimed += REWARD_DISTRIBUTOR.claimStakerRewards(address(this), validators[i]);
    }
  }

  /// @notice Claim and convert govMITO rewards to gmMITO
  /// @param validators Validator addresses
  /// @return gmMitoReceived Amount received
  function claimAndConvertRewards(
    address[] calldata validators
  ) external onlyRole(OPERATOR_ROLE) returns (uint256 gmMitoReceived) {
    require(validators.length > 0, ZeroAmount());

    uint256 supply = totalSupply();
    require(supply > 0, NoShares());

    gmMitoReceived = GM_MITO.userMint(validators, address(this));
    require(gmMitoReceived > 0, ZeroAmount());

    RewardState storage rewardState = _getStorage().rewardState;
    uint256 newRewardPerShare =
      rewardState.rewardPerShareStored + FixedPointMathLib.fullMulDiv(gmMitoReceived, 1e18, supply);
    rewardState.rewardPerShareStored = newRewardPerShare;
    emit RewardDistributed(gmMitoReceived, newRewardPerShare);
  }

  /// @notice Distribute gmMITO rewards (batch distribution)
  /// @param amount Amount to distribute
  function distributeRewards(
    uint256 amount
  ) external onlyRole(OPERATOR_ROLE) {
    require(amount > 0, ZeroAmount());

    uint256 supply = totalSupply();
    require(supply > 0, NoShares());

    SafeTransferLib.safeTransferFrom(address(GM_MITO), _msgSender(), address(this), amount);

    RewardState storage rewardState = _getStorage().rewardState;
    uint256 newRewardPerShare =
      rewardState.rewardPerShareStored + FixedPointMathLib.fullMulDiv(amount, 1e18, supply);
    rewardState.rewardPerShareStored = newRewardPerShare;
    emit RewardDistributed(amount, newRewardPerShare);
  }

  /// @notice Claim accumulated gmMITO rewards
  /// @return reward Amount claimed
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

  /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function validatorStake(
    address validator
  ) external view returns (uint256) {
    return _getStorage().stakingState.validatorStake[validator];
  }

  function totalStaked() external view returns (uint256) {
    return _getStorage().stakingState.totalStaked;
  }

  function getAuthorizedValidators() external view returns (address[] memory) {
    return _getAuthorizedValidators();
  }

  function earnedRewards(
    address account
  ) external view returns (uint256) {
    RewardState storage rewardState = _getStorage().rewardState;
    return rewardState.rewards[account] + _calculateRewardDelta(rewardState, account);
  }

  function rewardPerShare() external view returns (uint256) {
    return _getStorage().rewardState.rewardPerShareStored;
  }

  function rewardBalance() external view returns (uint256) {
    return IERC20(address(GM_MITO)).balanceOf(address(this));
  }

  function withdrawalPeriod() external view returns (uint32) {
    return _getStorage().withdrawalPeriod;
  }

  function maxClaimsPerTx() external view returns (uint16) {
    return _getStorage().maxClaimsPerTx;
  }

  function userRewardPerSharePaid(
    address account
  ) external view returns (uint256) {
    return _getStorage().rewardState.userRewardPerSharePaid[account];
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @dev Process staking to validator (DRY helper)
  function _processStake(
    address validator,
    uint256 amount
  ) internal {
    StakingState storage stakingState = _getStorage().stakingState;

    // Only allow staking to authorized validators
    require(hasRole(VALIDATOR_ROLE, validator), InvalidValidator());

    uint256 minStaking = TMITO_STAKING.minStakingAmount();
    require(amount >= minStaking, MinStakingAmountNotMet());

    SafeTransferLib.safeTransferFrom(address(TMITO), _msgSender(), address(this), amount);

    require(TMITO.approve(address(TMITO_STAKING), amount), ApproveFailed());
    TMITO_STAKING.stake(validator, address(this), amount);

    // Update tracking
    stakingState.validatorStake[validator] += amount;
    stakingState.totalStaked += amount;
  }

  /// @dev Update user reward (eager calculation on balance change)
  function _updateUserReward(
    address account
  ) internal {
    RewardState storage rewardState = _getStorage().rewardState;
    uint256 rewardDelta = _calculateRewardDelta(rewardState, account);
    rewardState.rewards[account] += rewardDelta;
    rewardState.userRewardPerSharePaid[account] = rewardState.rewardPerShareStored;
  }

  /// @dev Calculate pending reward delta (lazy helper)
  function _calculateRewardDelta(
    RewardState storage rewardState,
    address account
  ) internal view returns (uint256) {
    uint256 userBalance = balanceOf(account);
    return FixedPointMathLib.fullMulDiv(
      userBalance,
      rewardState.rewardPerShareStored - rewardState.userRewardPerSharePaid[account],
      1e18
    );
  }

  /// @dev Try to claim unstaked tMITO from validator (silent fail if nothing available)
  function _tryClaimFromValidator(
    address validator
  ) internal {
    try TMITO_STAKING.claimUnstake(validator) { } catch { }
  }

  /// @dev Get all authorized validators
  function _getAuthorizedValidators() internal view returns (address[] memory) {
    uint256 count = getRoleMemberCount(VALIDATOR_ROLE);
    address[] memory validators = new address[](count);

    for (uint256 i = 0; i < count; i++) {
      validators[i] = getRoleMember(VALIDATOR_ROLE, i);
    }

    return validators;
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
