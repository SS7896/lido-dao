// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

// See contracts/COMPILERS.md
pragma solidity 0.4.24;

import {AragonApp} from "@aragon/os/contracts/apps/AragonApp.sol";
import {SafeMath} from "@aragon/os/contracts/lib/math/SafeMath.sol";
import {SafeMath64} from "@aragon/os/contracts/lib/math/SafeMath64.sol";
import {UnstructuredStorage} from "@aragon/os/contracts/common/UnstructuredStorage.sol";

import {Math64} from "../lib/Math64.sol";
import {MemUtils} from "../../common/lib/MemUtils.sol";
import {MinFirstAllocationStrategy} from "../../common/lib/MinFirstAllocationStrategy.sol";
import {ILidoLocator} from "../../common/interfaces/ILidoLocator.sol";
import {IBurner} from "../../common/interfaces/IBurner.sol";
import {SigningKeys} from "../lib/SigningKeys.sol";
import {Packed64x4} from "../lib/Packed64x4.sol";
import {Versioned} from "../utils/Versioned.sol";

interface IStETH {
    function sharesOf(address _account) external view returns (uint256);
    function transferShares(address _recipient, uint256 _sharesAmount) external returns (uint256);
    function approve(address _spender, uint256 _amount) external returns (bool);
}


/// @title Node Operator registry
/// @notice Node Operator registry manages signing keys and other node operator data.
/// @dev Must implement the full version of IStakingModule interface, not only the one declared locally.
///      It's also responsible for distributing rewards to node operators.
/// NOTE: the code below assumes moderate amount of node operators, i.e. up to `MAX_NODE_OPERATORS_COUNT`.
contract NodeOperatorsRegistry is AragonApp, Versioned {
    using SafeMath for uint256;
    using SafeMath64 for uint64;
    using UnstructuredStorage for bytes32;
    using SigningKeys for bytes32;
    using Packed64x4 for Packed64x4.Packed;

    //
    // EVENTS
    //
    event NodeOperatorAdded(uint256 nodeOperatorId, string name, address rewardAddress, uint64 stakingLimit);
    event NodeOperatorActiveSet(uint256 indexed nodeOperatorId, bool active);
    event NodeOperatorNameSet(uint256 indexed nodeOperatorId, string name);
    event NodeOperatorRewardAddressSet(uint256 indexed nodeOperatorId, address rewardAddress);
    event NodeOperatorStakingLimitSet(uint256 indexed nodeOperatorId, uint64 stakingLimit);
    event NodeOperatorTotalStoppedValidatorsReported(uint256 indexed nodeOperatorId, uint64 totalStopped);
    event NodeOperatorTotalKeysTrimmed(uint256 indexed nodeOperatorId, uint64 totalKeysTrimmed);
    event KeysOpIndexSet(uint256 keysOpIndex);
    event ContractVersionSet(uint256 version);
    event StakingModuleTypeSet(bytes32 moduleType);
    event RewardsDistributed(address indexed rewardAddress, uint256 sharesAmount);
    event LocatorContractSet(address locatorAddress);
    event VettedSigningKeysCountChanged(uint256 indexed nodeOperatorId, uint256 approvedValidatorsCount);
    event DepositedSigningKeysCountChanged(uint256 indexed nodeOperatorId, uint256 depositedValidatorsCount);
    event ExitedSigningKeysCountChanged(uint256 indexed nodeOperatorId, uint256 exitedValidatorsCount);
    event TotalSigningKeysCountChanged(uint256 indexed nodeOperatorId, uint256 totalValidatorsCount);

    event ValidatorsKeysNonceChanged(uint256 validatorsKeysNonce);
    event StuckValidatorsCountChanged(uint256 indexed nodeOperatorId, uint256 stuckValidatorsCount);
    event RefundedValidatorsCountChanged(uint256 indexed nodeOperatorId, uint256 RefundedValidatorsCount);
    event TargetValidatorsCountChanged(uint256 indexed nodeOperatorId, uint256 targetValidatorsCount);
    event NodeOperatorPenalized(address indexed recipientAddress, uint256 sharesPenalizedAmount);

    //
    // ACL
    //
    // bytes32 public constant MANAGE_SIGNING_KEYS = keccak256("MANAGE_SIGNING_KEYS");
    bytes32 public constant MANAGE_SIGNING_KEYS = 0x75abc64490e17b40ea1e66691c3eb493647b24430b358bd87ec3e5127f1621ee;
    // bytes32 public constant ADD_NODE_OPERATOR_ROLE = keccak256("ADD_NODE_OPERATOR_ROLE");
    bytes32 public constant ADD_NODE_OPERATOR_ROLE = 0xe9367af2d321a2fc8d9c8f1e67f0fc1e2adf2f9844fb89ffa212619c713685b2;
    // bytes32 public constant SET_NODE_OPERATOR_LIMIT_ROLE = keccak256("SET_NODE_OPERATOR_LIMIT_ROLE");
    bytes32 public constant SET_NODE_OPERATOR_LIMIT_ROLE = 0x07b39e0faf2521001ae4e58cb9ffd3840a63e205d288dc9c93c3774f0d794754;
    // bytes32 public constant INVALIDATE_READY_TO_DEPOSIT_KEYS_ROLE = keccak256("INVALIDATE_READY_TO_DEPOSIT_KEYS_ROLE");
    bytes32 public constant INVALIDATE_READY_TO_DEPOSIT_KEYS_ROLE =
        0xeaf200990dc6840b2b98dda560b1fd49fc2bbb13aae6f2864e84b7af0b3026fe;
    // bytes32 public constant ACTIVATE_NODE_OPERATOR_ROLE = keccak256("MANAGE_NODE_OPERATOR_ROLE");
    bytes32 public constant MANAGE_NODE_OPERATOR_ROLE = 0x78523850fdd761612f46e844cf5a16bda6b3151d6ae961fd7e8e7b92bfbca7f8;
    // bytes32 public constant STAKING_ROUTER_ROLE = keccak256("STAKING_ROUTER_ROLE");
    bytes32 public constant STAKING_ROUTER_ROLE = 0xbb75b874360e0bfd87f964eadd8276d8efb7c942134fc329b513032d0803e0c6;

    //
    // CONSTANTS
    //
    uint256 public constant MAX_NODE_OPERATORS_COUNT = 200;
    uint256 public constant MAX_NODE_OPERATOR_NAME_LENGTH = 255;

    uint256 internal constant UINT64_MAX = uint256(~uint64(0));
    uint256 internal constant STUCK_VALIDATORS_PENALTY_DELAY = 2 days;

    // SigningKeysStats
    uint8 internal constant VETTED_KEYS_COUNT_OFFSET = 0;
    /// @dev Number of keys in the EXITED state for this operator for all time
    uint8 internal constant EXITED_KEYS_COUNT_OFFSET = 1;
    /// @dev Total number of keys of this operator for all time
    uint8 internal constant TOTAL_KEYS_COUNT_OFFSET = 2;
    /// @dev Number of keys of this operator which were in DEPOSITED state for all time
    uint8 internal constant DEPOSITED_KEYS_COUNT_OFFSET = 3;

    // TargetValidatorsStats

    /// @dev DAO target limit, used to check how many keys shoud be go to exit
    ///      UINT64_MAX - unlim
    ///      0 - all deposited keys
    ///      N < deposited keys -
    ///      deposited < N < vetted - use (N-deposited) as available
    uint8 internal constant TARGET_VALIDATORS_ACTIVE_OFFSET = 0;
    /// @dev relative target active validators limit for operator, set by DAO, UINT64_MAX === no limit
    uint8 internal constant TARGET_VALIDATORS_COUNT_OFFSET = 1;
    /// @dev excess validators count for operator that will be forced to exit
    uint8 internal constant EXCESS_VALIDATORS_COUNT_OFFSET = 2;

    // StuckPenaltyStats
    /// @dev stuck keys count from oracle report
    uint8 internal constant STUCK_VALIDATORS_COUNT_OFFSET = 0;
    /// @dev refunded keys count from dao
    uint8 internal constant REFUNDED_VALIDATORS_COUNT_OFFSET = 1;
    uint8 internal constant STUCK_PENALTY_END_TIMESTAMP_OFFSET = 2;

    //
    // UNSTRUCTURED STORAGE POSITIONS
    //
    // bytes32 internal constant SIGNING_KEYS_MAPPING_NAME = keccak256("lido.NodeOperatorsRegistry.signingKeysMappingName");
    bytes32 internal constant SIGNING_KEYS_MAPPING_NAME = 0xeb2b7ad4d8ce5610cfb46470f03b14c197c2b751077c70209c5d0139f7c79ee9;

    // bytes32 internal constant LIDO_LOCATOR_POSITION = keccak256("lido.NodeOperatorsRegistry.lidoLocator");
    bytes32 internal constant LIDO_LOCATOR_POSITION = 0xfb2059fd4b64256b64068a0f57046c6d40b9f0e592ba8bcfdf5b941910d03537;

    /// @dev Total number of operators
    // bytes32 internal constant TOTAL_OPERATORS_COUNT_POSITION = keccak256("lido.NodeOperatorsRegistry.totalOperatorsCount");
    bytes32 internal constant TOTAL_OPERATORS_COUNT_POSITION =
        0xe2a589ae0816b289a9d29b7c085f8eba4b5525accca9fa8ff4dba3f5a41287e8;

    /// @dev Cached number of active operators
    // bytes32 internal constant ACTIVE_OPERATORS_COUNT_POSITION = keccak256("lido.NodeOperatorsRegistry.activeOperatorsCount");
    bytes32 internal constant ACTIVE_OPERATORS_COUNT_POSITION =
        0x6f5220989faafdc182d508d697678366f4e831f5f56166ad69bfc253fc548fb1;

    /// @dev link to the index of operations with keys
    // bytes32 internal constant KEYS_OP_INDEX_POSITION = keccak256("lido.NodeOperatorsRegistry.keysOpIndex");
    bytes32 internal constant KEYS_OP_INDEX_POSITION = 0xcd91478ac3f2620f0776eacb9c24123a214bcb23c32ae7d28278aa846c8c380e;

    /// @dev module type
    // bytes32 internal constant TYPE_POSITION = keccak256("lido.NodeOperatorsRegistry.type");
    bytes32 internal constant TYPE_POSITION = 0xbacf4236659a602d72c631ba0b0d67ec320aaf523f3ae3590d7faee4f42351d0;

    //
    // DATA TYPES
    //

    /// @dev Node Operator parameters and internal state
    struct NodeOperator {
        /// @dev Flag indicating if the operator can participate in further staking and reward distribution
        bool active;
        /// @dev Ethereum address on Execution Layer which receives steth rewards for this operator
        address rewardAddress;
        /// @dev Human-readable name
        string name;
        /// @dev The below variables store the signing keys info of the node operator.
        ///     These variables can take values in the following ranges:
        ///
        ///                0             <=  exitedSigningKeysCount   <= depositedSigningKeysCount
        ///     exitedSigningKeysCount   <= depositedSigningKeysCount <=  vettedSigningKeysCount
        ///    depositedSigningKeysCount <=   vettedSigningKeysCount  <=   totalSigningKeysCount
        ///    depositedSigningKeysCount <=   totalSigningKeysCount   <=        MAX_UINT64
        ///
        /// Additionally, the exitedSigningKeysCount and depositedSigningKeysCount values are monotonically increasing:
        /// :                              :         :         :         :
        /// [....exitedSigningKeysCount....]-------->:         :         :
        /// [....depositedSigningKeysCount :.........]-------->:         :
        /// [....vettedSigningKeysCount....:.........:<--------]-------->:
        /// [....totalSigningKeysCount.....:.........:<--------:---------]------->
        /// :                              :         :         :         :
        Packed64x4.Packed signingKeysStats;
        Packed64x4.Packed stuckPenaltyStats;
        Packed64x4.Packed targetValidatorsStats;
    }

    //
    // STORAGE VARIABLES
    //

    /// @dev Mapping of all node operators. Mapping is used to be able to extend the struct.
    mapping(uint256 => NodeOperator) internal _nodeOperators;
    // NodeOperatorTotals internal _nodeOperatorTotals;

    //
    // METHODS
    //
    function initialize(address _locator, bytes32 _type) public onlyInit {
        // Initializations for v1 --> v2
        _initialize_v2(_locator, _type);
        initialized();
    }

    /// @notice A function to finalize upgrade to v2 (from v1). Can be called only once
    /// For more details see https://github.com/lidofinance/lido-improvement-proposals/blob/develop/LIPS/lip-10.md
    function finalizeUpgrade_v2(address _locator, bytes32 _type) external {
        require(hasInitialized() && !isPetrified(), "CONTRACT_NOT_INITIALIZED_OR_PETRIFIED");
        _checkContractVersion(0);
        _initialize_v2(_locator, _type);

        uint256 totalOperators = getNodeOperatorsCount();
        Packed64x4.Packed memory signingKeysStats;
        for (uint256 operatorId = 0; operatorId < totalOperators; ++operatorId) {
            signingKeysStats = _loadOperatorSigningKeysStats(operatorId);
            uint64 vettedSigningKeysCountBefore = signingKeysStats.get(VETTED_KEYS_COUNT_OFFSET);
            uint64 totalSigningKeysCount = signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET);
            uint64 depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);

            uint64 vettedSigningKeysCountAfter;
            if (!_nodeOperators[operatorId].active) {
                // trim vetted signing keys count when node operator is not active
                vettedSigningKeysCountAfter = depositedSigningKeysCount;
            } else {
                vettedSigningKeysCountAfter =
                    Math64.min(totalSigningKeysCount, Math64.max(depositedSigningKeysCount, vettedSigningKeysCountBefore));
            }

            if (vettedSigningKeysCountBefore != vettedSigningKeysCountAfter) {
                signingKeysStats.set(VETTED_KEYS_COUNT_OFFSET, vettedSigningKeysCountAfter);
                _saveOperatorSigningKeysStats(operatorId, signingKeysStats);
                emit VettedSigningKeysCountChanged(operatorId, vettedSigningKeysCountAfter);
            }
        }

        _increaseValidatorsKeysNonce();

        IStETH(getLocator().lido()).approve(getLocator().burner(), ~uint256(0));
    }

    function _initialize_v2(address _locator, bytes32 _type) internal {
        _onlyNonZeroAddress(_locator);
        LIDO_LOCATOR_POSITION.setStorageAddress(_locator);
        TYPE_POSITION.setStorageBytes32(_type);

        _setContractVersion(2);

        emit ContractVersionSet(2);
        emit LocatorContractSet(_locator);
        emit StakingModuleTypeSet(_type);
    }

    /// @notice Add node operator named `name` with reward address `rewardAddress` and staking limit = 0 validators
    /// @param _name Human-readable name
    /// @param _rewardAddress Ethereum 1 address which receives stETH rewards for this operator
    /// @return id a unique key of the added operator
    function addNodeOperator(string _name, address _rewardAddress) external returns (uint256 id) {
        _onlyValidNodeOperatorName(_name);
        _onlyNonZeroAddress(_rewardAddress);
        _auth(ADD_NODE_OPERATOR_ROLE);

        id = getNodeOperatorsCount();
        require(id < MAX_NODE_OPERATORS_COUNT, "MAX_OPERATORS_COUNT_EXCEEDED");

        TOTAL_OPERATORS_COUNT_POSITION.setStorageUint256(id + 1);

        NodeOperator storage operator = _nodeOperators[id];

        uint256 activeOperatorsCount = getActiveNodeOperatorsCount();
        ACTIVE_OPERATORS_COUNT_POSITION.setStorageUint256(activeOperatorsCount + 1);

        operator.active = true;
        operator.name = _name;
        operator.rewardAddress = _rewardAddress;

        emit NodeOperatorAdded(id, _name, _rewardAddress, 0);
    }

    /// @notice Activates deactivated node operator with given id
    /// @param _nodeOperatorId Node operator id to deactivate
    function activateNodeOperator(uint256 _nodeOperatorId) external {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _auth(MANAGE_NODE_OPERATOR_ROLE);

        _onlyCorrectNodeOperatorState(!getNodeOperatorIsActive(_nodeOperatorId));

        ACTIVE_OPERATORS_COUNT_POSITION.setStorageUint256(getActiveNodeOperatorsCount() + 1);

        _nodeOperators[_nodeOperatorId].active = true;

        emit NodeOperatorActiveSet(_nodeOperatorId, true);
        _increaseValidatorsKeysNonce();
    }

    /// @notice Deactivates active node operator with given id
    /// @param _nodeOperatorId Node operator id to deactivate
    function deactivateNodeOperator(uint256 _nodeOperatorId) external {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _auth(MANAGE_NODE_OPERATOR_ROLE);

        _onlyCorrectNodeOperatorState(getNodeOperatorIsActive(_nodeOperatorId));

        uint256 activeOperatorsCount = getActiveNodeOperatorsCount();
        ACTIVE_OPERATORS_COUNT_POSITION.setStorageUint256(activeOperatorsCount.sub(1));

        _nodeOperators[_nodeOperatorId].active = false;

        emit NodeOperatorActiveSet(_nodeOperatorId, false);

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        uint64 vettedSigningKeysCount = signingKeysStats.get(VETTED_KEYS_COUNT_OFFSET);
        uint64 depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);

        // reset vetted keys count to the deposited validators count
        if (vettedSigningKeysCount > depositedSigningKeysCount) {
            signingKeysStats.set(VETTED_KEYS_COUNT_OFFSET, depositedSigningKeysCount);
            _saveOperatorSigningKeysStats(_nodeOperatorId, signingKeysStats);

            emit VettedSigningKeysCountChanged(_nodeOperatorId, depositedSigningKeysCount);
        }
        _increaseValidatorsKeysNonce();
    }

    /// @notice Change human-readable name of the node operator with given id
    /// @param _nodeOperatorId Node operator id to set name for
    /// @param _name New human-readable name of the node operator
    function setNodeOperatorName(uint256 _nodeOperatorId, string _name) external {
        _onlyValidNodeOperatorName(_name);
        _onlyExistedNodeOperator(_nodeOperatorId);
        _authP(ADD_NODE_OPERATOR_ROLE, arr(uint256(_nodeOperatorId)));

        _nodeOperators[_nodeOperatorId].name = _name;
        emit NodeOperatorNameSet(_nodeOperatorId, _name);
    }

    /// @notice Change reward address of the node operator with given id
    /// @param _nodeOperatorId Node operator id to set reward address for
    /// @param _rewardAddress Execution layer Ethereum address to set as reward address
    function setNodeOperatorRewardAddress(uint256 _nodeOperatorId, address _rewardAddress) external {
        _onlyNonZeroAddress(_rewardAddress);
        _onlyExistedNodeOperator(_nodeOperatorId);
        _authP(ADD_NODE_OPERATOR_ROLE, arr(uint256(_nodeOperatorId), uint256(_rewardAddress)));

        _nodeOperators[_nodeOperatorId].rewardAddress = _rewardAddress;
        emit NodeOperatorRewardAddressSet(_nodeOperatorId, _rewardAddress);
    }

    /// @notice Set the maximum number of validators to stake for the node operator with given id
    /// @dev Current implementation preserves invariant: depositedSigningKeysCount <= vettedSigningKeysCount <= totalSigningKeysCount.
    ///     If _vettedSigningKeysCount out of range [depositedSigningKeysCount, totalSigningKeysCount], the new vettedSigningKeysCount
    ///     value will be set to the nearest range border.
    /// @param _nodeOperatorId Node operator id to set reward address for
    /// @param _vettedSigningKeysCount New staking limit of the node operator
    function setNodeOperatorStakingLimit(uint256 _nodeOperatorId, uint64 _vettedSigningKeysCount) external {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _authP(SET_NODE_OPERATOR_LIMIT_ROLE, arr(uint256(_nodeOperatorId), uint256(_vettedSigningKeysCount)));
        _onlyCorrectNodeOperatorState(getNodeOperatorIsActive(_nodeOperatorId));

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        uint64 vettedSigningKeysCountBefore = signingKeysStats.get(VETTED_KEYS_COUNT_OFFSET);
        uint64 depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);
        uint64 totalSigningKeysCount = signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET);

        uint64 vettedSigningKeysCountAfter =
            Math64.min(totalSigningKeysCount, Math64.max(_vettedSigningKeysCount, depositedSigningKeysCount));

        if (vettedSigningKeysCountAfter == vettedSigningKeysCountBefore) {
            return;
        }

        signingKeysStats.set(VETTED_KEYS_COUNT_OFFSET, vettedSigningKeysCountAfter);
        _saveOperatorSigningKeysStats(_nodeOperatorId, signingKeysStats);

        emit VettedSigningKeysCountChanged(_nodeOperatorId, vettedSigningKeysCountAfter);
        _increaseValidatorsKeysNonce();
    }

    /// @notice Called by StakingRouter to signal that stETH rewards were minted for this module.
    function handleRewardsMinted(uint256) external view {
        _auth(STAKING_ROUTER_ROLE);
        // since we're pushing rewards to operators after exited validators counts are
        // updated (as opposed to pulling by node ops), we don't need any handling here
    }

    /// @notice Called by StakingRouter to update the number of the validators of the given node
    /// operator that were requested to exit but failed to do so in the max allowed time
    ///
    /// @param _nodeOperatorId Id of the node operator
    /// @param _stuckValidatorsCount New number of stuck validators of the node operator
    function updateStuckValidatorsKeysCount(uint256 _nodeOperatorId, uint256 _stuckValidatorsCount) external {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _auth(STAKING_ROUTER_ROLE);

        _updateStuckValidatorsKeysCount(_nodeOperatorId, uint64(_stuckValidatorsCount));
    }

    /// @notice Called by StakingRouter to update the number of the validators in the EXITED state
    /// for node operator with given id
    ///
    /// @param _nodeOperatorId Id of the node operator
    /// @param _exitedValidatorsKeysCount New number of EXITED validators of the node operator
    /// @return Total number of exited validators across all node operators.
    function updateExitedValidatorsKeysCount(uint256 _nodeOperatorId, uint256 _exitedValidatorsKeysCount)
        external
        returns (uint256)
    {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _auth(STAKING_ROUTER_ROLE);

        return _updateExitedValidatorsKeysCount(_nodeOperatorId, uint64(_exitedValidatorsKeysCount), false);
    }

    /// @notice Called by StakingRouter after oracle finishes updating exited keys counts for all operators.
    function finishUpdatingExitedValidatorsKeysCount() external {
        _auth(STAKING_ROUTER_ROLE);
        // for the permissioned module, we're distributing rewards within oracle operation
        // since the number of node ops won't be high and thus gas costs are limited
        _distributeRewards();
    }

    /// FIXME: this conflicts with the two-phase exited keys reporting in the staking router.
    /// If we want to allow hand-correcting the oracle, we need to also support it in the
    /// staking router.
    ///
    /// @notice Unsafely updates the number of the validators in the EXITED state for node operator with given id
    /// @param _nodeOperatorId Id of the node operator
    /// @param _exitedValidatorsKeysCount New number of EXITED validators of the node operator
    /// @return Total number of exited validators across all node operators.
    function unsafeUpdateValidatorsKeysCount(
        uint256 _nodeOperatorId,
        uint256 _exitedValidatorsKeysCount,
        uint256 _stuckValidatorsKeysCount
    ) external {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _auth(STAKING_ROUTER_ROLE);

        _updateExitedValidatorsKeysCount(_nodeOperatorId, uint64(_exitedValidatorsKeysCount), true);
        _updateStuckValidatorsKeysCount(_nodeOperatorId, uint64(_stuckValidatorsKeysCount));
    }

    function _updateExitedValidatorsKeysCount(uint256 _nodeOperatorId, uint64 _exitedValidatorsKeysCount, bool _allowDecrease)
        internal
        returns (uint64)
    {
        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        uint64 depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);
        uint64 exitedValidatorsCount = signingKeysStats.get(EXITED_KEYS_COUNT_OFFSET);
    
        if (exitedValidatorsCount != _exitedValidatorsKeysCount) {
            _requireOutOfRange(_exitedValidatorsKeysCount <= depositedSigningKeysCount);
            if (_exitedValidatorsKeysCount < exitedValidatorsCount) {
                require(_allowDecrease, "EXITED_VALIDATORS_COUNT_DECREASED");
            }

            signingKeysStats.set(EXITED_KEYS_COUNT_OFFSET, _exitedValidatorsKeysCount);
            _saveOperatorSigningKeysStats(_nodeOperatorId, signingKeysStats);
            emit ExitedSigningKeysCountChanged(_nodeOperatorId, _exitedValidatorsKeysCount);
            return _exitedValidatorsKeysCount;
        }
        return exitedValidatorsCount;
    }
   

    /// @notice Updates the limit of the validators that can be used for deposit by DAO
    /// @param _nodeOperatorId Id of the node operator
    /// @param _targetValidatorsCount New number of EXITED validators of the node operator
    /// @param _targetActive active flag
    function updateTargetValidatorsLimits(uint256 _nodeOperatorId, uint64 _targetValidatorsCount, bool _targetActive)
        external
    {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _auth(STAKING_ROUTER_ROLE);

        Packed64x4.Packed memory operatorTargetStats = _loadOperatorTargetValidatorsStats(_nodeOperatorId);
        if (operatorTargetStats.get(TARGET_VALIDATORS_ACTIVE_OFFSET) == (_targetActive ? 1 : 0)) return;

        operatorTargetStats.set(TARGET_VALIDATORS_ACTIVE_OFFSET, _targetActive ? 1 : 0);
        operatorTargetStats.set(TARGET_VALIDATORS_COUNT_OFFSET, _targetActive ? _targetValidatorsCount : 0);

        _saveOperatorTargetValidatorsStats(_nodeOperatorId, operatorTargetStats);

        emit TargetValidatorsCountChanged(_nodeOperatorId, _targetValidatorsCount);
    }

    /**
     * @notice Set the stuck signings keys count
     */
    function _updateStuckValidatorsKeysCount(uint256 _nodeOperatorId, uint64 _stuckValidatorsCount) internal {
        Packed64x4.Packed memory stuckPenaltyStats = _loadOperatorStuckPenaltyStats(_nodeOperatorId);
        if (_stuckValidatorsCount == stuckPenaltyStats.get(STUCK_VALIDATORS_COUNT_OFFSET)) return;

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        _requireOutOfRange(_stuckValidatorsCount <= signingKeysStats.get(EXITED_KEYS_COUNT_OFFSET));

        stuckPenaltyStats.set(STUCK_VALIDATORS_COUNT_OFFSET, _stuckValidatorsCount);
        _saveOperatorStuckPenaltyStats(_nodeOperatorId, stuckPenaltyStats);

        emit StuckValidatorsCountChanged(_nodeOperatorId, _stuckValidatorsCount);
    }

    /**
     * @notice Set the refunded signing keys count
     */
    function updateRefundedValidatorsKeysCount(uint256 _nodeOperatorId, uint64 _refundedValidatorsCount) external {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _auth(STAKING_ROUTER_ROLE);

        Packed64x4.Packed memory stuckPenaltyStats = _loadOperatorStuckPenaltyStats(_nodeOperatorId);

        stuckPenaltyStats.set(REFUNDED_VALIDATORS_COUNT_OFFSET, _refundedValidatorsCount);

        if (stuckPenaltyStats.get(STUCK_VALIDATORS_COUNT_OFFSET) <= _refundedValidatorsCount) {
            stuckPenaltyStats.set(STUCK_PENALTY_END_TIMESTAMP_OFFSET, uint64(block.timestamp + STUCK_VALIDATORS_PENALTY_DELAY));
        }

        _saveOperatorStuckPenaltyStats(_nodeOperatorId, stuckPenaltyStats);

        emit RefundedValidatorsCountChanged(_nodeOperatorId, _refundedValidatorsCount);
    }

    function invalidateReadyToDepositKeys() external {
        uint256 operatorsCount = getNodeOperatorsCount();
        _requireOutOfRange(operatorsCount > 0);
        invalidateReadyToDepositKeysRange(0, operatorsCount - 1);
    }

    /// @notice Invalidates all unused validators keys for all node operators
    function invalidateReadyToDepositKeysRange(uint256 _indexFrom, uint256 _indexTo) public {
        _auth(INVALIDATE_READY_TO_DEPOSIT_KEYS_ROLE);
        _requireOutOfRange(_indexFrom <= _indexTo && _indexTo < getNodeOperatorsCount());

        uint64 trimmedKeysCount;
        uint64 totalTrimmedKeysCount;
        Packed64x4.Packed memory signingKeysStats;

        for (uint256 _nodeOperatorId = _indexFrom; _nodeOperatorId <= _indexTo; ++_nodeOperatorId) {
            signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);

            uint64 depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);
            trimmedKeysCount = signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET) - depositedSigningKeysCount;
            if (trimmedKeysCount == 0) continue;
            totalTrimmedKeysCount += trimmedKeysCount;

            signingKeysStats.set(TOTAL_KEYS_COUNT_OFFSET, depositedSigningKeysCount);
            signingKeysStats.set(VETTED_KEYS_COUNT_OFFSET, depositedSigningKeysCount);
            _saveOperatorSigningKeysStats(_nodeOperatorId, signingKeysStats);

            emit TotalSigningKeysCountChanged(_nodeOperatorId, depositedSigningKeysCount);
            emit VettedSigningKeysCountChanged(_nodeOperatorId, depositedSigningKeysCount);
            emit NodeOperatorTotalKeysTrimmed(_nodeOperatorId, trimmedKeysCount);
        }

        /// @todo revert?
        if (totalTrimmedKeysCount > 0) {
            _increaseValidatorsKeysNonce();
        }
    }

    /// @notice Requests the given number of the validator keys from the staking module
    /// @param _keysCount Requested keys count to return
    /// @return returnedKeysCount Actually returned keys count
    /// @return publicKeys Batch of the concatenated public validators keys
    /// @return signatures Batch of the concatenated signatures for returned public keys
    function requestValidatorsKeysForDeposits(uint256 _keysCount, bytes)
        external
        returns (uint256 enqueuedValidatorsKeysCount, bytes memory publicKeys, bytes memory signatures)
    {
        _auth(STAKING_ROUTER_ROLE);

        uint256[] memory nodeOperatorIds;
        uint256[] memory activeKeysCountAfterAllocation;
        uint256[] memory exitedSigningKeysCount;
        (enqueuedValidatorsKeysCount, nodeOperatorIds, activeKeysCountAfterAllocation, exitedSigningKeysCount) =
            _getSigningKeysAllocationData(_keysCount);

        if (enqueuedValidatorsKeysCount == 0) {
            return (0, new bytes(0), new bytes(0));
        }

        (publicKeys, signatures) = _loadAllocatedSigningKeys(
            enqueuedValidatorsKeysCount, nodeOperatorIds, activeKeysCountAfterAllocation, exitedSigningKeysCount
        );

        _increaseValidatorsKeysNonce();
    }

    function _getCorrectedNodeOperator(uint256 _nodeOperatorId)
        internal
        view
        returns (uint64 vettedSigningKeysCount, uint64 exitedSigningKeysCount, uint64 depositedSigningKeysCount)
    {
        if (!getNodeOperatorIsActive(_nodeOperatorId)) return (0, 0, 0);

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        vettedSigningKeysCount = signingKeysStats.get(VETTED_KEYS_COUNT_OFFSET);
        exitedSigningKeysCount = signingKeysStats.get(EXITED_KEYS_COUNT_OFFSET);
        depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);

        Packed64x4.Packed memory operatorTargetStats = _loadOperatorTargetValidatorsStats(_nodeOperatorId);
        // correct vetted count according to target
        if (operatorTargetStats.get(TARGET_VALIDATORS_ACTIVE_OFFSET) > 0) {
            // if target is enabled
            uint64 targetValidatorsCount = operatorTargetStats.get(TARGET_VALIDATORS_COUNT_OFFSET);
            if (targetValidatorsCount <= depositedSigningKeysCount.sub(exitedSigningKeysCount)) {
                vettedSigningKeysCount = depositedSigningKeysCount;
            } else {
                vettedSigningKeysCount = Math64.min(vettedSigningKeysCount, exitedSigningKeysCount.add(targetValidatorsCount));
            }
        }
    }

    function _getSigningKeysAllocationData(uint256 _keysCount)
        internal
        view
        returns (
            uint256 allocatedKeysCount,
            uint256[] memory nodeOperatorIds,
            uint256[] memory activeKeyCountsAfterAllocation,
            uint256[] memory operatorsExitedSigningKeysCount
        )
    {
        uint256 activeNodeOperatorsCount = getActiveNodeOperatorsCount();
        nodeOperatorIds = new uint256[](activeNodeOperatorsCount);
        activeKeyCountsAfterAllocation = new uint256[](activeNodeOperatorsCount);
        operatorsExitedSigningKeysCount = new uint256[](activeNodeOperatorsCount);
        uint256[] memory activeKeysCapacities = new uint256[](activeNodeOperatorsCount);

        uint256 activeNodeOperatorIndex;
        uint256 nodeOperatorsCount = getNodeOperatorsCount();
        uint64 vettedSigningKeysCount;
        uint64 exitedSigningKeysCount;
        uint64 depositedSigningKeysCount;
        for (uint256 nodeOperatorId = 0; nodeOperatorId < nodeOperatorsCount; ++nodeOperatorId) {
            (vettedSigningKeysCount, exitedSigningKeysCount, depositedSigningKeysCount) =
                _getCorrectedNodeOperator(nodeOperatorId);
            // the node operator has no available signing keys
            if (depositedSigningKeysCount == vettedSigningKeysCount) continue;

            nodeOperatorIds[activeNodeOperatorIndex] = nodeOperatorId;
            operatorsExitedSigningKeysCount[activeNodeOperatorIndex] = exitedSigningKeysCount;
            activeKeyCountsAfterAllocation[activeNodeOperatorIndex] = depositedSigningKeysCount.sub(exitedSigningKeysCount);
            activeKeysCapacities[activeNodeOperatorIndex] = vettedSigningKeysCount.sub(exitedSigningKeysCount);
            ++activeNodeOperatorIndex;
        }

        if (activeNodeOperatorIndex == 0) return (0, new uint256[](0), new uint256[](0), new uint256[](0));

        /// @dev shrink the length of the resulting arrays if some active node operators have no available keys to be deposited
        if (activeNodeOperatorIndex < activeNodeOperatorsCount) {
            assembly {
                mstore(nodeOperatorIds, activeNodeOperatorIndex)
                mstore(activeKeyCountsAfterAllocation, activeNodeOperatorIndex)
                mstore(operatorsExitedSigningKeysCount, activeNodeOperatorIndex)
                mstore(activeKeysCapacities, activeNodeOperatorIndex)
            }
        }

        allocatedKeysCount =
            MinFirstAllocationStrategy.allocate(activeKeyCountsAfterAllocation, activeKeysCapacities, uint64(_keysCount));

        assert(allocatedKeysCount <= _keysCount);
    }

    function _loadAllocatedSigningKeys(
        uint256 _keysCountToLoad,
        uint256[] memory _nodeOperatorIds,
        uint256[] memory _activeKeyCountsAfterAllocation,
        uint256[] memory _exitedSigningKeysCount
    ) internal returns (bytes memory pubkeys, bytes memory signatures) {
        (pubkeys, signatures) = SigningKeys.initKeySig(_keysCountToLoad);

        uint256 loadedKeysCount = 0;
        uint64 depositedSigningKeysCountBefore;
        uint64 depositedSigningKeysCountAfter;
        uint256 keyIndex;
        Packed64x4.Packed memory signingKeysStats;
        for (uint256 i = 0; i < _nodeOperatorIds.length; ++i) {
            signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorIds[i]);
            depositedSigningKeysCountBefore = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);

            // NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorIds[i]];
            // depositedSigningKeysCountBefore = nodeOperator.depositedSigningKeysCount;
            depositedSigningKeysCountAfter = uint64(_exitedSigningKeysCount[i].add(_activeKeyCountsAfterAllocation[i]));

            if (depositedSigningKeysCountBefore == depositedSigningKeysCountAfter) continue;

            for (keyIndex = depositedSigningKeysCountBefore; keyIndex < depositedSigningKeysCountAfter; ++keyIndex) {
                SIGNING_KEYS_MAPPING_NAME.loadKeySigAndAppend(
                    _nodeOperatorIds[i], keyIndex, loadedKeysCount, pubkeys, signatures
                );
                ++loadedKeysCount;
            }
            emit DepositedSigningKeysCountChanged(_nodeOperatorIds[i], depositedSigningKeysCountAfter);
            signingKeysStats.set(DEPOSITED_KEYS_COUNT_OFFSET, depositedSigningKeysCountAfter);
            _saveOperatorSigningKeysStats(_nodeOperatorIds[i], signingKeysStats);
        }

        assert(loadedKeysCount == _keysCountToLoad);
    }

    /// @notice Returns the node operator by id
    /// @param _nodeOperatorId Node Operator id
    /// @param _fullInfo If true, name will be returned as well
    function getNodeOperator(uint256 _nodeOperatorId, bool _fullInfo)
        external
        view
        returns (
            bool active,
            string name,
            address rewardAddress,
            uint64 stakingLimit,
            uint64 stoppedValidators,
            uint64 totalSigningKeys,
            uint64 usedSigningKeys
        )
    {
        _onlyExistedNodeOperator(_nodeOperatorId);

        NodeOperator storage nodeOperator = _nodeOperators[_nodeOperatorId];

        active = nodeOperator.active;
        rewardAddress = nodeOperator.rewardAddress;
        name = _fullInfo ? nodeOperator.name : ""; // reading name is 2+ SLOADs

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);

        stakingLimit = signingKeysStats.get(VETTED_KEYS_COUNT_OFFSET);
        stoppedValidators = signingKeysStats.get(EXITED_KEYS_COUNT_OFFSET);
        totalSigningKeys = signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET);
        usedSigningKeys = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);
    }

    /// @notice Returns the rewards distribution proportional to the effective stake for each node operator.
    /// @param _totalRewardShares Total amount of reward shares to distribute.
    function getRewardsDistribution(uint256 _totalRewardShares)
        public
        view
        returns (address[] memory recipients, uint256[] memory shares, bool[] memory penalized)
    {
        uint256 nodeOperatorCount = getNodeOperatorsCount();

        uint256 activeCount = getActiveNodeOperatorsCount();
        recipients = new address[](activeCount);
        shares = new uint256[](activeCount);
        penalized = new bool[](activeCount);
        uint256 idx = 0;

        uint256 totalActiveValidatorsCount = 0;
        for (uint256 operatorId = 0; operatorId < nodeOperatorCount; ++operatorId) {
            if (!getNodeOperatorIsActive(operatorId)) continue;

            Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(operatorId);
            uint256 activeValidatorsCount = signingKeysStats.diff(DEPOSITED_KEYS_COUNT_OFFSET, EXITED_KEYS_COUNT_OFFSET);
            totalActiveValidatorsCount = totalActiveValidatorsCount.add(activeValidatorsCount);

            recipients[idx] = _nodeOperators[operatorId].rewardAddress;
            // prefill shares array with 'key share' for recipient, see below
            shares[idx] = activeValidatorsCount;

            Packed64x4.Packed memory stuckPenaltyStats = _loadOperatorStuckPenaltyStats(operatorId);
            if (
                stuckPenaltyStats.get(REFUNDED_VALIDATORS_COUNT_OFFSET) < stuckPenaltyStats.get(STUCK_VALIDATORS_COUNT_OFFSET)
                    || block.timestamp <= stuckPenaltyStats.get(STUCK_PENALTY_END_TIMESTAMP_OFFSET)
            ) {
                penalized[idx] = true;
            }

            ++idx;
        }

        if (totalActiveValidatorsCount == 0) return (recipients, shares, penalized);

        uint256 perValidatorReward = _totalRewardShares.div(totalActiveValidatorsCount);

        for (idx = 0; idx < activeCount; ++idx) {
            shares[idx] = shares[idx].mul(perValidatorReward);
        }

        return (recipients, shares, penalized);
    }

    /// @notice Add `_quantity` validator signing keys to the keys of the node operator #`_nodeOperatorId`. Concatenated keys are: `_pubkeys`
    /// @dev Along with each key the DAO has to provide a signatures for the
    ///      (pubkey, withdrawal_credentials, 32000000000) message.
    ///      Given that information, the contract'll be able to call
    ///      deposit_contract.deposit on-chain.
    /// @param _nodeOperatorId Node Operator id
    /// @param _keysCount Number of signing keys provided
    /// @param _publicKeys Several concatenated validator signing keys
    /// @param _signatures Several concatenated signatures for (pubkey, withdrawal_credentials, 32000000000) messages
    function addSigningKeys(uint256 _nodeOperatorId, uint256 _keysCount, bytes _publicKeys, bytes _signatures) external {
        _addSigningKeys(_nodeOperatorId, _keysCount, _publicKeys, _signatures);
    }

    /// @notice Add `_quantity` validator signing keys of operator #`_id` to the set of usable keys. Concatenated keys are: `_pubkeys`. Can be done by node operator in question by using the designated rewards address.
    /// @dev Along with each key the DAO has to provide a signatures for the
    ///      (pubkey, withdrawal_credentials, 32000000000) message.
    ///      Given that information, the contract'll be able to call
    ///      deposit_contract.deposit on-chain.
    /// @param _nodeOperatorId Node Operator id
    /// @param _keysCount Number of signing keys provided
    /// @param _publicKeys Several concatenated validator signing keys
    /// @param _signatures Several concatenated signatures for (pubkey, withdrawal_credentials, 32000000000) messages
    function addSigningKeysOperatorBH(uint256 _nodeOperatorId, uint256 _keysCount, bytes _publicKeys, bytes _signatures)
        external
    {
        _addSigningKeys(_nodeOperatorId, _keysCount, _publicKeys, _signatures);
    }

    function _addSigningKeys(uint256 _nodeOperatorId, uint256 _keysCount, bytes _publicKeys, bytes _signatures) internal {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _onlyNodeOperatorManager(msg.sender, _nodeOperatorId);

        _requireOutOfRange(_keysCount != 0 && _keysCount <= UINT64_MAX);

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        uint256 totalSigningKeysCount = signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET);

        totalSigningKeysCount =
            SIGNING_KEYS_MAPPING_NAME.addKeysSigs(_nodeOperatorId, _keysCount, totalSigningKeysCount, _publicKeys, _signatures);

        _requireOutOfRange(totalSigningKeysCount.add(_keysCount) <= UINT64_MAX);

        emit TotalSigningKeysCountChanged(_nodeOperatorId, totalSigningKeysCount);

        signingKeysStats.set(TOTAL_KEYS_COUNT_OFFSET, uint64(totalSigningKeysCount));
        _saveOperatorSigningKeysStats(_nodeOperatorId, signingKeysStats);

        _increaseValidatorsKeysNonce();
    }

    /// @notice Removes a validator signing key #`_index` from the keys of the node operator #`_nodeOperatorId`
    /// @param _nodeOperatorId Node Operator id
    /// @param _index Index of the key, starting with 0
    /// @dev DEPRECATED use removeSigningKeys instead
    function removeSigningKey(uint256 _nodeOperatorId, uint256 _index) external {
        _removeUnusedSigningKeys(_nodeOperatorId, _index, 1);
    }

    /// @notice Removes an #`_keysCount` of validator signing keys starting from #`_index` of operator #`_id` usable keys. Executed on behalf of DAO.
    /// @param _nodeOperatorId Node Operator id
    /// @param _fromIndex Index of the key, starting with 0
    /// @param _keysCount Number of keys to remove
    function removeSigningKeys(uint256 _nodeOperatorId, uint256 _fromIndex, uint256 _keysCount) external {
        _removeUnusedSigningKeys(_nodeOperatorId, _fromIndex, _keysCount);
    }

    /// @notice Removes a validator signing key #`_index` of operator #`_id` from the set of usable keys. Executed on behalf of Node Operator.
    /// @param _nodeOperatorId Node Operator id
    /// @param _index Index of the key, starting with 0
    /// @dev DEPRECATED use removeSigningKeysOperatorBH instead
    function removeSigningKeyOperatorBH(uint256 _nodeOperatorId, uint256 _index) external {
        _removeUnusedSigningKeys(_nodeOperatorId, _index, 1);
    }

    /// @notice Removes an #`_keysCount` of validator signing keys starting from #`_index` of operator #`_id` usable keys. Executed on behalf of Node Operator.
    /// @param _nodeOperatorId Node Operator id
    /// @param _fromIndex Index of the key, starting with 0
    /// @param _keysCount Number of keys to remove
    function removeSigningKeysOperatorBH(uint256 _nodeOperatorId, uint256 _fromIndex, uint256 _keysCount) external {
        _removeUnusedSigningKeys(_nodeOperatorId, _fromIndex, _keysCount);
    }

    function _removeUnusedSigningKeys(uint256 _nodeOperatorId, uint256 _fromIndex, uint256 _keysCount) internal {
        _onlyExistedNodeOperator(_nodeOperatorId);
        _onlyNodeOperatorManager(msg.sender, _nodeOperatorId);

        _requireOutOfRange(_fromIndex < UINT64_MAX);
        /// @dev safemath(unit256) checks for overflow on addition, so _keysCount is guaranteed <= UINT64_MAX
        uint256 _toIndex = _fromIndex.add(_keysCount);
        _requireOutOfRange(_toIndex <= UINT64_MAX);

        // preserve the previous behavior of the method here and just return earlier
        if (_keysCount == 0) return;

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        uint256 totalSigningKeysCount = signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET);

        require(
            _fromIndex >= signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET) && _toIndex <= totalSigningKeysCount,
            "KEY_WAS_USED_OR_NOT_FOUND"
        );

        // removing from the last index to the highest one, so we won't get outside the array
        for (uint256 i = _toIndex; i > _fromIndex; --i) {
            totalSigningKeysCount =
                SIGNING_KEYS_MAPPING_NAME.removeUnusedKeySig(_nodeOperatorId, i - 1, totalSigningKeysCount.sub(1));
        }
        signingKeysStats.set(TOTAL_KEYS_COUNT_OFFSET, uint64(totalSigningKeysCount));
        emit TotalSigningKeysCountChanged(_nodeOperatorId, totalSigningKeysCount);

        uint64 vettedSigningKeysCount = signingKeysStats.get(VETTED_KEYS_COUNT_OFFSET);
        if (_fromIndex < vettedSigningKeysCount) {
            // decreasing the staking limit so the key at _index can't be used anymore
            signingKeysStats.set(VETTED_KEYS_COUNT_OFFSET, uint64(_fromIndex));
            emit VettedSigningKeysCountChanged(_nodeOperatorId, _fromIndex);
        }
        _saveOperatorSigningKeysStats(_nodeOperatorId, signingKeysStats);

        _increaseValidatorsKeysNonce();
    }

    /// @notice Returns total number of signing keys of the node operator #`_nodeOperatorId`
    function getTotalSigningKeyCount(uint256 _nodeOperatorId) external view returns (uint256) {
        _onlyExistedNodeOperator(_nodeOperatorId);
        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        return signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET);
    }

    /// @notice Returns number of usable signing keys of the node operator #`_nodeOperatorId`
    function getUnusedSigningKeyCount(uint256 _nodeOperatorId) external view returns (uint256) {
        _onlyExistedNodeOperator(_nodeOperatorId);

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        return signingKeysStats.diff(TOTAL_KEYS_COUNT_OFFSET, DEPOSITED_KEYS_COUNT_OFFSET);
    }

    /// @notice Returns a monotonically increasing counter that gets incremented when any of the following happens:
    ///   1. a node operator's key(s) is added;
    ///   2. a node operator's key(s) is removed;
    ///   3. a node operator's vetted keys count is changed.
    ///   4. a node operator was activated/deactivated. Activation or deactivation of node operator
    ///      might lead to usage of unvalidated keys in the assignNextSigningKeys method.
    function getKeysOpIndex() external view returns (uint256) {
        return KEYS_OP_INDEX_POSITION.getStorageUint256();
    }

    /// @notice Returns n-th signing key of the node operator #`_nodeOperatorId`
    /// @param _nodeOperatorId Node Operator id
    /// @param _index Index of the key, starting with 0
    /// @return key Key
    /// @return depositSignature Signature needed for a deposit_contract.deposit call
    /// @return used Flag indication if the key was used in the staking
    function getSigningKey(uint256 _nodeOperatorId, uint256 _index)
        external
        view
        returns (bytes key, bytes depositSignature, bool used)
    {
        bool[] memory keyUses;
        (key, depositSignature, keyUses) = getSigningKeys(_nodeOperatorId, _index, 1);
        used = keyUses[0];
    }

    /// @notice Returns n signing keys of the node operator #`_nodeOperatorId`
    /// @param _nodeOperatorId Node Operator id
    /// @param _offset Offset of the key, starting with 0
    /// @param _limit Number of keys to return
    /// @return pubkeys Keys concatenated into the bytes batch
    /// @return signatures Signatures concatenated into the bytes batch needed for a deposit_contract.deposit call
    /// @return used Array of flags indicated if the key was used in the staking
    function getSigningKeys(uint256 _nodeOperatorId, uint256 _offset, uint256 _limit)
        public
        view
        returns (bytes memory pubkeys, bytes memory signatures, bool[] memory used)
    {
        _onlyExistedNodeOperator(_nodeOperatorId);

        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        _requireOutOfRange(_offset.add(_limit) <= signingKeysStats.get(TOTAL_KEYS_COUNT_OFFSET));

        uint256 depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);
        (pubkeys, signatures) = SigningKeys.initKeySig(_limit);
        used = new bool[](_limit);

        for (uint256 i = 0; i < _limit; i++) {
            SIGNING_KEYS_MAPPING_NAME.loadKeySigAndAppend(_nodeOperatorId, _offset + i, i, pubkeys, signatures);
            used[i] = (_offset + i) < depositedSigningKeysCount;
        }
    }

    /// @notice Returns the type of the staking module
    function getType() external view returns (bytes32) {
        return TYPE_POSITION.getStorageBytes32();
    }

    function getNodeOperatorStats(uint256 _nodeOperatorId)
        external
        view
        returns (
            bool targetValidatorsActive,
            uint64 targetValidatorsCount,
            uint64 stuckValidatorsCount,
            uint64 refundedValidatorsCount,
            uint64 stuckPenaltyEndTimestamp
        )
    {
        _onlyExistedNodeOperator(_nodeOperatorId);

        Packed64x4.Packed memory operatorTargetStats = _loadOperatorTargetValidatorsStats(_nodeOperatorId);
        Packed64x4.Packed memory stuckPenaltyStats = _loadOperatorStuckPenaltyStats(_nodeOperatorId);

        targetValidatorsActive = operatorTargetStats.get(TARGET_VALIDATORS_ACTIVE_OFFSET) != 0;
        targetValidatorsCount = operatorTargetStats.get(TARGET_VALIDATORS_COUNT_OFFSET);
        stuckValidatorsCount = stuckPenaltyStats.get(STUCK_VALIDATORS_COUNT_OFFSET);
        refundedValidatorsCount = stuckPenaltyStats.get(REFUNDED_VALIDATORS_COUNT_OFFSET);
        stuckPenaltyEndTimestamp = stuckPenaltyStats.get(STUCK_PENALTY_END_TIMESTAMP_OFFSET);
    }

   

    function _isOperatorPenalized(uint256 _nodeOperatorId) internal view returns (bool) {
        Packed64x4.Packed memory stuckPenaltyStats = _loadOperatorStuckPenaltyStats(_nodeOperatorId);
        return stuckPenaltyStats.get(REFUNDED_VALIDATORS_COUNT_OFFSET) < stuckPenaltyStats.get(STUCK_VALIDATORS_COUNT_OFFSET)
            || block.timestamp <= stuckPenaltyStats.get(STUCK_PENALTY_END_TIMESTAMP_OFFSET);
    }
    /// @notice Returns the validators stats of given node operator
    /// @param _nodeOperatorId Node operator id to get data for
    /// @return exitedValidatorsCount Total number of validators in the EXITED state
    /// @return activeValidatorsKeysCount Total number of validators in active state
    /// @return readyToDepositValidatorsKeysCount Total number of validators ready to be deposited

    function _getValidatorsKeysStats(uint256 _nodeOperatorId)
        internal
        view
        returns (uint256 exitedValidatorsCount, uint256 activeValidatorsKeysCount, uint256 readyToDepositValidatorsKeysCount)
    {
        Packed64x4.Packed memory signingKeysStats = _loadOperatorSigningKeysStats(_nodeOperatorId);
        uint256 depositedSigningKeysCount = signingKeysStats.get(DEPOSITED_KEYS_COUNT_OFFSET);
        uint256 vettedSigningKeysCount = signingKeysStats.get(VETTED_KEYS_COUNT_OFFSET);

        exitedValidatorsCount = signingKeysStats.get(EXITED_KEYS_COUNT_OFFSET);
        activeValidatorsKeysCount = depositedSigningKeysCount - exitedValidatorsCount;

        if (!_isOperatorPenalized(_nodeOperatorId)) {
            Packed64x4.Packed memory operatorTargetStats = _loadOperatorTargetValidatorsStats(_nodeOperatorId);
            uint256 targetLimit = exitedValidatorsCount + operatorTargetStats.get(TARGET_VALIDATORS_COUNT_OFFSET);
            // if target moede is active and staking limit is greater than targeted keys amount
            if (operatorTargetStats.get(TARGET_VALIDATORS_ACTIVE_OFFSET) != 0 && targetLimit < vettedSigningKeysCount) {
                if (targetLimit > depositedSigningKeysCount) {
                    readyToDepositValidatorsKeysCount = targetLimit - depositedSigningKeysCount;
                }
            } else {
                readyToDepositValidatorsKeysCount = vettedSigningKeysCount - depositedSigningKeysCount;
            }
        }
        // else readyToDepositValidatorsKeysCount = 0 by default
    }

    function getValidatorsKeysStats(uint256 _nodeOperatorId)
        external
        view
        returns (uint256 exitedValidatorsCount, uint256 activeValidatorsKeysCount, uint256 readyToDepositValidatorsKeysCount)
    {
        _onlyExistedNodeOperator(_nodeOperatorId);
        return _getValidatorsKeysStats(_nodeOperatorId);
    }

 /// @notice Returns the validators stats of all node operators in the staking module
    /// @return exitedValidatorsCount Total number of validators in the EXITED state
    /// @return activeValidatorsKeysCount Total number of validators in active state
    /// @return readyToDepositValidatorsKeysCount Total number of validators ready to be deposited
    function getValidatorsKeysStats()
        external
        view
        returns (uint256 exitedValidatorsCount, uint256 activeValidatorsKeysCount, uint256 readyToDepositValidatorsKeysCount)
    {
        uint256 nodeOperatorsCount = getNodeOperatorsCount();
        uint256 tmpExitedValidatorsCount;
        uint256 tmpActiveValidatorsKeysCount;
         uint256 tmpReadyToDepositValidatorsKeysCount;
        for (uint i; i < nodeOperatorsCount; i++) {
            (tmpExitedValidatorsCount,  tmpActiveValidatorsKeysCount,  tmpReadyToDepositValidatorsKeysCount) = _getValidatorsKeysStats(i);
            exitedValidatorsCount += tmpExitedValidatorsCount;
            activeValidatorsKeysCount += tmpActiveValidatorsKeysCount;
            readyToDepositValidatorsKeysCount += tmpReadyToDepositValidatorsKeysCount;
        }
    }

    /// @notice Returns total number of node operators
    function getNodeOperatorsCount() public view returns (uint256) {
        return TOTAL_OPERATORS_COUNT_POSITION.getStorageUint256();
    }

    /// @notice Returns number of active node operators
    function getActiveNodeOperatorsCount() public view returns (uint256) {
        return ACTIVE_OPERATORS_COUNT_POSITION.getStorageUint256();
    }

    /// @notice Returns if the node operator with given id is active
    function getNodeOperatorIsActive(uint256 _nodeOperatorId) public view returns (bool) {
        return _nodeOperators[_nodeOperatorId].active;
    }

    /// @notice Returns a counter that MUST change it's value when any of the following happens:
    ///     1. a node operator's key(s) is added
    ///     2. a node operator's key(s) is removed
    ///     3. a node operator's ready to deposit keys count is changed
    ///     4. a node operator was activated/deactivated
    function getValidatorsKeysNonce() external view returns (uint256) {
        return KEYS_OP_INDEX_POSITION.getStorageUint256();
    }

    /// @notice distributes rewards among node operators
    /// @return the amount of stETH shares distributed among node operators
    function _distributeRewards() internal returns (uint256 distributed) {
        IStETH stETH = IStETH(getLocator().lido());

        uint256 sharesToDistribute = stETH.sharesOf(address(this));
        if (sharesToDistribute == 0) {
            return;
        }

        (address[] memory recipients, uint256[] memory shares, bool[] memory penalized) =
            getRewardsDistribution(sharesToDistribute);

        distributed = 0;

        for (uint256 idx = 0; idx < recipients.length; ++idx) {
            if (shares[idx] == 0) continue;
            if (penalized[idx]) {
                /// @dev half reward punishment
                /// @dev ignore remainder since it accumulated on contract balance
                shares[idx] >>= 1;
                IBurner(getLocator().burner()).requestBurnShares(address(this), shares[idx]);
                emit NodeOperatorPenalized(recipients[idx], shares[idx]);
            }
            stETH.transferShares(recipients[idx], shares[idx]);
            distributed = distributed.add(shares[idx]);
            emit RewardsDistributed(recipients[idx], shares[idx]);
        }
    }

    function getLocator() public view returns (ILidoLocator) {
        return ILidoLocator(LIDO_LOCATOR_POSITION.getStorageAddress());
    }

    function _increaseValidatorsKeysNonce() internal {
        uint256 keysOpIndex = KEYS_OP_INDEX_POSITION.getStorageUint256() + 1;
        KEYS_OP_INDEX_POSITION.setStorageUint256(keysOpIndex);
        /// @dev [DEPRECATED] event preserved for tooling compatibility
        emit KeysOpIndexSet(keysOpIndex);
        emit ValidatorsKeysNonceChanged(keysOpIndex);
    }
  
    function _loadOperatorTargetValidatorsStats(uint256 _nodeOperatorId) internal view returns (Packed64x4.Packed memory) {
        return _nodeOperators[_nodeOperatorId].targetValidatorsStats;
    }

    function _saveOperatorTargetValidatorsStats(uint256 _nodeOperatorId, Packed64x4.Packed memory _val) internal {
        _nodeOperators[_nodeOperatorId].targetValidatorsStats = _val;
    }

    function _loadOperatorStuckPenaltyStats(uint256 _nodeOperatorId) internal view returns (Packed64x4.Packed memory) {
        return _nodeOperators[_nodeOperatorId].stuckPenaltyStats;
    }

    function _saveOperatorStuckPenaltyStats(uint256 _nodeOperatorId, Packed64x4.Packed memory _val) internal {
        _nodeOperators[_nodeOperatorId].stuckPenaltyStats = _val;
    }

    function _loadOperatorSigningKeysStats(uint256 _nodeOperatorId) internal view returns (Packed64x4.Packed memory) {
        return _nodeOperators[_nodeOperatorId].signingKeysStats;
    }

    function _saveOperatorSigningKeysStats(uint256 _nodeOperatorId, Packed64x4.Packed memory _val) internal {
        _nodeOperators[_nodeOperatorId].signingKeysStats = _val;
    }

    function _requireAuth(bool _pass) internal pure {
        require(_pass, "APP_AUTH_FAILED");
    }

    function _requireOutOfRange(bool _pass) internal pure {
        require(_pass, "OUT_OF_RANGE");
    }

    function _onlyCorrectNodeOperatorState(bool _pass) internal pure {
        require(_pass, "WORNG_OPERATOR_ACTIVE_STATE");
    }

    function _auth(bytes32 _role) internal view {
        _requireAuth(canPerform(msg.sender, _role, new uint256[](0)));
    }

    function _authP(bytes32 _role, uint256[] _params) internal view {
        _requireAuth(canPerform(msg.sender, _role, _params));
    }

    function _onlyNodeOperatorManager(address _sender, uint256 _nodeOperatorId) internal view {
        bool isRewardAddress = _sender == _nodeOperators[_nodeOperatorId].rewardAddress;
        _requireAuth(isRewardAddress || canPerform(_sender, MANAGE_SIGNING_KEYS, arr(_nodeOperatorId)));
    }

    function _onlyExistedNodeOperator(uint256 _nodeOperatorId) internal view {
        _requireOutOfRange(_nodeOperatorId < getNodeOperatorsCount());
    }

    function _onlyValidNodeOperatorName(string _name) internal pure {
        require(bytes(_name).length > 0 && bytes(_name).length <= MAX_NODE_OPERATOR_NAME_LENGTH, "WRONG_NAME_LENGTH");
    }

    function _onlyNonZeroAddress(address _a) internal pure {
        require(_a != address(0), "ZERO_ADDRESS");
    }
}
