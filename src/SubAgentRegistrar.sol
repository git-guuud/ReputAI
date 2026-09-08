// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {AgentSandbox} from "./AgentSandbox.sol";

import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @title SubAgentRegistrar
/// @notice Lets an orchestrator agent spawn workers beneath its own name (IDEA.md §3.4), with
///         every grant provably attenuated: a worker can never hold a permission, a record key,
///         or a lease that the orchestrator does not itself hold.
///
/// **Why this contract has to exist.** IDEA.md §3.4 originally claimed attenuation was "enforced
/// by the registry hierarchy, not by our code". Reading the deployed contracts says otherwise, and
/// the correction is the interesting part of T5. `PermissionedRegistry.register()` grants the new
/// owner its role bitmap through `_grantRoles(resource, roleBitmap, owner, false)` — bypassing the
/// `canGrantRoles` modifier that governs every *later* grant. A caller holding nothing but root
/// `ROLE_REGISTRAR` in a registry can therefore mint a name carrying roles it does not hold
/// itself; the admin-nybble check that stops privilege escalation after registration does not
/// apply at registration. Asserted directly in `test/SubAgentHierarchy.t.sol`.
///
/// That is a sane protocol decision — a registrar is meant to be able to mint fully-powered names
/// — but it means "workers are a subset of their orchestrator" is an application-level invariant.
/// This contract is that invariant, in one place, checked against live state rather than against
/// a snapshot taken when the orchestrator was provisioned.
///
/// **What it is not.** It is not an authority. Like `AgentSandbox`, it holds no per-name roles and
/// no owner variable: the only thing it can do is call the child registry's sandbox, and it does
/// that only for the current owner of the orchestrator's name. Kill the orchestrator and the
/// registrar is inert — `getOwner()` returns `address(0)` for an unregistered or expired name, so
/// there is nobody it will act for. The fleet cannot outlive its parent, and cannot grow after it.
///
/// **Attenuation is checked in three dimensions**, all against the orchestrator's *current* state
/// in the parent registry:
///
///   - **Registry roles** — the requested bitmap must be a subset of the roles the orchestrator
///     holds at its own name's resource. Root roles do not count: what is delegated is the
///     orchestrator's grant over itself, not any registry-wide authority it happens to have.
///   - **Record keys** — every text key the worker may write must be a key the orchestrator may
///     write, checked on the orchestrator's own resolver at
///     `resource(orchestratorNode, keccak256(key))`. This is T2's tier, inherited: an orchestrator
///     allowed to publish an endpoint and rotate a key cannot hand a worker the right to publish
///     an avatar, let alone anything it was denied itself.
///   - **Lease** — a worker's expiry cannot exceed the orchestrator's. Reachability already
///     bounds it (an expired parent severs the subtree), but a lease that outlives its parent is
///     a claim nobody can honour, and refusing it keeps the hierarchy's arithmetic honest.
///
/// Everything else — the role ceiling, the permissioned-resolver requirement, the per-key
/// authorization, the atomic mint — is `AgentSandbox`'s job and is reused verbatim rather than
/// reimplemented. This contract adds exactly one thing: the subset proof.
contract SubAgentRegistrar {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The sandbox that mints into the orchestrator's own child registry.
    /// @dev Must hold root `ROLE_REGISTRAR` on that registry, and root `ROLE_SET_TEXT_ADMIN` on
    ///      any resolver it is asked to wire — the same wiring `AgentSandbox` always needs. This
    ///      registrar must additionally hold root `ROLE_REGISTRAR` there, because that is what
    ///      `AgentSandbox.provision()` checks of *its* caller.
    AgentSandbox public immutable SANDBOX;

    /// @notice The registry holding the orchestrator's own name — one tier up from the workers.
    IPermissionedRegistry public immutable PARENT_REGISTRY;

    /// @notice The namehash of the orchestrator's name, for resolver-tier lookups.
    bytes32 public immutable ORCHESTRATOR_NODE;

    /// @notice `labelhash` of the orchestrator's label, for registry-tier lookups.
    uint256 public immutable ORCHESTRATOR_ID;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice The orchestrator's label within `PARENT_REGISTRY` — e.g. `agent-404`.
    /// @dev Derived from the sandbox's parent name, never passed in, so the two cannot disagree.
    string public ORCHESTRATOR_LABEL;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice A worker was spawned beneath the orchestrator.
    /// @param tokenId The ERC1155 token ID of the worker's name in the child registry.
    /// @param orchestrator The orchestrator that spawned it — the owner of the parent name.
    /// @param worker The address the worker name was minted to.
    /// @param label The worker's label.
    /// @param roleBitmap The registry roles granted, already proved a subset of the orchestrator's.
    /// @param textKeys The text keys the worker may write, each one the orchestrator may write too.
    /// @param expiry The worker's lease, no later than the orchestrator's.
    event WorkerSpawned(
        uint256 indexed tokenId,
        address indexed orchestrator,
        address indexed worker,
        string label,
        uint256 roleBitmap,
        string[] textKeys,
        uint64 expiry
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Only the current owner of the orchestrator's name may spawn workers.
    /// @param caller The address that tried.
    /// @param orchestrator The current owner, or `address(0)` if the name is revoked or expired.
    error NotOrchestrator(address caller, address orchestrator);

    /// @notice The requested roles are not a subset of the orchestrator's own.
    /// @param requested The bitmap asked for.
    /// @param held The orchestrator's roles at its own name.
    /// @param exceeded The offending bits (`requested & ~held`).
    error RolesExceedOrchestrator(uint256 requested, uint256 held, uint256 exceeded);

    /// @notice The orchestrator may not write this text key itself, so it cannot delegate it.
    /// @param index Position in the `textKeys` array.
    /// @param key The offending key.
    error TextKeyExceedsOrchestrator(uint256 index, string key);

    /// @notice The worker's lease would outlive the orchestrator's.
    error ExpiryExceedsOrchestrator(uint64 requested, uint64 orchestratorExpiry);

    /// @notice The child registry is no longer the subregistry of the orchestrator's name, so
    ///         anything minted into it would be unreachable from the ENS root.
    error SubtreeDetached(address expected, address actual);

    /// @notice The orchestrator's name has no resolver, so no text key can be attenuated against
    ///         it. Provisioning a worker with no keys at all is still allowed.
    error OrchestratorHasNoResolver();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param sandbox The sandbox for the orchestrator's child registry. Its `PARENT_NAME` *is*
    ///                the orchestrator's full name, which is where this contract learns which
    ///                name it serves — one source of truth instead of two.
    /// @param parentRegistry The registry the orchestrator's own name lives in.
    constructor(AgentSandbox sandbox, IPermissionedRegistry parentRegistry) {
        SANDBOX = sandbox;
        PARENT_REGISTRY = parentRegistry;

        bytes memory orchestratorName = sandbox.PARENT_NAME();
        (string memory label, ) = NameCoder.extractLabel(orchestratorName, 0);
        ORCHESTRATOR_LABEL = label;
        ORCHESTRATOR_ID = LibLabel.id(label);
        ORCHESTRATOR_NODE = NameCoder.namehash(orchestratorName, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Spawn a worker beneath the orchestrator's name, attenuated to it.
    /// @param label The worker's label in the child registry.
    /// @param worker The address that will operate the worker identity.
    /// @param resolver The permissioned resolver holding the worker's records.
    /// @param subregistry The worker's own child registry, or `address(0)` — a worker may only
    ///                    have one if it was granted `ROLE_SET_SUBREGISTRY`, which requires the
    ///                    orchestrator to hold it, which makes the recursion terminate honestly.
    /// @param roleBitmap Registry roles for the worker. Must be a subset of the orchestrator's.
    /// @param textKeys Text keys the worker may write. Each must be one the orchestrator may write.
    /// @param expiry The worker's lease. Must not exceed the orchestrator's.
    /// @return tokenId The ERC1155 token ID of the worker's name.
    function spawn(
        string calldata label,
        address worker,
        address resolver,
        IRegistry subregistry,
        uint256 roleBitmap,
        string[] calldata textKeys,
        uint64 expiry
    )
        external
        returns (uint256 tokenId)
    {
        // The orchestrator is whoever owns the name *now*. After `unregister()` — or after the
        // lease lapses — `getOwner()` is `address(0)` and this contract acts for nobody.
        address orchestrator = PARENT_REGISTRY.getOwner(ORCHESTRATOR_ID);
        if (msg.sender != orchestrator || orchestrator == address(0)) {
            revert NotOrchestrator(msg.sender, orchestrator);
        }

        _checkAttached();
        _checkRoles(roleBitmap, orchestrator);
        _checkTextKeys(textKeys, orchestrator);
        _checkExpiry(expiry);

        tokenId = SANDBOX.provision(
            label, worker, resolver, subregistry, roleBitmap, textKeys, expiry
        );

        emit WorkerSpawned(
            tokenId, orchestrator, worker, label, roleBitmap, textKeys, expiry
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Attenuation
    ////////////////////////////////////////////////////////////////////////

    /// @notice The registry-tier roles the orchestrator can currently delegate.
    /// @dev Its roles at its own name's resource, and nothing more: root roles in the parent
    ///      registry are the operator's business, not something an orchestrator may pass down.
    ///      Public so an orchestrator (or a demo) can ask before it asks wrongly.
    function delegatableRoles() public view returns (uint256) {
        return PARENT_REGISTRY.roles(
            ORCHESTRATOR_ID, PARENT_REGISTRY.getOwner(ORCHESTRATOR_ID)
        );
    }

    /// @notice Whether the orchestrator may write `key` on its own name, and so may delegate it.
    function delegatableTextKey(string memory key) public view returns (bool) {
        address ownResolver = PARENT_REGISTRY.getResolver(ORCHESTRATOR_LABEL);
        if (ownResolver == address(0)) {
            return false;
        }
        return IEnhancedAccessControl(ownResolver).hasRoles(
            PermissionedResolverLib.resource(
                ORCHESTRATOR_NODE, PermissionedResolverLib.partHash(key)
            ),
            PermissionedResolverLib.ROLE_SET_TEXT,
            PARENT_REGISTRY.getOwner(ORCHESTRATOR_ID)
        );
    }

    /// @dev Mint only into the registry the orchestrator's name actually points at. Otherwise
    ///      the worker would exist but be unreachable from the root, which is worse than a revert.
    function _checkAttached() private view {
        address childRegistry = address(SANDBOX.REGISTRY());
        address attached = address(PARENT_REGISTRY.getSubregistry(ORCHESTRATOR_LABEL));
        if (attached != childRegistry) {
            revert SubtreeDetached(childRegistry, attached);
        }
    }

    /// @dev Lease-tier subset check: a worker cannot be promised time its parent does not have.
    function _checkExpiry(uint64 expiry) private view {
        uint64 orchestratorExpiry = PARENT_REGISTRY.getExpiry(ORCHESTRATOR_ID);
        if (expiry > orchestratorExpiry) {
            revert ExpiryExceedsOrchestrator(expiry, orchestratorExpiry);
        }
    }

    /// @dev Registry-tier subset check.
    function _checkRoles(uint256 roleBitmap, address orchestrator) private view {
        uint256 held = PARENT_REGISTRY.roles(ORCHESTRATOR_ID, orchestrator);
        uint256 exceeded = roleBitmap & ~held;
        if (exceeded != 0) {
            revert RolesExceedOrchestrator(roleBitmap, held, exceeded);
        }
    }

    /// @dev Record-tier subset check: T2's per-key allowlist, inherited one tier down.
    function _checkTextKeys(string[] calldata textKeys, address orchestrator) private view {
        if (textKeys.length == 0) {
            return;
        }
        address ownResolver = PARENT_REGISTRY.getResolver(ORCHESTRATOR_LABEL);
        if (ownResolver == address(0)) {
            revert OrchestratorHasNoResolver();
        }
        for (uint256 i; i < textKeys.length; ++i) {
            bool held = IEnhancedAccessControl(ownResolver).hasRoles(
                PermissionedResolverLib.resource(
                    ORCHESTRATOR_NODE, PermissionedResolverLib.partHash(textKeys[i])
                ),
                PermissionedResolverLib.ROLE_SET_TEXT,
                orchestrator
            );
            if (!held) {
                revert TextKeyExceedsOrchestrator(i, textKeys[i]);
            }
        }
    }
}
