// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable func-name-mixedcase, state-visibility

import {Test, Vm} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {AgentSandbox} from "../src/AgentSandbox.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IStandardRegistry} from "~src/registry/interfaces/IStandardRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @notice T1 — the sandbox registrar. Provisioning an agent identity is one call, and the
///         IDEA.md §3.2 permission split is a property of that call rather than of the
///         sequence a demo happens to run.
///
/// Everything here runs against the real `PermissionedRegistry` and a real
/// `PermissionedResolver` behind a `VerifiableFactory` proxy. Nothing is mocked.
contract AgentSandboxTest is Test {
    PermissionedRegistry registry;
    LabelStore labelStore;
    VerifiableFactory factory;
    PermissionedResolver resolver;
    AgentSandbox sandbox;

    address operator = makeAddr("operator");
    address agent = makeAddr("agent");
    address attacker = makeAddr("attacker");

    string constant LABEL = "agent-404";
    string constant PARENT = "operator.eth";
    uint64 expiry;

    /// @dev The bitmap the operator asks for in most tests: the one role the ceiling admits.
    uint256 constant REQUESTED_ROLES = RegistryRolesLib.ROLE_SET_SUBREGISTRY;

    function setUp() external {
        labelStore = new LabelStore(IContractNamer(address(0)));
        registry = new PermissionedRegistry(labelStore, operator, EACBaseRolesLib.ALL_ROLES);

        // A real permissioned resolver, deployed the way ENSv2 deploys it (UUPS behind a
        // VerifiableFactory proxy). The operator is its root admin.
        factory = new VerifiableFactory();
        PermissionedResolver implementation = new PermissionedResolver(address(this));
        bytes memory initData = abi.encodeCall(
            PermissionedResolver.initialize,
            (operator, EACBaseRolesLib.ALL_ROLES, new bytes[](0))
        );
        resolver = PermissionedResolver(
            factory.deployProxy(address(implementation), uint256(keccak256(initData)), initData)
        );

        sandbox = new AgentSandbox(
            IPermissionedRegistry(address(registry)), NameCoder.encode(PARENT)
        );

        // The sandbox's *only* authority: it may register. It gets no admin roles and no
        // per-name roles, so it cannot revoke, repoint, or transfer anything it mints.
        vm.prank(operator);
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(sandbox));

        expiry = uint64(block.timestamp + 365 days);
    }

    /// @dev T1 is about the registry tier, so these provisionings allowlist no text keys.
    ///      The record tier gets its own file (`test/AgentRecords.t.sol`).
    function _noKeys() internal pure returns (string[] memory) {
        return new string[](0);
    }

    function _provision() internal returns (uint256 tokenId) {
        vm.prank(operator);
        tokenId = sandbox.provision(
            LABEL, agent, address(resolver), IRegistry(address(0)), REQUESTED_ROLES, _noKeys(),
            expiry
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // One call does the whole provisioning
    ////////////////////////////////////////////////////////////////////////

    function test_provision_mintsWiresAndGrantsInOneCall() external {
        uint256 tokenId = _provision();
        uint256 id = LibLabel.id(LABEL);

        assertEq(registry.getOwner(id), agent, "agent holds the name");
        assertEq(registry.getTokenId(id), tokenId, "returned token id is the live one");
        assertEq(registry.getResolver(LABEL), address(resolver), "resolver wired");
        assertEq(registry.getExpiry(id), expiry, "lease expiry set");
        assertEq(
            uint8(registry.getStatus(id)), uint8(IPermissionedRegistry.Status.REGISTERED), "live"
        );
    }

    /// @notice The event is what an off-chain watcher indexes, so its fields are checked
    ///         against registry state rather than against the expressions that produced them.
    function test_provision_emitsAgentProvisioned() external {
        vm.recordLogs();
        uint256 tokenId = _provision();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = AgentSandbox.AgentProvisioned.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(sandbox) || logs[i].topics[0] != sig) {
                continue;
            }
            found = true;
            assertEq(uint256(logs[i].topics[1]), tokenId, "tokenId topic");
            assertEq(
                uint256(logs[i].topics[2]),
                registry.getResource(tokenId),
                "resource topic matches the live EAC resource"
            );
            assertEq(address(uint160(uint256(logs[i].topics[3]))), agent, "agent topic");

            (
                string memory label,
                address res,
                uint256 roleBitmap,
                string[] memory keys,
                uint64 exp
            ) = abi.decode(logs[i].data, (string, address, uint256, string[], uint64));
            assertEq(label, LABEL, "label");
            assertEq(res, address(resolver), "resolver");
            assertEq(roleBitmap, REQUESTED_ROLES, "roleBitmap");
            assertEq(keys.length, 0, "no text keys allowlisted");
            assertEq(exp, expiry, "expiry");
        }
        assertTrue(found, "AgentProvisioned emitted");
    }

    ////////////////////////////////////////////////////////////////////////
    // The agent receives EXACTLY the intended roles - asserted role by role
    ////////////////////////////////////////////////////////////////////////

    /// @notice The whole bitmap, compared as one value. If any stray bit were granted this fails.
    function test_agentRoles_bitmapIsExactlyWhatWasRequested() external {
        _provision();
        assertEq(
            registry.roles(LibLabel.id(LABEL), agent),
            REQUESTED_ROLES,
            "agent's role bitmap is exactly the requested one"
        );
    }

    /// @notice And the same claim role by role, so a reader can see which powers are withheld
    ///         without decoding a nybble bitmap.
    function test_agentRoles_grantedAndWithheldRoleByRole() external {
        uint256 id = _provision();

        // Granted.
        assertTrue(
            registry.hasRoles(id, RegistryRolesLib.ROLE_SET_SUBREGISTRY, agent),
            "ROLE_SET_SUBREGISTRY granted"
        );

        // Withheld - the sandbox walls (IDEA.md §3.2).
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_SET_RESOLVER, agent),
            "ROLE_SET_RESOLVER withheld"
        );
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_UNREGISTER, agent),
            "ROLE_UNREGISTER withheld"
        );
        assertFalse(registry.hasRoles(id, RegistryRolesLib.ROLE_RENEW, agent), "ROLE_RENEW withheld");
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_REGISTRAR, agent), "ROLE_REGISTRAR withheld"
        );
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_REGISTER_RESERVED, agent),
            "ROLE_REGISTER_RESERVED withheld"
        );
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_SET_PARENT, agent),
            "ROLE_SET_PARENT withheld"
        );
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_SET_URI, agent), "ROLE_SET_URI withheld"
        );
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_CAN_NAME, agent), "ROLE_CAN_NAME withheld"
        );
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_UPGRADE, agent), "ROLE_UPGRADE withheld"
        );

        // Admin roles - the escalation surface. Withheld as a block.
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN, agent),
            "ROLE_CAN_TRANSFER_ADMIN withheld"
        );
        assertFalse(
            registry.hasRoles(id, RegistryRolesLib.ROLE_SET_SUBREGISTRY_ADMIN, agent),
            "cannot re-delegate even its one granted role"
        );
        assertEq(
            registry.roles(id, agent) & EACBaseRolesLib.ADMIN_ROLES,
            0,
            "agent holds no admin nybble at all"
        );
    }

    /// @notice The tightest sandbox - zero registry roles - is a valid provisioning.
    function test_agentRoles_zeroBitmapIsAllowed() external {
        vm.prank(operator);
        sandbox.provision(
            LABEL, agent, address(resolver), IRegistry(address(0)), 0, _noKeys(), expiry
        );

        uint256 id = LibLabel.id(LABEL);
        assertEq(registry.getOwner(id), agent, "still owns the name");
        assertEq(registry.roles(id, agent), 0, "and holds nothing at the registry level");
    }

    ////////////////////////////////////////////////////////////////////////
    // The agent cannot escape the box
    ////////////////////////////////////////////////////////////////////////

    function test_agentCannotTransferTheName() external {
        uint256 tokenId = _provision();

        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, tokenId, agent)
        );
        vm.prank(agent);
        registry.safeTransferFrom(agent, attacker, tokenId, 1, "");
    }

    function test_agentCannotSetResolver() external {
        uint256 id = LibLabel.id(LABEL);
        _provision();
        uint256 resource = registry.getResource(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resource,
                RegistryRolesLib.ROLE_SET_RESOLVER,
                agent
            )
        );
        vm.prank(agent);
        registry.setResolver(id, attacker);

        assertEq(registry.getResolver(LABEL), address(resolver), "resolver unchanged");
    }

    function test_agentCannotUnregisterItself() external {
        uint256 id = LibLabel.id(LABEL);
        _provision();
        uint256 resource = registry.getResource(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resource,
                RegistryRolesLib.ROLE_UNREGISTER,
                agent
            )
        );
        vm.prank(agent);
        registry.unregister(id);
    }

    function test_agentCannotGrantItselfRoles() external {
        uint256 id = LibLabel.id(LABEL);
        _provision();
        uint256 resource = registry.getResource(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resource,
                RegistryRolesLib.ROLE_SET_RESOLVER,
                agent
            )
        );
        vm.prank(agent);
        registry.grantRoles(id, RegistryRolesLib.ROLE_SET_RESOLVER, agent);
    }

    /// @notice Not even the role it *does* hold can be handed to an accomplice: granting
    ///         requires the admin nybble, which the ceiling withholds.
    function test_agentCannotDelegateItsGrantedRole() external {
        uint256 id = LibLabel.id(LABEL);
        _provision();
        uint256 resource = registry.getResource(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resource,
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                agent
            )
        );
        vm.prank(agent);
        registry.grantRoles(id, RegistryRolesLib.ROLE_SET_SUBREGISTRY, attacker);
    }

    ////////////////////////////////////////////////////////////////////////
    // The ceiling: an operator cannot over-grant, even by accident
    ////////////////////////////////////////////////////////////////////////

    function test_provision_rejectsRolesAboveTheCeiling() external {
        uint256 requested = RegistryRolesLib.ROLE_SET_SUBREGISTRY | RegistryRolesLib.ROLE_UNREGISTER;

        vm.expectRevert(
            abi.encodeWithSelector(
                AgentSandbox.RoleBitmapExceedsCeiling.selector,
                requested,
                RegistryRolesLib.ROLE_UNREGISTER
            )
        );
        vm.prank(operator);
        sandbox.provision(
            LABEL, agent, address(resolver), IRegistry(address(0)), requested, _noKeys(), expiry
        );
    }

    /// @notice Every role the design withholds is individually rejected by the ceiling, so a
    ///         future refactor that widens `AGENT_ROLE_CEILING` breaks a named test.
    function test_ceiling_rejectsEachWithheldRole() external {
        uint256[10] memory withheld = [
            RegistryRolesLib.ROLE_SET_RESOLVER,
            RegistryRolesLib.ROLE_UNREGISTER,
            RegistryRolesLib.ROLE_RENEW,
            RegistryRolesLib.ROLE_REGISTRAR,
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            RegistryRolesLib.ROLE_SET_PARENT,
            RegistryRolesLib.ROLE_SET_URI,
            RegistryRolesLib.ROLE_CAN_NAME,
            RegistryRolesLib.ROLE_UPGRADE,
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN
        ];

        for (uint256 i; i < withheld.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AgentSandbox.RoleBitmapExceedsCeiling.selector, withheld[i], withheld[i]
                )
            );
            vm.prank(operator);
            sandbox.provision(
                LABEL, agent, address(resolver), IRegistry(address(0)), withheld[i], _noKeys(),
                expiry
            );
        }
    }

    function test_ceiling_admitsOnlySetSubregistry() external view {
        assertEq(
            sandbox.AGENT_ROLE_CEILING(),
            RegistryRolesLib.ROLE_SET_SUBREGISTRY,
            "ceiling is one role wide"
        );
        assertEq(
            sandbox.AGENT_ROLE_CEILING() & EACBaseRolesLib.ADMIN_ROLES,
            0,
            "ceiling admits no admin role"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Who may provision, and what a valid provisioning looks like
    ////////////////////////////////////////////////////////////////////////

    function test_provision_rejectsNonRegistrar() external {
        vm.expectRevert(abi.encodeWithSelector(AgentSandbox.NotRegistrar.selector, attacker));
        vm.prank(attacker);
        sandbox.provision(
            LABEL, attacker, address(resolver), IRegistry(address(0)), REQUESTED_ROLES, _noKeys(),
            expiry
        );
    }

    function test_provision_rejectsZeroAgent() external {
        vm.expectRevert(AgentSandbox.AgentRequired.selector);
        vm.prank(operator);
        sandbox.provision(
            LABEL, address(0), address(resolver), IRegistry(address(0)), 0, _noKeys(), expiry
        );
    }

    /// @notice A plain address is not a permissioned resolver, and a name wired to one has no
    ///         record-level tier - so the agent would have no autonomy at all (IDEA.md §3.3).
    function test_provision_rejectsNonPermissionedResolver() external {
        vm.expectRevert(
            abi.encodeWithSelector(AgentSandbox.NotPermissionedResolver.selector, address(0xBEEF))
        );
        vm.prank(operator);
        sandbox.provision(
            LABEL, agent, address(0xBEEF), IRegistry(address(0)), REQUESTED_ROLES, _noKeys(), expiry
        );
    }

    function test_provision_rejectsZeroResolver() external {
        vm.expectRevert(
            abi.encodeWithSelector(AgentSandbox.NotPermissionedResolver.selector, address(0))
        );
        vm.prank(operator);
        sandbox.provision(
            LABEL, agent, address(0), IRegistry(address(0)), REQUESTED_ROLES, _noKeys(), expiry
        );
    }

    /// @notice The sandbox is not a backdoor: it holds root ROLE_REGISTRAR and nothing else,
    ///         so it cannot revoke or repoint a name it minted.
    function test_sandboxItselfHoldsNoPowerOverTheNamesItMints() external {
        uint256 id = LibLabel.id(LABEL);
        _provision();

        assertEq(registry.roles(id, address(sandbox)), 0, "no per-name roles");
        assertEq(
            registry.roles(registry.ROOT_RESOURCE(), address(sandbox)),
            RegistryRolesLib.ROLE_REGISTRAR,
            "root roles are ROLE_REGISTRAR and nothing more"
        );

        vm.prank(address(sandbox));
        vm.expectRevert();
        registry.unregister(id);

        vm.prank(address(sandbox));
        vm.expectRevert();
        registry.setResolver(id, attacker);
    }

    ////////////////////////////////////////////////////////////////////////
    // The operator's kill switch still works on a provisioned name
    // (finding 001, re-asserted against the sandbox's output)
    ////////////////////////////////////////////////////////////////////////

    function test_operatorCanStillForceExpireAProvisionedName() external {
        uint256 id = LibLabel.id(LABEL);
        _provision();
        uint256 resourceBefore = registry.getResource(id);
        assertTrue(registry.hasRoles(resourceBefore, REQUESTED_ROLES, agent), "agent had roles");

        vm.prank(operator);
        registry.unregister(id);

        assertEq(registry.getExpiry(id), uint64(block.timestamp), "expiry slammed to now");
        assertEq(
            uint8(registry.getStatus(id)), uint8(IPermissionedRegistry.Status.AVAILABLE), "dead"
        );
        assertEq(registry.getOwner(id), address(0), "token burned");
        assertEq(registry.getResolver(LABEL), address(0), "stops resolving");

        uint256 resourceAfter = registry.getResource(id);
        assertTrue(resourceBefore != resourceAfter, "EAC resource rotated");
        assertFalse(registry.hasRoles(resourceAfter, REQUESTED_ROLES, agent), "agent roles dead");
    }

    ////////////////////////////////////////////////////////////////////////
    // Nothing is hard-coded (track requirement)
    ////////////////////////////////////////////////////////////////////////

    /// @notice Label, agent, subregistry and expiry are all caller-supplied. Fuzzed to prove
    ///         the sandbox has no baked-in demo values.
    function testFuzz_provision_isFullyParameterised(
        string calldata label,
        address anyAgent,
        address anySubregistry,
        uint64 anyExpiry
    )
        external
    {
        // ERC1155 mints only to an EOA or a declared receiver; that is a token property,
        // not a sandbox one, so keep the fuzzed agent an EOA.
        vm.assume(anyAgent != address(0) && anyAgent.code.length == 0);
        vm.assume(bytes(label).length > 0 && bytes(label).length < 256);
        anyExpiry = uint64(bound(anyExpiry, block.timestamp + 1, type(uint64).max));

        vm.prank(operator);
        uint256 tokenId = sandbox.provision(
            label,
            anyAgent,
            address(resolver),
            IRegistry(anySubregistry),
            REQUESTED_ROLES,
            _noKeys(),
            anyExpiry
        );

        uint256 id = LibLabel.id(label);
        assertEq(registry.getTokenId(id), tokenId, "token id matches label");
        assertEq(registry.getOwner(id), anyAgent, "arbitrary agent owns it");
        assertEq(registry.getExpiry(id), anyExpiry, "arbitrary expiry honoured");
        assertEq(registry.roles(id, anyAgent), REQUESTED_ROLES, "exact roles regardless of inputs");
        assertEq(address(registry.getSubregistry(label)), anySubregistry, "arbitrary subregistry");
    }
}
