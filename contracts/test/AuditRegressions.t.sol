// SPDX-License-Identifier: MIT
// Audit: AUDIT-REPORT.md findings F-1, F-2, F-4 regression tests
// ( PeekPeak-audit handoff package ). Each test fails on the pre-fix code.
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "../src/PeekRegistry.sol";

/// @dev F-1: target that tops up its own escrow DURING performJob. Pre-fix,
///      the success path wrote the stale pre-call escrow snapshot back and
///      erased the mid-call deposit (conservation invariant broken).
contract SelfDepositingJob {
    PeekRegistry public registry;
    bytes32 public ownJobId;
    uint256 public performCount;

    constructor(PeekRegistry r) payable {
        registry = r;
    }

    function setJobId(bytes32 id) external {
        ownJobId = id;
    }

    function checkJob() external view returns (bool, bytes memory) {
        return (true, "");
    }

    function performJob(bytes calldata) external {
        performCount += 1;
        registry.depositGas{value: 0.5 ether}(ownJobId); // mid-execution top-up
    }

    receive() external payable {}
}

/// @dev F-2: minimal honest target; used with oversized payloads.
contract CheapJob {
    uint256 public performCount;

    function checkJob() external view returns (bool, bytes memory) {
        return (true, "");
    }

    function performJob(bytes calldata) external {
        performCount += 1;
    }
}

contract AuditRegressionsTest is Test {
    uint32 internal constant BUFFER = 35_000;
    uint256 internal constant GAS_PRICE = 25 gwei;

    PeekRegistry internal registry;
    address internal owner = makeAddr("owner");
    address payable internal treasury = payable(makeAddr("treasury"));
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner);
        registry = new PeekRegistry(owner, treasury, BUFFER, 0);
        vm.prank(owner);
        registry.setExecutor(executor, true);
        vm.deal(alice, 10 ether);
        vm.txGasPrice(GAS_PRICE);
    }

    function _worstCase(uint32 gasLimit) internal view returns (uint256) {
        return (uint256(gasLimit) + 2 * uint256(BUFFER)) * GAS_PRICE + registry.keeperTip();
    }

    function _isActive(bytes32 jobId) internal view returns (bool) {
        (,, bool active,,,) = registry.jobs(jobId);
        return active;
    }

    // ------------------------------------------------------------------
    // F-1: concurrent depositGas during performJob must survive
    // ------------------------------------------------------------------

    function test_F1_MidCallDepositSurvivesExecution() public {
        SelfDepositingJob target = new SelfDepositingJob(registry);
        vm.deal(address(target), 1 ether);

        bytes32 jobId = keccak256(abi.encode(address(target), alice, registry.jobNonce()));
        vm.prank(alice);
        registry.registerJob{value: 1 ether}(address(target), 500_000, 100);
        target.setJobId(jobId);

        vm.prank(executor);
        registry.executeJob(jobId, "");

        assertEq(target.performCount(), 1);

        uint256 escrowAfter = registry.escrows(jobId);
        uint256 accounted = escrowAfter + registry.pendingPull(executor);

        // Conservation holds exactly: every wei the registry holds is
        // accounted for by escrows + pendingPull. Pre-fix, the registry held
        // exactly 0.5 ether more than accounted (the erased deposit).
        assertEq(
            address(registry).balance,
            accounted,
            "INV-1: registry balance must back escrows + pending pulls exactly"
        );

        // The deduction was taken from the CURRENT escrow (1.5 ether), not
        // the stale 1 ether snapshot.
        uint256 baseCost = executor.balance; // executor started funded at 0
        uint256 tip = treasury.balance;
        assertEq(escrowAfter, 1.5 ether - (baseCost + tip));
    }

    // ------------------------------------------------------------------
    // F-2: execPayload size bound (DIV-D-4)
    // ------------------------------------------------------------------

    function test_F2_OversizedPayloadRevertsPreDispatch() public {
        CheapJob target = new CheapJob();

        uint32 gasLimit = 60_000;
        uint256 required = _worstCase(gasLimit);
        bytes32 jobId = keccak256(abi.encode(address(target), alice, registry.jobNonce()));
        vm.prank(alice);
        registry.registerJob{value: required}(address(target), gasLimit, 100);

        // the original PoC shape: 200 KB payload
        bytes memory payload = new bytes(200_000);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = 0x01;
        }

        vm.prank(executor);
        vm.expectRevert(PeekRegistry.PayloadTooLarge.selector);
        registry.executeJob(jobId, payload);

        // nothing happened: no dispatch, no charge, no deactivation
        assertEq(target.performCount(), 0);
        assertEq(registry.escrows(jobId), required);
        assertTrue(_isActive(jobId));
    }

    function test_F2_ExactlyOneByteOverCapReverts() public {
        CheapJob target = new CheapJob();
        bytes32 jobId = keccak256(abi.encode(address(target), alice, registry.jobNonce()));
        vm.prank(alice);
        registry.registerJob{value: 1 ether}(address(target), 500_000, 100);

        bytes memory payload = new bytes(registry.MAX_EXEC_PAYLOAD() + 1);
        vm.prank(executor);
        vm.expectRevert(PeekRegistry.PayloadTooLarge.selector);
        registry.executeJob(jobId, payload);
    }

    function test_F2_PayloadAtCapExecutesAndStaysSolvent() public {
        CheapJob target = new CheapJob();

        uint32 gasLimit = 60_000;
        uint256 required = _worstCase(gasLimit);
        bytes32 jobId = keccak256(abi.encode(address(target), alice, registry.jobNonce()));
        vm.prank(alice);
        registry.registerJob{value: required}(address(target), gasLimit, 100);

        // payload at the cap: executes, charges within the prechecked bound,
        // and does NOT hit the defensive shortfall branch (job stays active)
        bytes memory payload = new bytes(registry.MAX_EXEC_PAYLOAD());
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = 0x01;
        }

        vm.prank(executor);
        registry.executeJob(jobId, payload);

        assertEq(target.performCount(), 1, "target executed");
        assertLt(registry.escrows(jobId), required, "escrow charged");
        assertTrue(_isActive(jobId), "no defensive-branch deactivation");
        assertGt(executor.balance, 0, "executor reimbursed");
        assertEq(treasury.balance, registry.keeperTip(), "tip paid");
    }

    // ------------------------------------------------------------------
    // F-4: OVERHEAD_BUFFER upper bound
    // ------------------------------------------------------------------

    function test_F4_Constructor_Reverts_BufferAboveBound() public {
        uint32 tooBig = registry.MAX_OVERHEAD_BUFFER() + 1;
        vm.prank(owner);
        vm.expectRevert(PeekRegistry.InvalidOverheadBuffer.selector);
        new PeekRegistry(owner, treasury, tooBig, 0);
    }

    function test_F4_Constructor_AcceptsBoundaryBuffer() public {
        vm.prank(owner);
        PeekRegistry r = new PeekRegistry(owner, treasury, registry.MAX_OVERHEAD_BUFFER(), 0);
        assertEq(r.OVERHEAD_BUFFER(), registry.MAX_OVERHEAD_BUFFER());
    }
}
