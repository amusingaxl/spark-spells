// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {
    IAccessControlEnumerable
} from "../../lib/diamond-pau/lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

import {IPAUFactory} from "diamond-pau/interfaces/IPAUFactory.sol";
import {IController} from "diamond-pau/interfaces/IController.sol";
import {IALMProxy} from "diamond-pau/interfaces/IALMProxy.sol";
import {IRateLimits} from "diamond-pau/interfaces/IRateLimits.sol";
import {IAccessControls} from "diamond-pau/interfaces/IAccessControls.sol";
import {ICCTPFacet} from "diamond-pau/facets/cctp/ICCTPFacet.sol";
import {makeAddressAddressKey} from "diamond-pau/libraries/RateLimitHelpers.sol";
import {IAdministeredAgent} from "pau-administered-agent/interfaces/IAdministeredAgent.sol";
import {IAdministeredAgentFactory} from "pau-administered-agent/interfaces/IAdministeredAgentFactory.sol";

interface ILegacyFundingController {
    function proxy() external view returns (address);
    function rateLimits() external view returns (address);
    function LIMIT_ASSET_TRANSFER() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function transferAsset(address asset, address destination, uint256 amount) external;
}

interface ISegregatedPAUController is IController {
    function cctp_setDomainParameters(uint32 domain, bytes32 recipient, uint32 minFeeCapRate, uint32 maxFeeCapRate)
        external;
    function cctp_getDomainParameters(uint32 domain) external view returns (ICCTPFacet.DomainParameters memory);
    function cctp_toCCTPRateLimitKey() external pure returns (bytes32);
    function cctp_getToDomainRateLimitKey(uint32 domain) external pure returns (bytes32);
    function cctp_usdc() external view returns (address);
    function cctp_cctp() external view returns (address);
    function cctp_transfer(uint256 amount, uint32 domain, uint64 feeCapRate) external;
    function transferAsset_getTransferRateLimitKey(address asset, address destination) external pure returns (bytes32);
    function transferAsset_transfer(address asset, address destination, uint256 amount) external;
}

/// @notice Deploys and activates separately funded CCTP custody without changing the legacy system.
library SegregatedPAU {
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant RELAYER_ROLE = keccak256("RELAYER");

    struct Instance {
        address proxy;
        address controller;
        address rateLimits;
        address accessControls;
        address agent;
    }

    struct RateLimit {
        uint256 maxAmount;
        uint256 slope;
    }

    struct Domain {
        uint32 domain;
        address mintRecipient;
        uint32 minFeeCapRate;
        uint32 maxFeeCapRate;
        RateLimit limit;
    }

    struct Config {
        address legacyController;
        address usdc;
        address[] actors;
        address freezer;
        uint256 fundingBudget;
        RateLimit globalLimit;
        Domain[] domains;
    }

    /// @dev Factories and their Beacon must be independently verified before deployment.
    function deploy(address pauFactory, address agentFactory, address admin)
        internal
        returns (Instance memory instance)
    {
        IPAUFactory factory = IPAUFactory(pauFactory);
        instance.accessControls = factory.deployAccessControls(admin);
        instance.proxy = factory.deployALMProxy(admin);
        instance.rateLimits = factory.deployRateLimits(admin);
        instance.controller = factory.deployController(instance.accessControls, instance.proxy, instance.rateLimits);
        instance.agent = IAdministeredAgentFactory(agentFactory).deploy(admin);
    }

    /// @dev Called in governance executor context. Amounts use USDC's six decimals; slopes are per second.
    function initialize(Instance memory instance, Config memory config) internal {
        ILegacyFundingController legacy = ILegacyFundingController(config.legacyController);
        IALMProxy proxy = IALMProxy(instance.proxy);
        IRateLimits rateLimits = IRateLimits(instance.rateLimits);
        IAccessControls accessControls = IAccessControls(instance.accessControls);
        IAdministeredAgent agent = IAdministeredAgent(instance.agent);
        ISegregatedPAUController controller = ISegregatedPAUController(instance.controller);
        address legacyProxy = legacy.proxy();
        IRateLimits legacyLimits = IRateLimits(legacy.rateLimits());

        require(
            instance.proxy != legacyProxy && instance.rateLimits != address(legacyLimits),
            "SegregatedPAU/shared-custody"
        );
        require(
            controller.proxy() == instance.proxy && controller.rateLimits() == instance.rateLimits
                && controller.accessControls() == instance.accessControls,
            "SegregatedPAU/wrong-instance"
        );
        require(
            config.usdc != address(0) && config.freezer != address(0) && config.actors.length > 0
                && config.domains.length > 0 && config.globalLimit.maxAmount > 0,
            "SegregatedPAU/invalid-config"
        );
        require(
            config.fundingBudget > 0 && config.fundingBudget < type(uint256).max, "SegregatedPAU/invalid-funding-budget"
        );
        require(
            controller.integrations().length == 0 && !proxy.hasRole(proxy.CONTROLLER(), instance.controller)
                && !rateLimits.hasRole(rateLimits.CONTROLLER(), instance.controller)
                && IAccessControlEnumerable(instance.accessControls).getRoleMemberCount(ALLOCATOR_ROLE) == 0
                && agent.actorCount() == 0,
            "SegregatedPAU/already-initialized"
        );
        require(
            !IALMProxy(legacyProxy).hasRole(proxy.CONTROLLER(), instance.controller)
                && !IALMProxy(legacyProxy).hasRole(proxy.CONTROLLER(), instance.agent)
                && !legacyLimits.hasRole(rateLimits.CONTROLLER(), instance.controller)
                && !legacyLimits.hasRole(rateLimits.CONTROLLER(), instance.agent)
                && !legacy.hasRole(RELAYER_ROLE, instance.agent) && !legacy.hasRole(RELAYER_ROLE, instance.controller),
            "SegregatedPAU/legacy-authority"
        );

        require(
            !IALMProxy(legacyProxy).hasRole(bytes32(0), instance.controller)
                && !IALMProxy(legacyProxy).hasRole(bytes32(0), instance.agent)
                && !legacyLimits.hasRole(bytes32(0), instance.controller)
                && !legacyLimits.hasRole(bytes32(0), instance.agent) && !legacy.hasRole(bytes32(0), instance.controller)
                && !legacy.hasRole(bytes32(0), instance.agent),
            "SegregatedPAU/legacy-authority"
        );

        bytes32 fundingKey = makeAddressAddressKey(legacy.LIMIT_ASSET_TRANSFER(), config.usdc, instance.proxy);
        require(legacyLimits.getRateLimitData(fundingKey).lastUpdated == 0, "SegregatedPAU/funding-already-configured");

        proxy.grantRole(proxy.CONTROLLER(), instance.controller);
        rateLimits.grantRole(rateLimits.CONTROLLER(), instance.controller);
        accessControls.grantRole(ALLOCATOR_ROLE, instance.agent);
        for (uint256 i; i < config.actors.length; ++i) {
            agent.addActor(config.actors[i]);
        }
        agent.addRevoker(config.freezer);

        bytes32[] memory integrations = new bytes32[](2);
        integrations[0] = "CCTP_FACET";
        integrations[1] = "TRANSFER_ASSET_FACET";
        controller.updateIntegrations(integrations);
        require(controller.cctp_usdc() == config.usdc, "SegregatedPAU/wrong-usdc");

        rateLimits.setRateLimitData(
            controller.cctp_toCCTPRateLimitKey(), config.globalLimit.maxAmount, config.globalLimit.slope
        );
        for (uint256 i; i < config.domains.length; ++i) {
            Domain memory domain = config.domains[i];
            require(domain.limit.maxAmount > 0, "SegregatedPAU/invalid-domain-limit");
            for (uint256 j; j < i; ++j) {
                require(config.domains[j].domain != domain.domain, "SegregatedPAU/duplicate-domain");
            }
            controller.cctp_setDomainParameters(
                domain.domain,
                bytes32(uint256(uint160(domain.mintRecipient))),
                domain.minFeeCapRate,
                domain.maxFeeCapRate
            );
            rateLimits.setRateLimitData(
                controller.cctp_getToDomainRateLimitKey(domain.domain), domain.limit.maxAmount, domain.limit.slope
            );
        }
        rateLimits.setUnlimitedRateLimitData(controller.transferAsset_getTransferRateLimitKey(config.usdc, legacyProxy));
        legacyLimits.setRateLimitData(fundingKey, config.fundingBudget, 0);
    }
}
