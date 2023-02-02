// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";

import "./interfaces/ILidoLocator.sol";
import "./interfaces/ISelfOwnedStETHBurner.sol";

import "./lib/StakeLimitUtils.sol";
import "./lib/PositiveTokenRebaseLimiter.sol";

import "./StETHPermit.sol";

interface IPostTokenRebaseReceiver {
    function handlePostTokenRebase(
        uint256 preTotalShares,
        uint256 preTotalEther,
        uint256 postTotalShares,
        uint256 postTotalEther,
        uint256 sharesMintedAsFees,
        uint256 timeElapsed
    ) external;
}

interface ILidoExecutionLayerRewardsVault {
    function withdrawRewards(uint256 _maxAmount) external returns (uint256 amount);
}

interface IWithdrawalVault {
    function withdrawWithdrawals(uint256 _amount) external;
}

interface IStakingRouter {
    function deposit(
        uint256 maxDepositsCount,
        uint256 stakingModuleId,
        bytes depositCalldata
    ) external payable returns (uint256);
    function getStakingRewardsDistribution()
        external
        view
        returns (
            address[] memory recipients,
            uint256[] memory stakingModuleIds,
            uint96[] memory stakingModuleFees,
            uint96 totalFee,
            uint256 precisionPoints
        );
    function getWithdrawalCredentials() external view returns (bytes32);
    function reportRewardsMinted(uint256[] _stakingModuleIds, uint256[] _totalShares) external;
}

interface IWithdrawalQueue {
    function finalizationBatch(uint256 _lastRequestIdToFinalize, uint256 _shareRate)
        external
        view
        returns (uint128 eth, uint128 shares);
    function finalize(uint256 _lastIdToFinalize) external payable;
    function isPaused() external view returns (bool);
    function unfinalizedStETH() external view returns (uint256);
    function isBunkerModeActive() external view returns (bool);
}

/**
* @title Liquid staking pool implementation
*
* Lido is an Ethereum liquid staking protocol solving the problem of frozen staked ether on Consensus Layer
* being unavailable for transfers and DeFi on Execution Layer.
*
* Since balances of all token holders change when the amount of total pooled Ether
* changes, this token cannot fully implement ERC20 standard: it only emits `Transfer`
* events upon explicit transfer between holders. In contrast, when Lido oracle reports
* rewards, no Transfer events are generated: doing so would require emitting an event
* for each token holder and thus running an unbounded loop.
*/
contract Lido is StETHPermit, AragonApp {
    using SafeMath for uint256;
    using UnstructuredStorage for bytes32;
    using StakeLimitUnstructuredStorage for bytes32;
    using StakeLimitUtils for StakeLimitState.Data;
    using PositiveTokenRebaseLimiter for LimiterState.Data;

    /// ACL
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");
    bytes32 public constant STAKING_PAUSE_ROLE = keccak256("STAKING_PAUSE_ROLE");
    bytes32 public constant STAKING_CONTROL_ROLE = keccak256("STAKING_CONTROL_ROLE");
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");
    bytes32 public constant MANAGE_MAX_POSITIVE_TOKEN_REBASE_ROLE = keccak256("MANAGE_MAX_POSITIVE_TOKEN_REBASE_ROLE");

    uint256 private constant DEPOSIT_SIZE = 32 ether;
    uint256 public constant TOTAL_BASIS_POINTS = 10000;

    /// @dev storage slot position for the Lido protocol contracts locator
    bytes32 internal constant LIDO_LOCATOR_POSITION = keccak256("lido.Lido.lidoLocator");
    /// @dev storage slot position of the staking rate limit structure
    bytes32 internal constant STAKING_STATE_POSITION = keccak256("lido.Lido.stakeLimit");
    /// @dev amount of Ether (on the current Ethereum side) buffered on this smart contract balance
    bytes32 internal constant BUFFERED_ETHER_POSITION = keccak256("lido.Lido.bufferedEther");
    /// @dev number of deposited validators (incrementing counter of deposit operations).
    bytes32 internal constant DEPOSITED_VALIDATORS_POSITION = keccak256("lido.Lido.depositedValidators");
    /// @dev total amount of ether on Consensus Layer (sum of all the balances of Lido validators)
    // "beacon" in the `keccak256()` parameter is staying here for compatibility reason
    bytes32 internal constant CL_BALANCE_POSITION = keccak256("lido.Lido.beaconBalance");
    /// @dev number of Lido's validators available in the Consensus Layer state
    // "beacon" in the `keccak256()` parameter is staying here for compatibility reason
    bytes32 internal constant CL_VALIDATORS_POSITION = keccak256("lido.Lido.beaconValidators");
    /// @dev positive token rebase allowed per single LidoOracle report
    /// uses 1e9 precision, e.g.: 1e6 - 0.1%; 1e9 - 100%, see `setMaxPositiveTokenRebase()`
    bytes32 internal constant MAX_POSITIVE_TOKEN_REBASE_POSITION = keccak256("lido.Lido.MaxPositiveTokenRebase");
    /// @dev Just a counter of total amount of execution layer rewards received by Lido contract. Not used in the logic.
    bytes32 internal constant TOTAL_EL_REWARDS_COLLECTED_POSITION = keccak256("lido.Lido.totalELRewardsCollected");
    /// @dev version of contract
    bytes32 internal constant CONTRACT_VERSION_POSITION = keccak256("lido.Lido.contractVersion");

    event ContractVersionSet(uint256 version);

    event Stopped();
    event Resumed();

    event StakingPaused();
    event StakingResumed();
    event StakingLimitSet(uint256 maxStakeLimit, uint256 stakeLimitIncreasePerBlock);
    event StakingLimitRemoved();

    event ETHDistributed(
        int256 clBalanceDiff,
        uint256 withdrawalsWithdrawn,
        uint256 executionLayerRewardsWithdrawn,
        uint256 postBufferredEther
    );

    event TokenRebase(
        uint256 preTotalShares,
        uint256 preTotalEther,
        uint256 postTotalShares,
        uint256 postTotalEther,
        uint256 sharesMintedAsFees,
        uint256 timeElapsed
    );

    // Lido locator set
    event LidoLocatorSet(address lidoLocator);

    // The amount of ETH withdrawn from LidoExecutionLayerRewardsVault to Lido
    event ELRewardsReceived(uint256 amount);

    // The amount of ETH withdrawn from WithdrawalVault to Lido
    event WithdrawalsReceived(uint256 amount);

    // Max positive token rebase set (see `setMaxPositiveTokenRebase()`)
    event MaxPositiveTokenRebaseSet(uint256 maxPositiveTokenRebase);

    // Records a deposit made by a user
    event Submitted(address indexed sender, uint256 amount, address referral);

    // The `amount` of ether was sent to the deposit_contract.deposit function
    event Unbuffered(uint256 amount);

    // The amount of ETH sended from StakingRouter contract to Lido contract
    event StakingRouterTransferReceived(uint256 amount);

    /**
    * @dev As AragonApp, Lido contract must be initialized with following variables:
    *      NB: by default, staking and the whole Lido pool are in paused state
    * @param _lidoLocator lido locator contract
    * @param _eip712StETH eip712 helper contract for StETH
    */
    function initialize(
        address _lidoLocator,
        address _eip712StETH
    )
        public onlyInit
    {
        _initialize_v2(_lidoLocator, _eip712StETH);
        initialized();
    }

    /**
     * initializer v2
     */
    function _initialize_v2(
        address _lidoLocator,
        address _eip712StETH
    ) internal {
        CONTRACT_VERSION_POSITION.setStorageUint256(2);
        LIDO_LOCATOR_POSITION.setStorageAddress(_lidoLocator);
        _initializeEIP712StETH(_eip712StETH);

        emit LidoLocatorSet(_lidoLocator);
    }

    /**
     * @notice A function to finalize upgrade to v2 (from v1). Can be called only once
     * @dev Value 1 in CONTRACT_VERSION_POSITION is skipped due to change in numbering
     * For more details see https://github.com/lidofinance/lido-improvement-proposals/blob/develop/LIPS/lip-10.md
     */
    function finalizeUpgrade_v2(
        address _lidoLocator,
        address _eip712StETH
    ) external {
        require(!isPetrified(), "PETRIFIED");
        require(CONTRACT_VERSION_POSITION.getStorageUint256() == 0, "WRONG_BASE_VERSION");

        require(_lidoLocator != address(0), "LIDO_LOCATOR_ZERO_ADDRESS");
        require(_eip712StETH != address(0), "EIP712_STETH_ZERO_ADDRESS");

        _initialize_v2(_lidoLocator, _eip712StETH);
    }

    /**
     * @notice Return the initialized version of this contract starting from 0
     */
    function getVersion() external view returns (uint256) {
        return CONTRACT_VERSION_POSITION.getStorageUint256();
    }

    /**
     * @notice Stops accepting new Ether to the protocol
     *
     * @dev While accepting new Ether is stopped, calls to the `submit` function,
     * as well as to the default payable function, will revert.
     *
     * Emits `StakingPaused` event.
     */
    function pauseStaking() external {
        _auth(STAKING_PAUSE_ROLE);

        _pauseStaking();
    }

    /**
     * @notice Resumes accepting new Ether to the protocol (if `pauseStaking` was called previously)
     * NB: Staking could be rate-limited by imposing a limit on the stake amount
     * at each moment in time, see `setStakingLimit()` and `removeStakingLimit()`
     *
     * @dev Preserves staking limit if it was set previously
     *
     * Emits `StakingResumed` event
     */
    function resumeStaking() external {
        _auth(STAKING_CONTROL_ROLE);

        _resumeStaking();
    }

    /**
     * @notice Sets the staking rate limit
     *
     * ▲ Stake limit
     * │.....  .....   ........ ...            ....     ... Stake limit = max
     * │      .       .        .   .   .      .    . . .
     * │     .       .              . .  . . .      . .
     * │            .                .  . . .
     * │──────────────────────────────────────────────────> Time
     * │     ^      ^          ^   ^^^  ^ ^ ^     ^^^ ^     Stake events
     *
     * @dev Reverts if:
     * - `_maxStakeLimit` == 0
     * - `_maxStakeLimit` >= 2^96
     * - `_maxStakeLimit` < `_stakeLimitIncreasePerBlock`
     * - `_maxStakeLimit` / `_stakeLimitIncreasePerBlock` >= 2^32 (only if `_stakeLimitIncreasePerBlock` != 0)
     *
     * Emits `StakingLimitSet` event
     *
     * @param _maxStakeLimit max stake limit value
     * @param _stakeLimitIncreasePerBlock stake limit increase per single block
     */
    function setStakingLimit(uint256 _maxStakeLimit, uint256 _stakeLimitIncreasePerBlock) external {
        _auth(STAKING_CONTROL_ROLE);

        STAKING_STATE_POSITION.setStorageStakeLimitStruct(
            STAKING_STATE_POSITION.getStorageStakeLimitStruct().setStakingLimit(_maxStakeLimit, _stakeLimitIncreasePerBlock)
        );

        emit StakingLimitSet(_maxStakeLimit, _stakeLimitIncreasePerBlock);
    }

    /**
     * @notice Removes the staking rate limit
     *
     * Emits `StakingLimitRemoved` event
     */
    function removeStakingLimit() external {
        _auth(STAKING_CONTROL_ROLE);

        STAKING_STATE_POSITION.setStorageStakeLimitStruct(STAKING_STATE_POSITION.getStorageStakeLimitStruct().removeStakingLimit());

        emit StakingLimitRemoved();
    }

    /**
     * @notice Check staking state: whether it's paused or not
     */
    function isStakingPaused() external view returns (bool) {
        return STAKING_STATE_POSITION.getStorageStakeLimitStruct().isStakingPaused();
    }


    /**
     * @notice Returns how much Ether can be staked in the current block
     * @dev Special return values:
     * - 2^256 - 1 if staking is unlimited;
     * - 0 if staking is paused or if limit is exhausted.
     */
    function getCurrentStakeLimit() external view returns (uint256) {
        return _getCurrentStakeLimit(STAKING_STATE_POSITION.getStorageStakeLimitStruct());
    }

    /**
     * @notice Returns full info about current stake limit params and state
     * @dev Might be used for the advanced integration requests.
     * @return isStakingPaused staking pause state (equivalent to return of isStakingPaused())
     * @return isStakingLimitSet whether the stake limit is set
     * @return currentStakeLimit current stake limit (equivalent to return of getCurrentStakeLimit())
     * @return maxStakeLimit max stake limit
     * @return maxStakeLimitGrowthBlocks blocks needed to restore max stake limit from the fully exhausted state
     * @return prevStakeLimit previously reached stake limit
     * @return prevStakeBlockNumber previously seen block number
     */
    function getStakeLimitFullInfo()
        external
        view
        returns (
            bool isStakingPaused,
            bool isStakingLimitSet,
            uint256 currentStakeLimit,
            uint256 maxStakeLimit,
            uint256 maxStakeLimitGrowthBlocks,
            uint256 prevStakeLimit,
            uint256 prevStakeBlockNumber
        )
    {
        StakeLimitState.Data memory stakeLimitData = STAKING_STATE_POSITION.getStorageStakeLimitStruct();

        isStakingPaused = stakeLimitData.isStakingPaused();
        isStakingLimitSet = stakeLimitData.isStakingLimitSet();

        currentStakeLimit = _getCurrentStakeLimit(stakeLimitData);

        maxStakeLimit = stakeLimitData.maxStakeLimit;
        maxStakeLimitGrowthBlocks = stakeLimitData.maxStakeLimitGrowthBlocks;
        prevStakeLimit = stakeLimitData.prevStakeLimit;
        prevStakeBlockNumber = stakeLimitData.prevStakeBlockNumber;
    }

    /**
    * @notice Send funds to the pool
    * @dev Users are able to submit their funds by transacting to the fallback function.
    * Unlike vanilla Ethereum Deposit contract, accepting only 32-Ether transactions, Lido
    * accepts payments of any size. Submitted Ethers are stored in Buffer until someone calls
    * deposit() and pushes them to the Ethereum Deposit contract.
    */
    // solhint-disable-next-line
    function() external payable {
        // protection against accidental submissions by calling non-existent function
        require(msg.data.length == 0, "NON_EMPTY_DATA");
        _submit(0);
    }

    /**
     * @notice Send funds to the pool with optional _referral parameter
     * @dev This function is alternative way to submit funds. Supports optional referral address.
     * @return Amount of StETH shares generated
     */
    function submit(address _referral) external payable returns (uint256) {
        return _submit(_referral);
    }

    /**
     * @notice A payable function for execution layer rewards. Can be called only by ExecutionLayerRewardsVault contract
     * @dev We need a dedicated function because funds received by the default payable function
     * are treated as a user deposit
     */
    function receiveELRewards() external payable {
        require(msg.sender == getLidoLocator().getELRewardsVault());

        TOTAL_EL_REWARDS_COLLECTED_POSITION.setStorageUint256(getTotalELRewardsCollected().add(msg.value));

        emit ELRewardsReceived(msg.value);
    }

    /**
    * @notice A payable function for withdrawals acquisition. Can be called only by WithdrawalVault contract
    * @dev We need a dedicated function because funds received by the default payable function
    * are treated as a user deposit
    */
    function receiveWithdrawals() external payable {
        require(msg.sender == getLidoLocator().getWithdrawalVault());

        emit WithdrawalsReceived(msg.value);
    }

    /**
     * @notice A payable function for execution layer rewards. Can be called only by ExecutionLayerRewardsVault contract
     * @dev We need a dedicated function because funds received by the default payable function
     * are treated as a user deposit
     */
    function receiveStakingRouter() external payable {
        require(msg.sender == getLidoLocator().getStakingRouter());

        emit StakingRouterTransferReceived(msg.value);
    }

    /**
     * @notice Destroys _sharesAmount shares from _account holdings, decreasing the total amount of shares.
     *
     * @param _account Address where shares will be burned
     * @param _sharesAmount Amount of shares to burn
     * @return Amount of new total shares after tokens burning
     */
    function burnShares(address _account, uint256 _sharesAmount)
        external
        authP(BURN_ROLE, arr(_account, _sharesAmount))
        returns (uint256 newTotalShares)
    {
        return _burnShares(_account, _sharesAmount);
    }

    /**
     * @notice Stop pool routine operations
     */
    function stop() external {
        _auth(PAUSE_ROLE);

        _stop();
        _pauseStaking();
    }

    /**
     * @notice Resume pool routine operations
     * @dev Staking should be resumed manually after this call using the desired limits
     */
    function resume() external {
        _auth(RESUME_ROLE);

        _resume();
        _resumeStaking();
    }

    /**
     * @dev Set max positive rebase allowed per single oracle report
     * token rebase happens on total supply adjustment,
     * huge positive rebase can incur oracle report sandwitching.
     *
     * stETH balance for the `account` defined as:
     * balanceOf(account) = shares[account] * totalPooledEther / totalShares = shares[account] * shareRate
     *
     * Suppose shareRate changes when oracle reports (see `handleOracleReport`)
     * which means that token rebase happens:
     *
     * preShareRate = preTotalPooledEther() / preTotalShares()
     * postShareRate = postTotalPooledEther() / postTotalShares()
     * R = (postShareRate - preShareRate) / preShareRate
     *
     * R > 0 corresponds to the relative positive rebase value (i.e., instant APR)
     *
     * NB: The value is not set by default (explicit initialization required),
     * the recommended sane values are from 0.05% to 0.1%.
     *
     * @param _maxTokenPositiveRebase max positive token rebase value with 1e9 precision:
     *   e.g.: 1e6 - 0.1%; 1e9 - 100%
     * - passing zero value is prohibited
     * - to allow unlimited rebases, pass max uint256, i.e.: uint256(-1)
     */
    function setMaxPositiveTokenRebase(uint256 _maxTokenPositiveRebase) external {
        _auth(MANAGE_MAX_POSITIVE_TOKEN_REBASE_ROLE);
        _setMaxPositiveTokenRebase(_maxTokenPositiveRebase);
    }

    struct OracleReportInputData {
        // Oracle report timing
        uint256 timeElapsed;
        // CL values
        uint256 clValidators;
        uint256 clBalance;
        // EL values
        uint256 withdrawalVaultBalance;
        uint256 elRewardsVaultBalance;
        // Decision about withdrawals processing
        uint256 requestIdToFinalizeUpTo;
        uint256 finalizationShareRate;
    }

    /**
    * @notice Updates accounting stats, collects EL rewards and distributes collected rewards if beacon balance increased
    * @dev periodically called by the Oracle contract
    * @param _timeElapsed time elapsed since the previous oracle report
    * @param _clValidators number of Lido validators on Consensus Layer
    * @param _clBalance sum of all Lido validators' balances on Consensus Layer
    * @param _withdrawalVaultBalance withdrawal vault balance on Execution Layer for report block
    * @param _elRewardsVaultBalance elRewards vault balance on Execution Layer for report block
    * @param _requestIdToFinalizeUpTo right boundary of requestId range if equals 0, no requests should be finalized
    * @param _finalizationShareRate share rate that should be used for finalization
    *
    * @return totalPooledEther amount of ether in the protocol after report
    * @return totalShares amount of shares in the protocol after report
    * @return withdrawals withdrawn from the withdrawals vault
    * @return elRewards withdrawn from the execution layer rewards vault
    */
    function handleOracleReport(
        // Oracle report timing
        uint256 _timeElapsed,
        // CL values
        uint256 _clValidators,
        uint256 _clBalance,
        // EL values
        uint256 _withdrawalVaultBalance,
        uint256 _elRewardsVaultBalance,
        // Decision about withdrawals processing
        uint256 _requestIdToFinalizeUpTo,
        uint256 _finalizationShareRate
    ) external returns (
        uint256 totalPooledEther,
        uint256 totalShares,
        uint256 withdrawals,
        uint256 elRewards
    ) {
        // TODO: safety checks

        require(msg.sender == getLidoLocator().getOracle(), "APP_AUTH_FAILED");
        _whenNotStopped();

        return _handleOracleReport(
            OracleReportInputData(
                _timeElapsed,
                _clValidators,
                _clBalance,
                _withdrawalVaultBalance,
                _elRewardsVaultBalance,
                _requestIdToFinalizeUpTo,
                _finalizationShareRate
            )
        );
    }

    /**
     * @notice Overrides default AragonApp behaviour to disallow recovery.
     */
    function transferToVault(address /* _token */) external {
        revert("NOT_SUPPORTED");
    }

    /**
    * @notice Get the amount of Ether temporary buffered on this contract balance
    * @dev Buffered balance is kept on the contract from the moment the funds are received from user
    * until the moment they are actually sent to the official Deposit contract.
    * @return amount of buffered funds in wei
    */
    function getBufferedEther() external view returns (uint256) {
        return _getBufferedEther();
    }

    /**
     * @notice Get total amount of execution layer rewards collected to Lido contract
     * @dev Ether got through LidoExecutionLayerRewardsVault is kept on this contract's balance the same way
     * as other buffered Ether is kept (until it gets deposited)
     * @return amount of funds received as execution layer rewards (in wei)
     */
    function getTotalELRewardsCollected() public view returns (uint256) {
        return TOTAL_EL_REWARDS_COLLECTED_POSITION.getStorageUint256();
    }

    /**
     * @notice Get max positive token rebase value
     * @return max positive token rebase value, nominated id MAX_POSITIVE_REBASE_PRECISION_POINTS (10**9 == 100% = 10000 BP)
     */
    function getMaxPositiveTokenRebase() public view returns (uint256) {
        return MAX_POSITIVE_TOKEN_REBASE_POSITION.getStorageUint256();
    }

    /**
     * @notice Gets authorized oracle address
     * @return address of oracle contract
     */
    function getLidoLocator() public view returns (ILidoLocator) {
        return ILidoLocator(LIDO_LOCATOR_POSITION.getStorageAddress());
    }

    /**
    * @notice Returns the key values related to Consensus Layer side of the contract. It historically contains beacon
    * @return depositedValidators - number of deposited validators from Lido contract side
    * @return beaconValidators - number of Lido validators visible on Consensus Layer, reported by oracle
    * @return beaconBalance - total amount of ether on the Consensus Layer side (sum of all the balances of Lido validators)
    *
    * @dev `beacon` in naming still here for historical reasons
    */
    function getBeaconStat() external view returns (uint256 depositedValidators, uint256 beaconValidators, uint256 beaconBalance) {
        depositedValidators = DEPOSITED_VALIDATORS_POSITION.getStorageUint256();
        beaconValidators = CL_VALIDATORS_POSITION.getStorageUint256();
        beaconBalance = CL_BALANCE_POSITION.getStorageUint256();
    }

    /**
     * @notice Returns current withdrawal credentials of deposited validators
     * @dev DEPRECATED: use StakingRouter.getWithdrawalCredentials() instead
     */
    function getWithdrawalCredentials() public view returns (bytes32) {
        return IStakingRouter(getLidoLocator().getStakingRouter()).getWithdrawalCredentials();
    }


    /// @dev updates Consensus Layer state according to the current report
    function _processClStateUpdate(
        uint256 _postClValidators,
        uint256 _postClBalance
    ) internal returns (int256 clBalanceDiff) {
        uint256 depositedValidators = DEPOSITED_VALIDATORS_POSITION.getStorageUint256();
        require(_postClValidators <= depositedValidators, "REPORTED_MORE_DEPOSITED");

        uint256 preClValidators = CL_VALIDATORS_POSITION.getStorageUint256();
        require(_postClValidators >= preClValidators, "REPORTED_LESS_VALIDATORS");

        // Save the current CL balance and validators to
        // calculate rewards on the next push
        CL_BALANCE_POSITION.setStorageUint256(_postClBalance);

        if (_postClValidators > preClValidators) {
            CL_VALIDATORS_POSITION.setStorageUint256(_postClValidators);
        }

        uint256 appearedValidators = _postClValidators.sub(preClValidators);
        uint256 preCLBalance = CL_BALANCE_POSITION.getStorageUint256();
        uint256 rewardsBase = appearedValidators.mul(DEPOSIT_SIZE).add(preCLBalance);

        return _signedSub(int256(_postClBalance), int256(rewardsBase));
    }

    /// @dev collect ETH from ELRewardsVault and WithdrawalVault and send to WithdrawalQueue
    function _processETHDistribution(
        uint256 _withdrawalsToWithdraw,
        uint256 _elRewardsToWithdraw,
        uint256 _requestIdToFinalizeUpTo,
        uint256 _finalizationShareRate
    ) internal {
        ILidoLocator locator = getLidoLocator();
        // withdraw execution layer rewards and put them to the buffer
        if (_elRewardsToWithdraw > 0) {
            ILidoExecutionLayerRewardsVault(locator.getELRewardsVault()).withdrawRewards(_elRewardsToWithdraw);
        }

        // withdraw withdrawals and put them to the buffer
        if (_withdrawalsToWithdraw > 0) {
            IWithdrawalVault(locator.getWithdrawalVault()).withdrawWithdrawals(_withdrawalsToWithdraw);
        }

        uint256 lockedToWithdrawalQueue = 0;
        if (_requestIdToFinalizeUpTo > 0) {
            lockedToWithdrawalQueue = _processWithdrawalQueue(
                _requestIdToFinalizeUpTo,
                _finalizationShareRate
            );
        }

        uint256 preBufferedEther = _getBufferedEther();
        uint256 postBufferedEther = _getBufferedEther()
            .add(_elRewardsToWithdraw) // Collected from ELVault
            .add(_withdrawalsToWithdraw) // Collected from WithdrawalVault
            .sub(lockedToWithdrawalQueue); // Sent to WithdrawalQueue

        // Storing even the same value costs gas, so just avoid it
        if (preBufferedEther != postBufferedEther) {
            BUFFERED_ETHER_POSITION.setStorageUint256(postBufferedEther);
        }
    }

    ///@dev finalize withdrawal requests in the queue, burn their shares and return the amount of ether locked for claiming
    function _processWithdrawalQueue(
        uint256 _requestIdToFinalizeUpTo,
        uint256 _finalizationShareRate
    ) internal returns (uint256 lockedToWithdrawalQueue) {
        IWithdrawalQueue withdrawalQueue = IWithdrawalQueue(getLidoLocator().getWithdrawalQueue());

        if (withdrawalQueue.isPaused()) return 0;

        (uint256 etherToLock, uint256 sharesToBurn) = withdrawalQueue.finalizationBatch(
            _requestIdToFinalizeUpTo,
            _finalizationShareRate
        );

        _burnShares(address(withdrawalQueue), sharesToBurn);
        withdrawalQueue.finalize.value(etherToLock)(_requestIdToFinalizeUpTo);

        return etherToLock;
    }

    /// @dev calculate the amount of rewards and distribute it
    function _processRewards(
        int256 _clBalanceDiff,
        uint256 _withdrawnWithdrawals,
        uint256 _withdrawnElRewards
    ) internal returns (uint256 sharesMintedAsFees) {
        int256 consensusLayerRewards = _signedAdd(_clBalanceDiff, int256(_withdrawnWithdrawals));
        // Don’t mint/distribute any protocol fee on the non-profitable Lido oracle report
        // (when consensus layer balance delta is zero or negative).
        // See ADR #3 for details:
        // https://research.lido.fi/t/rewards-distribution-after-the-merge-architecture-decision-record/1535
        if (consensusLayerRewards > 0) {
            sharesMintedAsFees = _distributeFee(uint256(consensusLayerRewards).add(_withdrawnElRewards));
        }
    }

    /**
     * @dev Process user deposit, mints liquid tokens and increase the pool buffer
     * @param _referral address of referral.
     * @return amount of StETH shares generated
     */
    function _submit(address _referral) internal returns (uint256) {
        require(msg.value != 0, "ZERO_DEPOSIT");

        StakeLimitState.Data memory stakeLimitData = STAKING_STATE_POSITION.getStorageStakeLimitStruct();
        require(!stakeLimitData.isStakingPaused(), "STAKING_PAUSED");

        if (stakeLimitData.isStakingLimitSet()) {
            uint256 currentStakeLimit = stakeLimitData.calculateCurrentStakeLimit();

            require(msg.value <= currentStakeLimit, "STAKE_LIMIT");

            STAKING_STATE_POSITION.setStorageStakeLimitStruct(stakeLimitData.updatePrevStakeLimit(currentStakeLimit - msg.value));
        }

        uint256 sharesAmount;
        if (_getTotalPooledEther() != 0) {
            sharesAmount = getSharesByPooledEth(msg.value);
        } else {
            // totalPooledEther is 0: for first-ever deposit
            // assume that shares correspond to Ether 1-to-1
            sharesAmount = msg.value;
        }

        _mintShares(msg.sender, sharesAmount);

        BUFFERED_ETHER_POSITION.setStorageUint256(_getBufferedEther().add(msg.value));
        emit Submitted(msg.sender, msg.value, _referral);

        _emitTransferAfterMintingShares(msg.sender, sharesAmount);
        return sharesAmount;
    }

    /**
     * @dev Emits {Transfer} and {TransferShares} events where `from` is 0 address. Indicates mint events.
     */
    function _emitTransferAfterMintingShares(address _to, uint256 _sharesAmount) internal {
        emit Transfer(address(0), _to, getPooledEthByShares(_sharesAmount));
        emit TransferShares(address(0), _to, _sharesAmount);
    }

    /**
     * @dev Distributes fee portion of the rewards by minting and distributing corresponding amount of liquid tokens.
     * @param _totalRewards Total rewards accrued both on the Execution Layer and the Consensus Layer sides in wei.
     */
    function _distributeFee(uint256 _totalRewards) internal returns (uint256 sharesMintedAsFees) {
        // We need to take a defined percentage of the reported reward as a fee, and we do
        // this by minting new token shares and assigning them to the fee recipients (see
        // StETH docs for the explanation of the shares mechanics). The staking rewards fee
        // is defined in basis points (1 basis point is equal to 0.01%, 10000 (TOTAL_BASIS_POINTS) is 100%).
        //
        // Since we've increased totalPooledEther by _totalRewards (which is already
        // performed by the time this function is called), the combined cost of all holders'
        // shares has became _totalRewards StETH tokens more, effectively splitting the reward
        // between each token holder proportionally to their token share.
        //
        // Now we want to mint new shares to the fee recipient, so that the total cost of the
        // newly-minted shares exactly corresponds to the fee taken:
        //
        // shares2mint * newShareCost = (_totalRewards * totalFee) / PRECISION_POINTS
        // newShareCost = newTotalPooledEther / (prevTotalShares + shares2mint)
        //
        // which follows to:
        //
        //                        _totalRewards * totalFee * prevTotalShares
        // shares2mint = --------------------------------------------------------------
        //                 (newTotalPooledEther * PRECISION_POINTS) - (_totalRewards * totalFee)
        //
        // The effect is that the given percentage of the reward goes to the fee recipient, and
        // the rest of the reward is distributed between token holders proportionally to their
        // token shares.
        IStakingRouter router = IStakingRouter(getLidoLocator().getStakingRouter());

        (address[] memory recipients,
            uint256[] memory moduleIds,
            uint96[] memory modulesFees,
            uint96 totalFee,
            uint256 precisionPoints) = router.getStakingRewardsDistribution();

        require(recipients.length == modulesFees.length, "WRONG_RECIPIENTS_INPUT");
        require(moduleIds.length == modulesFees.length, "WRONG_MODULE_IDS_INPUT");

        if (totalFee > 0) {
            sharesMintedAsFees =
                _totalRewards.mul(totalFee).mul(_getTotalShares()).div(
                    _getTotalPooledEther().mul(precisionPoints).sub(_totalRewards.mul(totalFee))
                );

            _mintShares(address(this), sharesMintedAsFees);

            (uint256[] memory moduleRewards, uint256 totalModuleRewards) =
                _transferModuleRewards(recipients, modulesFees, totalFee, sharesMintedAsFees);

            _transferTreasuryRewards(sharesMintedAsFees.sub(totalModuleRewards));

            router.reportRewardsMinted(moduleIds, moduleRewards);
        }
    }

    function _transferModuleRewards(
        address[] memory recipients,
        uint96[] memory modulesFees,
        uint256 totalFee,
        uint256 totalRewards
    ) internal returns (uint256[] memory moduleRewards, uint256 totalModuleRewards) {
        totalModuleRewards = 0;
        moduleRewards = new uint256[](recipients.length);

        for (uint256 i = 0; i < recipients.length; i++) {
            if (modulesFees[i] > 0) {
                uint256 iModuleRewards = totalRewards.mul(modulesFees[i]).div(totalFee);
                moduleRewards[i] = iModuleRewards;
                _transferShares(address(this), recipients[i], iModuleRewards);
                _emitTransferAfterMintingShares(recipients[i], iModuleRewards);
                totalModuleRewards = totalModuleRewards.add(iModuleRewards);
            }
        }
    }

    function _transferTreasuryRewards(uint256 treasuryReward) internal {
        address treasury = getLidoLocator().getTreasury();
        _transferShares(address(this), treasury, treasuryReward);
        _emitTransferAfterMintingShares(treasury, treasuryReward);
    }

    /**
    * @dev Records a deposit to the deposit_contract.deposit function
    * @param _amount Total amount deposited to the Consensus Layer side
    */
    function _markAsUnbuffered(uint256 _amount) internal {
        BUFFERED_ETHER_POSITION.setStorageUint256(_getBufferedEther().sub(_amount));

        emit Unbuffered(_amount);
    }

    /**
    * @dev Write a value nominated in basis points
    */
    function _setBPValue(bytes32 _slot, uint16 _value) internal {
        require(_value <= TOTAL_BASIS_POINTS, "VALUE_OVER_100_PERCENT");
        _slot.setStorageUint256(uint256(_value));
    }

    /**
     * @dev Gets the amount of Ether temporary buffered on this contract balance
     */
    function _getBufferedEther() internal view returns (uint256) {
        return BUFFERED_ETHER_POSITION.getStorageUint256();
    }

    /**
     * @dev Gets unaccounted (excess) Ether on this contract balance
     */
    function _getUnaccountedEther() internal view returns (uint256) {
        return address(this).balance.sub(_getBufferedEther());
    }

    /// @dev Calculates and returns the total base balance (multiple of 32) of validators in transient state,
    ///     i.e. submitted to the official Deposit contract but not yet visible in the CL state.
    /// @return transient balance in wei (1e-18 Ether)
    function _getTransientBalance() internal view returns (uint256) {
        uint256 depositedValidators = DEPOSITED_VALIDATORS_POSITION.getStorageUint256();
        uint256 clValidators = CL_VALIDATORS_POSITION.getStorageUint256();
        // clValidators can never be less than deposited ones.
        assert(depositedValidators >= clValidators);
        return depositedValidators.sub(clValidators).mul(DEPOSIT_SIZE);
    }

    /**
     * @dev Gets the total amount of Ether controlled by the system
     * @return total balance in wei
     */
    function _getTotalPooledEther() internal view returns (uint256) {
        return _getBufferedEther()
            .add(CL_BALANCE_POSITION.getStorageUint256())
            .add(_getTransientBalance());
    }

    function _pauseStaking() internal {
        STAKING_STATE_POSITION.setStorageStakeLimitStruct(
            STAKING_STATE_POSITION.getStorageStakeLimitStruct().setStakeLimitPauseState(true)
        );

        emit StakingPaused();
    }

    function _resumeStaking() internal {
        STAKING_STATE_POSITION.setStorageStakeLimitStruct(
            STAKING_STATE_POSITION.getStorageStakeLimitStruct().setStakeLimitPauseState(false)
        );

        emit StakingResumed();
    }

    function _getCurrentStakeLimit(StakeLimitState.Data memory _stakeLimitData) internal view returns (uint256) {
        if (_stakeLimitData.isStakingPaused()) {
            return 0;
        }
        if (!_stakeLimitData.isStakingLimitSet()) {
            return uint256(-1);
        }

        return _stakeLimitData.calculateCurrentStakeLimit();
    }

    /**
     * @dev Set max positive token rebase value
     * @param _maxPositiveTokenRebase max positive token rebase, nominated in MAX_POSITIVE_REBASE_PRECISION_POINTS
     */
    function _setMaxPositiveTokenRebase(uint256 _maxPositiveTokenRebase) internal {
        MAX_POSITIVE_TOKEN_REBASE_POSITION.setStorageUint256(_maxPositiveTokenRebase);

        emit MaxPositiveTokenRebaseSet(_maxPositiveTokenRebase);
    }

    /**
     * @dev Size-efficient analog of the `auth(_role)` modifier
     * @param _role Permission name
     */
    function _auth(bytes32 _role) internal view auth(_role) {
        // no-op
    }

    /**
     * @dev Invokes a deposit call to the Staking Router contract and updates buffered counters
     * @param _maxDepositsCount max deposits count
     * @param _stakingModuleId id of the staking module to be deposited
     * @param _depositCalldata module calldata
     */
    function deposit(uint256 _maxDepositsCount, uint256 _stakingModuleId, bytes _depositCalldata) external {
        ILidoLocator locator = getLidoLocator();

        require(msg.sender == locator.getDepositSecurityModule(), "APP_AUTH_DSM_FAILED");
        require(_stakingModuleId <= uint24(-1), "STAKING_MODULE_ID_TOO_LARGE");
        _whenNotStopped();

        IWithdrawalQueue withdrawalQueue = IWithdrawalQueue(locator.getWithdrawalQueue());
        require(!withdrawalQueue.isBunkerModeActive(), "CANT_DEPOSIT_IN_BUNKER_MODE");

        uint256 bufferedEth = _getBufferedEther();
        // we dont deposit funds that will go to withdrawals
        uint256 withdrawalReserve = withdrawalQueue.unfinalizedStETH();

        if (bufferedEth > withdrawalReserve) {
            bufferedEth = bufferedEth.sub(withdrawalReserve);
            /// available ether amount for deposits (multiple of 32eth)
            uint256 depositableEth = _min(bufferedEth.div(DEPOSIT_SIZE), _maxDepositsCount).mul(DEPOSIT_SIZE);

            uint256 unaccountedEth = _getUnaccountedEther();
            /// @dev transfer ether to SR and make deposit at the same time
            /// @notice allow zero value of depositableEth, in this case SR will simply transfer the unaccounted ether to Lido contract
            uint256 depositedKeysCount = IStakingRouter(locator.getStakingRouter()).deposit.value(depositableEth)(
                _maxDepositsCount,
                _stakingModuleId,
                _depositCalldata
            );
            assert(depositedKeysCount <= depositableEth / DEPOSIT_SIZE );

            if (depositedKeysCount > 0) {
                uint256 depositedAmount = depositedKeysCount.mul(DEPOSIT_SIZE);
                DEPOSITED_VALIDATORS_POSITION.setStorageUint256(DEPOSITED_VALIDATORS_POSITION.getStorageUint256().add(depositedKeysCount));

                _markAsUnbuffered(depositedAmount);
                assert(_getUnaccountedEther() == unaccountedEth);
            }
        }
    }

    function _handleOracleReport(
        OracleReportInputData memory _inputData
    ) internal returns (
        uint256 postTotalPooledEther,
        uint256 postTotalShares,
        uint256 withdrawals,
        uint256 elRewards
    ) {
        int256 clBalanceDiff = _processClStateUpdate(_inputData.clValidators, _inputData.clBalance);

        LimiterState.Data memory tokenRebaseLimiter = PositiveTokenRebaseLimiter.initLimiterState(
            getMaxPositiveTokenRebase(),
            _getTotalPooledEther(),
            _getTotalShares()
        );

        tokenRebaseLimiter.applyCLBalanceUpdate(clBalanceDiff);
        withdrawals = tokenRebaseLimiter.appendEther(_inputData.withdrawalVaultBalance);
        elRewards = tokenRebaseLimiter.appendEther(_inputData.elRewardsVaultBalance);

        // collect ETH from EL and Withdrawal vaults and send some to WithdrawalQueue if required
        _processETHDistribution(
            withdrawals,
            elRewards,
            _inputData.requestIdToFinalizeUpTo,
            _inputData.finalizationShareRate
        );

        // distribute rewards to Lido and Node Operators
        uint256 sharesMintedAsFees = _processRewards(clBalanceDiff, withdrawals, elRewards);

        _applyCoverage(tokenRebaseLimiter);

        (
            postTotalPooledEther, postTotalShares
        ) = _completeTokenRebase(
            tokenRebaseLimiter, sharesMintedAsFees, _inputData.timeElapsed
        );

        emit ETHDistributed(
            clBalanceDiff,
            withdrawals,
            elRewards,
            _getBufferedEther()
        );
    }

    function _completeTokenRebase(
        LimiterState.Data memory _tokenRebaseLimiter,
        uint256 _sharesMintedAsFees,
        uint256 _timeElapsed
    ) internal returns (uint256 postTotalPooledEther, uint256 postTotalShares) {
        uint256 preTotalPooledEther = _tokenRebaseLimiter.totalPooledEther;
        uint256 preTotalShares = _tokenRebaseLimiter.totalShares;

        postTotalPooledEther = _getTotalPooledEther();
        postTotalShares = _getTotalShares();

        address postTokenRebaseReceiver = getLidoLocator().getPostTokenRebaseReceiver();
        if (postTokenRebaseReceiver != address(0)) {
            IPostTokenRebaseReceiver(postTokenRebaseReceiver).handlePostTokenRebase(
                preTotalShares,
                preTotalPooledEther,
                postTotalShares,
                postTotalPooledEther,
                _sharesMintedAsFees,
                _timeElapsed
            );
        }

        emit TokenRebase(
            preTotalShares,
            preTotalPooledEther,
            postTotalShares,
            postTotalPooledEther,
            _sharesMintedAsFees,
            _timeElapsed
        );
    }

    function _applyCoverage(LimiterState.Data memory _tokenRebaseLimiter) internal {
        ISelfOwnedStETHBurner burner = ISelfOwnedStETHBurner(getLidoLocator().getSelfOwnedStETHBurner());
        (uint256 coverShares, uint256 nonCoverShares) = burner.getSharesRequestedToBurn();
        uint256 maxSharesToBurn = _tokenRebaseLimiter.deductShares(coverShares.add(nonCoverShares));

        if (maxSharesToBurn > 0) {
            burner.processLidoOracleReport(maxSharesToBurn);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _signedSub(int256 a, int256 b) internal pure returns (int256 c) {
        c = a - b;
        require(b - a == -c, "MATH_SUB_UNDERFLOW");
    }

    function _signedAdd(int256 a, int256 b) internal pure returns (int256 c) {
        c = a + b;
        require(c - a == b, "MATH_ADD_OVERFLOW");
    }
}
