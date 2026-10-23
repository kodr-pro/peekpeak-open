// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAutoJob} from "../IAutoJob.sol";

/// @title MockRevertingJob - always reverts on-chain. Proves the registry never
///        charges the client nor pays the executor for failed work (RULE-4).
contract MockRevertingJob is IAutoJob {
    error AlwaysReverts();

    function checkJob() external pure returns (bool canExec, bytes memory) {
        return (true, "");
    }

    function performJob(bytes calldata) external pure {
        revert AlwaysReverts();
    }
}
