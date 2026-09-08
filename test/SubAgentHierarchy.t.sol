// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable func-name-mixedcase, state-visibility

import {Test} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AgentSandbox} from "../src/AgentSandbox.sol";
import {CounterpartyVerifier} from "../src/CounterpartyVerifier.sol";
import {SubAgentRegistrar} from "../src/SubAgentRegistrar.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @notice T5 — sub-agent hierarchy (IDEA.md §3.4). An orchestrator spawns a worker fleet beneath
///         its own name, every grant provably a subset of its own, and the operator's kill switch
///         still reaches the whole tree in one transaction.
///
/// The hierarchy is four registries deep and entirely real:
///
///   <root>                    -> rootRegistry
///     eth                     -> ethRegistry
///       operator              -> operatorRegistry
///         agent-404           -> agentRegistry      (the orchestrator's own subtree)
///           worker-1..3       -> minted through SubAgentRegistrar
///
/// The fleet is proved online and offline from the *outside*, with T4's `CounterpartyVerifier`,
/// rather than by reading registry storage: the claim in IDEA.md §3.4 is that revoking an
/// orchestrator takes its workers down, and what that has to mean is that counterparties stop
/// paying them.
contract SubAgentHierarchyTest is Test {
    LabelStore labelStore;
    PermissionedRegistry rootRegistry;
    PermissionedRegistry ethRegistry;
    PermissionedRegistry operatorRegistry;
    PermissionedRegistry agentRegistry; // the orchestrator's own subtree
    VerifiableFactory factory;
    PermissionedResolver resolver;
    AgentSandbox sandbox; // mints into operatorRegistry
    AgentSandbox agentSandbox; // mints into agentRegistry
    SubAgentRegistrar registrar;
    CounterpartyVerifier verifier;

    address root = makeAddr("root");
    address operator = makeAddr("operator");
    address agent = makeAddr("agent"); // the orchestrator
    address worker = makeAddr("worker");
    address stranger = makeAddr("stranger");
    address treasury = makeAddr("treasury");
    address counterparty = makeAddr("counterparty");

    uint256 workerKeyPk;
    address workerKey;

    string constant PARENT = "operator.eth";
    string constant ORCH_LABEL = "agent-404";
    string constant ORCH_NAME = "agent-404.operator.eth";

    string keyEndpoint = "agent:endpoint";
    string keyStatus = "agent:status";
    string keyOperating;

    bytes orchName;
    bytes32 orchNode;
    uint256 orchId;
    uint64 expiry;

    bytes message = bytes("worker-1: task 9 complete");

    function setUp() external {
        labelStore = new LabelStore(IContractNamer(address(0)));
        rootRegistry = new PermissionedRegistry(labelStore, root, EACBaseRolesLib.ALL_ROLES);
        ethRegistry = new PermissionedRegistry(labelStore, root, EACBaseRolesLib.ALL_ROLES);
        operatorRegistry = new PermissionedRegistry(
            labelStore, operator, EACBaseRolesLib.ALL_ROLES
        );

        // The orchestrator's own registry is rooted on the *operator*, not the orchestrator.
        // This is the load-bearing wiring decision of T5: an orchestrator holding root
        // `ROLE_REGISTRAR` here could mint workers directly, bypassing every attenuation check
        // the registrar performs. Asserted in `test_orchestratorCannotMintDirectly`.
        agentRegistry = new PermissionedRegistry(labelStore, operator, EACBaseRolesLib.ALL_ROLES);

        factory = new VerifiableFactory();
        PermissionedResolver implementation = new PermissionedResolver(address(this));
        bytes memory initData = abi.encodeCall(
            PermissionedResolver.initialize,
            (operator, EACBaseRolesLib.ALL_ROLES, new bytes[](0))
        );
        resolver = PermissionedResolver(
            factory.deployProxy(address(implementation), uint256(keccak256(initData)), initData)
        );

        expiry = uint64(block.timestamp + 365 days);

        vm.startPrank(root);
        rootRegistry.register("eth", root, IRegistry(address(ethRegistry)), address(0), 0, expiry);
        ethRegistry.register(
            "operator", operator, IRegistry(address(operatorRegistry)), address(0), 0, expiry
        );
        vm.stopPrank();

        sandbox = new AgentSandbox(
            IPermissionedRegistry(address(operatorRegistry)), NameCoder.encode(PARENT)
        );
        agentSandbox = new AgentSandbox(
            IPermissionedRegistry(address(agentRegistry)), NameCoder.encode(ORCH_NAME)
        );
        registrar = new SubAgentRegistrar(
            agentSandbox, IPermissionedRegistry(address(operatorRegistry))
        );
        keyOperating = sandbox.OPERATING_KEY();

        vm.startPrank(operator);
        operatorRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(sandbox));
        agentRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(agentSandbox));
        // The registrar is the only thing allowed to ask the child sandbox for a name.
        agentRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(registrar));
        resolver.grantRootRoles(PermissionedResolverLib.ROLE_SET_TEXT_ADMIN, address(sandbox));
        resolver.grantRootRoles(PermissionedResolverLib.ROLE_SET_TEXT_ADMIN, address(agentSandbox));
        vm.stopPrank();

        verifier = new CounterpartyVerifier(
            IRegistry(address(rootRegistry)), keyEndpoint, keyOperating
        );

        orchName = NameCoder.encode(ORCH_NAME);
        orchNode = NameCoder.namehash(orchName, 0);
        orchId = LibLabel.id(ORCH_LABEL);

        // The orchestrator: allowed to point at a child registry, and to publish an endpoint and
        // an operating key. Not allowed to publish a status - so it cannot delegate one either.
        vm.prank(operator);
        sandbox.provision(
            ORCH_LABEL,
            agent,
            address(resolver),
            IRegistry(address(agentRegistry)),
            RegistryRolesLib.ROLE_SET_SUBREGISTRY,
            _keys(keyEndpoint, keyOperating),
            expiry
        );

        (workerKey, workerKeyPk) = makeAddrAndKey("worker-operating-key");
        vm.deal(counterparty, 100 ether);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _keys(string memory a, string memory b) internal pure returns (string[] memory k) {
        k = new string[](2);
        k[0] = a;
        k[1] = b;
    }

    function _keys(string memory a) internal pure returns (string[] memory k) {
        k = new string[](1);
        k[0] = a;
    }

    function _spawn(string memory label, uint256 roleBitmap, string[] memory keys)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(agent);
        tokenId = registrar.spawn(
            label, worker, address(resolver), IRegistry(address(0)), roleBitmap, keys, expiry
        );
    }

    function _workerName(string memory label) internal pure returns (bytes memory) {
        return NameCoder.encode(string.concat(label, ".", ORCH_NAME));
    }

    /// @dev A worker a counterparty could actually transact with: minted, paid-to address wired
    ///      by the operator, endpoint and operating key published by the worker itself.
    function _liveWorker(string memory label) internal returns (bytes32 node) {
        _spawn(label, 0, _keys(keyEndpoint, keyOperating));
        node = NameCoder.namehash(_workerName(label), 0);

        vm.prank(operator);
        resolver.setAddr(node, treasury);
        vm.startPrank(worker);
        resolver.setText(node, keyEndpoint, string.concat("https://", label, ".example/api"));
        resolver.setText(node, keyOperating, Strings.toHexString(workerKey));
        vm.stopPrank();
    }

    function _sign(uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(message));
        return abi.encodePacked(r, s, v);
    }

    function _refusal(bytes memory name) internal view returns (CounterpartyVerifier.Refusal) {
        (CounterpartyVerifier.Refusal reason, , ) =
            verifier.checkAgent(name, message, _sign(workerKeyPk));
        return reason;
    }

    ////////////////////////////////////////////////////////////////////////
    // Attenuation: the roles a worker may hold
    ////////////////////////////////////////////////////////////////////////

    /// @notice The first exit criterion. The worker's bitmap is asserted to be a subset of the
    ///         orchestrator's *as read from the registry*, not merely equal to what the test asked
    ///         for — the subset relation is the property, the specific bits are incidental.
    function test_orchestratorSpawnsAWorkerWithASubsetOfItsOwnRoles() external {
        uint256 tokenId = _spawn(
            "worker-1", RegistryRolesLib.ROLE_SET_SUBREGISTRY, _keys(keyEndpoint)
        );

        uint256 orchestratorRoles = operatorRegistry.roles(orchId, agent);
        uint256 workerRoles = agentRegistry.roles(tokenId, worker);

        assertEq(agentRegistry.getOwner(tokenId), worker, "the worker owns its name");
        assertEq(workerRoles, RegistryRolesLib.ROLE_SET_SUBREGISTRY, "exactly what was asked for");
        assertEq(workerRoles & ~orchestratorRoles, 0, "and provably a subset of the parent's");
        assertEq(
            address(operatorRegistry.getSubregistry(ORCH_LABEL)),
            address(agentRegistry),
            "minted inside the orchestrator's own subtree"
        );
    }

    /// @notice The second exit criterion: asking for a role the orchestrator does not hold is
    ///         refused, naming the offending bits.
    function test_spawningARoleTheOrchestratorLacksReverts() external {
        // `ROLE_SET_RESOLVER` is the escalation path IDEA.md §3.2 exists to close. The
        // orchestrator was never given it, so it cannot hand it to a worker either.
        vm.expectRevert(
            abi.encodeWithSelector(
                SubAgentRegistrar.RolesExceedOrchestrator.selector,
                RegistryRolesLib.ROLE_SET_RESOLVER,
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                RegistryRolesLib.ROLE_SET_RESOLVER
            )
        );
        _spawn("worker-1", RegistryRolesLib.ROLE_SET_RESOLVER, _keys(keyEndpoint));

        assertEq(
            agentRegistry.getOwner(LibLabel.id("worker-1")), address(0), "nothing was minted"
        );
    }

    /// @notice Attenuation is checked against live state, not against a snapshot taken when the
    ///         orchestrator was provisioned: the operator narrowing the orchestrator narrows what
    ///         it can delegate, in the same transaction and with no redeployment.
    function test_attenuationTracksTheOrchestratorsCurrentRoles() external {
        assertEq(
            registrar.delegatableRoles(),
            RegistryRolesLib.ROLE_SET_SUBREGISTRY,
            "delegatable today"
        );

        vm.prank(operator);
        operatorRegistry.revokeRoles(orchId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, agent);

        assertEq(registrar.delegatableRoles(), 0, "and nothing tomorrow");
        vm.expectRevert(
            abi.encodeWithSelector(
                SubAgentRegistrar.RolesExceedOrchestrator.selector,
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                0,
                RegistryRolesLib.ROLE_SET_SUBREGISTRY
            )
        );
        _spawn("worker-1", RegistryRolesLib.ROLE_SET_SUBREGISTRY, _keys(keyEndpoint));

        // A role-less worker is still perfectly spawnable: attenuation narrows, it does not block.
        uint256 tokenId = _spawn("worker-1", 0, _keys(keyEndpoint));
        assertEq(agentRegistry.roles(tokenId, worker), 0, "minted with nothing, as requested");
    }

    /// @notice **Finding: registration is not admin-checked.** This is why `SubAgentRegistrar`
    ///         exists, and it corrects IDEA.md §3.4's original claim that the registry hierarchy
    ///         enforces attenuation on its own.
    ///
    ///         `PermissionedRegistry.register()` grants the new owner its bitmap through
    ///         `_grantRoles(..., false)`, which skips the `canGrantRoles` modifier that governs
    ///         every later grant. So an account holding nothing but root `ROLE_REGISTRAR` can
    ///         mint a name carrying roles it does not hold and could not grant a second later.
    ///         Attenuation between tiers is an application-level invariant in ENSv2, not a
    ///         protocol-level one.
    function test_finding_registrationGrantsRolesTheRegistrarCannotOtherwiseGrant() external {
        PermissionedRegistry bare =
            new PermissionedRegistry(labelStore, root, EACBaseRolesLib.ALL_ROLES);
        vm.prank(root);
        bare.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, stranger);

        uint256 escalated =
            RegistryRolesLib.ROLE_SET_RESOLVER | RegistryRolesLib.ROLE_UNREGISTER;
        assertFalse(bare.hasRootRoles(escalated, stranger), "the registrar holds none of these");

        vm.prank(stranger);
        uint256 tokenId =
            bare.register("escalated", worker, IRegistry(address(0)), address(0), escalated, expiry);

        assertEq(
            bare.roles(tokenId, worker),
            escalated,
            "yet the minted name carries them: register() bypasses the admin check"
        );

        // ...whereas the same grant one transaction later is refused, which is the check that
        // everyone assumes is also protecting registration. It is not.
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                bare.getResource(tokenId),
                escalated,
                stranger
            )
        );
        vm.prank(stranger);
        bare.grantRoles(tokenId, escalated, stranger);
    }

    ////////////////////////////////////////////////////////////////////////
    // Attenuation: the records a worker may write
    ////////////////////////////////////////////////////////////////////////

    /// @notice T2's per-key allowlist, inherited one tier down: the orchestrator can delegate the
    ///         keys it may write and no others. Without this, a worker fleet would be the hole in
    ///         the record-level sandbox — spawn a worker with `agent:status`, have it publish what
    ///         you were denied.
    function test_orchestratorCannotDelegateATextKeyItCannotWrite() external {
        assertTrue(registrar.delegatableTextKey(keyEndpoint), "it may write its endpoint");
        assertFalse(registrar.delegatableTextKey(keyStatus), "it was never given status");

        vm.expectRevert(
            abi.encodeWithSelector(
                SubAgentRegistrar.TextKeyExceedsOrchestrator.selector, 1, keyStatus
            )
        );
        _spawn("worker-1", 0, _keys(keyEndpoint, keyStatus));
    }

    /// @notice The positive half: a delegated key really is writable by the worker, and only by
    ///         the worker — the orchestrator gets no authority over its child's records by having
    ///         spawned it.
    function test_aDelegatedKeyIsWritableByTheWorkerAlone() external {
        _spawn("worker-1", 0, _keys(keyEndpoint, keyOperating));
        bytes32 node = NameCoder.namehash(_workerName("worker-1"), 0);

        vm.prank(worker);
        resolver.setText(node, keyEndpoint, "https://worker-1.example/api");
        assertEq(resolver.text(node, keyEndpoint), "https://worker-1.example/api", "worker wrote");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(node, bytes32(0)),
                PermissionedResolverLib.ROLE_SET_TEXT,
                agent
            )
        );
        vm.prank(agent);
        resolver.setText(node, keyEndpoint, "https://orchestrator-hijack.example");
    }

    ////////////////////////////////////////////////////////////////////////
    // Attenuation: the lease, and who may ask at all
    ////////////////////////////////////////////////////////////////////////

    /// @notice A worker cannot be promised time its parent does not have.
    function test_workerLeaseCannotOutliveTheOrchestrator() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                SubAgentRegistrar.ExpiryExceedsOrchestrator.selector, expiry + 1, expiry
            )
        );
        vm.prank(agent);
        registrar.spawn(
            "worker-1",
            worker,
            address(resolver),
            IRegistry(address(0)),
            0,
            _keys(keyEndpoint),
            expiry + 1
        );
    }

    /// @notice Only the current owner of the orchestrator's name may spawn — not the operator,
    ///         not a stranger, not a worker. The registrar acts for an identity, not an address
    ///         list, so a transferred name would carry the ability with it.
    function test_onlyTheOrchestratorMaySpawn() external {
        address[3] memory impostors = [operator, stranger, worker];
        for (uint256 i; i < impostors.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    SubAgentRegistrar.NotOrchestrator.selector, impostors[i], agent
                )
            );
            vm.prank(impostors[i]);
            registrar.spawn(
                "worker-1",
                worker,
                address(resolver),
                IRegistry(address(0)),
                0,
                _keys(keyEndpoint),
                expiry
            );
        }
    }

    /// @notice The wiring caveat, asserted rather than assumed: the registrar is only binding
    ///         because the orchestrator holds no root `ROLE_REGISTRAR` in its own child registry.
    ///         The operator keeps root there, so the only route to a name in the subtree is
    ///         through the attenuating registrar.
    function test_orchestratorCannotMintDirectly() external {
        assertFalse(
            agentRegistry.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, agent),
            "the orchestrator is not a registrar in its own subtree"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                agentRegistry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR,
                agent
            )
        );
        vm.prank(agent);
        agentRegistry.register(
            "worker-rogue",
            worker,
            IRegistry(address(0)),
            address(resolver),
            EACBaseRolesLib.ALL_ROLES,
            expiry
        );
    }

    /// @notice A worker spawned with no roles cannot start a fleet of its own: the recursion
    ///         terminates where the delegation runs out, without needing a depth limit.
    function test_recursionTerminatesWhereTheRolesDo() external {
        uint256 tokenId = _spawn("worker-1", 0, _keys(keyEndpoint));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                agentRegistry.getResource(tokenId),
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                worker
            )
        );
        vm.prank(worker);
        agentRegistry.setSubregistry(tokenId, IRegistry(address(agentRegistry)));
    }

    /// @notice If the operator repoints the orchestrator's subregistry, the registrar stops
    ///         minting rather than producing names nothing can route to.
    function test_refusesToMintIntoADetachedSubtree() external {
        PermissionedRegistry other =
            new PermissionedRegistry(labelStore, operator, EACBaseRolesLib.ALL_ROLES);
        vm.prank(operator);
        operatorRegistry.setSubregistry(orchId, IRegistry(address(other)));

        vm.expectRevert(
            abi.encodeWithSelector(
                SubAgentRegistrar.SubtreeDetached.selector, address(agentRegistry), address(other)
            )
        );
        _spawn("worker-1", 0, _keys(keyEndpoint));
    }

    ////////////////////////////////////////////////////////////////////////
    // Revocation takes the fleet with it
    ////////////////////////////////////////////////////////////////////////

    /// @notice The third exit criterion, and demo beat 4's optional flourish: one `unregister()`
    ///         on the orchestrator and the whole fleet goes dark — proved the way a counterparty
    ///         would see it, by asking T4's verifier whether it would still pay each worker.
    ///
    ///         Nothing is enumerated and nothing is cleaned up: severing one traversal edge is
    ///         the entire operation, no matter how many workers hang off it.
    function test_revokingTheOrchestratorTakesTheWholeFleetOffline() external {
        bytes32 node1 = _liveWorker("worker-1");
        _liveWorker("worker-2");
        _liveWorker("worker-3");

        // Baseline: the fleet is real. A counterparty pays worker-1 through the verifier.
        assertEq(uint256(_refusal(_workerName("worker-1"))), 0, "worker-1 transactable");
        assertEq(uint256(_refusal(_workerName("worker-2"))), 0, "worker-2 transactable");
        assertEq(uint256(_refusal(_workerName("worker-3"))), 0, "worker-3 transactable");
        vm.prank(counterparty);
        assertEq(
            verifier.payAgent{value: 1 ether}(
                _workerName("worker-1"), message, _sign(workerKeyPk)
            ),
            treasury,
            "and paid"
        );

        // One transaction, at the tier above the fleet.
        vm.prank(operator);
        operatorRegistry.unregister(orchId);

        for (uint256 i = 1; i <= 3; ++i) {
            bytes memory name = _workerName(string.concat("worker-", vm.toString(i)));
            assertEq(
                uint256(_refusal(name)),
                uint256(CounterpartyVerifier.Refusal.Unresolvable),
                "the worker is unreachable from the root"
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    CounterpartyVerifier.Refused.selector,
                    CounterpartyVerifier.Refusal.Unresolvable,
                    name
                )
            );
            vm.prank(counterparty);
            verifier.payAgent{value: 1 ether}(name, message, _sign(workerKeyPk));
        }

        // The honest limit, restated at this tier: the workers' own records and registry entries
        // survive inside the orphaned subtree. What died is the path to them (IDEA.md §3.4).
        assertEq(
            agentRegistry.getOwner(LibLabel.id("worker-1")), worker, "the entry still exists"
        );
        assertEq(
            resolver.text(node1, keyOperating),
            Strings.toHexString(workerKey),
            "as does its published key - unreachable, not deleted"
        );
        assertEq(
            address(operatorRegistry.getSubregistry(ORCH_LABEL)), address(0), "no path to it"
        );
    }

    /// @notice The fleet cannot regrow after the kill switch either: with the name gone there is
    ///         no orchestrator for the registrar to act for.
    function test_revokedOrchestratorCannotSpawnMore() external {
        _spawn("worker-1", 0, _keys(keyEndpoint));

        vm.prank(operator);
        operatorRegistry.unregister(orchId);

        vm.expectRevert(
            abi.encodeWithSelector(SubAgentRegistrar.NotOrchestrator.selector, agent, address(0))
        );
        _spawn("worker-2", 0, _keys(keyEndpoint));
    }

    /// @notice Same for a lapsed lease: expiry and revocation reach the fleet identically.
    function test_expiredOrchestratorCannotSpawnMore() external {
        vm.warp(expiry + 1);

        vm.expectRevert(
            abi.encodeWithSelector(SubAgentRegistrar.NotOrchestrator.selector, agent, address(0))
        );
        _spawn("worker-1", 0, _keys(keyEndpoint));
    }
}
