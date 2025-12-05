// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { ERC4626 } from '@solady/tokens/ERC4626.sol';
import { SafeTransferLib } from '@solady/utils/SafeTransferLib.sol';

import { SafeCast } from '@oz/utils/math/SafeCast.sol';

import {
  AccessControlEnumerableUpgradeable
} from '@ozu/access/extensions/AccessControlEnumerableUpgradeable.sol';
import { OwnableUpgradeable } from '@ozu/access/OwnableUpgradeable.sol';
import { UUPSUpgradeable } from '@ozu/proxy/utils/UUPSUpgradeable.sol';

import { IGovMITO } from '@mitosis/interfaces/hub/IGovMITO.sol';
import { IValidatorManager } from '@mitosis/interfaces/hub/validator/IValidatorManager.sol';
import {
  IValidatorRewardDistributor
} from '@mitosis/interfaces/hub/validator/IValidatorRewardDistributor.sol';
import { IValidatorStaking } from '@mitosis/interfaces/hub/validator/IValidatorStaking.sol';

import { IgmMITO } from '../interfaces/vaults/IgmMITO.sol';
import { IWithdrawalNFT } from '../interfaces/vaults/IWithdrawalNFT.sol';
import { Versioned } from '../libs/Versioned.sol';

/// @title gmMITO
/// @notice ERC4626 vault for govMITO with claim and withdrawal queue functionality
/// @dev All-in-one vault that holds govMITO directly
/// @dev Uses ERC721 NFTs to represent pending withdrawal requests
contract gmMITO is
  IgmMITO,
  ERC4626,
  OwnableUpgradeable,
  AccessControlEnumerableUpgradeable,
  UUPSUpgradeable,
  Versioned
{
  using SafeCast for uint256;

  /// @custom:storage-location erc7201:munja.storage.gmMITO
  struct Storage {
    uint32 withdrawalPeriod;
    uint16 maxClaimsPerTx;
    uint128 totalPendingWithdrawal;
    uint8 lastStakeValidatorIndex;
    uint8 lastUnstakeValidatorIndex;
  }

  // keccak256(abi.encode(uint256(keccak256("munja.storage.gmMITO")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _STORAGE_SLOT =
    0x03095cd7fd0bfe73fb3319f5811c90a09c5ce65e066162906a6c2d3022d7d500;

  // keccak256(abi.encodePacked("validator"))
  bytes32 public constant VALIDATOR_ROLE =
    0x7f11e8a47c8f6f2761361211fdf25db4167076f4c74d7c390a15f4211bc8c214;

  function _getStorage() internal pure returns (Storage storage $) {
    assembly {
      $.slot := _STORAGE_SLOT
    }
  }

  IGovMITO public immutable GOV_MITO;
  IValidatorRewardDistributor public immutable REWARD_DISTRIBUTOR;
  IValidatorStaking public immutable VALIDATOR_STAKING;
  IValidatorManager public immutable VALIDATOR_MANAGER;
  IWithdrawalNFT public immutable WITHDRAWAL_NFT;

  constructor(
    address govMito,
    address rewardDistributor,
    address validatorStaking,
    address validatorManager,
    address withdrawalNFT
  ) {
    require(govMito != address(0), ZeroAddress());
    require(rewardDistributor != address(0), ZeroAddress());
    require(validatorStaking != address(0), ZeroAddress());
    require(validatorManager != address(0), ZeroAddress());
    require(withdrawalNFT != address(0), ZeroAddress());

    _disableInitializers();

    GOV_MITO = IGovMITO(payable(govMito));
    REWARD_DISTRIBUTOR = IValidatorRewardDistributor(rewardDistributor);
    VALIDATOR_STAKING = IValidatorStaking(validatorStaking);
    VALIDATOR_MANAGER = IValidatorManager(validatorManager);
    WITHDRAWAL_NFT = IWithdrawalNFT(withdrawalNFT);
  }

  function initialize(
    address initialOwner,
    uint32 initialWithdrawalPeriod,
    uint16 initialMaxClaimsPerTx
  ) external initializer {
    __Ownable_init(initialOwner);
    __AccessControlEnumerable_init();
    __UUPSUpgradeable_init();

    Storage storage $ = _getStorage();
    _setWithdrawalPeriod($, initialWithdrawalPeriod);
    _setMaxClaimsPerTx($, initialMaxClaimsPerTx);

    // Grant DEFAULT_ADMIN_ROLE to owner
    _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

    // max approval
    GOV_MITO.approve(address(VALIDATOR_STAKING), type(uint128).max);
  }

  /*//////////////////////////////////////////////////////////////
                            ERC4626 OVERRIDES
  //////////////////////////////////////////////////////////////*/

  function name() public pure override returns (string memory) {
    return 'Munja Governance MITO';
  }

  function symbol() public pure override returns (string memory) {
    return 'gmMITO';
  }

  function asset() public view override returns (address) {
    return address(GOV_MITO);
  }

  function totalAssets() public view override returns (uint256) {
    // Total = balance + staked amount (excluding unclaimed rewards)
    uint256 balance = GOV_MITO.balanceOf(address(this));
    uint256 staked = VALIDATOR_STAKING.stakerTotal(address(this), uint48(block.timestamp));
    return balance + staked;
  }

  /// @notice Deposit is not supported (use claim functions)
  function deposit(
    uint256,
    address
  ) public pure override returns (uint256) {
    revert DepositNotSupported();
  }

  /// @notice Mint is not supported (use claim functions)
  function mint(
    uint256,
    address
  ) public pure override returns (uint256) {
    revert DepositNotSupported();
  }

  /// @notice Withdraw govMITO
  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public override returns (uint256 shares) {
    shares = previewWithdraw(assets);

    if (_msgSender() != owner) _spendAllowance(owner, _msgSender(), shares);

    _burn(owner, shares);

    // Request withdrawal
    _requestWithdraw(receiver, assets, shares);

    emit Withdraw(_msgSender(), receiver, owner, assets, shares);

    return shares;
  }

  /// @notice Redeem gmMITO for govMITO
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public override returns (uint256 assets) {
    assets = previewRedeem(shares);

    if (_msgSender() != owner) _spendAllowance(owner, _msgSender(), shares);

    _burn(owner, shares);

    // Request withdrawal
    _requestWithdraw(receiver, assets, shares);

    emit Withdraw(_msgSender(), receiver, owner, assets, shares);

    return assets;
  }

  /*//////////////////////////////////////////////////////////////
                        CLAIM & CONVERT FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IgmMITO
  /// @dev Caller must be the user and must have approved this contract as staker claim operator
  /// @dev Automatically processes matured unstake requests before claiming
  function userMint(
    address[] calldata validators,
    address recipient
  ) external returns (uint256 shares) {
    require(validators.length > 0, ZeroAmount());
    require(recipient != address(0), ZeroAddress());

    _process();

    address to = _msgSender();
    uint256 assets = 0;

    for (uint256 i = 0; i < validators.length; i++) {
      address validator = validators[i];

      require(
        REWARD_DISTRIBUTOR.stakerClaimAllowed(to, validator, address(this)), //
        NotApproved()
      );

      (uint256 claimableAssets,) = REWARD_DISTRIBUTOR.claimableStakerRewards(to, validator);
      if (claimableAssets == 0) continue;

      require(claimableAssets <= maxDeposit(to), DepositMoreThanMax());

      uint256 claimedShares = previewDeposit(claimableAssets);
      {
        _mint(recipient, claimedShares);
        shares += claimedShares;
      }

      uint256 claimedAssets = REWARD_DISTRIBUTOR.claimStakerRewards(to, validator);
      require(claimedAssets == claimableAssets, AmountMismatch());

      assets += claimedAssets;

      emit UserRewardsClaimed(validator, to, recipient, claimedAssets, claimedShares);
    }

    require(shares > 0, ZeroAmount());

    emit Deposit(to, recipient, assets, shares);

    _afterDeposit(assets, shares);
  }

  /// @inheritdoc IgmMITO
  /// @dev Caller must be the operator and must have approved this contract as operator claim operator
  /// @dev Automatically processes matured unstake requests before claiming
  function operatorMint(
    address[] calldata validators,
    address recipient
  ) external returns (uint256 shares) {
    require(validators.length > 0, ZeroAmount());
    require(recipient != address(0), ZeroAddress());

    _process();

    uint256 assets = 0;

    for (uint256 i = 0; i < validators.length; i++) {
      address validator = validators[i];

      address rewardManager = VALIDATOR_MANAGER.validatorInfo(validator).rewardManager;
      require(rewardManager == _msgSender(), Unauthorized());
      require(
        REWARD_DISTRIBUTOR.operatorClaimAllowed(rewardManager, validator, address(this)),
        NotApproved()
      );

      (uint256 claimableAssets,) = REWARD_DISTRIBUTOR.claimableOperatorRewards(validator);
      if (claimableAssets == 0) continue;

      require(claimableAssets <= maxDeposit(rewardManager), DepositMoreThanMax());

      uint256 claimedShares = previewDeposit(claimableAssets);
      {
        _mint(recipient, claimedShares);
        shares += claimedShares;
      }

      uint256 claimedAssets = REWARD_DISTRIBUTOR.claimOperatorRewards(validator);
      require(claimedAssets == claimableAssets, AmountMismatch());

      assets += claimedAssets;

      emit OperatorRewardsClaimed(validator, rewardManager, recipient, claimedAssets, claimedShares);
    }

    require(shares > 0, ZeroAmount());

    emit Deposit(_msgSender(), recipient, assets, shares);

    _afterDeposit(assets, shares);
  }

  /// @inheritdoc IgmMITO
  /// @dev Claims rewards from gmMITO vault's own staking and restakes for compounding
  /// @dev Automatically processes matured unstake requests before compounding
  /// @dev Only claims from validators with claimable >= minStakingAmount to avoid idle govMITO
  function compound() external returns (uint256 totalCompounded) {
    _process();

    address[] memory validators = _getAuthorizedValidators();
    require(validators.length > 0, NoValidators());

    uint256 minStaking = VALIDATOR_STAKING.minStakingAmount();

    for (uint256 i = 0; i < validators.length; i++) {
      address validator = validators[i];

      // Check claimable first to avoid claiming and leaving idle govMITO
      (uint256 claimable,) = REWARD_DISTRIBUTOR.claimableStakerRewards(address(this), validator);
      if (claimable < minStaking) continue;

      uint256 compounded = REWARD_DISTRIBUTOR.claimStakerRewards(address(this), validator);
      VALIDATOR_STAKING.stake(validator, address(this), compounded);
      emit RewardsStaked(validator, compounded);
      emit RewardsCompounded(validator, compounded);
      totalCompounded += compounded;
    }

    require(totalCompounded > 0, ZeroAmount());
  }

  /// @inheritdoc IgmMITO
  /// @dev Claims matured unstake → immediately requests govMITO withdrawal
  /// @dev This is called automatically before most operations, or manually by anyone
  function process() external returns (uint256) {
    return _process();
  }

  /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IgmMITO
  function totalPendingWithdrawal() external view returns (uint256) {
    return _getStorage().totalPendingWithdrawal;
  }

  /// @inheritdoc IgmMITO
  function withdrawalPeriod() external view returns (uint32) {
    return _getStorage().withdrawalPeriod;
  }

  /// @inheritdoc IgmMITO
  function maxClaimsPerTx() external view returns (uint16) {
    return _getStorage().maxClaimsPerTx;
  }

  /// @inheritdoc IgmMITO
  function claimWithdraw(
    uint256[] calldata tokenIds
  ) external returns (uint256) {
    Storage storage $ = _getStorage();

    // Determine claim limit
    uint256 tokenIdsLen = tokenIds.length;
    require(0 < tokenIdsLen && tokenIdsLen <= $.maxClaimsPerTx, ArrayOutOfBounds());

    uint256 maturity = block.timestamp - $.withdrawalPeriod;

    uint256 totalClaimed = 0;
    uint256 totalClaimedTokens = 0;

    for (uint256 i = 0; i < tokenIdsLen; i++) {
      uint256 tokenId = tokenIds[i];
      IWithdrawalNFT.WithdrawalResponse memory withdrawal =
        WITHDRAWAL_NFT.getWithdrawalRequest(tokenId);

      if (withdrawal.timestamp <= maturity) {
        totalClaimed += withdrawal.assets;
        totalClaimedTokens++;
      }

      WITHDRAWAL_NFT.burn(tokenId);
    }

    require(totalClaimed > 0, NoClaimableWithdrawals());

    $.totalPendingWithdrawal -= totalClaimed.toUint128();

    uint256 mitoClaimed = GOV_MITO.claimWithdraw(address(this));
    require(mitoClaimed == totalClaimed, AmountMismatch());

    // Transfer claimed govMITO to user
    SafeTransferLib.safeTransfer(address(GOV_MITO), _msgSender(), mitoClaimed);

    emit WithdrawalClaimed(_msgSender(), totalClaimed, totalClaimedTokens, tokenIds);

    return totalClaimed;
  }

  /// @inheritdoc IgmMITO
  function setWithdrawalPeriod(
    uint32 withdrawalPeriod_
  ) external onlyOwner {
    _setWithdrawalPeriod(_getStorage(), withdrawalPeriod_);
  }

  /// @inheritdoc IgmMITO
  function setMaxClaimsPerTx(
    uint16 maxClaimsPerTx_
  ) external onlyOwner {
    _setMaxClaimsPerTx(_getStorage(), maxClaimsPerTx_);
  }

  /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _process() internal returns (uint256) {
    // Claim matured unstake requests
    (, uint256 claimable) = VALIDATOR_STAKING.unstaking(address(this), uint48(block.timestamp));
    if (claimable == 0) return 0;

    uint256 claimed = VALIDATOR_STAKING.claimUnstake(address(this));
    require(claimed == claimable, AmountMismatch());

    GOV_MITO.requestWithdraw(address(this), claimed);
    emit UnstakeProcessed(claimed);

    return claimed;
  }

  function _afterDeposit(
    uint256 assets,
    uint256 /* shares */
  ) internal override {
    uint256 balance = GOV_MITO.balanceOf(address(this));
    require(assets <= balance, InvalidAmount());

    uint256 minStaking = VALIDATOR_STAKING.minStakingAmount();
    require(assets >= minStaking, MinStakingAmountNotMet());

    address[] memory validators = _getAuthorizedValidators();
    require(validators.length > 0, NoValidators());

    Storage storage $ = _getStorage();
    uint256 validatorCount = validators.length;
    uint256 startIndex = $.lastStakeValidatorIndex;

    // Calculate how many validators can receive stake
    uint256 recipientCount = assets / minStaking;
    if (recipientCount > validatorCount) recipientCount = validatorCount;

    // Distribute round-robin starting from lastStakeValidatorIndex
    for (uint256 i = 0; i < recipientCount; i++) {
      uint256 validatorIndex = (startIndex + i) % validatorCount;
      address validator = validators[validatorIndex];

      // Distribute evenly with remainder going to first recipients
      uint256 amountToStake = assets / recipientCount;
      if (i < assets % recipientCount) amountToStake += 1;

      VALIDATOR_STAKING.stake(validator, address(this), amountToStake);
      emit RewardsStaked(validator, amountToStake);
    }

    // Update last index for next round
    $.lastStakeValidatorIndex = uint8((startIndex + recipientCount) % validatorCount);
  }

  /// @notice Request withdrawal (internal)
  /// @dev Automatically requests unstake from validators with available stake
  /// @dev GOV_MITO.requestWithdraw will be called later in process() after unstaking completes
  /// @dev Uses greedy round-robin: unstakes from validators with actual stake balance
  function _requestWithdraw(
    address user,
    uint256 assets,
    uint256 shares
  ) internal returns (uint256 tokenId) {
    uint256 minUnstaking = VALIDATOR_STAKING.minUnstakingAmount();
    require(assets >= minUnstaking, MinUnstakingAmountNotMet());

    address[] memory validators = _getAuthorizedValidators();
    uint256 validatorCount = validators.length;
    require(validatorCount > 0, NoValidators());

    Storage storage $ = _getStorage();
    uint256 startIndex = $.lastUnstakeValidatorIndex;
    uint48 currentTime = uint48(block.timestamp);

    uint256 remaining = assets;
    uint256 lastProcessedIndex = startIndex;

    // Greedy round-robin: unstake from validators with available stake
    for (uint256 i = 0; i < validatorCount && remaining > 0; i++) {
      uint256 validatorIndex = (startIndex + i) % validatorCount;
      address validator = validators[validatorIndex];

      // Check actual stake balance for this validator
      uint256 available = VALIDATOR_STAKING.staked(validator, address(this), currentTime);
      if (available == 0) continue;

      // Calculate amount to unstake from this validator
      uint256 amountToUnstake = remaining > available ? available : remaining;

      // Skip if below minUnstaking (unless it's the last validator and we need exactly this amount)
      if (amountToUnstake < minUnstaking) continue;

      VALIDATOR_STAKING.requestUnstake(validator, address(this), amountToUnstake);
      remaining -= amountToUnstake;
      lastProcessedIndex = (validatorIndex + 1) % validatorCount;
    }

    require(remaining == 0, InsufficientGovMitoBalance());

    // Update last index for next round
    $.lastUnstakeValidatorIndex = uint8(lastProcessedIndex);

    tokenId = WITHDRAWAL_NFT.mint(
      user, //
      assets,
      shares,
      block.timestamp,
      address(GOV_MITO),
      address(this)
    );

    $.totalPendingWithdrawal += assets.toUint128();

    emit WithdrawalRequested(user, assets, shares, tokenId);
  }

  function _setWithdrawalPeriod(
    Storage storage $,
    uint32 withdrawalPeriod_
  ) internal {
    uint256 govMitoWithdrawalPeriod = GOV_MITO.withdrawalPeriod();
    require(govMitoWithdrawalPeriod < withdrawalPeriod_, PeriodMustBeLongerThanGovMito());

    $.withdrawalPeriod = withdrawalPeriod_;
    emit WithdrawalPeriodSet(withdrawalPeriod_);
  }

  function _setMaxClaimsPerTx(
    Storage storage $,
    uint16 maxClaimsPerTx_
  ) internal {
    require(maxClaimsPerTx_ > 0, ZeroAmount());
    $.maxClaimsPerTx = maxClaimsPerTx_;
    emit MaxClaimsPerTxSet(maxClaimsPerTx_);
  }

  function _authorizeUpgrade(
    address
  ) internal override onlyOwner { }

  /// @notice Get all authorized validators
  /// @dev Returns all addresses with VALIDATOR_ROLE
  function _getAuthorizedValidators() internal view returns (address[] memory) {
    uint256 count = getRoleMemberCount(VALIDATOR_ROLE);
    address[] memory validators = new address[](count);
    for (uint256 i = 0; i < count; i++) {
      validators[i] = getRoleMember(VALIDATOR_ROLE, i);
    }
    return validators;
  }
}
