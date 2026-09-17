// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {IERC20} from "../../lib/diamond-pau/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Beacon} from "../../lib/diamond-pau/src/Beacon.sol";
import {PAUFactory} from "../../lib/diamond-pau/src/PAUFactory.sol";
import {CCTPFacet} from "../../lib/diamond-pau/src/facets/cctp/CCTPFacet.sol";
import {ICCTPFacet} from "../../lib/diamond-pau/src/facets/cctp/ICCTPFacet.sol";
import {TransferAssetFacet} from "../../lib/diamond-pau/src/facets/transfer-asset/TransferAssetFacet.sol";
import {ITransferAssetFacet} from "../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetFacet.sol";
import {IEnumerableIntegrations} from "../../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";
import {IALMProxy} from "../../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import {IRateLimits} from "../../lib/diamond-pau/src/interfaces/IRateLimits.sol";
import {AdministeredAgentFactory} from "../../lib/pau-administered-agent/src/AdministeredAgentFactory.sol";
import {IAdministeredAgent} from "../../lib/pau-administered-agent/src/interfaces/IAdministeredAgent.sol";
import {Ethereum} from "../../lib/spark-address-registry/src/Ethereum.sol";
import {Arbitrum} from "../../lib/spark-address-registry/src/Arbitrum.sol";
import {Base} from "../../lib/spark-address-registry/src/Base.sol";
import {Bridge} from "../../lib/diamond-pau/lib/grove-xchain-helpers/src/testing/Bridge.sol";
import {Domain, DomainHelpers} from "../../lib/diamond-pau/lib/grove-xchain-helpers/src/testing/Domain.sol";
import {
    CCTPv2BridgeTesting
} from "../../lib/diamond-pau/lib/grove-xchain-helpers/src/testing/bridges/CCTPv2BridgeTesting.sol";
import {SegregatedPAU, ILegacyFundingController, ISegregatedPAUController} from "./SegregatedPAU.sol";
import {SegregatedPAUPayload} from "./SegregatedPAUPayload.sol";
import {IStarGuardLike} from "../interfaces/Interfaces.sol";
import {IExecutor} from "../../lib/spark-gov-relay/src/interfaces/IExecutor.sol";

interface ILegacyPSMController {
    function depositPSM(address asset, uint256 amount) external returns (uint256 shares);
    function withdrawPSM(address asset, uint256 amount) external returns (uint256 withdrawn);
    function swapUSDCToUSDS(uint256 amount) external;
}

/// @dev Actual legacy controllers and Circle contracts on three forks. The existing bridge helper
/// disables attestation signatures and supplies the message nonce/finality fields normally signed by Circle.
contract SegregatedPAUForkTest is Test {
    using DomainHelpers for Domain;
    using CCTPv2BridgeTesting for Bridge;

    uint256 internal constant FUNDING_BUDGET = 1_000e6;
    uint256 internal constant BRIDGE_AMOUNT = 600e6;
    address internal constant RELAYER = Ethereum.ALM_RELAYER_MULTISIG;
    bytes32 internal constant CONTROLLER_ROLE = keccak256("CONTROLLER");

    struct ChainContext {
        Domain domain;
        uint32 circleDomain;
        address admin;
        address legacyController;
        address legacyProxy;
        address legacyLimits;
        address usdc;
        address messenger;
        SegregatedPAU.Instance fresh;
    }

    ChainContext[3] internal chains;
    Bridge internal bridge;

    function setUp() public {
        _createChain(
            0,
            "mainnet",
            "MAINNET_RPC_URL",
            0,
            Ethereum.SPARK_PROXY,
            Ethereum.ALM_CONTROLLER,
            Ethereum.ALM_PROXY,
            Ethereum.ALM_RATE_LIMITS,
            Ethereum.USDC,
            Ethereum.CCTP_TOKEN_MESSENGER
        );
        _createChain(
            1,
            "arbitrum_one",
            "ARBITRUM_ONE_RPC_URL",
            3,
            Arbitrum.SPARK_EXECUTOR,
            Arbitrum.ALM_CONTROLLER,
            Arbitrum.ALM_PROXY,
            Arbitrum.ALM_RATE_LIMITS,
            Arbitrum.USDC,
            Arbitrum.CCTP_TOKEN_MESSENGER
        );
        _createChain(
            2,
            "base",
            "BASE_RPC_URL",
            6,
            Base.SPARK_EXECUTOR,
            Base.ALM_CONTROLLER,
            Base.ALM_PROXY,
            Base.ALM_RATE_LIMITS,
            Base.USDC,
            Base.CCTP_TOKEN_MESSENGER
        );
        for (uint256 i; i < chains.length; ++i) {
            _deployAndInitialize(i);
        }
    }

    function _createChain(
        uint256 index,
        string memory alias_,
        string memory rpcKey,
        uint32 circleDomain,
        address admin,
        address legacyController,
        address legacyProxy,
        address legacyLimits,
        address usdc,
        address messenger
    ) internal {
        ChainContext storage chain = chains[index];
        chain.domain.chain = getChain(alias_);
        chain.domain.chain.rpcUrl = vm.envString(rpcKey);
        chain.domain.forkId = vm.createFork(chain.domain.chain.rpcUrl);
        chain.circleDomain = circleDomain;
        chain.admin = admin;
        chain.legacyController = legacyController;
        chain.legacyProxy = legacyProxy;
        chain.legacyLimits = legacyLimits;
        chain.usdc = usdc;
        chain.messenger = messenger;
    }

    function _deployAndInitialize(uint256 index) internal {
        ChainContext storage chain = chains[index];
        chain.domain.selectFork();
        assertEq(ILegacyFundingController(chain.legacyController).proxy(), chain.legacyProxy);
        assertEq(ILegacyFundingController(chain.legacyController).rateLimits(), chain.legacyLimits);
        assertTrue(ILegacyFundingController(chain.legacyController).hasRole(keccak256("RELAYER"), RELAYER));
        Beacon beacon = new Beacon(address(this));
        _wireFacets(beacon, chain.messenger, chain.usdc);
        chain.fresh = SegregatedPAU.deploy(
            address(new PAUFactory(address(beacon))), address(new AdministeredAgentFactory()), chain.admin
        );
        SegregatedPAU.Config memory config;
        config.legacyController = chain.legacyController;
        config.usdc = chain.usdc;
        config.actors = new address[](2);
        config.actors[0] = RELAYER;
        config.actors[1] = Ethereum.ALM_BACKSTOP_RELAYER_MULTISIG;
        config.freezer = Ethereum.ALM_FREEZER_MULTISIG;
        config.fundingBudget = FUNDING_BUDGET;
        config.globalLimit = SegregatedPAU.RateLimit(FUNDING_BUDGET, 1e6);
        config.domains = new SegregatedPAU.Domain[](2);
        uint256 domainIndex;
        for (uint256 i; i < chains.length; ++i) {
            if (i == index) continue;
            config.domains[domainIndex++] = SegregatedPAU.Domain({
                domain: chains[i].circleDomain,
                mintRecipient: chains[i].legacyProxy,
                minFeeCapRate: 0,
                maxFeeCapRate: 100,
                limit: SegregatedPAU.RateLimit(FUNDING_BUDGET, 1e6)
            });
        }
        SegregatedPAUPayload payload = new SegregatedPAUPayload(chain.admin, chain.fresh, config);
        _executePayload(index, address(payload));
        _assertIsolated(chain);
    }

    function _executePayload(uint256 index, address payload) internal {
        if (index == 0) {
            vm.prank(Ethereum.PAUSE_PROXY);
            IStarGuardLike(Ethereum.SPARK_STAR_GUARD).plot(payload, payload.codehash);
            // Same office-hours simulation as SpellRunner._executeMainnetPayload.
            vm.mockCall(payload, abi.encodeCall(SegregatedPAUPayload.isExecutable, ()), abi.encode(true));
            assertEq(IStarGuardLike(Ethereum.SPARK_STAR_GUARD).exec(), payload);
        } else {
            IExecutor executor = IExecutor(chains[index].admin);
            address[] memory targets = new address[](1);
            uint256[] memory values = new uint256[](1);
            string[] memory signatures = new string[](1);
            bytes[] memory calldatas = new bytes[](1);
            bool[] memory withDelegatecalls = new bool[](1);
            targets[0] = payload;
            signatures[0] = "execute()";
            withDelegatecalls[0] = true;
            uint256 actionId = executor.actionsSetCount();
            vm.prank(index == 1 ? Arbitrum.SPARK_RECEIVER : Base.SPARK_RECEIVER);
            executor.queue(targets, values, signatures, calldatas, withDelegatecalls);
            vm.warp(executor.getActionsSetById(actionId).executionTime);
            executor.execute(actionId);
            // Keep this timestamp: initialization wrote rate-limit lastUpdated at execution time.
        }
    }

    function _wireFacets(Beacon beacon, address messenger, address usdc) internal {
        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](7);
        wires[0] = IEnumerableIntegrations.Wire(
            ISegregatedPAUController.cctp_setDomainParameters.selector, ICCTPFacet.setDomainParameters.selector
        );
        wires[1] =
            IEnumerableIntegrations.Wire(ISegregatedPAUController.cctp_transfer.selector, ICCTPFacet.transfer.selector);
        wires[2] = IEnumerableIntegrations.Wire(
            ISegregatedPAUController.cctp_toCCTPRateLimitKey.selector, ICCTPFacet.toCCTPRateLimitKey.selector
        );
        wires[3] = IEnumerableIntegrations.Wire(
            ISegregatedPAUController.cctp_getDomainParameters.selector, ICCTPFacet.getDomainParameters.selector
        );
        wires[4] = IEnumerableIntegrations.Wire(
            ISegregatedPAUController.cctp_getToDomainRateLimitKey.selector, ICCTPFacet.getToDomainRateLimitKey.selector
        );
        wires[5] = IEnumerableIntegrations.Wire(ISegregatedPAUController.cctp_cctp.selector, ICCTPFacet.cctp.selector);
        wires[6] = IEnumerableIntegrations.Wire(ISegregatedPAUController.cctp_usdc.selector, ICCTPFacet.usdc.selector);
        beacon.setIntegration(
            "CCTP_FACET", IEnumerableIntegrations.Config({facet: address(new CCTPFacet(messenger, usdc)), wires: wires})
        );
        wires = new IEnumerableIntegrations.Wire[](2);
        wires[0] = IEnumerableIntegrations.Wire(
            ISegregatedPAUController.transferAsset_transfer.selector, ITransferAssetFacet.transfer.selector
        );
        wires[1] = IEnumerableIntegrations.Wire(
            ISegregatedPAUController.transferAsset_getTransferRateLimitKey.selector,
            ITransferAssetFacet.getTransferRateLimitKey.selector
        );
        beacon.setIntegration(
            "TRANSFER_ASSET_FACET",
            IEnumerableIntegrations.Config({facet: address(new TransferAssetFacet()), wires: wires})
        );
    }

    function _assertIsolated(ChainContext storage chain) internal view {
        assertTrue(IALMProxy(chain.legacyProxy).hasRole(CONTROLLER_ROLE, chain.legacyController));
        assertTrue(IRateLimits(chain.legacyLimits).hasRole(CONTROLLER_ROLE, chain.legacyController));
        assertFalse(IALMProxy(chain.legacyProxy).hasRole(CONTROLLER_ROLE, chain.fresh.controller));
        assertFalse(IALMProxy(chain.legacyProxy).hasRole(CONTROLLER_ROLE, chain.fresh.agent));
        assertFalse(IRateLimits(chain.legacyLimits).hasRole(CONTROLLER_ROLE, chain.fresh.controller));
        assertFalse(IRateLimits(chain.legacyLimits).hasRole(CONTROLLER_ROLE, chain.fresh.agent));
        assertFalse(ILegacyFundingController(chain.legacyController).hasRole(keccak256("RELAYER"), chain.fresh.agent));
        assertFalse(
            ILegacyFundingController(chain.legacyController).hasRole(keccak256("RELAYER"), chain.fresh.controller)
        );
    }

    function _fundingKey(ChainContext storage chain) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                ILegacyFundingController(chain.legacyController).LIMIT_ASSET_TRANSFER(), chain.usdc, chain.fresh.proxy
            )
        );
    }

    function _actorCall(ChainContext storage chain, bytes memory data) internal {
        vm.prank(RELAYER);
        IAdministeredAgent(chain.fresh.agent).call(chain.fresh.controller, data);
    }

    function _bridge(uint256 sourceIndex, uint256 destinationIndex) internal {
        ChainContext storage source = chains[sourceIndex];
        ChainContext storage destination = chains[destinationIndex];
        bridge = CCTPv2BridgeTesting.createCircleBridge(source.domain, destination.domain);
        destination.domain.selectFork();
        uint256 destinationBefore = IERC20(destination.usdc).balanceOf(destination.legacyProxy);
        assertEq(IERC20(destination.usdc).balanceOf(destination.fresh.proxy), 0);
        source.domain.selectFork();
        // Seed test liquidity only in legacy custody. Fresh custody is funded solely by the live legacy controller.
        uint256 sourceBefore = IERC20(source.usdc).balanceOf(source.legacyProxy);
        deal(source.usdc, source.legacyProxy, sourceBefore + FUNDING_BUDGET);
        vm.prank(RELAYER);
        ILegacyFundingController(source.legacyController).transferAsset(source.usdc, source.fresh.proxy, FUNDING_BUDGET);
        assertEq(IERC20(source.usdc).balanceOf(source.fresh.proxy), FUNDING_BUDGET);
        assertEq(IERC20(source.usdc).balanceOf(source.legacyProxy), sourceBefore);
        bytes32 fundingKey = _fundingKey(source);
        assertEq(IRateLimits(source.legacyLimits).getCurrentRateLimit(fundingKey), 0);
        assertEq(IRateLimits(source.legacyLimits).getRateLimitData(fundingKey).slope, 0);

        ISegregatedPAUController controller = ISegregatedPAUController(source.fresh.controller);
        _actorCall(
            source,
            abi.encodeCall(ISegregatedPAUController.cctp_transfer, (BRIDGE_AMOUNT, destination.circleDomain, uint64(0)))
        );
        assertEq(IERC20(source.usdc).balanceOf(source.fresh.proxy), FUNDING_BUDGET - BRIDGE_AMOUNT);
        assertEq(IERC20(source.usdc).allowance(source.fresh.proxy, source.messenger), 0);
        assertEq(
            IRateLimits(source.fresh.rateLimits).getCurrentRateLimit(controller.cctp_toCCTPRateLimitKey()),
            FUNDING_BUDGET - BRIDGE_AMOUNT
        );
        assertEq(
            IRateLimits(source.fresh.rateLimits)
                .getCurrentRateLimit(controller.cctp_getToDomainRateLimitKey(destination.circleDomain)),
            FUNDING_BUDGET - BRIDGE_AMOUNT
        );
        _actorCall(
            source,
            abi.encodeCall(
                ISegregatedPAUController.transferAsset_transfer,
                (source.usdc, source.legacyProxy, FUNDING_BUDGET - BRIDGE_AMOUNT)
            )
        );
        assertEq(IERC20(source.usdc).balanceOf(source.fresh.proxy), 0);
        assertEq(IERC20(source.usdc).balanceOf(source.legacyProxy), sourceBefore + FUNDING_BUDGET - BRIDGE_AMOUNT);
        skip(30 days);
        assertEq(IRateLimits(source.legacyLimits).getCurrentRateLimit(fundingKey), 0);
        vm.startPrank(RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        ILegacyFundingController(source.legacyController).transferAsset(source.usdc, source.fresh.proxy, 1);
        vm.stopPrank();
        _assertIsolated(source);

        bridge.relayMessagesToDestination(true);
        assertEq(IERC20(destination.usdc).balanceOf(destination.legacyProxy), destinationBefore + BRIDGE_AMOUNT);
        assertEq(IERC20(destination.usdc).balanceOf(destination.fresh.proxy), 0);
        _assertIsolated(destination);
        _useLegacyLiquidity(destinationIndex, destinationBefore);
    }

    function _useLegacyLiquidity(uint256 destinationIndex, uint256 usdcBefore) internal {
        ChainContext storage destination = chains[destinationIndex];
        ILegacyPSMController legacy = ILegacyPSMController(destination.legacyController);
        if (destinationIndex == 0) {
            uint256 usdsBefore = IERC20(Ethereum.USDS).balanceOf(destination.legacyProxy);
            vm.prank(RELAYER);
            legacy.swapUSDCToUSDS(BRIDGE_AMOUNT);
            assertEq(IERC20(destination.usdc).balanceOf(destination.legacyProxy), usdcBefore);
            assertEq(IERC20(Ethereum.USDS).balanceOf(destination.legacyProxy), usdsBefore + BRIDGE_AMOUNT * 1e12);
        } else {
            vm.startPrank(RELAYER);
            uint256 shares = legacy.depositPSM(destination.usdc, BRIDGE_AMOUNT);
            assertGt(shares, 0);
            assertEq(IERC20(destination.usdc).balanceOf(destination.legacyProxy), usdcBefore);
            assertEq(legacy.withdrawPSM(destination.usdc, BRIDGE_AMOUNT), BRIDGE_AMOUNT);
            vm.stopPrank();
            assertEq(IERC20(destination.usdc).balanceOf(destination.legacyProxy), usdcBefore + BRIDGE_AMOUNT);
        }
    }

    function test_mainnetToArbitrum() public {
        _bridge(0, 1);
    }

    function test_arbitrumToMainnet() public {
        _bridge(1, 0);
    }

    function test_mainnetToBase() public {
        _bridge(0, 2);
    }

    function test_baseToMainnet() public {
        _bridge(2, 0);
    }
}
