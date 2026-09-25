// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAutoJob} from "../IAutoJob.sol";

/// @title MockJob - well-behaved reference `IAutoJob` for tests and the Fuji
///        end-to-end dry run (SPEC-11).
contract MockJob is IAutoJob {
    address public immutable REGISTRY_ADDRESS;
    bool public ready;
    uint256 public performCount;
    uint256 public gasToBurn;
    bytes public lastPayload;

    event Performed(bytes payload);

    error NotRegistry();
    error NotReady();

    constructor(address registry) {
        REGISTRY_ADDRESS = registry;
    }

    function setReady(bool _ready) external {
        ready = _ready;
    }

    function setGasToBurn(uint256 _gas) external {
        gasToBurn = _gas;
    }

    function checkJob() external view returns (bool canExec, bytes memory) {
        return (ready, hex"deadbeef");
    }

    function performJob(bytes calldata execPayload) external {
        if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
        if (!ready) revert NotReady();
        ready = false; // effect first: checkJob must be false on the next block (RULE-12)
        lastPayload = execPayload;
        performCount += 1;
        if (gasToBurn > 0) _burn(gasToBurn);
        emit Performed(execPayload);
    }

    function _burn(uint256 amount) internal view {
        uint256 start = gasleft();
        while (start - gasleft() < amount) {}
    }
}
