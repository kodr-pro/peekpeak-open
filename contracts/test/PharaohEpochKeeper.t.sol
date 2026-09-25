// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PharaohEpochKeeper} from "../src/adapters/PharaohEpochKeeper.sol";
import {FailingGauge, FailingVoter, MockGauge, MockVoter} from "./helpers/TestContracts.sol";

contract PharaohEpochKeeperTest is Test {
    address internal registry = makeAddr("registry");
    address internal attacker = makeAddr("attacker");
    uint256 internal firstEpoch = 1_700_000_000;

    MockVoter internal voter;
    MockGauge internal gauge;
    PharaohEpochKeeper internal keeper;

    function setUp() public {
        voter = new MockVoter();
        gauge = new MockGauge();
        keeper = new PharaohEpochKeeper(registry, address(voter), address(gauge), firstEpoch);
    }

    function test_CheckJob_BeforeAndAfterEpoch() public {
        (bool canExec,) = keeper.checkJob();
        vm.warp(firstEpoch - 1);
        (canExec,) = keeper.checkJob();
        assertFalse(canExec);
        vm.warp(firstEpoch);
        (canExec,) = keeper.checkJob();
        assertTrue(canExec);
        vm.warp(firstEpoch + 1 weeks - 1);
        (canExec,) = keeper.checkJob();
        assertTrue(canExec);
    }

    function test_PerformJob_RollsEpochAndCallsLegs() public {
        vm.warp(firstEpoch);
        vm.prank(registry);
        keeper.performJob("");
        assertEq(voter.distributeCount(), 1);
        assertEq(gauge.harvestCount(), 1);
        assertEq(keeper.nextEpochTimestamp(), firstEpoch + 1 weeks);
        (bool canExec,) = keeper.checkJob();
        assertFalse(canExec); // false on the very next block (RULE-12)
    }

    function test_PerformJob_Reverts_NotRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(PharaohEpochKeeper.NotRegistry.selector);
        keeper.performJob("");
    }

    function test_PerformJob_IdempotentWithinEpoch() public {
        vm.warp(firstEpoch);
        vm.prank(registry);
        keeper.performJob("");
        vm.prank(registry);
        keeper.performJob(""); // quiet no-op
        assertEq(voter.distributeCount(), 1);
        assertEq(gauge.harvestCount(), 1);
    }

    function test_PerformJob_VoterOnlyAndGaugeOnlyConfigs() public {
        PharaohEpochKeeper voterOnly = new PharaohEpochKeeper(registry, address(voter), address(0), firstEpoch);
        PharaohEpochKeeper gaugeOnly = new PharaohEpochKeeper(registry, address(0), address(gauge), firstEpoch);
        vm.warp(firstEpoch);
        vm.startPrank(registry);
        voterOnly.performJob("");
        gaugeOnly.performJob("");
        vm.stopPrank();
        assertEq(voter.distributeCount(), 1); // only voterOnly's call in this test
        assertEq(gauge.harvestCount(), 1);
        assertTrue(address(voterOnly.voter()) == address(voter) && address(voterOnly.gauge()) == address(0));
    }

    function test_PerformJob_FailingLegDoesNotRollBackEpoch() public {
        FailingVoter failingVoter = new FailingVoter();
        FailingGauge failingGauge = new FailingGauge();
        PharaohEpochKeeper broken = new PharaohEpochKeeper(registry, address(failingVoter), address(failingGauge), firstEpoch);
        vm.warp(firstEpoch);
        vm.prank(registry);
        vm.expectEmit(false, false, false, true, address(broken));
        emit EpochRolled(firstEpoch + 1 weeks, false, false);
        broken.performJob("");
        assertEq(broken.nextEpochTimestamp(), firstEpoch + 1 weeks); // advanced despite failing legs
        (bool canExec,) = broken.checkJob();
        assertFalse(canExec); // no retry storm: epoch stays rolled
    }

    event EpochRolled(uint256 newEpochTimestamp, bool voterOk, bool gaugeOk);
}
