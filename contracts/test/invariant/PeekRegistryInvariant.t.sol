// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "../../src/PeekRegistry.sol";
import {MockJob} from "../../src/mocks/MockJob.sol";
import {MockRevertingJob} from "../../src/mocks/MockRevertingJob.sol";
import {ToggledExecutor} from "../helpers/TestContracts.sol";
import {Handler} from "./Handler.sol";

/// @title Invariant campaign for PeekRegistry (SPEC-11, RULE-15).
/// @dev INV-1 registry solvency: registry balance == sum(escrows) + pendingPull.
///      INV-2 full conservation: deposits == escrows + pendingPull + premiums +
///          executor refunds + owner withdrawals (every wei event-accounted).
///      INV-3 gas bound: every executed gasUsed <= gasLimit + 2*OVERHEAD_BUFFER.
///      INV-4 treasury accrual == sum of emitted keeper tips (flat 0.005 AVAX default).
contract PeekRegistryInvariantTest is Test {
    PeekRegistry internal registry;
    ToggledExecutor internal executor;
    MockJob internal goodTarget;
    MockRevertingJob internal revertingTarget;
    Handler internal handler;

    address internal owner = makeAddr("owner");
    address payable internal treasury = payable(makeAddr("treasury"));
    address[4] internal users;
    // baselines captured post-setUp: the invariant fuzzer endows addresses it
    // uses as senders, so every value invariant is measured as a delta.
    uint256 internal treasuryBalance0;
    uint256 internal registryBalance0;

    function setUp() public {
        vm.prank(owner);
        registry = new PeekRegistry(owner, treasury, 35_000, 0);
        goodTarget = new MockJob(address(registry));
        revertingTarget = new MockRevertingJob();
        executor = new ToggledExecutor(registry);
        vm.prank(owner);
        registry.setExecutor(address(executor), true);

        for (uint256 i = 0; i < 4; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            vm.deal(users[i], 1 ether);
        }

        handler = new Handler(registry, executor, goodTarget, revertingTarget, owner, users);
        vm.deal(address(handler), 1 ether);

        targetContract(address(handler));
        // restrict fuzz senders to dedicated actors so the runner never endows
        // the treasury/registry addresses and breaks the baselines
        targetSender(makeAddr("fuzz-sender-1"));
        targetSender(makeAddr("fuzz-sender-2"));

        treasuryBalance0 = treasury.balance;
        registryBalance0 = address(registry).balance;
    }

    function invariant_RegistryBalanceSolvent() public view {
        assertEq(
            address(registry).balance - registryBalance0,
            handler.sumEscrows() + registry.pendingPull(address(executor)),
            "INV-1: registry balance must back escrows + pending pulls exactly"
        );
    }

    function invariant_FullConservation() public view {
        uint256 accounted = handler.sumEscrows() + registry.pendingPull(address(executor))
            + handler.ghostTips() + handler.ghostExecutorRefunds() + handler.ghostOwnerWithdrawn();
        assertEq(
            handler.ghostDeposits(),
            accounted,
            "INV-2: every deposited wei must be escrowed, pulled, paid out, or withdrawn"
        );
    }

    function invariant_GasUsedBoundedBySolvencyModel() public view {
        uint256 n = handler.trackedExecutions();
        if (n == 0) return;
        uint256 checked = n > 64 ? 64 : n;
        for (uint256 i = 0; i < checked; i++) {
            uint256 idx = (n - 1 - i) % 64;
            assertLe(
                handler.lastGasUsed(idx),
                handler.lastGasLimits(idx) + 2 * uint256(registry.OVERHEAD_BUFFER()),
                "INV-3: gasUsed must stay within gasLimit + 2*OVERHEAD_BUFFER"
            );
        }
    }

    function invariant_TreasuryMatchesEmittedPremiums() public view {
        assertEq(
            treasury.balance - treasuryBalance0,
            handler.ghostTips(),
            "INV-4: treasury accrual must equal the sum of emitted keeper tips"
        );
    }
}
