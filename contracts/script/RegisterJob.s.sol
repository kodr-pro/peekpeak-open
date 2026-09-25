// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PeekPeakScript} from "./PeekPeak.s.sol";
import {PeekRegistry} from "../src/PeekRegistry.sol";
import {MockJob} from "../src/mocks/MockJob.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Registers a job on a deployed PeekRegistry.
///         Env: DEPLOYER_KEY, REGISTRY, TARGET, GAS_LIMIT, MAX_GAS_PRICE_GWEI, DEPOSIT_WEI.
contract RegisterJob is PeekPeakScript {
    function run() external {
        PeekRegistry registry = PeekRegistry(vm.envAddress("REGISTRY"));
        address target = vm.envAddress("TARGET");
        uint32 gasLimit = uint32(vm.envUint("GAS_LIMIT"));
        uint64 ceiling = uint64(vm.envUint("MAX_GAS_PRICE_GWEI"));
        uint256 deposit = vm.envUint("DEPOSIT_WEI");

        _broadcast();
        bytes32 jobId = registry.registerJob{value: deposit}(target, gasLimit, ceiling);
        vm.stopBroadcast();

        console2.log("jobId:");
        console2.logBytes32(jobId);
    }
}

/// @notice Deploys MockJob (registry-wired) and registers it - the Fuji dry-run
///         path from SPEC-11. Env: DEPLOYER_KEY, REGISTRY, DEPOSIT_WEI (>= the
///         worst-case cost printed by the registry).
contract DeployMockJob is PeekPeakScript {
    function run() external {
        PeekRegistry registry = PeekRegistry(vm.envAddress("REGISTRY"));
        uint256 deposit = vm.envUint("DEPOSIT_WEI");

        _broadcast();
        MockJob job = new MockJob(address(registry));
        bytes32 jobId = registry.registerJob{value: deposit}(address(job), 500_000, 100);
        job.setReady(true);
        vm.stopBroadcast();

        _recordChainJson("MockJob", address(job));
        console2.log("jobId:");
        console2.logBytes32(jobId);
    }
}
