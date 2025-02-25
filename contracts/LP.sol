// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.9;

import "./interface/IAccess.sol";
import "./interface/ICoreBase.sol";
import "./interface/ILP.sol";
import "./interface/IOwnable.sol";
import "./interface/IWNative.sol";
import "./interface/IBet.sol";
import "./interface/IAffiliate.sol";
import "./interface/ILiquidityManager.sol";
import "./libraries/FixedMath.sol";
import "./libraries/SafeCast.sol";
import "./utils/LiquidityTree.sol";
import "./utils/OwnableUpgradeable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";

/// @title Azuro Liquidity Pool managing
contract LP is
    LiquidityTree,
    OwnableUpgradeable,
    ERC721EnumerableUpgradeable,
    ILP
{
    using FixedMath for uint64;
    using SafeCast for uint256;
    using SafeCast for uint128;

    IOwnable public factory;
    IAccess public access;

    address public token;
    address public dataProvider;

    uint128 public minDepo; // Minimum amount of liquidity deposit
    uint128 public lockedLiquidity; // Liquidity reserved by conditions

    uint64 public claimTimeout; // Withdraw reward timeout
    uint64 public withdrawTimeout; // Deposit-withdraw liquidity timeout

    mapping(address => CoreData) public cores;

    mapping(uint256 => Game) public games;

    uint64[3] public fees;

    mapping(address => Reward) public rewards;
    // withdrawAfter[depNum] = timestamp when liquidity withdraw will be available
    mapping(uint48 => uint64) public withdrawAfter;
    mapping(address => uint128) public override coreAffRewards; // Affiliate rewards by Core's conditions

    ILiquidityManager public liquidityManager;

    /**
     * @notice Check if Core `core` belongs to this Liquidity Pool and is active.
     */
    modifier isActive(address core) {
        _checkCoreActive(core);
        _;
    }

    /**
     * @notice Check if Core `core` belongs to this Liquidity Pool.
     */
    modifier isCore(address core) {
        checkCore(core);
        _;
    }

    /**
     * @notice Throw if caller is not the Pool Factory.
     */
    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert OnlyFactory();
        _;
    }

    /**
     * @notice Throw if caller have no access to function with selector `selector`.
     */
    modifier restricted(bytes4 selector) {
        checkAccess(msg.sender, address(this), selector);
        _;
    }

    receive() external payable {
        require(msg.sender == token);
    }

    function initialize(
        address access_,
        address dataProvider_,
        address token_,
        uint128 minDepo_,
        uint64 daoFee,
        uint64 dataProviderFee,
        uint64 affiliateFee
    ) external virtual override initializer {
        if (minDepo_ == 0) revert IncorrectMinDepo();

        __Ownable_init();
        __ERC721_init("Azuro LP NFT token", "LP-AZR");
        __liquidityTree_init();
        factory = IOwnable(msg.sender);
        access = IAccess(access_);
        dataProvider = dataProvider_;
        token = token_;
        fees[0] = daoFee;
        fees[1] = dataProviderFee;
        fees[2] = affiliateFee;
        _checkFee();
        minDepo = minDepo_;
    }

    /**
     * @notice Owner: Set `newClaimTimeout` as claim timeout.
     */
    function changeClaimTimeout(uint64 newClaimTimeout) external onlyOwner {
        claimTimeout = newClaimTimeout;
        emit ClaimTimeoutChanged(newClaimTimeout);
    }

    /**
     * @notice Owner: Set `newDataProvider` as Data Provider.
     */
    function changeDataProvider(address newDataProvider) external onlyOwner {
        dataProvider = newDataProvider;
        emit DataProviderChanged(newDataProvider);
    }

    /**
     * @notice Owner: Set `newFee` as type `feeType` fee.
     * @param  newFee fee share where `FixedMath.ONE` is 100% of the Liquidity Pool profit
     */
    function changeFee(FeeType feeType, uint64 newFee) external onlyOwner {
        fees[uint256(feeType)] = newFee;
        _checkFee();
        emit FeeChanged(feeType, newFee);
    }

    /**
     * @notice Owner: Set `newLiquidityManager` as liquidity manager contract address.
     */
    function changeLiquidityManager(address newLiquidityManager)
        external
        onlyOwner
    {
        liquidityManager = ILiquidityManager(newLiquidityManager);
        emit LiquidityManagerChanged(newLiquidityManager);
    }

    /**
     * @notice Owner: Set `newMinDepo` as minimum liquidity deposit.
     */
    function changeMinDepo(uint128 newMinDepo) external onlyOwner {
        if (newMinDepo == 0) revert IncorrectMinDepo();
        minDepo = newMinDepo;
        emit MinDepoChanged(newMinDepo);
    }

    /**
     * @notice Owner: Set `withdrawTimeout` as liquidity deposit withdrawal timeout.
     */
    function changeWithdrawTimeout(uint64 newWithdrawTimeout)
        external
        onlyOwner
    {
        withdrawTimeout = newWithdrawTimeout;
        emit WithdrawTimeoutChanged(newWithdrawTimeout);
    }

    /**
     * @notice Owner: Update Core `core` settings.
     */
    function updateCoreSettings(
        address core,
        CoreState state,
        uint64 reinforcementAbility,
        uint128 minBet
    ) external onlyOwner isCore(core) {
        if (minBet == 0) revert IncorrectMinBet();
        if (reinforcementAbility > FixedMath.ONE)
            revert IncorrectReinforcementAbility();
        if (state == CoreState.UNKNOWN) revert IncorrectCoreState();

        CoreData storage coreData = cores[core];
        coreData.minBet = minBet;
        coreData.reinforcementAbility = reinforcementAbility;
        coreData.state = state;

        emit CoreSettingsUpdated(core, state, reinforcementAbility, minBet);
    }

    /**
     * @notice See {ILP-cancelGame}.
     */
    function cancelGame(uint256 gameId)
        external
        restricted(this.cancelGame.selector)
    {
        Game storage game = _getGame(gameId);
        if (game.canceled) revert GameAlreadyCanceled();

        lockedLiquidity -= game.lockedLiquidity;
        game.canceled = true;
        emit GameCanceled(gameId);
    }

    /**
     * @notice See {ILP-createGame}.
     */
    function createGame(
        uint256 gameId,
        bytes32 ipfsHash,
        uint64 startsAt
    ) external restricted(this.createGame.selector) {
        Game storage game = games[gameId];
        if (game.startsAt > 0) revert GameAlreadyCreated();
        if (gameId == 0) revert IncorrectGameId();
        if (startsAt < block.timestamp) revert IncorrectTimestamp();

        game.ipfsHash = ipfsHash;
        game.startsAt = startsAt;

        emit NewGame(gameId, ipfsHash, startsAt);
    }

    /**
     * @notice See {ILP-shiftGame}.
     */
    function shiftGame(uint256 gameId, uint64 startsAt)
        external
        restricted(this.shiftGame.selector)
    {
        _getGame(gameId).startsAt = startsAt;
        emit GameShifted(gameId, startsAt);
    }

    /**
     * @notice Deposit liquidity in the Liquidity Pool.
     * @notice Emits deposit token to `msg.sender`.
     * @param  amount token's amount to deposit
     */
    function addLiquidity(uint128 amount) external {
        _deposit(amount);
        _addLiquidity(amount);
    }

    /**
     * @notice Deposit liquidity in the Liquidity Pool via sending native tokens with msg.value.
     * @notice Emits deposit token to `msg.sender`.
     */
    function addLiquidityNative() external payable {
        _depositNative();
        _addLiquidity(msg.value.toUint128());
    }

    /**
     * @notice Withdraw payout for liquidity deposit.
     * @param  depNum deposit token ID
     * @param  percent payout share to withdraw where `FixedMath.ONE` is 100% of deposit payout
     * @param  isNative whether to make withdrawal in native or `token` tokens
     */
    function withdrawLiquidity(
        uint48 depNum,
        uint40 percent,
        bool isNative
    ) external {
        _withdraw(msg.sender, _withdrawLiquidity(depNum, percent), isNative);
    }

    /**
     * @notice Withdraw affiliate profit share based on the contribution to betting traffic.
     * @notice The gas cost of the function is directly proportional to the number of elements of
               the array of all conditions contributed by the affiliate that are not rewarded yet.
     * @param  core address of the Core traffic to which should be rewarded
     * @param  data core specific params
     * @return claimedAmount claimed reward amount
     */
    function claimAffiliateReward(address core, bytes calldata data)
        external
        isCore(core)
        returns (uint128 claimedAmount)
    {
        claimedAmount = IAffiliate(core)
            .resolveAffiliateReward(msg.sender, data)
            .toUint128();
        if (claimedAmount > 0) {
            _withdraw(msg.sender, claimedAmount, false);
            emit AffiliateRewarded(msg.sender, claimedAmount);
        }
    }

    /**
     * @notice Reward the Factory owner (DAO) or Data Provider with total amount of charged fees.
     * @return claimedAmount claimed reward amount
     */
    function claimReward() external returns (uint128 claimedAmount) {
        Reward storage reward = rewards[msg.sender];
        if ((block.timestamp - reward.claimedAt) < claimTimeout)
            revert ClaimTimeout(reward.claimedAt + claimTimeout);

        int128 rewardAmount = reward.amount;
        if (rewardAmount > 0) {
            reward.amount = 0;
            reward.claimedAt = uint64(block.timestamp);

            claimedAmount = uint128(rewardAmount);
            _withdraw(msg.sender, claimedAmount, false);
        }
    }

    /**
     * @notice Make new bet.
     * @notice Emits bet token to `msg.sender`.
     * @notice See {ILP-bet}.
     */
    function bet(
        address core,
        uint128 amount,
        uint64 expiresAt,
        IBet.BetData calldata betData
    ) external override returns (uint256) {
        _deposit(amount);
        return _bet(msg.sender, core, amount, expiresAt, betData);
    }

    /**
     * @notice Make new bet for `bettor`.
     * @notice Emits bet token to `bettor`.
     * @param  bettor wallet for emitting bet token
     * @param  core address of the Core the bet is intended
     * @param  amount amount of tokens to bet
     * @param  expiresAt the time before which bet should be made
     * @param  betData customized bet data
     */
    function betFor(
        address bettor,
        address core,
        uint128 amount,
        uint64 expiresAt,
        IBet.BetData calldata betData
    ) external override returns (uint256) {
        _deposit(amount);
        return _bet(bettor, core, amount, expiresAt, betData);
    }

    /**
     * @notice Make new bet via sending native tokens with msg.value.
     * @notice Emits bet token to `msg.sender`.
     * @param  core address of the Core the bet is intended
     * @param  expiresAt the time before which bet should be made
     * @param  betData customized bet data
     */
    function betNative(
        address core,
        uint64 expiresAt,
        IBet.BetData calldata betData
    ) external payable override returns (uint256) {
        _depositNative();
        return
            _bet(msg.sender, core, msg.value.toUint128(), expiresAt, betData);
    }

    /**
     * @notice Core: Withdraw payout for bet token `tokenId` from the Core `core`.
     * @param  isNative whether to make withdrawal in native or `token` tokens
     */
    function withdrawPayout(
        address core,
        uint256 tokenId,
        bool isNative
    ) external override isCore(core) {
        (address account, uint128 amount) = IBet(core).resolvePayout(tokenId);
        if (amount > 0) {
            _withdraw(account, amount, isNative);
            emit BettorWin(core, account, tokenId, amount);
        }
    }

    /**
     * @notice Active Core: Check if Core `msg.sender` can create condition for game `gameId`.
     */
    function addCondition(uint256 gameId)
        external
        view
        override
        isActive(msg.sender)
        returns (uint64)
    {
        Game storage game = _getGame(gameId);
        if (game.canceled) revert GameCanceled_();

        return game.startsAt;
    }

    /**
     * @notice Active Core: Change amount of liquidity reserved by the game `gameId`.
     * @param  gameId the game ID
     * @param  deltaReserve value of the change in the amount of liquidity used by the game as a reinforcement
     */
    function changeLockedLiquidity(uint256 gameId, int128 deltaReserve)
        external
        override
        isActive(msg.sender)
    {
        if (deltaReserve > 0) {
            uint128 _deltaReserve = uint128(deltaReserve);
            if (gameId > 0) {
                games[gameId].lockedLiquidity += _deltaReserve;
            }

            CoreData storage coreData = _getCore(msg.sender);
            coreData.lockedLiquidity += _deltaReserve;
            lockedLiquidity += _deltaReserve;

            uint256 reserve = getReserve();
            if (
                lockedLiquidity > reserve ||
                coreData.lockedLiquidity >
                coreData.reinforcementAbility.mul(reserve)
            ) revert NotEnoughLiquidity();
        } else
            _reduceLockedLiquidity(msg.sender, gameId, uint128(-deltaReserve));
    }

    /**
     * @notice Factory: Indicate `core` as new active Core.
     */
    function addCore(address core) external override onlyFactory {
        CoreData storage coreData = _getCore(core);
        coreData.minBet = 1;
        coreData.reinforcementAbility = uint64(FixedMath.ONE);
        coreData.state = CoreState.ACTIVE;

        emit CoreSettingsUpdated(
            core,
            CoreState.ACTIVE,
            uint64(FixedMath.ONE),
            1
        );
    }

    /**
     * @notice Core: Finalize changes in the balance of Liquidity Pool
     *         after the game `gameId` condition's resolve.
     * @param  gameId the game ID
     * @param  lockedReserve amount of liquidity reserved by condition
     * @param  finalReserve amount of liquidity that was not demand according to the condition result
     */
    function addReserve(
        uint256 gameId,
        uint128 lockedReserve,
        uint128 finalReserve,
        uint48 leaf
    ) external override isCore(msg.sender) returns (uint128 affiliatesReward) {
        Reward storage dataProviderRewards = rewards[dataProvider];
        Reward storage daoRewards = rewards[factory.owner()];

        if (finalReserve > lockedReserve) {
            uint128 netProfit = finalReserve - lockedReserve;
            uint256 profit = netProfit;

            // increase data provider rewards
            uint128 dataProviderReward = _getShare(
                profit,
                FeeType.DATA_PROVIDER
            );
            netProfit -= _addDelta(
                dataProviderRewards.amount,
                dataProviderReward
            );
            dataProviderRewards.amount += dataProviderReward.toInt128();
            // increase DAO rewards
            uint128 daoReward = _getShare(profit, FeeType.DAO);
            netProfit -= _addDelta(daoRewards.amount, daoReward);
            daoRewards.amount += daoReward.toInt128();
            // calc affiliate rewards
            affiliatesReward = _getShare(profit, FeeType.AFFILIATE);

            // add profit to core aff accumulator, save raw rewards
            coreAffRewards[msg.sender] += affiliatesReward;

            // add profit to liquidity (reduced by data provider/dao's rewards)
            _addLimit(netProfit - affiliatesReward, leaf);
        } else {
            // remove loss from liquidityTree excluding canceled conditions (when finalReserve = lockedReserve)
            if (lockedReserve - finalReserve > 0) {
                uint128 netLoss = lockedReserve - finalReserve;
                uint256 loss = netLoss;

                // reduce data provider loss
                uint128 dataProviderLoss = _getShare(
                    loss,
                    FeeType.DATA_PROVIDER
                );
                netLoss -= _reduceDelta(
                    dataProviderRewards.amount,
                    dataProviderLoss
                );
                dataProviderRewards.amount -= dataProviderLoss.toInt128();
                // reduce DAO rewards
                uint128 daoLoss = _getShare(loss, FeeType.DAO);
                netLoss -= _reduceDelta(daoRewards.amount, daoLoss);
                daoRewards.amount -= daoLoss.toInt128();

                // remove all loss (reduced by data provider/dao's losses) from liquidity
                _remove(netLoss);
            }
        }
        if (lockedReserve > 0)
            _reduceLockedLiquidity(msg.sender, gameId, lockedReserve);
    }

    /**
     * @notice Get the start time of the game `gameId` and whether it was canceled.
     */
    function getGameInfo(uint256 gameId)
        external
        view
        override
        returns (uint64, bool)
    {
        Game storage game = games[gameId];
        return (game.startsAt, game.canceled);
    }

    /**
     * @notice Get the max amount of liquidity that can be locked by Core `core` conditions.
     */
    function getLockedLiquidityLimit(address core)
        external
        view
        returns (uint128)
    {
        return uint128(_getCore(core).reinforcementAbility.mul(getReserve()));
    }

    /**
     * @notice Get the total amount of liquidity in the Pool.
     */
    function getReserve() public view returns (uint128 reserve) {
        return _getReserve(1);
    }

    /**
     * @notice Get ID of the last added leaf to the liquidity tree.
     */
    function getLeaf() external view override returns (uint48 leaf) {
        return (nextNode - 1);
    }

    /**
     * @notice Check if game `gameId` is canceled.
     */
    function isGameCanceled(uint256 gameId)
        external
        view
        override
        returns (bool)
    {
        return games[gameId].canceled;
    }

    /**
     * @notice Get bet token `tokenId` payout.
     * @param  core address of the Core where bet was placed
     * @param  tokenId bet token ID
     * @return payout winnings of the token owner
     */
    function viewPayout(address core, uint256 tokenId)
        external
        view
        isCore(core)
        returns (uint128)
    {
        return IBet(core).viewPayout(tokenId);
    }

    /**
     * @notice Throw if `account` have no access to function with selector `selector` of `target`.
     */
    function checkAccess(
        address account,
        address target,
        bytes4 selector
    ) public {
        access.checkAccess(account, target, selector);
    }

    /**
     * @notice Throw if `core` not belongs to the Liquidity Pool's Cores.
     */
    function checkCore(address core) public view {
        if (_getCore(core).state == CoreState.UNKNOWN) revert UnknownCore();
    }

    /**
     * @notice Deposit liquidity in the Liquidity Pool.
     * @notice Emits deposit token to `msg.sender`.
     * @param  amount token's amount to deposit
     */
    function _addLiquidity(uint128 amount) internal {
        if (amount < minDepo) revert SmallDepo();

        uint48 leaf = _nodeAddLiquidity(amount);

        if (address(liquidityManager) != address(0))
            liquidityManager.beforeAddLiquidity(msg.sender, leaf, amount);

        withdrawAfter[leaf] = uint64(block.timestamp) + withdrawTimeout;
        _mint(msg.sender, leaf);
        emit LiquidityAdded(msg.sender, leaf, amount);
    }

    /**
     * @notice Make new bet.
     * @param  bettor wallet for emitting bet token
     * @param  core address of the Core the bet is intended
     * @param  amount amount of tokens to bet
     * @param  expiresAt the time before which bet should be made
     * @param  betData customized bet data
     */
    function _bet(
        address bettor,
        address core,
        uint128 amount,
        uint64 expiresAt,
        IBet.BetData memory betData
    ) internal isActive(core) returns (uint256) {
        if (block.timestamp >= expiresAt) revert BetExpired();
        if (amount < _getCore(core).minBet) revert SmallBet();
        // owner is default affiliate
        if (betData.affiliate == address(0)) betData.affiliate = owner();
        return IBet(core).putBet(bettor, amount, betData);
    }

    /**
     * @notice Deposit `amount` of `token` tokens from `account` balance to the contract.
     */
    function _deposit(uint128 amount) internal {
        TransferHelper.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            amount
        );
    }

    /**
     * @notice Deposit `amount` of native tokens from `account` balance to the contract.
     */
    function _depositNative() internal {
        IWNative(token).deposit{value: msg.value}();
    }

    function _reduceLockedLiquidity(
        address core,
        uint256 gameId,
        uint128 deltaReserve
    ) internal {
        if (gameId > 0) {
            games[gameId].lockedLiquidity -= deltaReserve;
        }
        _getCore(core).lockedLiquidity -= deltaReserve;
        lockedLiquidity -= deltaReserve;
    }

    /**
     * @notice Withdraw `amount` of tokens to `account` balance.
     * @param  isNative whether to make withdrawal in native or `token` tokens
     */
    function _withdraw(
        address account,
        uint128 amount,
        bool isNative
    ) internal {
        if (isNative) {
            IWNative(token).withdraw(amount);
            TransferHelper.safeTransferETH(account, amount);
        } else {
            TransferHelper.safeTransfer(token, account, amount);
        }
    }

    /**
     * @notice Resolve payout for liquidity deposit.
     * @param  depNum deposit token ID
     * @param  percent payout share to resolve where `FixedMath.ONE` is 100% of deposit payout
     */
    function _withdrawLiquidity(uint48 depNum, uint40 percent)
        internal
        returns (uint128 withdrawAmount)
    {
        uint64 time = uint64(block.timestamp);
        uint64 _withdrawAfter = withdrawAfter[depNum];
        if (time < _withdrawAfter)
            revert WithdrawalTimeout(_withdrawAfter - time);
        if (msg.sender != ownerOf(depNum)) revert LiquidityNotOwned();

        withdrawAfter[depNum] = time + withdrawTimeout;
        uint128 topNodeAmount = getReserve();
        withdrawAmount = _nodeWithdrawPercent(depNum, percent);

        if (withdrawAmount == 0) revert NoLiquidity();

        // check withdrawAmount allowed in ("node #1" - "active condition reinforcements")
        if (withdrawAmount > (topNodeAmount - lockedLiquidity))
            revert LiquidityIsLocked();

        if (address(liquidityManager) != address(0))
            liquidityManager.afterWithdrawLiquidity(
                msg.sender,
                depNum,
                _getReserve(depNum)
            );

        emit LiquidityRemoved(msg.sender, depNum, withdrawAmount);
    }

    /**
     * @notice Throw if `core` not belongs to the Liquidity Pool's active Cores.
     */
    function _checkCoreActive(address core) internal view {
        if (_getCore(core).state != CoreState.ACTIVE) revert CoreNotActive();
    }

    /**
     * @notice Throw if set fees are incorrect.
     */
    function _checkFee() internal view {
        if (
            _getFee(FeeType.DAO) +
                _getFee(FeeType.DATA_PROVIDER) +
                _getFee(FeeType.AFFILIATE) >
            FixedMath.ONE
        ) revert IncorrectFee();
    }

    function _getCore(address core) internal view returns (CoreData storage) {
        return cores[core];
    }

    /**
     * @notice Get current fee type `feeType` profit share.
     */
    function _getFee(FeeType feeType) internal view returns (uint64) {
        return fees[uint256(feeType)];
    }

    /**
     * @notice Get game by it's ID.
     */
    function _getGame(uint256 gameId) internal view returns (Game storage) {
        Game storage game = games[gameId];
        if (game.startsAt == 0) revert GameNotExists();

        return game;
    }

    /**
     * @notice Get the amount of liquidity in the node `leaf`.
     */
    function _getReserve(uint48 leaf) internal view returns (uint128) {
        return treeNode[leaf].amount;
    }

    function _getShare(uint256 amount, FeeType feeType)
        internal
        view
        returns (uint128)
    {
        return _getFee(feeType).mul(amount).toUint128();
    }

    /**
     * @notice Calculate the positive delta between `a` and `a + b`.
     */
    function _addDelta(int128 a, uint128 b) internal pure returns (uint128) {
        if (a < 0) {
            int128 c = a + b.toInt128();
            return (c > 0) ? uint128(c) : 0;
        } else return b;
    }

    /**
     * @notice Calculate the positive delta between `a - b` and `a`.
     */
    function _reduceDelta(int128 a, uint128 b) internal pure returns (uint128) {
        return (a < 0 ? 0 : (a > b.toInt128() ? b : uint128(a)));
    }
}
