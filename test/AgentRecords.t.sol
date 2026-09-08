// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable func-name-mixedcase, state-visibility

import {Test, Vm} from "forge-std/Test.sol";

import {COIN_TYPE_ETH} from "@ens/contracts/utils/ENSIP19.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {AgentSandbox} from "../src/AgentSandbox.sol";

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

/// @notice T2 — the record-level tier (IDEA.md §3.3). The registry tier says what the agent
///         *cannot* do; this file is about the small, explicit set of things it *can*.
///
/// The claim under test: an agent provisioned with a text-key allowlist may write exactly those
/// keys on the resolver, and nothing else — `addr()` above all. Nothing here is mocked: it runs
/// against the real `PermissionedRegistry` and a real `PermissionedResolver` behind a
/// `VerifiableFactory` proxy, so the per-key scoping is ENSv2's, not ours.
contract AgentRecordsTest is Test {
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

    /// @dev The allowlist a working agent gets: where to reach it, what it claims it can do,
    ///      whether it is up, and a commitment to its current state.
    string constant KEY_ENDPOINT = "agent:endpoint";
    string constant KEY_MANIFEST = "agent:manifest";
    string constant KEY_STATUS = "agent:status";
    string constant KEY_STATE_HASH = "agent:state-hash";

    bytes32 node;
    bytes name;
    uint64 expiry;

    function setUp() external {
        labelStore = new LabelStore(IContractNamer(address(0)));
        registry = new PermissionedRegistry(labelStore, operator, EACBaseRolesLib.ALL_ROLES);

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

        vm.startPrank(operator);
        // Registry tier: the sandbox may register, and nothing more.
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(sandbox));
        // Resolver tier: the sandbox may hand out ROLE_SET_TEXT. This is an *admin* nybble, so
        // it delegates the write permission without conferring it - asserted below.
        resolver.grantRootRoles(PermissionedResolverLib.ROLE_SET_TEXT_ADMIN, address(sandbox));
        vm.stopPrank();

        name = NameCoder.encode(string.concat(LABEL, ".", PARENT));
        node = NameCoder.namehash(name, 0);
        expiry = uint64(block.timestamp + 365 days);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _allowlist() internal pure returns (string[] memory keys) {
        keys = new string[](4);
        keys[0] = KEY_ENDPOINT;
        keys[1] = KEY_MANIFEST;
        keys[2] = KEY_STATUS;
        keys[3] = KEY_STATE_HASH;
    }

    function _provision() internal returns (uint256 tokenId) {
        return _provision(LABEL, agent, _allowlist());
    }

    function _provision(string memory label, address who, string[] memory keys)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(operator);
        tokenId = sandbox.provision(
            label,
            who,
            address(resolver),
            IRegistry(address(0)),
            RegistryRolesLib.ROLE_SET_SUBREGISTRY,
            keys,
            expiry
        );
    }

    /// @dev The EAC resource a single text key's permission lives at.
    function _partResource(bytes32 forNode, string memory key) internal pure returns (uint256) {
        return PermissionedResolverLib.resource(forNode, PermissionedResolverLib.partHash(key));
    }

    /// @dev The name-wide resource. Holding `ROLE_SET_TEXT` here would mean *every* key.
    function _nameResource(bytes32 forNode) internal pure returns (uint256) {
        return PermissionedResolverLib.resource(forNode, bytes32(0));
    }

    function _expectUnauthorized(uint256 resource, uint256 role, address who) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector, resource, role, who
            )
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // The agent can write its allowlisted keys
    ////////////////////////////////////////////////////////////////////////

    function test_agentCanWriteEachAllowlistedKey() external {
        _provision();
        string[] memory keys = _allowlist();
        string[4] memory values = [
            "https://agent-404.example/api",
            "ipfs://bafyManifest",
            "online",
            "0xfeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"
        ];

        for (uint256 i; i < keys.length; ++i) {
            vm.prank(agent);
            resolver.setText(node, keys[i], values[i]);
            assertEq(resolver.text(node, keys[i]), values[i], keys[i]);
        }
    }

    /// @notice The agent updates a key it already wrote - autonomy is repeatable, not one-shot.
    function test_agentCanOverwriteAnAllowlistedKey() external {
        _provision();

        vm.startPrank(agent);
        resolver.setText(node, KEY_STATUS, "online");
        resolver.setText(node, KEY_STATUS, "draining");
        vm.stopPrank();

        assertEq(resolver.text(node, KEY_STATUS), "draining", "latest write wins");
    }

    /// @notice The grant is scoped to the *part* resource, not the name. If it ever landed on
    ///         the name-wide resource the agent would hold every text key at once, and every
    ///         rejection test below would pass for the wrong reason.
    function test_agentsTextRoleIsScopedPerKeyNotPerName() external {
        _provision();

        string[] memory keys = _allowlist();
        for (uint256 i; i < keys.length; ++i) {
            assertTrue(
                resolver.hasRoles(
                    _partResource(node, keys[i]), PermissionedResolverLib.ROLE_SET_TEXT, agent
                ),
                "ROLE_SET_TEXT at the key's own resource"
            );
        }
        assertFalse(
            resolver.hasRoles(
                _nameResource(node), PermissionedResolverLib.ROLE_SET_TEXT, agent
            ),
            "but never name-wide"
        );
        assertFalse(
            resolver.hasRoles(
                PermissionedResolverLib.resource(0, PermissionedResolverLib.partHash(KEY_ENDPOINT)),
                PermissionedResolverLib.ROLE_SET_TEXT,
                agent
            ),
            "and never for that key across all names"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // The agent is rejected everywhere else
    ////////////////////////////////////////////////////////////////////////

    function test_agentCannotWriteANonAllowlistedKey() external {
        _provision();
        string[4] memory denied = ["avatar", "url", "com.twitter", "agent:endpoint2"];

        for (uint256 i; i < denied.length; ++i) {
            _expectUnauthorized(
                _nameResource(node), PermissionedResolverLib.ROLE_SET_TEXT, agent
            );
            vm.prank(agent);
            resolver.setText(node, denied[i], "attacker-controlled");

            assertEq(resolver.text(node, denied[i]), "", "key stayed empty");
        }
    }

    /// @notice The headline boundary (IDEA.md §3.3): the agent publishes where to reach it and
    ///         which key signs for it, but never where its money goes. `addr()` is a different
    ///         role — `ROLE_SET_ADDR` — that `provision()` grants to nobody.
    function test_agentCannotWriteAddr() external {
        _provision();

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_ADDR, agent);
        vm.prank(agent);
        resolver.setAddr(node, attacker);

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_ADDR, agent);
        vm.prank(agent);
        resolver.setAddr(node, COIN_TYPE_ETH, abi.encodePacked(attacker));

        assertEq(resolver.addr(node), payable(address(0)), "addr() untouched");
    }

    /// @notice An allowlist of text keys is not a foothold on the other profiles. Each of these
    ///         needs its own role, and the agent holds none of them.
    function test_agentCannotWriteAnyOtherProfile() external {
        _provision();

        _expectUnauthorized(
            _nameResource(node), PermissionedResolverLib.ROLE_SET_CONTENTHASH, agent
        );
        vm.prank(agent);
        resolver.setContenthash(node, hex"1234");

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_PUBKEY, agent);
        vm.prank(agent);
        resolver.setPubkey(node, bytes32(uint256(1)), bytes32(uint256(2)));

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_NAME, agent);
        vm.prank(agent);
        resolver.setName(node, "attacker.eth");

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_DATA, agent);
        vm.prank(agent);
        resolver.setData(node, KEY_ENDPOINT, hex"1234"); // same key, different profile

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_ABI, agent);
        vm.prank(agent);
        resolver.setABI(node, 1, hex"1234");

        _expectUnauthorized(
            _nameResource(node), PermissionedResolverLib.ROLE_SET_INTERFACE, agent
        );
        vm.prank(agent);
        resolver.setInterface(node, 0xdeadbeef, attacker);

        // Nor may it wipe the record set and start clean.
        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_CLEAR, agent);
        vm.prank(agent);
        resolver.clearRecords(node);
    }

    /// @notice The escalation the allowlist would be worthless without: the agent cannot widen
    ///         its own allowlist, because granting `ROLE_SET_TEXT` needs the admin nybble.
    function test_agentCannotAuthorizeItselfMoreKeys() external {
        _provision();

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                _nameResource(node),
                PermissionedResolverLib.ROLE_SET_TEXT,
                agent
            )
        );
        vm.prank(agent);
        resolver.authorizeTextRoles(name, "avatar", agent, true);
    }

    /// @notice Nor may it hand an allowlisted key to an accomplice.
    function test_agentCannotDelegateAnAllowlistedKey() external {
        _provision();

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                _nameResource(node),
                PermissionedResolverLib.ROLE_SET_TEXT,
                agent
            )
        );
        vm.prank(agent);
        resolver.authorizeTextRoles(name, KEY_ENDPOINT, attacker, true);
    }

    /// @notice A second agent's name is a different namehash, so a compromised agent gains
    ///         nothing against its neighbours even on a shared resolver.
    function test_agentCannotWriteAnotherAgentsRecords() external {
        _provision();
        _provision("agent-777", attacker, _allowlist());
        bytes32 otherNode =
            NameCoder.namehash(NameCoder.encode(string.concat("agent-777.", PARENT)), 0);

        _expectUnauthorized(
            _nameResource(otherNode), PermissionedResolverLib.ROLE_SET_TEXT, agent
        );
        vm.prank(agent);
        resolver.setText(otherNode, KEY_ENDPOINT, "https://evil.example");
    }

    ////////////////////////////////////////////////////////////////////////
    // The operator keeps everything
    ////////////////////////////////////////////////////////////////////////

    function test_operatorCanWriteAnything() external {
        _provision();

        vm.startPrank(operator);
        resolver.setAddr(node, operator);
        resolver.setText(node, KEY_ENDPOINT, "https://operator-override.example");
        resolver.setText(node, "avatar", "ipfs://bafyAvatar"); // never allowlisted to the agent
        resolver.setContenthash(node, hex"1234");
        resolver.setName(node, "agent-404.operator.eth");
        vm.stopPrank();

        assertEq(resolver.addr(node), payable(operator), "operator owns addr()");
        assertEq(resolver.text(node, "avatar"), "ipfs://bafyAvatar", "and every text key");
        assertEq(resolver.contenthash(node), hex"1234", "and every other profile");
    }

    /// @notice The record-level kill switch, one tier below `unregister()`: the operator can
    ///         take a single key back without touching the name.
    function test_operatorCanRevokeASingleKeyFromTheAgent() external {
        _provision();

        vm.prank(agent);
        resolver.setText(node, KEY_ENDPOINT, "https://agent-404.example/api");

        vm.prank(operator);
        resolver.authorizeTextRoles(name, KEY_ENDPOINT, agent, false);

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_TEXT, agent);
        vm.prank(agent);
        resolver.setText(node, KEY_ENDPOINT, "https://evil.example");

        assertEq(
            resolver.text(node, KEY_ENDPOINT),
            "https://agent-404.example/api",
            "last honest value stands"
        );

        // Surgical: the agent's other keys are untouched.
        vm.prank(agent);
        resolver.setText(node, KEY_STATUS, "online");
        assertEq(resolver.text(node, KEY_STATUS), "online", "other keys still writable");
    }

    ////////////////////////////////////////////////////////////////////////
    // The sandbox delegates the permission without holding it
    ////////////////////////////////////////////////////////////////////////

    /// @notice The sandbox holds root `ROLE_SET_TEXT_ADMIN` on the resolver, which lets it grant
    ///         `ROLE_SET_TEXT` but is not itself a write permission. Worth asserting: the whole
    ///         "the sandbox is not a backdoor" claim now spans two contracts.
    function test_sandboxCannotWriteRecordsItself() external {
        _provision();

        assertEq(
            resolver.roles(resolver.ROOT_RESOURCE(), address(sandbox)),
            PermissionedResolverLib.ROLE_SET_TEXT_ADMIN,
            "sandbox's resolver authority is exactly one admin role"
        );

        _expectUnauthorized(
            _nameResource(node), PermissionedResolverLib.ROLE_SET_TEXT, address(sandbox)
        );
        vm.prank(address(sandbox));
        resolver.setText(node, KEY_ENDPOINT, "https://sandbox-was-a-backdoor.example");

        _expectUnauthorized(
            _nameResource(node), PermissionedResolverLib.ROLE_SET_ADDR, address(sandbox)
        );
        vm.prank(address(sandbox));
        resolver.setAddr(node, attacker);
    }

    /// @notice Provisioning fails loudly if the operator forgot to delegate on the resolver,
    ///         rather than minting a name whose agent silently cannot publish anything.
    function test_provision_revertsWhenSandboxLacksTextAdminOnResolver() external {
        AgentSandbox bare = new AgentSandbox(
            IPermissionedRegistry(address(registry)), NameCoder.encode(PARENT)
        );
        vm.prank(operator);
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(bare));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                _nameResource(
                    NameCoder.namehash(NameCoder.encode(string.concat("agent-9.", PARENT)), 0)
                ),
                PermissionedResolverLib.ROLE_SET_TEXT,
                address(bare)
            )
        );
        vm.prank(operator);
        bare.provision(
            "agent-9",
            agent,
            address(resolver),
            IRegistry(address(0)),
            0,
            _allowlist(),
            expiry
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // The allowlist is per-provisioning, not a constant
    ////////////////////////////////////////////////////////////////////////

    /// @notice Two agents, two different allowlists, same sandbox and same resolver. Each is
    ///         rejected on the other's key.
    function test_allowlistIsConfiguredPerProvisioning() external {
        string[] memory statusOnly = new string[](1);
        statusOnly[0] = KEY_STATUS;

        string[] memory endpointOnly = new string[](1);
        endpointOnly[0] = KEY_ENDPOINT;

        _provision("agent-a", agent, statusOnly);
        _provision("agent-b", attacker, endpointOnly);

        bytes32 aNode = NameCoder.namehash(NameCoder.encode(string.concat("agent-a.", PARENT)), 0);
        bytes32 bNode = NameCoder.namehash(NameCoder.encode(string.concat("agent-b.", PARENT)), 0);

        vm.prank(agent);
        resolver.setText(aNode, KEY_STATUS, "online");
        assertEq(resolver.text(aNode, KEY_STATUS), "online", "a writes its own key");

        _expectUnauthorized(_nameResource(aNode), PermissionedResolverLib.ROLE_SET_TEXT, agent);
        vm.prank(agent);
        resolver.setText(aNode, KEY_ENDPOINT, "https://a.example");

        vm.prank(attacker);
        resolver.setText(bNode, KEY_ENDPOINT, "https://b.example");
        assertEq(resolver.text(bNode, KEY_ENDPOINT), "https://b.example", "b writes its own key");

        _expectUnauthorized(_nameResource(bNode), PermissionedResolverLib.ROLE_SET_TEXT, attacker);
        vm.prank(attacker);
        resolver.setText(bNode, KEY_STATUS, "online");
    }

    /// @notice An empty allowlist is a valid provisioning: a name that resolves and an agent
    ///         that can publish nothing at all.
    function test_emptyAllowlistYieldsAMuteAgent() external {
        _provision(LABEL, agent, new string[](0));

        assertEq(registry.getOwner(LibLabel.id(LABEL)), agent, "the name still exists");

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_TEXT, agent);
        vm.prank(agent);
        resolver.setText(node, KEY_ENDPOINT, "https://agent-404.example/api");
    }

    function test_provision_rejectsAnEmptyTextKey() external {
        string[] memory keys = new string[](2);
        keys[0] = KEY_STATUS;
        keys[1] = "";

        vm.expectRevert(abi.encodeWithSelector(AgentSandbox.EmptyTextKey.selector, 1));
        vm.prank(operator);
        sandbox.provision(
            LABEL, agent, address(resolver), IRegistry(address(0)), 0, keys, expiry
        );
    }

    /// @notice The allowlist reaches the event a watcher indexes, in the order it was granted.
    function test_provision_emitsTheAllowlist() external {
        vm.recordLogs();
        _provision();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(sandbox) ||
                logs[i].topics[0] != AgentSandbox.AgentProvisioned.selector
            ) {
                continue;
            }
            found = true;
            (, , , string[] memory keys, ) =
                abi.decode(logs[i].data, (string, address, uint256, string[], uint64));
            string[] memory expected = _allowlist();
            assertEq(keys.length, expected.length, "allowlist length");
            for (uint256 j; j < keys.length; ++j) {
                assertEq(keys[j], expected[j], "allowlist entry");
            }
        }
        assertTrue(found, "AgentProvisioned emitted");
    }

    ////////////////////////////////////////////////////////////////////////
    // Interaction with the kill switch (finding 001)
    ////////////////////////////////////////////////////////////////////////

    /// @notice An honest limit, of the same shape as the orphaned-subtree note in IDEA.md §3.4:
    ///         resolver grants are keyed by *namehash*, which `unregister()` does not rotate, so
    ///         the agent's `ROLE_SET_TEXT` survives revocation. Containment comes from the name
    ///         no longer pointing at the resolver — nothing resolves, so nothing the agent
    ///         writes is reachable. This is exactly why T4's verifier is not optional.
    function test_revocationStopsResolutionButLeavesResolverRolesInPlace() external {
        uint256 id = _provision();

        vm.prank(operator);
        registry.unregister(id);

        assertEq(registry.getResolver(LABEL), address(0), "the name no longer resolves");
        assertEq(
            registry.roles(id, agent), 0, "registry-tier roles died with the name (finding 001)"
        );

        assertTrue(
            resolver.hasRoles(
                _partResource(node, KEY_STATUS), PermissionedResolverLib.ROLE_SET_TEXT, agent
            ),
            "but the resolver grant is keyed by namehash and outlives the registration"
        );
        vm.prank(agent);
        resolver.setText(node, KEY_STATUS, "still-writing-into-the-void");
        assertEq(resolver.text(node, KEY_STATUS), "still-writing-into-the-void", "write lands");
    }
}
