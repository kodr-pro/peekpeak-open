// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAutoJob} from "../IAutoJob.sol";

/// @notice Minimal interface surface PeekPeak needs from a Solidly-fork voter.
interface IPharaohVoter {
    function distribute() external;
}

/// @notice Minimal interface surface PeekPeak needs from a Solidly-fork gauge.
interface IPharaohGauge {
    function harvest() external;
}

/// @title PharaohEpochKeeper - reference `IAutoJob` adapter for Pharaoh DEX (phar.gg).
/// @notice Rolls ve(3,3) gauge epochs: calls `voter.distribute()` and/or
///         `gauge.harvest()` once per epoch (SPEC-8). Deploy one keeper per
///         vault/gauge; PeekPeak funds it via the registry escrow.
/// @dev `performJob` is restricted to the immutable `REGISTRY_ADDRESS`. The
///      `nextEpochTimestamp` state advances BEFORE external calls (RULE-1), so a
///      mid-call revert cannot cause double-distribution on retry within the same
///      epoch - `checkJob` is already false for the block after any successful poke.
contract PharaohEpochKeeper is IAutoJob {
    uint256 public constant EPOCH = 1 weeks;

    address public immutable REGISTRY_ADDRESS;
    IPharaohVoter public immutable voter;
    IPharaohGauge public immutable gauge;
    uint256 public nextEpochTimestamp;

    event EpochRolled(uint256 newEpochTimestamp, bool voterOk, bool gaugeOk);

    error NotRegistry();

    /// @param registry Address of the deployed PeekRegistry that may call performJob.
    /// @param _voter Pharaoh voter (may be address(0) if only harvesting).
    /// @param _gauge Pharaoh gauge (may be address(0) if only distributing).
    /// @param firstEpochTimestamp Unix time of the first epoch rollover to perform.
    constructor(address registry, address _voter, address _gauge, uint256 firstEpochTimestamp) {
        REGISTRY_ADDRESS = registry;
        voter = IPharaohVoter(_voter);
        gauge = IPharaohGauge(_gauge);
        nextEpochTimestamp = firstEpochTimestamp;
    }

    /// @notice Ready when the current epoch has elapsed.
    function checkJob() external view returns (bool canExec, bytes memory) {
        return (block.timestamp >= nextEpochTimestamp, "");
    }

    /// @notice Distribute/harvest and roll the epoch. Only the registry may call.
    /// @dev Idempotent: if the epoch already rolled this block (or a concurrent
    ///      executor won the race), returns quietly - never re-distributes.
    ///      External calls are wrapped in try/catch: if one leg fails after the
    ///      epoch advanced, the failure is recorded (not reverted) so a retry can
    ///      never double-distribute the leg that already succeeded.
    function performJob(bytes calldata) external {
        if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
        uint256 ts = nextEpochTimestamp;
        if (block.timestamp < ts) return;

        nextEpochTimestamp = ts + EPOCH; // effect first (RULE-1, RULE-12)

        bool voterOk;
        bool gaugeOk;
        if (address(voter) != address(0)) {
            // swallow-on-purpose: a failed leg must not roll the epoch back
            // (no double-distribution on retry); the outcome is recorded in
            // the EpochRolled flags and caught up at the next epoch.
            try voter.distribute() {
                voterOk = true;
            } catch {
                voterOk = false;
            }
        }
        if (address(gauge) != address(0)) {
            try gauge.harvest() {
                gaugeOk = true;
            } catch {
                gaugeOk = false;
            }
        }

        emit EpochRolled(ts + EPOCH, voterOk, gaugeOk);
    }
}
