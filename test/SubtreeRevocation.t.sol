// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable func-name-mixedcase, state-visibility

import {Test} from "forge-std/Test.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @notice Verifies IDEA.md §3.4: revoking an orchestrator agent takes its entire
///         worker subtree offline in the same transaction, with no enumeration.
///
/// Hierarchy under test:
///   operator.eth        -> parentRegistry
///     agent-404         -> owned by `agent`, subregistry = agentRegistry
///       worker-1        -> owned by `worker`
contract SubtreeRevocationTest is Test {
    PermissionedRegistry parentRegistry; // operator's registry
    PermissionedRegistry agentRegistry; // orchestrator's own subregistry
    LabelStore labelStore;

    address operator = makeAddr("operator");
    address agent = makeAddr("agent");
    address worker = makeAddr("worker");

    string constant AGENT_LABEL = "agent-404";
    string constant WORKER_LABEL = "worker-1";
    address constant AGENT_RESOLVER = address(0xBEEF);
    address constant WORKER_RESOLVER = address(0xF00D);

    function setUp() external {
        labelStore = new LabelStore(IContractNamer(address(0)));
        parentRegistry = new PermissionedRegistry(
            labelStore, operator, EACBaseRolesLib.ALL_ROLES
        );

        // The orchestrator gets its own registry to mint workers into. It holds
        // ROLE_REGISTRAR there (it may spawn children) but the operator retains
        // root control of the parent registry.
        agentRegistry = new PermissionedRegistry(labelStore, agent, EACBaseRolesLib.ALL_ROLES);

        uint64 expiry = uint64(block.timestamp + 365 days);

        vm.prank(operator);
        parentRegistry.register(
            AGENT_LABEL,
            agent,
            IRegistry(address(agentRegistry)),
            AGENT_RESOLVER,
            RegistryRolesLib.ROLE_SET_SUBREGISTRY,
            expiry
        );

        // Orchestrator spawns a worker beneath itself.
        vm.prank(agent);
        agentRegistry.register(
            WORKER_LABEL, worker, IRegistry(address(0)), WORKER_RESOLVER, 0, expiry
        );
    }

    function test_baseline_subtreeIsReachable() external view {
        assertEq(
            address(parentRegistry.getSubregistry(AGENT_LABEL)),
            address(agentRegistry),
            "agent subregistry reachable"
        );
        assertEq(
            agentRegistry.getResolver(WORKER_LABEL), WORKER_RESOLVER, "worker resolves"
        );
        assertEq(agentRegistry.getOwner(LibLabel.id(WORKER_LABEL)), worker, "worker owned");
    }

    /// @notice Revoking the orchestrator severs the path to every worker beneath it,
    ///         in one transaction, without touching the child registry at all.
    function test_revokingOrchestratorSeversWholeSubtree() external {
        vm.prank(operator);
        parentRegistry.unregister(LibLabel.id(AGENT_LABEL));

        // The traversal edge is gone: resolution of *.agent-404.operator.eth now
        // dead-ends at the parent registry.
        assertEq(
            address(parentRegistry.getSubregistry(AGENT_LABEL)),
            address(0),
            "subtree unreachable"
        );
        assertEq(parentRegistry.getResolver(AGENT_LABEL), address(0), "agent unresolvable");
    }

    /// @notice Honest limitation, worth stating in the demo: the child registry's own
    ///         state is untouched. The worker record still exists in isolation - it is
    ///         merely orphaned, because nothing can route to it from the ENS root.
    ///         Containment is reachability, not deletion (IDEA.md §3.5).
    function test_childRegistryStateSurvivesButIsOrphaned() external {
        vm.prank(operator);
        parentRegistry.unregister(LibLabel.id(AGENT_LABEL));

        // Still true inside the orphaned registry...
        assertEq(agentRegistry.getOwner(LibLabel.id(WORKER_LABEL)), worker, "record persists");
        // ...but there is no longer a path to it from the parent.
        assertEq(address(parentRegistry.getSubregistry(AGENT_LABEL)), address(0), "no path");
    }

    /// @notice The orchestrator cannot save its fleet by re-pointing the subregistry
    ///         after revocation: the parent entry is expired, so setSubregistry reverts.
    function test_agentCannotReattachSubtreeAfterRevocation() external {
        uint256 id = LibLabel.id(AGENT_LABEL);

        vm.prank(operator);
        parentRegistry.unregister(id);

        vm.prank(agent);
        vm.expectRevert();
        parentRegistry.setSubregistry(id, IRegistry(address(agentRegistry)));
    }
}
