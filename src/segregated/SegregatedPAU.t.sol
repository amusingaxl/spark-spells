// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {Test} from "../../lib/forge-std/src/Test.sol";

import {Beacon} from "../../lib/diamond-pau/src/Beacon.sol";
import {PAUFactory} from "../../lib/diamond-pau/src/PAUFactory.sol";
import {AccessControls} from "../../lib/diamond-pau/src/AccessControls.sol";
import {ALMProxy} from "../../lib/diamond-pau/src/ALMProxy.sol";
import {RateLimits} from "../../lib/diamond-pau/src/RateLimits.sol";
import {IFacet} from "../../lib/diamond-pau/src/facets/IFacet.sol";
import {CCTPFacet} from "../../lib/diamond-pau/src/facets/cctp/CCTPFacet.sol";
import {ICCTPFacet} from "../../lib/diamond-pau/src/facets/cctp/ICCTPFacet.sol";
import {TransferAssetFacet} from "../../lib/diamond-pau/src/facets/transfer-asset/TransferAssetFacet.sol";
import {ITransferAssetFacet} from "../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetFacet.sol";
import {IController} from "../../lib/diamond-pau/src/interfaces/IController.sol";
import {IEnumerableIntegrations} from "../../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";
import {SegregatedPAU, ISegregatedPAUController} from "./SegregatedPAU.sol";
import {SegregatedPAUPayload} from "./SegregatedPAUPayload.sol";

import {AdministeredAgent} from "../../lib/pau-administered-agent/src/AdministeredAgent.sol";
import {IAdministeredAgent} from "../../lib/pau-administered-agent/src/interfaces/IAdministeredAgent.sol";
import {AdministeredAgentFactory} from "../../lib/pau-administered-agent/src/AdministeredAgentFactory.sol";

import {ALMProxy as LegacyProxy} from "../../lib/spark-alm-controller/src/ALMProxy.sol";
import {RateLimits as LegacyRateLimits} from "../../lib/spark-alm-controller/src/RateLimits.sol";

contract FundingToken {
    mapping(address => uint256) public balanceOf;

    function mint(address receiver, uint256 amount) external {
        balanceOf[receiver] += amount;
    }

    function transfer(address receiver, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[receiver] += amount;
        return true;
    }
}

// The funding operation uses the existing legacy proxy and rate-limit implementation.
contract LegacyFundingController {
    bytes32 public constant LIMIT_ASSET_TRANSFER = keccak256("LIMIT_ASSET_TRANSFER");
    LegacyProxy public immutable proxy;
    LegacyRateLimits public immutable rateLimits;
    address public immutable relayer;

    constructor(LegacyProxy proxy_, LegacyRateLimits rateLimits_, address relayer_) {
        proxy = proxy_;
        rateLimits = rateLimits_;
        relayer = relayer_;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == keccak256("RELAYER") && account == relayer;
    }

    function transferAsset(address asset, address destination, uint256 amount) external {
        require(msg.sender == relayer, "not-relayer");
        rateLimits.triggerRateLimitDecrease(keccak256(abi.encode(LIMIT_ASSET_TRANSFER, asset, destination)), amount);
        bytes memory result = proxy.doCall(asset, abi.encodeCall(FundingToken.transfer, (destination, amount)));
        require(abi.decode(result, (bool)), "transfer-failed");
    }
}

contract SegregatedPAUTest is Test {
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    uint256 internal constant FUNDING_BUDGET = 1_000e6;

    address internal relayer;
    address internal backstop;
    address internal freezer;
    FundingToken internal usdc;
    LegacyProxy internal legacyProxy;
    LegacyRateLimits internal legacyLimits;
    LegacyFundingController internal legacyController;
    ALMProxy internal proxy;
    RateLimits internal rateLimits;
    AccessControls internal accessControls;
    AdministeredAgent internal agent;
    ISegregatedPAUController internal controller;
    PAUFactory internal factory;
    AdministeredAgentFactory internal agentFactory;
    SegregatedPAU.Instance internal instance;

    function setUp() public {
        relayer = makeAddr("relayer");
        backstop = makeAddr("backstop");
        freezer = makeAddr("freezer");
        usdc = new FundingToken();
        legacyProxy = new LegacyProxy(address(this));
        legacyLimits = new LegacyRateLimits(address(this));
        legacyController = new LegacyFundingController(legacyProxy, legacyLimits, relayer);
        legacyProxy.grantRole(legacyProxy.CONTROLLER(), address(legacyController));
        legacyLimits.grantRole(legacyLimits.CONTROLLER(), address(legacyController));
        usdc.mint(address(legacyProxy), 2 * FUNDING_BUDGET);

        Beacon beacon = new Beacon(address(this));
        factory = new PAUFactory(address(beacon));
        agentFactory = new AdministeredAgentFactory();
        _wireFacets(beacon);
        _deployFresh();
        _onboard();
    }

    function _deployFresh() internal {
        instance = SegregatedPAU.deploy(address(factory), address(agentFactory), address(this));
        proxy = ALMProxy(payable(instance.proxy));
        rateLimits = RateLimits(instance.rateLimits);
        accessControls = AccessControls(instance.accessControls);
        agent = AdministeredAgent(payable(instance.agent));
        controller = ISegregatedPAUController(instance.controller);
    }

    function _wireFacets(Beacon beacon) internal {
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
            "CCTP_FACET",
            IEnumerableIntegrations.Config({
                facet: address(new CCTPFacet(makeAddr("CCTP V2 messenger"), address(usdc))), wires: wires
            })
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

    function _config() internal view returns (SegregatedPAU.Config memory config) {
        config.legacyController = address(legacyController);
        config.usdc = address(usdc);
        config.actors = new address[](2);
        config.actors[0] = relayer;
        config.actors[1] = backstop;
        config.freezer = freezer;
        config.fundingBudget = FUNDING_BUDGET;
        config.globalLimit = SegregatedPAU.RateLimit(500e6, 1e6);
        config.domains = new SegregatedPAU.Domain[](1);
        config.domains[0] = SegregatedPAU.Domain({
            domain: 6,
            mintRecipient: address(0xBEEF),
            minFeeCapRate: 0,
            maxFeeCapRate: 100,
            limit: SegregatedPAU.RateLimit(400e6, 1e6)
        });
    }

    function _onboard() internal {
        SegregatedPAU.initialize(instance, _config());
    }

    function initialize(SegregatedPAU.Config memory config) external {
        SegregatedPAU.initialize(instance, config);
    }

    function test_initializeRolesAndFunding() public view {
        assertTrue(proxy.hasRole(proxy.CONTROLLER(), address(controller)));
        assertTrue(rateLimits.hasRole(rateLimits.CONTROLLER(), address(controller)));
        assertTrue(accessControls.hasRole(ALLOCATOR_ROLE, address(agent)));
        assertFalse(accessControls.hasRole(ALLOCATOR_ROLE, relayer));
        assertTrue(agent.getIsActor(relayer));
        assertTrue(agent.getIsActor(backstop));
        assertTrue(agent.getIsRevoker(freezer));
        bytes32 key = _fundingKey();
        assertEq(legacyLimits.getRateLimitData(key).maxAmount, FUNDING_BUDGET);
        assertEq(legacyLimits.getRateLimitData(key).slope, 0);
        assertEq(legacyLimits.getCurrentRateLimit(key), FUNDING_BUDGET);
        key = controller.transferAsset_getTransferRateLimitKey(address(usdc), address(legacyProxy));
        assertEq(rateLimits.getCurrentRateLimit(key), type(uint256).max);
    }

    function _fundingKey() internal view returns (bytes32) {
        return keccak256(abi.encode(legacyController.LIMIT_ASSET_TRANSFER(), address(usdc), address(proxy)));
    }

    function _fund(uint256 amount) internal {
        vm.prank(relayer);
        legacyController.transferAsset(address(usdc), address(proxy), amount);
    }

    function _actorCall(bytes memory data) internal {
        vm.prank(relayer);
        agent.call(address(controller), data);
    }

    function _return(uint256 amount) internal {
        _actorCall(
            abi.encodeCall(
                ISegregatedPAUController.transferAsset_transfer, (address(usdc), address(legacyProxy), amount)
            )
        );
    }

    function test_initializeDomainAndAuthority() public view {
        assertEq(controller.proxy(), address(proxy));
        assertEq(controller.rateLimits(), address(rateLimits));
        assertEq(controller.accessControls(), address(accessControls));
        assertEq(accessControls.getRoleMemberCount(ALLOCATOR_ROLE), 1);
        assertEq(agent.actorCount(), 2);
        assertEq(agent.adminCount(), 1);
        assertTrue(agent.getIsAdmin(address(this)));
        assertFalse(agent.getIsActor(address(this)));
        assertFalse(accessControls.hasRole(bytes32(0), address(agent)));
        assertFalse(accessControls.hasRole(bytes32(0), freezer));
        assertFalse(legacyProxy.hasRole(legacyProxy.CONTROLLER(), address(controller)));
        assertFalse(legacyProxy.hasRole(legacyProxy.CONTROLLER(), address(agent)));
        assertFalse(legacyLimits.hasRole(legacyLimits.CONTROLLER(), address(controller)));
        assertFalse(legacyLimits.hasRole(legacyLimits.CONTROLLER(), address(agent)));
        assertFalse(legacyController.hasRole(keccak256("RELAYER"), address(agent)));
        assertFalse(legacyController.hasRole(keccak256("RELAYER"), address(controller)));
        assertTrue(legacyProxy.hasRole(legacyProxy.CONTROLLER(), address(legacyController)));
        assertTrue(legacyLimits.hasRole(legacyLimits.CONTROLLER(), address(legacyController)));
        assertEq(controller.integrations().length, 2);
        ICCTPFacet.DomainParameters memory params = controller.cctp_getDomainParameters(6);
        assertEq(params.mintRecipient, bytes32(uint256(uint160(address(0xBEEF)))));
        assertEq(params.minFeeCapRate, 0);
        assertEq(params.maxFeeCapRate, 100);
        assertEq(rateLimits.getCurrentRateLimit(controller.cctp_toCCTPRateLimitKey()), 500e6);
        assertEq(rateLimits.getCurrentRateLimit(controller.cctp_getToDomainRateLimitKey(6)), 400e6);
    }

    function test_fundingRemainsCumulativeAfterTimeAndReturns() public {
        _fund(200e6);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 800e6);
        _return(200e6);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 800e6);
        vm.warp(block.timestamp + 30 days);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 800e6);
        _fund(800e6);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 0);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _fund(1);
        assertEq(usdc.balanceOf(address(proxy)), 800e6);
        assertEq(usdc.balanceOf(address(legacyProxy)), 1_200e6);
    }

    function test_returnRemainsAvailableAfterFundingIsExhausted() public {
        _fund(FUNDING_BUDGET);
        _return(FUNDING_BUDGET);
        usdc.mint(address(proxy), 2 * FUNDING_BUDGET);
        _return(2 * FUNDING_BUDGET);
        assertEq(usdc.balanceOf(address(proxy)), 0);
        assertEq(usdc.balanceOf(address(legacyProxy)), 4 * FUNDING_BUDGET);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 0);
        bytes32 key = controller.transferAsset_getTransferRateLimitKey(address(usdc), address(legacyProxy));
        assertEq(rateLimits.getCurrentRateLimit(key), type(uint256).max);
    }

    function test_returnRejectsOtherRecipientsAndAssets() public {
        _fund(100e6);
        address recipient = makeAddr("unauthorized recipient");
        vm.expectRevert("RateLimits/zero-maxAmount");
        _actorCall(abi.encodeCall(ISegregatedPAUController.transferAsset_transfer, (address(usdc), recipient, 1e6)));
        FundingToken otherToken = new FundingToken();
        otherToken.mint(address(proxy), 100e6);
        vm.expectRevert("RateLimits/zero-maxAmount");
        _actorCall(
            abi.encodeCall(
                ISegregatedPAUController.transferAsset_transfer, (address(otherToken), address(legacyProxy), 1e6)
            )
        );
        assertEq(usdc.balanceOf(address(proxy)), 100e6);
        assertEq(usdc.balanceOf(recipient), 0);
        assertEq(otherToken.balanceOf(address(proxy)), 100e6);
        assertEq(otherToken.balanceOf(address(legacyProxy)), 0);
    }

    function test_unauthorizedCallersCannotOperate() public {
        _fund(100e6);
        bytes memory data = abi.encodeCall(
            ISegregatedPAUController.transferAsset_transfer, (address(usdc), address(legacyProxy), 100e6)
        );
        vm.expectRevert(IAdministeredAgent.NotActor.selector);
        agent.call(address(controller), data);
        vm.expectRevert(
            abi.encodeWithSelector(IFacet.AccessControlUnauthorizedAccount.selector, relayer, ALLOCATOR_ROLE)
        );
        vm.prank(relayer);
        controller.transferAsset_transfer(address(usdc), address(legacyProxy), 100e6);
        assertEq(usdc.balanceOf(address(proxy)), 100e6);
    }

    function test_agentCannotAdministerControllerOrAccessControls() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "CCTP_FACET";
        vm.expectRevert(abi.encodeWithSelector(IController.NotAdmin.selector, address(agent)));
        _actorCall(abi.encodeCall(IController.removeIntegrations, (ids)));
        vm.expectRevert(
            abi.encodeWithSelector(IFacet.AccessControlUnauthorizedAccount.selector, address(agent), bytes32(0))
        );
        _actorCall(
            abi.encodeCall(
                ISegregatedPAUController.cctp_setDomainParameters, (6, bytes32(uint256(uint160(relayer))), 0, 100)
            )
        );
        vm.expectRevert();
        vm.prank(relayer);
        agent.call(address(accessControls), abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), relayer));
        assertEq(controller.integrations().length, 2);
        assertFalse(accessControls.hasRole(bytes32(0), relayer));
    }

    function test_agentCannotSpendLegacyCustody() public {
        vm.expectRevert("not-relayer");
        vm.prank(relayer);
        agent.call(
            address(legacyController),
            abi.encodeCall(LegacyFundingController.transferAsset, (address(usdc), address(proxy), 1e6))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IFacet.AccessControlUnauthorizedAccount.selector, address(agent), legacyProxy.CONTROLLER()
            )
        );
        vm.prank(relayer);
        agent.call(
            address(legacyProxy),
            abi.encodeCall(LegacyProxy.doCall, (address(usdc), abi.encodeCall(FundingToken.transfer, (relayer, 1e6))))
        );
        assertEq(usdc.balanceOf(address(legacyProxy)), 2 * FUNDING_BUDGET);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), FUNDING_BUDGET);
    }

    function test_freezerCanRevokeButCannotGrantOrOperate() public {
        _fund(100e6);
        vm.prank(freezer);
        agent.removeActor(relayer);
        vm.expectRevert(IAdministeredAgent.NotActor.selector);
        _return(100e6);
        vm.expectRevert(IAdministeredAgent.NotGrantor.selector);
        vm.prank(freezer);
        agent.addActor(relayer);
        vm.expectRevert(IAdministeredAgent.NotActor.selector);
        vm.prank(freezer);
        agent.call(
            address(controller),
            abi.encodeCall(
                ISegregatedPAUController.transferAsset_transfer, (address(usdc), address(legacyProxy), 100e6)
            )
        );
        vm.prank(backstop);
        agent.call(
            address(controller),
            abi.encodeCall(
                ISegregatedPAUController.transferAsset_transfer, (address(usdc), address(legacyProxy), 100e6)
            )
        );
        assertEq(usdc.balanceOf(address(proxy)), 0);
    }

    function test_disablingCCTPPreservesReturnPath() public {
        _fund(100e6);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "CCTP_FACET";
        controller.removeIntegrations(ids);
        vm.expectRevert(
            abi.encodeWithSelector(
                IController.CallSelectorNotWired.selector, ISegregatedPAUController.cctp_transfer.selector
            )
        );
        _actorCall(abi.encodeCall(ISegregatedPAUController.cctp_transfer, (1e6, 6, 0)));
        _return(100e6);
        assertEq(controller.integrations().length, 1);
        assertEq(usdc.balanceOf(address(proxy)), 0);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 900e6);
    }

    function _assertUninitialized() internal view {
        assertFalse(proxy.hasRole(proxy.CONTROLLER(), address(controller)));
        assertFalse(rateLimits.hasRole(rateLimits.CONTROLLER(), address(controller)));
        assertEq(accessControls.getRoleMemberCount(ALLOCATOR_ROLE), 0);
        assertEq(agent.actorCount(), 0);
        assertEq(agent.revokerCount(), 0);
        assertEq(controller.integrations().length, 0);
        assertEq(legacyLimits.getRateLimitData(_fundingKey()).lastUpdated, 0);
    }

    function test_failedSecondDomainRollsBackWholeInitialization() public {
        _deployFresh();
        SegregatedPAU.Config memory config = _config();
        SegregatedPAU.Domain memory validDomain = config.domains[0];
        config.domains = new SegregatedPAU.Domain[](2);
        config.domains[0] = validDomain;
        config.domains[1] = validDomain;
        config.domains[1].domain = 3;
        config.domains[1].mintRecipient = address(0);
        vm.expectRevert("CCTPFacet/zero-recipient");
        this.initialize(config);
        _assertUninitialized();
        assertEq(rateLimits.getCurrentRateLimit(keccak256("LIMIT_USDC_TO_CCTP")), 0);
        assertEq(rateLimits.getCurrentRateLimit(keccak256(abi.encode(keccak256("LIMIT_USDC_TO_DOMAIN"), uint32(6)))), 0);
    }

    function test_duplicateDomainRejectedAtomically() public {
        _deployFresh();
        SegregatedPAU.Config memory config = _config();
        SegregatedPAU.Domain memory validDomain = config.domains[0];
        config.domains = new SegregatedPAU.Domain[](2);
        config.domains[0] = validDomain;
        config.domains[1] = validDomain;
        vm.expectRevert("SegregatedPAU/duplicate-domain");
        this.initialize(config);
        _assertUninitialized();
    }

    function test_wrongTokenRejectedAtomically() public {
        _deployFresh();
        SegregatedPAU.Config memory config = _config();
        config.usdc = address(new FundingToken());
        vm.expectRevert("SegregatedPAU/wrong-usdc");
        this.initialize(config);
        _assertUninitialized();
    }

    function test_invalidFundingBudgetsRejected() public {
        _deployFresh();
        SegregatedPAU.Config memory config = _config();
        config.fundingBudget = 0;
        vm.expectRevert("SegregatedPAU/invalid-funding-budget");
        this.initialize(config);
        config.fundingBudget = type(uint256).max;
        vm.expectRevert("SegregatedPAU/invalid-funding-budget");
        this.initialize(config);
        _assertUninitialized();
    }

    function test_legacyAuthorityRejected() public {
        _deployFresh();
        legacyProxy.grantRole(legacyProxy.CONTROLLER(), address(agent));
        vm.expectRevert("SegregatedPAU/legacy-authority");
        this.initialize(_config());
        _assertUninitialized();
    }

    function test_legacyAdministratorAuthorityRejected() public {
        _deployFresh();
        legacyProxy.grantRole(bytes32(0), address(agent));
        vm.expectRevert("SegregatedPAU/legacy-authority");
        this.initialize(_config());
        _assertUninitialized();
    }

    function test_legacyRelayerAuthorityRejected() public {
        _deployFresh();
        SegregatedPAU.Config memory config = _config();
        config.legacyController = address(new LegacyFundingController(legacyProxy, legacyLimits, address(agent)));
        vm.expectRevert("SegregatedPAU/legacy-authority");
        this.initialize(config);
        _assertUninitialized();
    }

    function test_preconfiguredFundingCannotBeReset() public {
        _deployFresh();
        legacyLimits.setRateLimitData(_fundingKey(), 0, 0);
        vm.expectRevert("SegregatedPAU/funding-already-configured");
        this.initialize(_config());
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 0);
        assertEq(controller.integrations().length, 0);
    }

    function test_reinitializeCannotRestoreSpentFunding() public {
        _fund(500e6);
        vm.expectRevert("SegregatedPAU/already-initialized");
        this.initialize(_config());
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 500e6);
    }

    function test_offboardingCannotEnableFundingReset() public {
        _fund(500e6);
        proxy.revokeRole(proxy.CONTROLLER(), address(controller));
        rateLimits.revokeRole(rateLimits.CONTROLLER(), address(controller));
        accessControls.revokeRole(ALLOCATOR_ROLE, address(agent));
        agent.removeActor(relayer);
        agent.removeActor(backstop);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = "CCTP_FACET";
        ids[1] = "TRANSFER_ASSET_FACET";
        controller.removeIntegrations(ids);
        vm.expectRevert("SegregatedPAU/funding-already-configured");
        this.initialize(_config());
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 500e6);
    }

    function test_payloadCannotExecuteOutsideGovernanceExecutor() public {
        _deployFresh();
        SegregatedPAUPayload payload = new SegregatedPAUPayload(address(this), instance, _config());
        vm.expectRevert("SegregatedPAUPayload/wrong-executor");
        payload.execute();
        _assertUninitialized();
    }

    function test_payloadDelegatecallUsesPayloadConfiguration() public {
        _deployFresh();
        SegregatedPAU.Config memory config = _config();
        config.fundingBudget = 500e6;
        config.domains[0].mintRecipient = address(0xCAFE);
        config.globalLimit.maxAmount = 123e6;
        SegregatedPAUPayload payload = new SegregatedPAUPayload(address(this), instance, config);
        bytes32 executorSlot = vm.load(address(this), bytes32(0));
        assertNotEq(executorSlot, vm.load(address(payload), bytes32(0)));
        (bool success, bytes memory result) =
            address(payload).delegatecall(abi.encodeCall(SegregatedPAUPayload.execute, ()));
        assertTrue(success, string(result));
        assertEq(vm.load(address(this), bytes32(0)), executorSlot);
        assertEq(controller.proxy(), address(proxy));
        assertTrue(accessControls.hasRole(ALLOCATOR_ROLE, address(agent)));
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 500e6);
        assertEq(rateLimits.getCurrentRateLimit(controller.cctp_toCCTPRateLimitKey()), 123e6);
        assertEq(controller.cctp_getDomainParameters(6).mintRecipient, bytes32(uint256(uint160(address(0xCAFE)))));
        _fund(200e6);
        _return(100e6);
        assertEq(usdc.balanceOf(address(proxy)), 100e6);
        assertEq(legacyLimits.getCurrentRateLimit(_fundingKey()), 300e6);
    }

    function test_payloadRejectsDelegatecallOnOtherChain() public {
        _deployFresh();
        SegregatedPAUPayload payload = new SegregatedPAUPayload(address(this), instance, _config());
        vm.chainId(block.chainid + 1);
        (bool success, bytes memory result) =
            address(payload).delegatecall(abi.encodeCall(SegregatedPAUPayload.execute, ()));
        assertFalse(success);
        assertEq(result, abi.encodeWithSignature("Error(string)", "SegregatedPAUPayload/wrong-chain"));
        _assertUninitialized();
    }
}
