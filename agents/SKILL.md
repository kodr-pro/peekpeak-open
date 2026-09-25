# PeekPeak - Autonomous Execution Skill for Avalanche

> **Peek the state. Poke the peak.**
> Zero-overhead autonomous keeper engine native to Avalanche C-Chain and L1s.
> Zero token tax. No governance token. No subscriptions. Settlement in native coin.

You are integrating a contract with **PeekPeak**, an autonomous execution
protocol. Follow this file top to bottom. When you finish, your contract will
be executed automatically by the PeekPeak keeper network and pay for its own
gas out of a native-coin escrow - nothing else changes.

## What PeekPeak does

- **Peek** (off-chain, free): every block, the watcher static-calls
  `checkJob()` on your contract via `eth_call`. No gas, no transaction.
- **Poke** (on-chain, escrow-funded): when `checkJob()` returns `true`, an
  authorized executor calls `performJob(payload)` through `PeekRegistry`.
  The executor is reimbursed exactly for gas used from YOUR escrow, plus a
  flat 0.005 AVAX keeper tip to the protocol treasury. Failed or reverting
  executions charge nothing.

## The interface (implement exactly this)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAutoJob {
    /// @dev MUST NOT mutate state. Returns true only when performJob is ready.
    function checkJob() external view returns (bool canExec, bytes memory execPayload);

    /// @dev MUST be restricted to the PeekRegistry. MUST flip checkJob to
    ///      false for the next block.
    function performJob(bytes calldata execPayload) external;
}
```

## Rules you MUST follow

1. **Inspect your target function first.** Identify the exact maintenance call
   (e.g. `voter.distribute()`, `gauge.harvest()`, `vault.rebalance()`), its
   gas cost, and the on-chain condition that makes it due.
2. **Implement `IAutoJob`** on the target contract directly, or in a thin
   adapter if the target must not change (see the reference adapter below).
3. **Restrict `performJob` to the registry:**

   ```solidity
   address public immutable REGISTRY_ADDRESS; // set in constructor

   function performJob(bytes calldata) external {
       if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
       ...
   }
   ```

   Use the registry address for your chain from `deploy/chains/*.json`
   (Fuji testnet first). Make it a constructor arg - never hardcode across
   environments.
4. **Make the state transition honest (critical):** after `performJob`
   succeeds, `checkJob()` MUST return `false` on the very next block. Write
   the "already done" state BEFORE any external call:

   ```solidity
   function performJob(bytes calldata) external {
       if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
       if (block.timestamp < nextRun) return;   // idempotent: nothing due
       nextRun = block.timestamp + INTERVAL;    // EFFECT FIRST
       target.maintain();                        // interaction after
   }
   ```

   If an external call can fail mid-way, wrap it in try/catch and record the
   partial failure as an event - never revert the whole performJob after the
   effect, or a retry storm will double-execute the earlier legs.
5. **Keep `checkJob` cheap and pure.** Only reads, arithmetic, and a single
   boolean decision. The watcher batches thousands per block.
6. **Gas model:** set `gasLimit` to your worst-case `performJob` cost
   (measure with `forge snapshot`), `maxGasPriceGwei` to the ceiling you
   accept, and fund the escrow with at least
   `(gasLimit + 70000) * gasPrice + keeperTip(chain)` per execution you want
   banked. `keeperTip` is denominated in YOUR chain's native gas token - read
   it from the registry (0.005 AVAX default on C-Chain/Fuji; some L1s run
   zero-tip). Depleted jobs auto-deactivate (top up before that).
 7. **Never** hold secrets, use block.timestamp randomness for security, or
    make `performJob` payable - the registry handles all value flows.
 8. **Register from an EOA or an ETH-accepting contract** (audit F-6):
    escrow withdrawals are pushed via `call` to the job owner and revert if
    the receiving wallet rejects native coin. A wallet that can never accept
    ETH strands its escrow (a pull fallback would transfer the same way).
 9. **Keep `execPayload` small** (audit F-2 / DIV-D-4): the registry reverts
    `executeJob` for payloads above `MAX_EXEC_PAYLOAD` (4 KB). Return at most
    a few hundred bytes from `checkJob` - the reference adapter returns `""`.
10. **Economics trust note** (audit F-7): each execution pays
    `gasUsed * gasPrice + keeperTip` from your escrow and only PeekPeak's
    authorized executors can dispatch, so escrow exposure is bounded by the
    executor's honesty - keep `performJob` idempotent (rule 4) and deactivate
    (`setJobStatus(false)`) / withdraw if you observe unwanted executions.

## Foundry test template (REQUIRED - ship these three cases)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAutoJob} from "peekpeak/IAutoJob.sol";
import {MyKeeper} from "../src/MyKeeper.sol";

contract MockRegistry {}

contract MyKeeperTest is Test {
    MyKeeper keeper;
    address registry = makeAddr("registry");

    function setUp() public {
        keeper = new MyKeeper(registry);
    }

    function test_CheckJobFlipsFalseToTrueWhenDue() public {
        (bool canExec,) = keeper.checkJob();
        assertFalse(canExec);                 // not due initially
        vm.warp(block.timestamp + keeper.INTERVAL());
        (canExec,) = keeper.checkJob();
        assertTrue(canExec);                  // due after the interval
    }

    function test_PerformJobFromMockRegistryExecutesAndResets() public {
        vm.warp(block.timestamp + keeper.INTERVAL());
        vm.prank(registry);
        keeper.performJob("");
        assertEq(keeper.maintainCount(), 1);  // target maintenance ran
        (bool canExec,) = keeper.checkJob();
        assertFalse(canExec);                 // reset to false for next block
    }

    function test_PerformJobRevertsForNonRegistry() public {
        vm.expectRevert(MyKeeper.NotRegistry.selector);
        keeper.performJob("");
    }
}
```

## Deploy & register script template

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PeekRegistry} from "peekpeak/PeekRegistry.sol";
import {MyKeeper} from "../src/MyKeeper.sol";

contract DeployAndRegister is Script {
    function run() external {
        PeekRegistry registry = PeekRegistry(vm.envAddress("REGISTRY"));
        uint32 gasLimit = uint32(vm.envOr("GAS_LIMIT", uint256(500_000)));
        uint64 ceiling = uint64(vm.envOr("MAX_GAS_PRICE_GWEI", uint256(100)));
        uint256 deposit = vm.envUint("DEPOSIT_WEI"); // >= worst-case cost * runs

        vm.startBroadcast();
        MyKeeper keeper = new MyKeeper(address(registry));
        bytes32 jobId = registry.registerJob{value: deposit}(
            address(keeper), gasLimit, ceiling
        );
        vm.stopBroadcast();

        console2.log("keeper:", address(keeper));
        console2.logBytes32(jobId);
    }
}
```

Interface + registry sources live in the PeekPeak repo under
`contracts/src/` (`IAutoJob.sol`, `PeekRegistry.sol`). Install as a git
submodule or vendor the two files (they are MIT).

## Reference adapter: epoch keeper (ve(3,3) style)

```solidity
contract EpochKeeper is IAutoJob {
    address public immutable REGISTRY_ADDRESS;
    IVoter public immutable voter;
    uint256 public nextEpoch;

    error NotRegistry();

    constructor(address registry, address voter_, uint256 firstEpoch) {
        REGISTRY_ADDRESS = registry;
        voter = IVoter(voter_);
        nextEpoch = firstEpoch;
    }

    function checkJob() external view returns (bool, bytes memory) {
        return (block.timestamp >= nextEpoch, "");
    }

    function performJob(bytes calldata) external {
        if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
        uint256 ts = nextEpoch;
        if (block.timestamp < ts) return;      // idempotent within an epoch
        nextEpoch = ts + 1 weeks;              // effect first
        bool ok;
        try voter.distribute() {
            ok = true;   // recorded; a failed leg retries next epoch
        } catch {
            ok = false;  // never roll back the epoch
        }
    }
}
```

## Registry cheat-sheet (what you get)

| Call | Who | Effect |
|------|-----|--------|
| `registerJob(target, gasLimit, maxGasPriceGwei)` payable | you | creates the job, funds escrow (min one worst-case execution) |
| `depositGas(jobId)` payable | anyone | tops up escrow |
| `withdrawGas(jobId, amount)` | job owner | drains escrow |
| `setJobStatus(jobId, bool)` | job owner | pause/resume |
| `executeJob(jobId, payload)` | authorized PeekPeak executor only | runs `performJob`, charges escrow exactly `gasUsed * gasPrice + 0.005 AVAX flat tip` |

A reverting `performJob` never charges your escrow. Three consecutive
reverts auto-deactivate the job (fix your contract, re-activate, resume).

## Definition of done for an integration

- [ ] `IAutoJob` implemented (direct or adapter) with `REGISTRY_ADDRESS` restriction.
- [ ] `checkJob` view-only, cheap, false-when-nothing-due.
- [ ] `performJob` effect-before-interaction, idempotent, try/catch on externals.
- [ ] Three Foundry tests (flip false->true, mock-registry execution + reset,
      non-revert-for-non-registry) passing.
- [ ] Deploy script parameterized (gas limit, ceiling, deposit).
- [ ] Registered on Fuji, escrow funded, first automated execution observed.
