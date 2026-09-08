// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {IPermissionedResolver} from "~src/resolver/interfaces/IPermissionedResolver.sol";

/// @title AgentSandbox
/// @notice Provisions an agent-bound ENSv2 subname in a single call, with the IDEA.md §3.2
///         permission split baked in so a demo cannot get the sequence wrong.
///
/// The sandbox is deliberately *not* an authority of its own. It holds exactly two grants —
/// `ROLE_REGISTRAR` at the registry's root resource, and `ROLE_SET_TEXT_ADMIN` at the resolver's
/// — so:
///
///   - who may provision is decided by ENS (root `ROLE_REGISTRAR`), not by a local owner var;
///   - the sandbox receives no per-name roles, so it is not a backdoor into names it mints;
///   - `ROLE_SET_TEXT_ADMIN` is an *admin* nybble: it lets the sandbox delegate `ROLE_SET_TEXT`
///     for a named key without conferring any ability to write a record itself;
///   - the operator's kill switch (`ROLE_UNREGISTER`, finding 001) is untouched by its existence.
///
/// Its only job is to enforce the *shape* of an agent grant. Everything the caller supplies —
/// label, agent address, resolver, subregistry, requested roles, text-key allowlist, expiry —
/// is a parameter. The one thing that is not negotiable is the ceiling on what an agent may hold.
///
/// The grant has two tiers, and they pull in opposite directions on purpose (IDEA.md §3.2-3.3):
///
///   - at the **registry**, autonomy is defined by subtraction — see `AGENT_ROLE_CEILING`;
///   - at the **resolver**, autonomy is defined by addition — the agent gets `ROLE_SET_TEXT`
///     scoped to individual text keys it was provisioned with, and nothing else. `addr()`,
///     contenthash, pubkey, the reverse name and every non-listed text key stay with the
///     operator, because `provision()` never grants a role that would reach them.
contract AgentSandbox {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The complete set of registry-level roles a sandboxed agent may ever be granted.
    ///
    /// @dev This is an allowlist, not a denylist: `provision()` rejects any requested bit outside
    ///      it, so a role added to ENSv2 in future is withheld until it is deliberately admitted
    ///      here. The agent's real write surface lives one layer down, on the permissioned
    ///      resolver (IDEA.md §3.3) — at the registry level autonomy is defined by subtraction.
    ///
    ///      `ROLE_SET_SUBREGISTRY` is the sole admitted role: it lets an orchestrator point its
    ///      name at a child registry to spawn workers (IDEA.md §3.4) without granting it anything
    ///      over its own name. Notably withheld, and why:
    ///
    ///      - `ROLE_SET_RESOLVER`        — repointing the resolver rewrites every record at once,
    ///                                     `addr()` included. The escalation path (IDEA.md §3.2).
    ///      - `ROLE_UNREGISTER`          — *is* the operator kill switch; an agent holding it could
    ///                                     destroy its own identity (finding 001).
    ///      - `ROLE_RENEW`               — the lease is the operator's to extend, not the agent's.
    ///      - every admin nybble         — including `ROLE_CAN_TRANSFER_ADMIN`, which gates ERC1155
    ///                                     transfer, and the `*_ADMIN` bits that would let the
    ///                                     agent grant roles to itself or to anyone else.
    ///      - the root-only roles        — `ROLE_REGISTRAR`, `ROLE_REGISTER_RESERVED`,
    ///                                     `ROLE_SET_PARENT`, `ROLE_SET_URI`, `ROLE_CAN_NAME`,
    ///                                     `ROLE_UPGRADE`: registry-wide, never per-agent.
    uint256 public constant AGENT_ROLE_CEILING = RegistryRolesLib.ROLE_SET_SUBREGISTRY;

    /// @notice The canonical text key an agent publishes its current operating key under.
    ///
    /// @dev A *convention*, not a constraint. `provision()` neither requires nor implies it: an
    ///      agent that should not rotate simply never receives this key in its allowlist, and one
    ///      that should gets it like any other. It lives here so the three parties that must agree
    ///      on which record carries the signing key — the agent, the operator's watcher, and the
    ///      counterparty verifier (IDEA.md §3.5) — read it from one place instead of three.
    ///
    ///      **Value format.** The 0x-prefixed, 20-byte hex address of the secp256k1 key the agent
    ///      currently signs with: what `ecrecover` returns, compared case-insensitively so an
    ///      EIP-55 checksummed form is equally valid. An address rather than a public key, because
    ///      an address is what a verifier recovers from a signature.
    ///
    ///      **Why a text key and not the `pubkey` record.** `pubkey` is the obvious home for a
    ///      signing credential and cannot be used: `setPubkey` checks `onlyPartRoles(node, 0,
    ///      ROLE_SET_PUBKEY)` — part `0`, the name-wide resource — and the resolver ships no
    ///      `authorizePubkeyRoles` to scope it any tighter. Granting it would hand the agent a
    ///      permission the operator cannot narrow. ENSv2 scopes per part only where an
    ///      `authorize*Roles` helper exists: text (by key), data (by key) and addr (by coin
    ///      type). Text is the one of those every ENS client already reads, so the rotatable
    ///      credential lives there.
    ///
    ///      **Rotation safety.** Rotations are deliberately *not* rate-limited; the operator-side
    ///      lever is the `TextChanged(node, keccak256(OPERATING_KEY), ...)` event a watcher
    ///      filters on, backed by per-key revocation. Reasoning recorded in IDEA.md §6.
    string public constant OPERATING_KEY = "agent:operating-key";

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The parent registry this sandbox mints agent subnames into.
    IPermissionedRegistry public immutable REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice The DNS-encoded name of `REGISTRY` — e.g. `\x08operator\x03eth\x00`.
    ///
    /// @dev Set once in the constructor and never written again; `bytes` cannot be `immutable`.
    ///      The registry addresses names by labelhash and has no idea what it is called, but the
    ///      resolver scopes every permission by *namehash*, so the sandbox has to know the parent
    ///      name to authorize anything. Supplying it at construction rather than per call keeps
    ///      the two layers from silently disagreeing about which name they are talking about.
    bytes public PARENT_NAME;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice An agent subname was provisioned.
    /// @param tokenId The ERC1155 token ID of the minted name.
    /// @param resource The EAC resource the agent's roles are scoped to.
    /// @param agent The agent that received the name.
    /// @param label The label minted under the parent registry.
    /// @param resolver The permissioned resolver the name was wired to.
    /// @param roleBitmap The registry roles granted to the agent.
    /// @param textKeys The text keys the agent may write on the resolver.
    /// @param expiry The lease expiry.
    event AgentProvisioned(
        uint256 indexed tokenId,
        uint256 indexed resource,
        address indexed agent,
        string label,
        address resolver,
        uint256 roleBitmap,
        string[] textKeys,
        uint64 expiry
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Caller does not hold `ROLE_REGISTRAR` at the registry's root resource.
    error NotRegistrar(address caller);

    /// @notice The requested role bitmap contains bits outside `AGENT_ROLE_CEILING`.
    /// @param requested The bitmap the caller asked for.
    /// @param exceeded The offending bits (`requested & ~AGENT_ROLE_CEILING`).
    error RoleBitmapExceedsCeiling(uint256 requested, uint256 exceeded);

    /// @notice A sandboxed name must be owned by an agent; `address(0)` would reserve it instead.
    error AgentRequired();

    /// @notice The resolver must be a live `IPermissionedResolver`; the record-level tier
    ///         (IDEA.md §3.3) is what gives the agent any autonomy at all.
    error NotPermissionedResolver(address resolver);

    /// @notice A text key the agent is allowed to write must not be empty: the empty key is a
    ///         real, writable record, and allowlisting it by accident is not something a caller
    ///         should be able to do silently.
    error EmptyTextKey(uint256 index);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param registry The parent registry. The sandbox must be granted root `ROLE_REGISTRAR`
    ///                 on it by the operator before `provision()` will succeed.
    /// @param parentName The DNS-encoded name of `registry`, used to derive the namehash the
    ///                   resolver scopes permissions by.
    ///
    /// @dev The sandbox also needs root `ROLE_SET_TEXT_ADMIN` on each resolver it is asked to
    ///      wire, granted by that resolver's own admin. That is the *only* authority it holds
    ///      there, and it is an admin nybble: it lets the sandbox hand `ROLE_SET_TEXT` to an
    ///      agent for a named key, but never lets the sandbox write a record itself.
    constructor(IPermissionedRegistry registry, bytes memory parentName) {
        REGISTRY = registry;
        NameCoder.namehash(parentName, 0); // reverts `DNSDecodingFailed` on a malformed name
        PARENT_NAME = parentName;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Provision a sandboxed identity for an agent: register the subname, grant the
    ///         agent its (ceiling-checked) role bitmap, wire the permissioned resolver, and
    ///         authorize the agent's text-key allowlist on it — atomically, so the name never
    ///         exists in a half-configured state.
    /// @param label The label to mint under the parent registry.
    /// @param agent The agent that will operate — but not own — the identity.
    /// @param resolver The permissioned resolver holding the agent's records.
    /// @param subregistry The child registry for the agent's own subtree, or `address(0)` for none.
    /// @param roleBitmap The registry roles to grant the agent. Must be a subset of
    ///                   `AGENT_ROLE_CEILING`; `0` is valid and is the tightest sandbox.
    /// @param textKeys The text keys the agent may write on `resolver` — its whole write surface
    ///                 (IDEA.md §3.3). Per-provisioning, not a constant: a status-only agent and
    ///                 one that rotates an operating key get different lists. An empty array is
    ///                 valid and gives an agent that can publish nothing.
    /// @param expiry The lease expiry.
    /// @return tokenId The ERC1155 token ID of the minted name.
    function provision(
        string calldata label,
        address agent,
        address resolver,
        IRegistry subregistry,
        uint256 roleBitmap,
        string[] calldata textKeys,
        uint64 expiry
    )
        external
        returns (uint256 tokenId)
    {
        if (!REGISTRY.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, msg.sender)) {
            revert NotRegistrar(msg.sender);
        }
        if (agent == address(0)) {
            revert AgentRequired();
        }
        uint256 exceeded = roleBitmap & ~AGENT_ROLE_CEILING;
        if (exceeded != 0) {
            revert RoleBitmapExceedsCeiling(roleBitmap, exceeded);
        }
        if (!ERC165Checker.supportsInterface(resolver, type(IPermissionedResolver).interfaceId)) {
            revert NotPermissionedResolver(resolver);
        }

        tokenId = REGISTRY.register(label, agent, subregistry, resolver, roleBitmap, expiry);

        // The record-level tier. `authorizeTextRoles` scopes `ROLE_SET_TEXT` to
        // `resource(namehash, keccak256(key))`, so the agent's write permission exists for
        // exactly these keys and nowhere else — a key that was never listed has no role holder
        // at all, and `setText` on it falls through to the name-wide resource the agent is
        // absent from. Nothing here can reach `addr()`: that is a different role entirely
        // (`ROLE_SET_ADDR`), which `provision()` never grants to anyone.
        bytes memory name = NameCoder.addLabel(PARENT_NAME, label);
        for (uint256 i; i < textKeys.length; ++i) {
            if (bytes(textKeys[i]).length == 0) {
                revert EmptyTextKey(i);
            }
            PermissionedResolver(resolver).authorizeTextRoles(name, textKeys[i], agent, true);
        }

        emit AgentProvisioned(
            tokenId,
            REGISTRY.getResource(tokenId),
            agent,
            label,
            resolver,
            roleBitmap,
            textKeys,
            expiry
        );
    }
}
