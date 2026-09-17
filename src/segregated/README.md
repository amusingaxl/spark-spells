# Segregated CCTP custody

Deploy a fresh ALMProxy, Controller, RateLimits, AccessControls and AdministeredAgent on each supported chain. Existing investment positions and controllers remain in place. Independently verify the supplied PAUFactory/Beacon and AgentFactory against the pinned releases before use; this implementation does not deploy or hand over a Beacon.

- Funding: the existing relayer calls legacy `transferAsset(USDC, freshProxy, amount)`. Its destination-specific key has an approved finite budget and `slope = 0`. Time, local returns and incoming bridges never refill that budget. Changing it later is a new governance allocation.
- Bridging: the agent forwards an actor's `cctp_transfer` to the fresh Controller. Approved Circle domains mint to the remote **legacy** ALMProxy. Legacy investment and withdrawal operations continue there.
- Return: `transferAsset_transfer` permits local USDC only, to the local legacy ALMProxy, with an unlimited return key. Other asset/destination keys remain unset. A CCTP pause preserves the return integration. A revoked actor needs another approved actor or governance intervention to return funds.
- Permissions: only the agent has `ALLOCATOR_ROLE`; existing relayer/backstop are actors and existing freezer can revoke them. Neither fresh Controller nor agent receives legacy CONTROLLER, RELAYER or admin roles. Preserve this in subsequent spells. Proxy/RateLimits roles are not enumerable: verify factory deployment provenance and known current role getters instead of claiming full enumeration.

## Stage and activate

`script/DeploySegregatedPAU.s.sol` accepts verified factory addresses and an ABI-encoded `SegregatedPAU.Config`. It derives the component admin from the registry: Spark Proxy on Ethereum, Spark Executor on Arbitrum/Base. It stages five components and one activation payload without configuring integrations, granting allocator roles or funding custody. Deployment broadcasting requires separate operational authorization.

Configuration tuple:

```text
(address legacyController, address usdc, address[] actors, address freezer,
 uint256 fundingBudget, (uint256 maxAmount, uint256 slope) globalLimit,
 (uint32 domain, address mintRecipient, uint32 minFeeCapRate,
  uint32 maxFeeCapRate, (uint256 maxAmount, uint256 slope) limit)[] domains)
```

Use registry addresses for local controller, USDC, relayer/backstop in that order, and freezer. Circle domain 0 is Ethereum, 3 is Arbitrum and 6 is Base. Recipients must be the registry's remote legacy ALMProxy; the script rejects local or other recipients. Budgets use six USDC decimals, slopes use USDC base units per second, and fee-cap rates use the facet's 10,000 denominator. Risk/governance must supply the funding budget, bridge limits and fee bounds. No production values or deployment addresses are invented here.

Encode the complete tuple with native Cast:

```sh
cast abi-encode 'f((address,address,address[],address,uint256,(uint256,uint256),(uint32,address,uint32,uint32,(uint256,uint256))[]))' "$CONFIG_TUPLE"
```

Use its output as `ENCODED_CONFIG`. Dry-run staging on each chain with the matching RPC:

```sh
FOUNDRY_PROFILE=segregated forge script script/DeploySegregatedPAU.s.sol:DeploySegregatedPAU \
  --rpc-url "$RPC_URL" --sig 'run(address,address,bytes)' \
  "$PAU_FACTORY" "$AGENT_FACTORY" "$ENCODED_CONFIG"
```

Review returned addresses, the payload's `configuration()`, bytecode, dispatch wiring and admin ownership. Simulate **activation** with the intended configuration through existing governance before scheduling it; staging alone does not validate every activation parameter. Mainnet uses StarGuard/Spark Proxy; L2 uses the receiver/Executor queue. Queue `execute()` with delegatecall enabled. The payload checks chain/executor and reads its constructor configuration via immutable `SELF`, then atomically activates fresh permissions/integrations and creates the legacy funding key. Mainnet retains existing office hours. Re-execution and previously configured funding keys are rejected.

For a dated cross-chain spell, use existing mainnet forwarding/receiver helpers to schedule the chain-local payloads. Register each fresh proxy with `_registerSegregatedFunding(chainId, freshProxy)` in that spell's test setup. Existing pre/post coverage checks then include its active funding key and continue testing legacy investment integrations.

## Tests

The default profile remains Solidity 0.8.25. PAU v1.14.0 and AdministeredAgent v1.0.0 require the separate 0.8.34 profile. Existing CI adds only the segregated unit suite; fork checks run with separately configured RPCs.

```sh
forge test --match-contract SegregatedFundingHarnessTest -vv
FOUNDRY_PROFILE=segregated forge test --match-contract '^SegregatedPAUTest$' -vv
FOUNDRY_PROFILE=segregated forge test --match-contract '^SegregatedPAUForkTest$' -vv
```

Fork tests require `MAINNET_RPC_URL`, `ARBITRUM_ONE_RPC_URL` and `BASE_RPC_URL`. They check all four Ethereum/L2 directions through actual governance execution, legacy funding, CCTP V2, local returns and existing PSM operations. Test liquidity is seeded only into legacy custody. The existing Grove CCTP V2 helper bypasses Circle attestations and supplies signed nonce/finality fields: these test protocol flows, not attestations or the offchain relayer.

This branch does not deploy production contracts, reset budgets, migrate positions, replace legacy controllers or mandate later migration. Separate inbound allocations need separate governance limits: custody separation does not cap all money anyone may send to the fresh address.
