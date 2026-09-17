// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {Script} from "../lib/forge-std/src/Script.sol";
import {Ethereum} from "../lib/spark-address-registry/src/Ethereum.sol";
import {Arbitrum} from "../lib/spark-address-registry/src/Arbitrum.sol";
import {Base} from "../lib/spark-address-registry/src/Base.sol";
import {IPAUFactory} from "../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import {IBeacon} from "../lib/diamond-pau/src/interfaces/IBeacon.sol";
import {ICCTPFacet} from "../lib/diamond-pau/src/facets/cctp/ICCTPFacet.sol";
import {SegregatedPAU, ILegacyFundingController} from "../src/segregated/SegregatedPAU.sol";
import {SegregatedPAUPayload} from "../src/segregated/SegregatedPAUPayload.sol";

/// @notice Stages five unconfigured components and a reviewable payload; does not activate or fund them.
contract DeploySegregatedPAU is Script {
    function run(address pauFactory, address agentFactory, bytes calldata encodedConfig)
        external
        returns (SegregatedPAU.Instance memory instance, address payload)
    {
        SegregatedPAU.Config memory config = abi.decode(encodedConfig, (SegregatedPAU.Config));
        (address admin, address legacyController, address usdc, address relayer, address backstop, address freezer) =
            _addresses();
        require(
            config.legacyController == legacyController && config.usdc == usdc && config.freezer == freezer
                && config.actors.length == 2 && config.actors[0] == relayer && config.actors[1] == backstop,
            "DeploySegregatedPAU/wrong-chain-config"
        );
        address localLegacyProxy = ILegacyFundingController(legacyController).proxy();
        for (uint256 i; i < config.domains.length; ++i) {
            SegregatedPAU.Domain memory domain = config.domains[i];
            require(
                domain.mintRecipient == _legacyProxy(domain.domain) && domain.mintRecipient != localLegacyProxy,
                "DeploySegregatedPAU/wrong-recipient"
            );
        }
        address facet = IBeacon(IPAUFactory(pauFactory).beacon()).getConfig("CCTP_FACET").facet;
        require(
            ICCTPFacet(facet).usdc() == usdc && ICCTPFacet(facet).cctp() == Ethereum.CCTP_TOKEN_MESSENGER,
            "DeploySegregatedPAU/wrong-cctp"
        );
        vm.startBroadcast();
        instance = SegregatedPAU.deploy(pauFactory, agentFactory, admin);
        payload = address(new SegregatedPAUPayload(admin, instance, config));
        vm.stopBroadcast();
    }

    function _addresses() internal view returns (address, address, address, address, address, address) {
        if (block.chainid == 1) {
            return (
                Ethereum.SPARK_PROXY,
                Ethereum.ALM_CONTROLLER,
                Ethereum.USDC,
                Ethereum.ALM_RELAYER_MULTISIG,
                Ethereum.ALM_BACKSTOP_RELAYER_MULTISIG,
                Ethereum.ALM_FREEZER_MULTISIG
            );
        }
        if (block.chainid == 42161) {
            return (
                Arbitrum.SPARK_EXECUTOR,
                Arbitrum.ALM_CONTROLLER,
                Arbitrum.USDC,
                Arbitrum.ALM_RELAYER_MULTISIG,
                Arbitrum.ALM_BACKSTOP_RELAYER_MULTISIG,
                Arbitrum.ALM_FREEZER_MULTISIG
            );
        }
        require(block.chainid == 8453, "DeploySegregatedPAU/unsupported-chain");
        return (
            Base.SPARK_EXECUTOR,
            Base.ALM_CONTROLLER,
            Base.USDC,
            Base.ALM_RELAYER_MULTISIG,
            Base.ALM_BACKSTOP_RELAYER_MULTISIG,
            Base.ALM_FREEZER_MULTISIG
        );
    }

    function _legacyProxy(uint32 domain) internal pure returns (address) {
        if (domain == 0) return Ethereum.ALM_PROXY;
        if (domain == 3) return Arbitrum.ALM_PROXY;
        require(domain == 6, "DeploySegregatedPAU/unsupported-domain");
        return Base.ALM_PROXY;
    }
}
