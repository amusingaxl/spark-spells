// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import {ALMProxy} from "spark-alm-controller/src/ALMProxy.sol";
import {ForeignController} from "spark-alm-controller/src/ForeignController.sol";
import {RateLimits} from "spark-alm-controller/src/RateLimits.sol";
import {IALMProxy} from "spark-alm-controller/src/interfaces/IALMProxy.sol";
import {IRateLimits} from "spark-alm-controller/src/interfaces/IRateLimits.sol";
import {RateLimitHelpers} from "spark-alm-controller/src/RateLimitHelpers.sol";

import {Ethereum} from "spark-address-registry/Ethereum.sol";
import {Base} from "spark-address-registry/Base.sol";
import {Arbitrum} from "spark-address-registry/Arbitrum.sol";

import {SparkLiquidityLayerTests} from "src/test-harness/SparkLiquidityLayerTests.sol";

// A constructor argument prevents Foundry from running the inherited spell tests on this adapter.
contract FundingHarnessAdapter is SparkLiquidityLayerTests {
    constructor(bool) {}

    function runTransfer(TransferAssetE2ETestParams calldata params) external {
        _testTransferAssetIntegration(params);
    }

    function registerFunding(uint256 chainId, address destination) external {
        _registerSegregatedFunding(chainId, destination);
    }

    function preIntegrations() external view returns (SLLIntegration[] memory) {
        return _getPreExecutionIntegrations();
    }

    function postIntegrations(SLLIntegration[] calldata integrations) external view returns (SLLIntegration[] memory) {
        return _getPostExecutionIntegrations(integrations);
    }

    function legacyContext() external view returns (SparkLiquidityLayerContext memory) {
        return _getSparkLiquidityLayerContext();
    }
}

contract SegregatedFundingHarnessTest is Test {
    FundingHarnessAdapter internal harness;
    ForeignController internal controller;
    ALMProxy internal proxy;
    RateLimits internal limits;
    ERC20Mock internal token;

    address internal relayer = address(0x123);
    address internal destination = address(0x456);
    bytes32 internal key;

    function setUp() public {
        harness = FundingHarnessAdapter(
            vm.deployCode("SegregatedFundingHarness.t.sol:FundingHarnessAdapter", abi.encode(true))
        );
        token = new ERC20Mock();
        proxy = new ALMProxy(address(this));
        limits = new RateLimits(address(this));
        controller = new ForeignController(
            address(this), address(proxy), address(limits), address(0), address(token), address(0)
        );
        proxy.grantRole(proxy.CONTROLLER(), address(controller));
        limits.grantRole(limits.CONTROLLER(), address(controller));
        controller.grantRole(controller.RELAYER(), relayer);
        key = RateLimitHelpers.makeAddressAddressKey(controller.LIMIT_ASSET_TRANSFER(), address(token), destination);
    }

    function _runTransfer(uint256 amount) internal {
        harness.runTransfer(
            SparkLiquidityLayerTests.TransferAssetE2ETestParams({
                ctx: SparkLiquidityLayerTests.SparkLiquidityLayerContext({
                    controller: address(controller),
                    prevController: address(0),
                    proxy: IALMProxy(address(proxy)),
                    rateLimits: IRateLimits(address(limits)),
                    relayer: relayer,
                    freezer: address(0)
                }),
                asset: address(token),
                destination: destination,
                transferKey: key,
                transferAmount: amount
            })
        );
    }

    function test_finiteFundingDoesNotRecharge() public {
        limits.setRateLimitData(key, 1_000e18, 0);
        _runTransfer(400e18);
        assertEq(limits.getCurrentRateLimit(key), 600e18);
        assertEq(token.balanceOf(destination), 400e18);
    }

    function test_registeredFundingUsesAvailableBudget() public {
        vm.chainId(8453);
        harness.registerFunding(block.chainid, destination);
        limits.setRateLimitData(key, 250e18, 0);
        _runTransfer(400e18);
        assertEq(token.balanceOf(destination), 250e18);
        assertEq(limits.getCurrentRateLimit(key), 0);
    }

    function _mockFunding(uint256 chainId, uint256 maxAmount) internal returns (bytes32 fundingKey) {
        vm.chainId(chainId);
        address legacyController =
            chainId == 1 ? Ethereum.ALM_CONTROLLER : chainId == 8453 ? Base.ALM_CONTROLLER : Arbitrum.ALM_CONTROLLER;
        address legacyLimits =
            chainId == 1 ? Ethereum.ALM_RATE_LIMITS : chainId == 8453 ? Base.ALM_RATE_LIMITS : Arbitrum.ALM_RATE_LIMITS;
        address usdc = chainId == 1 ? Ethereum.USDC : chainId == 8453 ? Base.USDC : Arbitrum.USDC;
        address[5] memory vaults = [
            Ethereum.SPARK_VAULT_V2_SPETH,
            Ethereum.SPARK_VAULT_V2_SPUSDC,
            Ethereum.SPARK_VAULT_V2_SPUSDT,
            Ethereum.SPARK_VAULT_V2_SPPYUSD,
            Arbitrum.SPARK_VAULT_V2_SPUSDT
        ];
        for (uint256 i = 0; i < vaults.length; ++i) {
            vm.etch(vaults[i], hex"00");
            vm.mockCall(vaults[i], abi.encodeWithSignature("asset()"), abi.encode(usdc));
        }
        vm.etch(legacyController, hex"00");
        vm.mockCall(legacyController, bytes(""), abi.encode(bytes32(uint256(1))));
        vm.etch(legacyLimits, hex"00");
        fundingKey = RateLimitHelpers.makeAddressAddressKey(bytes32(uint256(1)), usdc, destination);
        vm.mockCall(
            legacyLimits,
            abi.encodeCall(IRateLimits.getRateLimitData, (fundingKey)),
            abi.encode(IRateLimits.RateLimitData(maxAmount, 0, maxAmount, block.timestamp))
        );
        harness.registerFunding(chainId, destination);
    }

    function _countFunding(SparkLiquidityLayerTests.SLLIntegration[] memory integrations, bytes32 fundingKey)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i = 0; i < integrations.length; ++i) {
            if (integrations[i].entryId == fundingKey) ++count;
        }
    }

    function test_activeFundingCoveredOnceBeforeAndAfterExecution() public {
        uint256[3] memory chains = [uint256(1), 8453, 42161];
        for (uint256 i = 0; i < chains.length; ++i) {
            bytes32 fundingKey = _mockFunding(chains[i], 100_000e6);
            SparkLiquidityLayerTests.SLLIntegration[] memory integrations = harness.preIntegrations();
            assertEq(_countFunding(integrations, fundingKey), 1);
            integrations = harness.postIntegrations(integrations);
            assertEq(_countFunding(integrations, fundingKey), 1);
            address legacyProxy =
                chains[i] == 1 ? Ethereum.ALM_PROXY : chains[i] == 8453 ? Base.ALM_PROXY : Arbitrum.ALM_PROXY;
            assertEq(address(harness.legacyContext().proxy), legacyProxy);
        }
    }

    function test_fundingOnlyAppearsAfterActivation() public {
        bytes32 fundingKey = _mockFunding(1, 0);
        SparkLiquidityLayerTests.SLLIntegration[] memory integrations = harness.preIntegrations();
        assertEq(_countFunding(integrations, fundingKey), 0);
        _mockFunding(1, 100_000e6);
        assertEq(_countFunding(harness.postIntegrations(integrations), fundingKey), 1);
    }

    function test_unregisteredHarnessKeepsLegacyCoverage() public {
        bytes32 fundingKey = _mockFunding(1, 100_000e6);
        FundingHarnessAdapter legacyHarness = FundingHarnessAdapter(
            vm.deployCode("SegregatedFundingHarness.t.sol:FundingHarnessAdapter", abi.encode(true))
        );
        SparkLiquidityLayerTests.SLLIntegration[] memory integrations = legacyHarness.preIntegrations();
        assertEq(integrations.length, 65);
        assertEq(_countFunding(integrations, fundingKey), 0);
        assertEq(legacyHarness.postIntegrations(integrations).length, 46);
        assertEq(address(legacyHarness.legacyContext().proxy), Ethereum.ALM_PROXY);
    }

    function test_disabledFundingRemovedFromPostExecutionCoverage() public {
        bytes32 fundingKey = _mockFunding(1, 100_000e6);
        SparkLiquidityLayerTests.SLLIntegration[] memory integrations = harness.preIntegrations();
        assertEq(_countFunding(integrations, fundingKey), 1);
        _mockFunding(1, 0);
        assertEq(_countFunding(harness.preIntegrations(), fundingKey), 0);
        assertEq(_countFunding(harness.postIntegrations(integrations), fundingKey), 0);
    }

    function test_replenishingTransferStillRecharges() public {
        limits.setRateLimitData(key, 1_000e18, uint256(1_000e18) / 1 days);
        _runTransfer(400e18);
        assertEq(limits.getCurrentRateLimit(key), 1_000e18);
    }

    function test_unlimitedTransferRemainsUnlimited() public {
        limits.setUnlimitedRateLimitData(key);
        _runTransfer(400e18);
        assertEq(limits.getCurrentRateLimit(key), type(uint256).max);
    }
}
