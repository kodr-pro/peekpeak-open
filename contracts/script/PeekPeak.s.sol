// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2, stdJson} from "forge-std/Script.sol";

/// @dev Shared base for PeekPeak deploy scripts. All values come from
///      environment variables (never committed); see contracts/README.md.
abstract contract PeekPeakScript is Script {
    using stdJson for string;

    /// @notice Provisional OVERHEAD_BUFFER default; calibrated on a Fuji fork
    ///         in Phase 5 (Q-6 in docs/ground-truth/questions.md).
    uint32 internal constant DEFAULT_OVERHEAD_BUFFER = 50_000; // calibrated: docs/gas-anomaly.md

    function _privateKey() internal view returns (uint256) {
        return vm.envUint("DEPLOYER_KEY");
    }

    function _requireEnv(string memory name) internal view returns (string memory value) {
        value = vm.envString(name);
        require(bytes(value).length > 0, string.concat("missing env ", name));
    }

    function _broadcast() internal returns (uint256 pk) {
        pk = _privateKey();
        vm.startBroadcast(pk);
    }

    function _overheadBuffer() internal view returns (uint32) {
        return uint32(vm.envOr("OVERHEAD_BUFFER", uint256(DEFAULT_OVERHEAD_BUFFER)));
    }

    function _recordChainJson(string memory contractName, address deployed) internal pure {
        console2.log(string.concat(contractName, " deployed at:"), deployed);
        console2.log("Record this address in deploy/chains/<chain>.json (public data only).");
    }
}
