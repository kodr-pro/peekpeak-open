// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAutoJob - the 2-method automation interface for PeekPeak.
/// @notice "Peek": `checkJob` is evaluated off-chain via static `eth_call` on every
///         new block. "Poke": when it returns true, PeekRegistry calls `performJob`.
/// @dev Integrators MUST keep `checkJob` free of state mutation and MUST restrict
///      `performJob` to the registry so only PeekPeak can trigger execution.
interface IAutoJob {
    /// @notice Evaluated off-chain via static call (eth_call) on every new block.
    /// @dev MUST NOT mutate state. Must return true only when performJob is ready to run.
    /// @return canExec True when `performJob` is ready to be executed.
    /// @return execPayloadOpaque Bytes forwarded unchanged to `performJob` by the registry.
    function checkJob() external view returns (bool canExec, bytes memory execPayloadOpaque);

    /// @notice Executed on-chain by PeekRegistry when checkJob returns true.
    /// @dev Must be access-restricted so only the PeekRegistry can call it, and must
    ///      mutate state such that `checkJob()` returns false on the next block.
    /// @param execPayload The exact bytes returned by the preceding `checkJob` call.
    function performJob(bytes calldata execPayload) external;
}
