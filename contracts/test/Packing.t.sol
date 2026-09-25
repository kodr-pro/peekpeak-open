// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "../src/PeekRegistry.sol";
import {MockJob} from "../src/mocks/MockJob.sol";

/// @dev Proves the `Job` struct occupies exactly two storage slots with the
///      declared layout, that the declared padding bytes are zero, and that the
///      escrow balance lives OUTSIDE the struct (RULE-7, SPEC-2 D5).
///      Inherited storage (Ownable / ReentrancyGuard in OZ v5.1) is located
///      by scanning for the distinctive slot-A pattern rather than assuming
///      a fixed base offset.
contract PackingTest is Test {
    PeekRegistry internal registry;
    MockJob internal job;

    address internal owner = makeAddr("owner");
    address payable internal treasury = payable(makeAddr("treasury"));
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner);
        registry = new PeekRegistry(owner, treasury, 35_000, 0);
        vm.deal(alice, 1 ether);
        job = new MockJob(address(registry));
        vm.txGasPrice(25 gwei);
    }

    function test_JobStructOccupiesExactlyTwoSlotsWithZeroPadding() public {
        // distinctive values so slot A is unambiguous
        uint32 gasLimit = 123_457;
        uint64 ceiling = 77;
        vm.prank(alice);
        bytes32 jobId = registry.registerJob{value: 1 ether}(address(job), gasLimit, ceiling);

        // find the mapping data slot: probe base slots p in 0..23 with
        // dataSlot = keccak256(abi.encode(jobId, p)) and match slot A's pattern.
        uint256 slotA = _findSlotA(jobId, address(job), gasLimit);
        uint256 wordA = uint256(vm.load(address(registry), bytes32(slotA)));
        uint256 wordB = uint256(vm.load(address(registry), bytes32(slotA + 1)));

        // slot A: target (bytes 0..19)
        assertEq(address(uint160(wordA)), address(job), "slotA.target");
        // slot A: gasLimit (bytes 20..24)
        assertEq(uint32(wordA >> 160), gasLimit, "slotA.gasLimit");
        // slot A: isActive (byte 24)
        assertEq(uint8(wordA >> 192), 1, "slotA.isActive");
        // slot A: consecutiveReverts (byte 25)
        assertEq(uint8(wordA >> 200), 0, "slotA.consecutiveReverts");
        // slot A: padding bytes 26..31 must be zero
        assertEq(wordA >> 208, 0, "slotA.padding");

        // slot B: owner (bytes 0..19)
        assertEq(address(uint160(wordB)), alice, "slotB.owner");
        // slot B: maxGasPriceGwei (bytes 20..28)
        assertEq(uint64(wordB >> 160), ceiling, "slotB.maxGasPriceGwei");
        // slot B: padding bytes 28..31 must be zero
        assertEq(wordB >> 224, 0, "slotB.padding");

        // slot A + 2 is NOT part of this struct: escrow lives elsewhere.
        // Flip isActive off via the owner and observe byte 24 only.
        vm.prank(alice);
        registry.setJobStatus(jobId, false);
        wordA = uint256(vm.load(address(registry), bytes32(slotA)));
        assertEq(uint8(wordA >> 192), 0, "slotA.isActive after toggle");
        assertEq(uint32(wordA >> 160), gasLimit, "slotA.gasLimit unaffected");
    }

    function test_EscrowLivesOutsideJobStruct() public {
        vm.prank(alice);
        bytes32 jobId = registry.registerJob{value: 0.42 ether}(address(job), 100_000, 30);

        uint256 slotA = _findSlotA(jobId, address(job), 100_000);
        uint256 wordA = uint256(vm.load(address(registry), bytes32(slotA)));
        uint256 wordB = uint256(vm.load(address(registry), bytes32(slotA + 1)));

        // escrow value must not appear in either struct slot
        assertFalse(_contains(wordA, 0.42 ether) || _contains(wordB, 0.42 ether));
        // and the public escrow mapping still holds the truth
        assertEq(registry.escrows(jobId), 0.42 ether);
    }

    // -- internals ------------------------------------------------------

    function _findSlotA(bytes32 jobId, address target, uint32 gasLimit) internal view returns (uint256) {
        // low 20 bytes = target, next 4 bytes = gasLimit (integer math: bytes20
        // would left-align)
        uint256 pattern = uint256(uint160(target)) | (uint256(gasLimit) << 160);
        for (uint256 p = 0; p < 24; p++) {
            uint256 dataSlot = uint256(keccak256(abi.encode(jobId, p)));
            bytes32 word = vm.load(address(registry), bytes32(dataSlot));
            if ((uint256(word) & ((1 << 192) - 1)) == uint256(pattern)) {
                return dataSlot;
            }
        }
        revert("Job struct slot not found behind the jobs mapping");
    }

    function _contains(uint256 word, uint256 value) internal pure returns (bool) {
        for (uint256 i = 0; i + 128 <= 256; i += 8) {
            if (((word >> i) & type(uint128).max) == value) {
                return true;
            }
        }
        return false;
    }
}
