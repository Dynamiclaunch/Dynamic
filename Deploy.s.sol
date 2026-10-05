// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Dynamic} from "../src/Dynamic.sol";

/// Deploys Dynamic to Base (8453) or Base Sepolia (84532).
/// Every parameter comes from environment variables, so no address is hard-coded in the repo.
/// The contract starts PAUSED with maxGoal = 0: nothing can be launched or funded until the owner
/// calls setAllowedPay / setMaxGoal / setPaused(false).
contract Deploy is Script {
    function run() external returns (Dynamic d) {
        require(block.chainid == 8453 || block.chainid == 84532, "unexpected chain");

        address owner = vm.envAddress("OWNER");              // admin wallet (not the deployer key)
        address treasury = vm.envAddress("TREASURY");
        address[] memory oracles = vm.envAddress("ORACLES", ",");
        uint8 threshold = uint8(vm.envUint("THRESHOLD"));    // e.g. 2 (of 3)
        uint16 feeBps = uint16(vm.envUint("FEE_BPS"));       // release fee, max 500 (= 5%)
        uint256 createFee = vm.envUint("CREATE_FEE");        // flat fee in USDC units (6 decimals); 0 = none

        require(owner != address(0) && treasury != address(0), "zero address");
        require(threshold > 0 && threshold <= oracles.length, "threshold");
        for (uint256 i; i < oracles.length; i++) {
            require(oracles[i] != address(0) && oracles[i] != owner, "bad oracle");
            for (uint256 j = i + 1; j < oracles.length; j++) require(oracles[i] != oracles[j], "duplicate oracle");
        }

        vm.startBroadcast();
        d = new Dynamic(owner, oracles, threshold, treasury, feeBps, createFee);
        vm.stopBroadcast();

        console2.log("Dynamic deployed at:", address(d));
        console2.log("owner:", d.owner());
        console2.log("paused:", d.paused());
    }
}
