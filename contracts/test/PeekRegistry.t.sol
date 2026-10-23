// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {PeekRegistry} from "../src/PeekRegistry.sol";
import {IAutoJob} from "../src/IAutoJob.sol";
import {MockJob} from "../src/mocks/MockJob.sol";
import {MockRevertingJob} from "../src/mocks/MockRevertingJob.sol";
import {PharaohEpochKeeper} from "../src/adapters/PharaohEpochKeeper.sol";
import {AttackerJob, ReentrantWithdrawer, ToggledExecutor} from "./helpers/TestContracts.sol";

contract PeekRegistryTest is Test {
    uint32 internal constant BUFFER = 35_000;
    uint256 internal constant GAS_PRICE = 25 gwei;
    uint32 internal constant GAS_LIMIT = 500_000;
    uint64 internal constant CEILING_GWEI = 100;

    PeekRegistry internal registry;
    MockJob internal job;
    MockRevertingJob internal revertingJob;

    address internal owner = makeAddr("owner");
    address payable internal treasury = payable(makeAddr("treasury"));
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(owner);
        registry = new PeekRegistry(owner, treasury, BUFFER, 0);
        vm.prank(owner);
        registry.setExecutor(executor, true);
        job = new MockJob(address(registry));
        revertingJob = new MockRevertingJob();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.txGasPrice(GAS_PRICE);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _worstCase(uint32 gasLimit) internal view returns (uint256) {
        return (uint256(gasLimit) + 2 * uint256(BUFFER)) * GAS_PRICE + registry.keeperTip();
    }

    function _register() internal returns (bytes32 jobId) {
        return _register(alice, address(job), GAS_LIMIT, CEILING_GWEI);
    }

    function _register(address who, address target, uint32 gasLimit, uint64 ceiling)
        internal
        returns (bytes32 jobId)
    {
        jobId = keccak256(abi.encode(target, who, registry.jobNonce()));
        vm.prank(who);
        registry.registerJob{value: 1 ether}(target, gasLimit, ceiling);
    }

    function _job(bytes32 jobId) internal view returns (PeekRegistry.Job memory j) {
        (j.target, j.gasLimit, j.isActive, j.consecutiveReverts, j.owner, j.maxGasPriceGwei) =
            registry.jobs(jobId);
    }

    // ------------------------------------------------------------------
    // constructor
    // ------------------------------------------------------------------

    function test_Constructor_SetsDefaults() public view {
        assertEq(registry.keeperTip(), 0.005 ether);
        assertEq(registry.maxConsecutiveReverts(), 3);
        assertEq(registry.OVERHEAD_BUFFER(), BUFFER);
        assertEq(address(registry.treasury()), treasury);
        assertEq(registry.owner(), owner);
        assertFalse(registry.paused());
    }

    function test_Constructor_Reverts_ZeroTreasury() public {
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.InvalidTreasury.selector);
        new PeekRegistry(owner, payable(address(0)), BUFFER, 0);
    }

    function test_Constructor_Reverts_LowOverheadBuffer() public {
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.InvalidOverheadBuffer.selector);
        new PeekRegistry(owner, treasury, 10_000 - 1, 0);
    }

    function test_Constructor_Reverts_ZeroOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new PeekRegistry(address(0), treasury, BUFFER, 0);
    }

    function test_Constructor_CustomNativeTip() public {
        // an L1 whose native token has a different unit value deploys with its
        // own denomination; 0 falls back to the chain default
        vm.prank(owner);
        PeekRegistry custom = new PeekRegistry(owner, treasury, BUFFER, 0.02 ether);
        assertEq(custom.keeperTip(), 0.02 ether);
        PeekRegistry def = new PeekRegistry(owner, treasury, BUFFER, 0);
        assertEq(def.keeperTip(), 0.005 ether);
    }

    function test_Constructor_Reverts_TipAboveBound() public {
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.TipOutOfBounds.selector);
        new PeekRegistry(owner, treasury, BUFFER, 0.05 ether + 1);
    }

    // ------------------------------------------------------------------
    // registerJob
    // ------------------------------------------------------------------

    function test_RegisterJob_HappyPath() public {
        bytes32 expectedId = keccak256(abi.encode(address(job), alice, 0));
        vm.expectEmit(true, true, true, true, address(registry));
        emit PeekRegistry.JobRegistered(
            expectedId, address(job), alice, GAS_LIMIT, CEILING_GWEI, 1 ether
        );
        vm.prank(alice);
        bytes32 jobId = registry.registerJob{value: 1 ether}(address(job), GAS_LIMIT, CEILING_GWEI);

        assertEq(jobId, expectedId);
        PeekRegistry.Job memory stored = _job(jobId);
        assertEq(stored.target, address(job));
        assertEq(stored.owner, alice);
        assertEq(stored.gasLimit, GAS_LIMIT);
        assertEq(stored.maxGasPriceGwei, CEILING_GWEI);
        assertTrue(stored.isActive);
        assertEq(stored.consecutiveReverts, 0);
        assertEq(registry.escrows(jobId), 1 ether);
        assertEq(registry.jobNonce(), 1);
    }

    function test_RegisterJob_UniqueIdsForSameTarget() public {
        bytes32 id1 = _register();
        bytes32 id2 = _register();
        assertFalse(id1 == id2);
        PeekRegistry.Job memory a = _job(id1);
        PeekRegistry.Job memory b = _job(id2);
        assertTrue(a.target == b.target && a.owner == b.owner);
    }

    function test_RegisterJob_AcceptsExactMinimum() public {
        uint256 min = _worstCase(GAS_LIMIT);
        vm.prank(alice);
        registry.registerJob{value: min}(address(job), GAS_LIMIT, CEILING_GWEI);
    }

    function test_RegisterJob_Reverts_InsufficientDeposit() public {
        uint256 min = _worstCase(GAS_LIMIT);
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.InsufficientEscrowDeposit.selector);
        registry.registerJob{value: min - 1}(address(job), GAS_LIMIT, CEILING_GWEI);
    }

    function test_RegisterJob_Reverts_ZeroTarget() public {
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.InvalidTarget.selector);
        registry.registerJob{value: 1 ether}(address(0), GAS_LIMIT, CEILING_GWEI);
    }

    function test_RegisterJob_Reverts_GasLimitBounds() public {
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.GasLimitOutOfBounds.selector);
        registry.registerJob{value: 1 ether}(address(job), 0, CEILING_GWEI);
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.GasLimitOutOfBounds.selector);
        registry.registerJob{value: 1 ether}(address(job), 2_500_001, CEILING_GWEI);
    }

    function test_RegisterJob_Reverts_CeilingTooLow() public {
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.GasPriceCeilingTooLow.selector);
        registry.registerJob{value: 1 ether}(address(job), GAS_LIMIT, 24);
    }

    function test_RegisterJob_Reverts_WhenPaused() public {
        vm.prank(owner);
        registry.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.Paused.selector);
        registry.registerJob{value: 1 ether}(address(job), GAS_LIMIT, CEILING_GWEI);
    }

    function test_RegisterJob_Reverts_EscrowOverflow() public {
        uint128 huge = type(uint128).max;
        vm.deal(alice, uint256(huge) + 1);
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.EscrowOverflow.selector);
        registry.registerJob{value: uint256(huge) + 1}(address(job), GAS_LIMIT, CEILING_GWEI);
    }

    // ------------------------------------------------------------------
    // depositGas / withdrawGas / setJobStatus
    // ------------------------------------------------------------------

    function test_DepositGas_IncreasesEscrow() public {
        bytes32 jobId = _register();
        vm.expectEmit(true, false, false, true, address(registry));
        emit PeekRegistry.GasDeposited(jobId, 0.5 ether, 1.5 ether);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        registry.depositGas{value: 0.5 ether}(jobId);
        assertEq(registry.escrows(jobId), 1.5 ether);
    }

    function test_DepositGas_Reverts_UnknownJob() public {
        vm.expectRevert(PeekRegistry.JobNotFound.selector);
        registry.depositGas{value: 1 ether}(bytes32("nope"));
    }

    function test_DepositGas_Reverts_ZeroDeposit() public {
        bytes32 jobId = _register();
        vm.expectRevert(PeekRegistry.ZeroDeposit.selector);
        registry.depositGas(jobId);
    }

    function test_WithdrawGas_PaysOwnerAndReducesEscrow() public {
        bytes32 jobId = _register();
        uint256 before = alice.balance;
        vm.prank(alice);
        registry.withdrawGas(jobId, 0.4 ether);
        assertEq(alice.balance, before + 0.4 ether);
        assertEq(registry.escrows(jobId), 0.6 ether);
    }

    function test_WithdrawGas_Reverts_NotOwner() public {
        bytes32 jobId = _register();
        vm.prank(bob);
        vm.expectRevert(PeekRegistry.NotJobOwner.selector);
        registry.withdrawGas(jobId, 0.1 ether);
    }

    function test_WithdrawGas_Reverts_UnknownJob() public {
        vm.expectRevert(PeekRegistry.JobNotFound.selector);
        registry.withdrawGas(bytes32("nope"), 0.1 ether);
    }

    function test_WithdrawGas_Reverts_InsufficientEscrow() public {
        bytes32 jobId = _register();
        vm.prank(alice);
        vm.expectRevert(PeekRegistry.InsufficientEscrow.selector);
        registry.withdrawGas(jobId, 1 ether + 1);
    }

    function test_WithdrawGas_Reverts_WhenReceiverRejectsEth() public {
        ToggledExecutor rejecting = new ToggledExecutor(registry);
        rejecting.setAcceptEth(false);
        vm.deal(address(rejecting), 2 ether);
        vm.prank(address(rejecting));
        bytes32 jobId = keccak256(abi.encode(address(job), address(rejecting), registry.jobNonce()));
        vm.prank(address(rejecting));
        registry.registerJob{value: 1 ether}(address(job), GAS_LIMIT, CEILING_GWEI);
        uint128 bal = registry.escrows(jobId);

        vm.prank(address(rejecting));
        vm.expectRevert(PeekRegistry.TransferFailed.selector);
        registry.withdrawGas(jobId, 0.1 ether);

        assertEq(registry.escrows(jobId), bal); // rolled back
    }

    function test_WithdrawGas_ReentrantAttemptGetsNothing() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(registry);
        MockJob ownedJob = new MockJob(address(registry));
        vm.deal(address(attacker), 2 ether);
        bytes32 jobId = keccak256(abi.encode(address(ownedJob), address(attacker), registry.jobNonce()));
        vm.prank(address(attacker));
        registry.registerJob{value: 1 ether}(address(ownedJob), GAS_LIMIT, CEILING_GWEI);

        uint128 bal = registry.escrows(jobId);
        uint128 amt = 0.1 ether;
        attacker.attack(jobId, amt);

        // withdrawal completed exactly once despite the caught reentry attempt
        assertTrue(attacker.attacked());
        assertEq(registry.escrows(jobId), bal - amt);
        assertEq(address(attacker).balance, 1 ether + amt); // 2 ether - 1 ether registration + amt
    }

    function test_SetJobStatus_Toggles() public {
        bytes32 jobId = _register();
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(registry));
        emit PeekRegistry.JobStatusSet(jobId, false);
        registry.setJobStatus(jobId, false);
        assertFalse(_job(jobId).isActive);
        vm.prank(alice);
        registry.setJobStatus(jobId, true);
        assertTrue(_job(jobId).isActive);
    }

    function test_SetJobStatus_Reverts_NotOwner() public {
        bytes32 jobId = _register();
        vm.prank(bob);
        vm.expectRevert(PeekRegistry.NotJobOwner.selector);
        registry.setJobStatus(jobId, false);
    }

    function test_SetJobStatus_Reverts_UnknownJob() public {
        vm.expectRevert(PeekRegistry.JobNotFound.selector);
        registry.setJobStatus(bytes32("nope"), false);
    }

    // ------------------------------------------------------------------
    // executeJob - happy path & accounting
    // ------------------------------------------------------------------

    function test_ExecuteJob_HappyPathAccounting() public {
        bytes32 jobId = _register();
        job.setReady(true);
        uint256 executorBefore = executor.balance;
        uint256 treasuryBefore = treasury.balance;

        PeekRegistry.Job memory j = _job(jobId);
        vm.prank(executor);
        registry.executeJob(jobId, hex"deadbeef");

        // decode accounting from the balance deltas + escrow
        uint256 escrowBefore = 1 ether;
        uint256 escrowAfter = registry.escrows(jobId);
        uint256 totalDeduction = escrowBefore - escrowAfter;
        uint256 baseCost = executor.balance - executorBefore;
        uint256 premium = treasury.balance - treasuryBefore;

        assertEq(baseCost + premium, totalDeduction);
        assertEq(premium, 0.005 ether); // exact flat keeper tip (SPEC-11, DIV-D-3)
        assertGt(baseCost, 0);
        assertFalse(job.ready()); // checkJob false next block
        assertEq(job.performCount(), 1);
        assertEq(job.lastPayload(), hex"deadbeef"); // payload passed through
        assertEq(_job(jobId).consecutiveReverts, 0);
    }

    function test_ExecuteJob_EmitsJobExecuted() public {
        bytes32 jobId = _register();
        job.setReady(true);
        vm.recordLogs();
        vm.prank(executor);
        registry.executeJob(jobId, hex"deadbeef");
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("JobExecuted(bytes32,address,uint256,uint256,uint256)")) {
                (uint256 gasUsed, uint256 baseCost,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(logs[i].topics[1], bytes32(jobId));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), executor);
                // gasUsed = internal consumption + BUFFER; structurally bounded by
                // the solvency precondition gasLimit + 2*BUFFER (SPEC-5).
                assertGe(gasUsed, BUFFER + 50_000);
                assertLe(gasUsed, uint256(GAS_LIMIT) + 2 * uint256(BUFFER));
                assertEq(baseCost, gasUsed * GAS_PRICE);
                found = true;
            }
        }
        assertTrue(found);
    }

    function test_ExecuteJob_TipChangeApplies() public {
        vm.prank(owner);
        registry.setKeeperTip(0.002 ether);
        bytes32 jobId = _register();
        job.setReady(true);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(executor);
        registry.executeJob(jobId, hex"deadbeef");
        assertEq(treasury.balance - treasuryBefore, 0.002 ether); // exact adjusted tip
    }

    // ------------------------------------------------------------------
    // executeJob - access & precondition reverts
    // ------------------------------------------------------------------

    function test_ExecuteJob_Reverts_UnauthorizedExecutor() public {
        bytes32 jobId = _register();
        vm.prank(bob);
        vm.expectRevert(PeekRegistry.UnauthorizedExecutor.selector);
        registry.executeJob(jobId, "");
    }

    function test_ExecuteJob_Reverts_UnknownJob() public {
        vm.prank(executor);
        vm.expectRevert(PeekRegistry.JobNotFound.selector);
        registry.executeJob(bytes32("nope"), "");
    }

    function test_ExecuteJob_Reverts_InactiveJob() public {
        bytes32 jobId = _register();
        vm.prank(alice);
        registry.setJobStatus(jobId, false);
        vm.prank(executor);
        vm.expectRevert(PeekRegistry.JobInactive.selector);
        registry.executeJob(jobId, "");
    }

    function test_ExecuteJob_Reverts_GasPriceAboveCeiling() public {
        bytes32 jobId = _register();
        vm.txGasPrice((CEILING_GWEI + 1) * 1 gwei);
        vm.prank(executor);
        vm.expectRevert(PeekRegistry.GasPriceExceedsJobCeiling.selector);
        registry.executeJob(jobId, "");
    }

    function test_ExecuteJob_Reverts_WhenPaused() public {
        bytes32 jobId = _register();
        vm.prank(owner);
        registry.setPaused(true);
        vm.prank(executor);
        vm.expectRevert(PeekRegistry.Paused.selector);
        registry.executeJob(jobId, "");
    }

    // ------------------------------------------------------------------
    // executeJob - soft-exit paths (DIV-D-1): protective state persists
    // ------------------------------------------------------------------

    function test_ExecuteJob_DepletedJobSoftExitsAndDeactivates() public {
        bytes32 jobId = _register();
        uint256 required = _worstCase(GAS_LIMIT);
        vm.prank(alice);
        registry.withdrawGas(jobId, uint128(1 ether - required + 1)); // just under
        uint256 escrow = registry.escrows(jobId);

        vm.prank(executor);
        registry.executeJob(jobId, ""); // no revert

        assertFalse(_job(jobId).isActive);
        assertEq(registry.escrows(jobId), escrow); // client not charged
        assertEq(job.performCount(), 0); // target not called
        assertEq(executor.balance, 0); // executor not paid
        assertEq(treasury.balance, 0);
    }

    function test_ExecuteJob_RevertingTargetNeverChargesAnyone() public {
        bytes32 jobId = _register(alice, address(revertingJob), GAS_LIMIT, CEILING_GWEI);
        uint256 escrow = registry.escrows(jobId);

        vm.prank(executor);
        registry.executeJob(jobId, "");

        assertEq(registry.escrows(jobId), escrow);
        assertEq(_job(jobId).consecutiveReverts, 1);
        assertTrue(_job(jobId).isActive);
        assertEq(executor.balance, 0);
        assertEq(treasury.balance, 0);
    }

    function test_ExecuteJob_ConsecutiveRevertsDeactivateJob() public {
        bytes32 jobId = _register(alice, address(revertingJob), GAS_LIMIT, CEILING_GWEI);
        for (uint256 i = 1; i <= 3; i++) {
            vm.prank(executor);
            registry.executeJob(jobId, "");
            assertEq(_job(jobId).consecutiveReverts, i);
        }
        // deactivation triggers exactly when the counter reaches the max (3)
        assertFalse(_job(jobId).isActive);
        vm.prank(executor);
        vm.expectRevert(PeekRegistry.JobInactive.selector);
        registry.executeJob(jobId, "");
    }

    function test_ExecuteJob_SuccessResetsRevertCounter() public {
        bytes32 revId = _register(alice, address(revertingJob), GAS_LIMIT, CEILING_GWEI);
        bytes32 okId = _register(alice, address(job), GAS_LIMIT, CEILING_GWEI);
        vm.prank(executor);
        registry.executeJob(revId, "");
        vm.prank(executor);
        registry.executeJob(revId, "");
        job.setReady(true);
        vm.prank(executor);
        registry.executeJob(okId, "");
        assertEq(_job(revId).consecutiveReverts, 2); // untouched by other job's success
        assertEq(_job(okId).consecutiveReverts, 0);
    }

    function test_ExecuteJob_GasLimitCapsTargetConsumption() public {
        // target wants to burn more gas than the job's gasLimit allows
        bytes32 jobId = _register(alice, address(job), 100_000, CEILING_GWEI);
        job.setReady(true);
        job.setGasToBurn(400_000);
        vm.prank(executor);
        registry.executeJob(jobId, "");
        // inner call ran out of gas -> counted as a revert, nobody charged
        assertEq(_job(jobId).consecutiveReverts, 1);
        assertEq(registry.escrows(jobId), 1 ether);
    }

    // ------------------------------------------------------------------
    // executeJob - reentrancy & pull fallback
    // ------------------------------------------------------------------

    function test_ExecuteJob_ReentrancyNeutralized() public {
        _reentrantSetup(0);
    }

    function _reentrantSetup(uint8 mode) internal returns (address attackerAddr) {
        AttackerJob attacker = new AttackerJob(registry);
        vm.prank(owner);
        registry.setExecutor(executor, true);
        bytes32 jobId = _register(alice, address(attacker), GAS_LIMIT, CEILING_GWEI);
        attacker.configure(jobId, mode);
        uint256 escrow = registry.escrows(jobId);

        vm.prank(executor);
        registry.executeJob(jobId, "");

        // The attacker's own frame reverts with the guard, so even its state
        // changes (attackCount) roll back - proof the reentry fully failed.
        assertEq(attacker.attackCount(), 0);
        assertEq(registry.escrows(jobId), escrow); // untouched
        assertEq(_job(jobId).consecutiveReverts, 1); // reentry counted as target failure
        attackerAddr = address(attacker);
    }

    function test_ExecuteJob_WithdrawReentryNeutralized() public {
        _reentrantSetup(1);
    }

    function test_ExecuteJob_PullReentryNeutralized() public {
        _reentrantSetup(2);
    }

    function test_ExecuteJob_FailedRefundGoesToPendingPull() public {
        ToggledExecutor rejecting = new ToggledExecutor(registry);
        vm.prank(owner);
        registry.setExecutor(address(rejecting), true);
        rejecting.setAcceptEth(false);

        bytes32 jobId = _register();
        job.setReady(true);
        uint256 registryBefore = address(registry).balance;
        uint256 treasuryBefore = treasury.balance;

        assertTrue(rejecting.doExecute(jobId, hex"deadbeef")); // execution still succeeds

        uint256 refund = registry.pendingPull(address(rejecting));
        uint256 premium = treasury.balance - treasuryBefore;
        assertGt(refund, 0);
        assertGt(premium, 0);
        assertLt(registry.escrows(jobId), 1 ether); // escrow charged in full
        assertEq(address(registry).balance, registryBefore - premium); // refund retained

        rejecting.setAcceptEth(true);
        assertTrue(rejecting.doPull());
        assertEq(address(rejecting).balance, refund);
        assertEq(registry.pendingPull(address(rejecting)), 0);
    }

    function test_Pull_Reverts_NothingPending() public {
        vm.expectRevert(PeekRegistry.NothingToPull.selector);
        registry.pull();
    }

    // ------------------------------------------------------------------
    // native-coin hygiene
    // ------------------------------------------------------------------

    function test_DirectEthTransferReverts() public {
        (bool ok,) = address(registry).call{value: 1 ether}("");
        assertFalse(ok); // no receive()/fallback: conservation is not breakable
    }

    // ------------------------------------------------------------------
    // admin
    // ------------------------------------------------------------------

    function test_SetTreasury() public {
        address payable t = payable(makeAddr("t2"));
        vm.prank(owner);
        registry.setTreasury(t);
        assertEq(address(registry.treasury()), t);
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.InvalidTreasury.selector);
        registry.setTreasury(payable(address(0)));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        registry.setTreasury(t);
    }

    function test_SetExecutor() public {
        vm.prank(owner);
        registry.setExecutor(bob, true);
        assertTrue(registry.authorizedExecutors(bob));
        vm.prank(owner);
        registry.setExecutor(bob, false);
        assertFalse(registry.authorizedExecutors(bob));
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.InvalidTarget.selector);
        registry.setExecutor(address(0), true);
    }

    function test_SetKeeperTip_Bounds() public {
        vm.prank(owner);
        registry.setKeeperTip(0);
        assertEq(registry.keeperTip(), 0);
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.TipOutOfBounds.selector);
        registry.setKeeperTip(0.05 ether + 1);
    }

    function test_SetMaxConsecutiveReverts() public {
        vm.prank(owner);
        registry.setMaxConsecutiveReverts(1);
        assertEq(registry.maxConsecutiveReverts(), 1);
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.RevertLimitOutOfBounds.selector);
        registry.setMaxConsecutiveReverts(0);
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.RevertLimitOutOfBounds.selector);
        registry.setMaxConsecutiveReverts(11);
    }

    function test_SetMaxConsecutiveReverts_AppliesImmediately() public {
        vm.prank(owner);
        registry.setMaxConsecutiveReverts(1);
        bytes32 jobId = _register(alice, address(revertingJob), GAS_LIMIT, CEILING_GWEI);
        vm.prank(executor);
        registry.executeJob(jobId, "");
        assertFalse(_job(jobId).isActive); // deactivated after a single revert
    }
}
