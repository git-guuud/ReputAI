// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Canonical ENSv2 Sepolia deployment addresses.
///
/// Source: `lib/contracts-v2/contracts/docs/addresses/sepolia.md`, the auto-generated table from
/// the upstream deployment (chain 11155111, deployed 2026-06-29). Every address below was checked
/// to hold code on Sepolia before being written here — none of this is a mock, and none of it is
/// ours. We deploy *beneath* this tree; we do not replace any of it.
library SepoliaConfig {
    uint256 internal constant CHAIN_ID = 11155111;

    /// @notice The ENS root. This is the only address `CounterpartyVerifier` is handed — it walks
    ///         everything else itself, which is the point of T4.
    address internal constant ROOT_REGISTRY = 0x11b5BfbE9078D826b1eDBDd1cFC12f5828D9F50C;

    /// @notice The `.eth` registry. The operator name lives here.
    address internal constant ETH_REGISTRY = 0x67b728a792e789a8978b30cF1b3b641f19354b43;

    /// @notice Commit-reveal registrar for `.eth`. Payment is ERC-20 only; there is no ETH path.
    address internal constant ETH_REGISTRAR = 0xa4449a0dD2b83007553D9b1d28b583A46A805a30;

    /// @notice Shared label database, passed to every registry.
    address internal constant LABEL_STORE = 0xB03524289C16424f71802A1794c29c7Bd1B9f577;

    /// @notice CREATE2 proxy factory. Both of our proxies (operator registry, resolver) come from
    ///         it, which is how ENSv2 intends user-owned registries to be deployed.
    address internal constant VERIFIABLE_FACTORY = 0x118Bc31A50d559F7015a8Da26d54B3b030CdB70F;

    /// @notice `UserRegistry` implementation — a UUPS `PermissionedRegistry` meant to sit behind a
    ///         `VerifiableFactory` proxy. Our operator registry is one of these.
    address internal constant USER_REGISTRY_IMPL = 0x840Fa461059862Ea466A711E8C98c8dE732061C0;

    /// @notice `PermissionedResolver` implementation, same proxy pattern.
    address internal constant PERMISSIONED_RESOLVER_IMPL = 0x7E4B2d59938930168024201752EE5503df402303;

    /// @notice Mock USDC accepted by `StandardRentPriceOracle`. `mint()` is unpermissioned on
    ///         testnet, so rent costs the deployer nothing but gas. Marked explicitly: this is the
    ///         one mocked component in the deployment, and it is upstream's mock, not ours.
    address internal constant MOCK_USDC = 0xD3322B29a7BdEe707D1684676f149bf41Aa3422f;

    /// @notice Record keys the agent publishes and the verifier reads. `endpoint` is ours to pick;
    ///         the operating key is canonicalised by `AgentSandbox.OPERATING_KEY()` and read from
    ///         there rather than duplicated, so the three parties cannot disagree.
    string internal constant ENDPOINT_KEY = "agent:endpoint";
}
