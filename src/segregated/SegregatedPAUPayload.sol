// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {SegregatedPAU} from "./SegregatedPAU.sol";

/// @notice Chain-local activation, executed by the existing Spark governance proxy/executor.
contract SegregatedPAUPayload {
    address public immutable SELF = address(this);
    address public immutable ADMIN;
    uint256 public immutable CHAIN_ID = block.chainid;
    bytes internal _configuration;

    constructor(address admin, SegregatedPAU.Instance memory instance, SegregatedPAU.Config memory config) {
        ADMIN = admin;
        _configuration = abi.encode(instance, config);
    }

    function configuration() external view returns (SegregatedPAU.Instance memory, SegregatedPAU.Config memory) {
        return abi.decode(_configuration, (SegregatedPAU.Instance, SegregatedPAU.Config));
    }

    function execute() external {
        require(block.chainid == CHAIN_ID, "SegregatedPAUPayload/wrong-chain");
        require(address(this) == ADMIN, "SegregatedPAUPayload/wrong-executor");
        // Governance uses delegatecall. Read constructor configuration from this payload, not executor storage.
        (SegregatedPAU.Instance memory instance, SegregatedPAU.Config memory config) =
            SegregatedPAUPayload(SELF).configuration();
        SegregatedPAU.initialize(instance, config);
    }

    // Same office hours as SparkPayloadEthereum; required by the existing mainnet StarGuard.
    function isExecutable() external view returns (bool) {
        uint256 day = (block.timestamp / 1 days + 3) % 7;
        uint256 hour = block.timestamp / 1 hours % 24;
        return block.chainid == CHAIN_ID && day < 5 && hour >= 14 && hour < 21;
    }
}
