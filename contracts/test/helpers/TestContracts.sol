// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PeekRegistry} from "../../src/PeekRegistry.sol";

/// @dev Records `distribute()` invocations for the epoch keeper tests.
contract MockVoter {
    uint256 public distributeCount;

    function distribute() external {
        distributeCount += 1;
    }
}

/// @dev Always-failing voter: exercises the keeper's try/catch leg.
contract FailingVoter {
    error DistributeBroken();

    function distribute() external pure {
        revert DistributeBroken();
    }
}

/// @dev Records `harvest()` invocations for the epoch keeper tests.
contract MockGauge {
    uint256 public harvestCount;

    function harvest() external {
        harvestCount += 1;
    }
}

/// @dev Always-failing gauge: exercises the keeper's try/catch leg.
contract FailingGauge {
    error HarvestBroken();

    function harvest() external pure {
        revert HarvestBroken();
    }
}

/// @dev Executor wallet whose ETH acceptance can be toggled. Used to prove the
///      pull-payment fallback (failed refunds never revert execution).
contract ToggledExecutor {
    PeekRegistry public registry;
    bool public acceptEth = true;

    error NoEth();

    constructor(PeekRegistry _registry) {
        registry = _registry;
    }

    function setAcceptEth(bool accept) external {
        acceptEth = accept;
    }

    function setAuthorized(address owner, bool authorized) external {
        registry.setExecutor(address(this), authorized);
    }

    function doExecute(bytes32 jobId, bytes calldata payload) external returns (bool ok) {
        (ok,) = address(registry).call(abi.encodeCall(PeekRegistry.executeJob, (jobId, payload)));
    }

    function doPull() external returns (bool ok) {
        (ok,) = address(registry).call(abi.encodeCall(PeekRegistry.pull, ()));
    }

    receive() external payable {
        if (!acceptEth) revert NoEth();
    }
}

/// @dev Malicious target that attempts reentrancy into the registry mid-perform.
///      All attempts are neutralized by the registry's reentrancy guard (the
///      re-entering call reverts, so the registry records a TargetReverted and
///      never charges anyone).
contract AttackerJob {
    PeekRegistry public registry;
    bytes32 public attackJobId;
    uint256 public attackCount;
    uint8 public attackMode; // 0: reenter executeJob, 1: reenter withdrawGas, 2: reenter pull

    constructor(PeekRegistry _registry) {
        registry = _registry;
    }

    function configure(bytes32 jobId, uint8 mode) external {
        attackJobId = jobId;
        attackMode = mode;
    }

    function checkJob() external pure returns (bool, bytes memory) {
        return (true, "");
    }

    function performJob(bytes calldata) external {
        attackCount += 1;
        if (attackMode == 0) {
            registry.executeJob(attackJobId, "");
        } else if (attackMode == 1) {
            registry.withdrawGas(attackJobId, 1);
        } else {
            registry.pull();
        }
    }

    receive() external payable {}
}

/// @dev Legitimate job owner whose receive() attempts a re-entrant withdrawGas
///      exactly once, swallowing the guard revert so the attempt is observable.
///      The outer withdrawal must still complete exactly once - the reentrant
///      call gets nothing.
contract ReentrantWithdrawer {
    PeekRegistry public registry;
    bytes32 public jobId;
    uint128 public amount;
    bool public attacked;

    constructor(PeekRegistry _registry) {
        registry = _registry;
    }

    function attack(bytes32 _jobId, uint128 _amount) external {
        jobId = _jobId;
        amount = _amount;
        registry.withdrawGas(_jobId, _amount);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // re-entrant attempt is EXPECTED to revert (reentrancy guard);
            // swallow-on-purpose so the attempt is observable in `attacked`
            // while the outer withdrawal completes exactly once.
            try registry.withdrawGas(jobId, amount) {
                // unreachable: the guard rejects the re-entry
            } catch {
                // expected outcome
            }
        }
    }
}
