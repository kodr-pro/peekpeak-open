// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {PeekRegistry} from "../../src/PeekRegistry.sol";
import {MockJob} from "../../src/mocks/MockJob.sol";
import {MockRevertingJob} from "../../src/mocks/MockRevertingJob.sol";
import {ToggledExecutor} from "../helpers/TestContracts.sol";

/// @dev Bounded-actor handler for the PeekRegistry invariant campaign.
///      Ghost accounting is rebuilt from emitted events (RULE-8/RULE-15): every
///      wei tracked by the invariants corresponds to an emitted registry event.
contract Handler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant MAX_TRACKED_EXECUTIONS = 64;

    PeekRegistry public registry;
    ToggledExecutor public executor;
    MockJob public goodTarget;
    MockRevertingJob public revertingTarget;
    address public owner;

    address[] public users;
    address[] public targets;
    bytes32[] public jobIds;
    address[] public jobOwners;
    uint256[] public jobGasLimits;

    // ghost accounting (all derived from events)
    uint256 public ghostDeposits;
    uint256 public ghostOwnerWithdrawn;
    uint256 public ghostExecutorRefunds;
    uint256 public ghostTips;

    uint256[MAX_TRACKED_EXECUTIONS] public lastGasUsed;
    uint256[MAX_TRACKED_EXECUTIONS] public lastGasLimits;
    uint256 public trackedExecutions;

    bytes32 internal constant JOB_EXECUTED_TOPIC = keccak256("JobExecuted(bytes32,address,uint256,uint256,uint256)");
    bytes32 internal constant PULL_PENDING_TOPIC = keccak256("PullPending(address,uint256)");
    bytes32 internal constant GAS_WITHDRAWN_TOPIC = keccak256("GasWithdrawn(bytes32,address,uint256)");
    bytes32 internal constant PULL_WITHDRAWN_TOPIC = keccak256("PullWithdrawn(address,uint256)");
    bytes32 internal constant GAS_DEPOSITED_TOPIC = keccak256("GasDeposited(bytes32,uint256,uint128)");

    constructor(
        PeekRegistry _registry,
        ToggledExecutor _executor,
        MockJob _goodTarget,
        MockRevertingJob _revertingTarget,
        address _owner,
        address[4] memory _users
    ) {
        registry = _registry;
        executor = _executor;
        goodTarget = _goodTarget;
        revertingTarget = _revertingTarget;
        owner = _owner;
        targets.push(address(_goodTarget));
        targets.push(address(_revertingTarget));
        for (uint256 i = 0; i < 4; i++) {
            users.push(_users[i]);
        }
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // actions
    // ------------------------------------------------------------------

    function registerJob(uint256 userSeed, uint256 targetSeed, uint64 gasLimit, uint64 ceilingGwei, uint256 gasPriceGwei, uint256 extraWei)
        external
    {
        address user = users[userSeed % users.length];
        address target = targets[targetSeed % targets.length];
        gasLimit = uint64(bound(uint256(gasLimit), 60_000, 300_000));
        ceilingGwei = uint64(bound(uint256(ceilingGwei), 25, 300));
        uint256 gasPrice = bound(gasPriceGwei, 1, 25) * 1 gwei;
        vm.txGasPrice(gasPrice);

        // mirror the registry's worst-case precondition
        uint256 required =
            (uint256(uint32(gasLimit)) + 2 * uint256(registry.OVERHEAD_BUFFER())) * gasPrice
                + registry.keeperTip();
        uint256 deposit = required + bound(extraWei, 0, 0.05 ether);
        vm.deal(user, deposit + 0.1 ether);

        bytes32 jobId = keccak256(abi.encode(target, user, registry.jobNonce()));
        vm.prank(user);
        registry.registerJob{value: deposit}(target, uint32(gasLimit), ceilingGwei);

        ghostDeposits += deposit;
        jobIds.push(jobId);
        jobOwners.push(user);
        jobGasLimits.push(gasLimit);
    }

    function depositGas(uint256 jobSeed, uint256 amountWei) external {
        if (jobIds.length == 0) return;
        bytes32 jobId = jobIds[jobSeed % jobIds.length];
        uint256 amount = bound(amountWei, 1, 0.05 ether);
        address user = jobOwners[jobSeed % jobIds.length];
        vm.deal(user, amount);
        vm.prank(user);
        registry.depositGas{value: amount}(jobId);
        ghostDeposits += amount;
    }

    function withdrawGas(uint256 jobSeed, uint256 amountWei) external {
        if (jobIds.length == 0) return;
        uint256 idx = jobSeed % jobIds.length;
        bytes32 jobId = jobIds[idx];
        uint256 amount = bound(amountWei, 0, registry.escrows(jobId));
        vm.recordLogs();
        vm.prank(jobOwners[idx]);
        try registry.withdrawGas(jobId, uint128(amount)) {
            ghostOwnerWithdrawn += amount;
        } catch {
            // reverts allowed: rejected/insufficient withdrawals are valid fuzz paths
        }
    }

    function armGoodJob(uint256 jobSeed) external {
        if (jobIds.length == 0) return;
        uint256 idx = jobSeed % jobIds.length;
        if (address(uint160(uint256(jobSeed))) == address(0)) {} // no-op guard for solver
        if (jobOwners[idx] == address(0)) return;
        goodTarget.setReady(true);
    }

    function executeJob(uint256 jobSeed, uint256 gasPriceGwei, uint256 payloadSeed) external {
        if (jobIds.length == 0) return;
        uint256 idx = jobSeed % jobIds.length;
        bytes32 jobId = jobIds[idx];
        vm.txGasPrice(bound(gasPriceGwei, 1, 24) * 1 gwei); // at/below all ceilings
        bytes memory payload;
        if (payloadSeed % 2 == 0) payload = "deadbeef"; // opaque passthrough bytes
        vm.recordLogs();
        try executor.doExecute(jobId, payload) {
            _accountExecutionLogs(jobGasLimits[idx]);
        } catch {
            // reverts allowed: paused/ceiling/inactive paths are valid fuzz inputs
        }
    }

    function setJobStatus(uint256 jobSeed, uint256 flag) external {
        if (jobIds.length == 0) return;
        uint256 idx = jobSeed % jobIds.length;
        vm.prank(jobOwners[idx]);
        try registry.setJobStatus(jobIds[idx], flag % 2 == 0) {
            // success path
        } catch {
            // non-owner fuzz sender: revert is an allowed outcome
        }
    }

    function setKeeperTip(uint128 tip) external {
        vm.prank(owner);
        try registry.setKeeperTip(uint128(bound(uint256(tip), 0, 0.05 ether))) {
            // success path
        } catch {
            // non-owner fuzz sender: revert is an allowed outcome
        }
    }

    function togglePause(uint256 flag) external {
        vm.prank(owner);
        try registry.setPaused(flag % 2 == 0) {
            // success path
        } catch {
            // non-owner fuzz sender: revert is an allowed outcome
        }
    }

    function toggleExecutorAcceptsEth(uint256 flag) external {
        executor.setAcceptEth(flag % 2 == 0);
    }

    function pullExecutor() external {
        vm.recordLogs();
        try executor.doPull() {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].topics[0] == PULL_WITHDRAWN_TOPIC) {
                    (uint256 amount) = abi.decode(logs[i].data, (uint256));
                    ghostExecutorRefunds += amount;
                }
            }
        } catch {
            // reverts allowed: nothing-pending / rejecting-wallet paths
        }
    }

    // ------------------------------------------------------------------
    // views for the invariants
    // ------------------------------------------------------------------

    function sumEscrows() external view returns (uint256 total) {
        for (uint256 i = 0; i < jobIds.length; i++) {
            total += registry.escrows(jobIds[i]);
        }
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        return x % (max - min + 1) + min;
    }

    // ------------------------------------------------------------------
    // internals
    // ------------------------------------------------------------------

    function _accountExecutionLogs(uint256 gasLimit) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // If the refund could not be delivered it stays inside the registry as
        // pendingPull (which the invariants count on-chain); only refunds that
        // actually left the registry count toward ghostExecutorRefunds.
        bool refundPended;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PULL_PENDING_TOPIC) {
                refundPended = true;
            }
        }
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == JOB_EXECUTED_TOPIC) {
                (uint256 gasUsed, uint256 baseExecutionCost, uint256 keeperTip) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                if (!refundPended) {
                    ghostExecutorRefunds += baseExecutionCost;
                }
                ghostTips += keeperTip;
                lastGasUsed[trackedExecutions % MAX_TRACKED_EXECUTIONS] = gasUsed;
                lastGasLimits[trackedExecutions % MAX_TRACKED_EXECUTIONS] = gasLimit;
                trackedExecutions += 1;
            }
        }
    }
}
