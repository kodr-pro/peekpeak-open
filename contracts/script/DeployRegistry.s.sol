// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PeekPeakScript} from "./PeekPeak.s.sol";
import {PeekRegistry} from "../src/PeekRegistry.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys the immutable PeekRegistry.
///         Plain CREATE by default; set CREATE2_SALT for a deterministic address
///         via the universal deployer (same address on every EVM chain).
///         Env: DEPLOYER_KEY, TREASURY, OWNER (optional, defaults to deployer),
///              OVERHEAD_BUFFER (optional, default 35000), CREATE2_SALT (optional).
contract DeployRegistry is PeekPeakScript {
    // CREATE2_FACTORY is inherited from forge-std Base (0x4e59b4...956C)
    function run() external {
        address payable treasury = payable(vm.envAddress("TREASURY"));
        uint256 buffer = _overheadBuffer();
        uint256 pk = _broadcast();
        address owner = vm.envOr("OWNER", address(0));
        if (owner == address(0)) {
            owner = vm.addr(pk);
            console2.log("WARNING (SEC-14): OWNER unset - registry owner defaults to the DEPLOYER hot wallet.");
            console2.log("           Production deployments MUST set OWNER=<Safe multisig> so the executor key never holds admin rights.");
        }

        // per-deployment tip in the chain's NATIVE denomination (0 = default)
        uint128 initialTip = uint128(vm.envOr("KEEPER_TIP_WEI", uint256(0)));
        bytes memory initCode =
            abi.encodePacked(type(PeekRegistry).creationCode, abi.encode(owner, treasury, buffer, initialTip));

        address deployed;
        bytes32 salt = vm.envOr("CREATE2_SALT", bytes32(0));
        if (uint256(salt) != 0) {
            // The universal deployer (0x4e59b4...) semantics: raw calldata is
            // salt ++ initCode (NOT abi-encoded args); it returns the address.
            (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
            require(ok, "factory call reverted");
            // the proxy returns the raw 20-byte address, not abi-encoded
            require(ret.length == 20, "unexpected factory return");
            deployed = address(bytes20(ret));
            require(deployed.code.length > 0, "CREATE2 deployed no code");
            // Audit F-5: validate against the EFFECTIVE expected tip, not the
            // hardcoded default - a custom KEEPER_TIP_WEI deployment (SPEC-13)
            // must not fail the sanity check after the factory tx already ran.
            uint128 expectedTip = initialTip == 0 ? PeekRegistry(deployed).DEFAULT_KEEPER_TIP() : initialTip;
            require(
                PeekRegistry(deployed).keeperTip() == expectedTip, "factory returned a non-registry address"
            );
            console2.log("CREATE2 address (same across chains with this salt + code):", deployed);
        } else {
            deployed = address(new PeekRegistry(owner, treasury, uint32(buffer), initialTip));
        }
        vm.stopBroadcast();

        _recordChainJson("PeekRegistry", deployed);
        console2.log("owner:", owner);
        console2.log("treasury:", treasury);
        console2.log("keeperTip (native denom):", PeekRegistry(deployed).keeperTip());
        console2.log("OVERHEAD_BUFFER:", PeekRegistry(deployed).OVERHEAD_BUFFER());
    }
}

