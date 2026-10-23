// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAutoJob} from "../src/IAutoJob.sol";

/// @notice Compile-proof fixture for the SKILL.md Foundry test template.
///         The three `test_*` bodies below are VERBATIM the template shipped
///         to integrators (agents/SKILL.md "Foundry test template"); MyKeeper
///         is the canonical implementation the template + /start funnel
///         teach. If either the template or the taught contract drifts and
///         stops compiling/passing here, the doc is lying - fix the doc.
///         (Remapping difference: the repo imports IAutoJob directly.)
contract MyKeeper is IAutoJob {
    address public immutable REGISTRY_ADDRESS;
    uint256 public nextRun = block.timestamp + 1 hours;
    uint256 public maintainCount;

    error NotRegistry();

    constructor(address registry) {
        REGISTRY_ADDRESS = registry;
    }

    function INTERVAL() external pure returns (uint256) {
        return 1 hours;
    }

    function checkJob() external view returns (bool, bytes memory) {
        return (block.timestamp >= nextRun, "");
    }

    function performJob(bytes calldata) external {
        if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
        if (block.timestamp < nextRun) return; // idempotent
        nextRun = block.timestamp + 1 hours; // effect first
        maintainCount++; // ...your maintenance call here...
    }
}

contract MyKeeperTest is Test {
    MyKeeper keeper;
    address registry = makeAddr("registry");

    function setUp() public {
        keeper = new MyKeeper(registry);
    }

    function test_CheckJobFlipsFalseToTrueWhenDue() public {
        (bool canExec,) = keeper.checkJob();
        assertFalse(canExec); // not due initially
        vm.warp(block.timestamp + keeper.INTERVAL());
        (canExec,) = keeper.checkJob();
        assertTrue(canExec); // due after the interval
    }

    function test_PerformJobFromMockRegistryExecutesAndResets() public {
        vm.warp(block.timestamp + keeper.INTERVAL());
        vm.prank(registry);
        keeper.performJob("");
        assertEq(keeper.maintainCount(), 1); // target maintenance ran
        (bool canExec,) = keeper.checkJob();
        assertFalse(canExec); // reset to false for next block
    }

    function test_PerformJobRevertsForNonRegistry() public {
        vm.expectRevert(MyKeeper.NotRegistry.selector);
        keeper.performJob("");
    }
}
