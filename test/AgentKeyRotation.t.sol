// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable func-name-mixedcase, state-visibility

import {Test, Vm} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AgentSandbox} from "../src/AgentSandbox.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IStandardRegistry} from "~src/registry/interfaces/IStandardRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @notice T3 — operating-key rotation (IDEA.md §3.3), the sharpest case for the sandbox.
///
/// T2 supplied the mechanism: the operating key is just another allowlisted text key. What this
/// file establishes is the *semantics* — rotation is unilateral, repeatable, and inert on
/// `addr()` — and the claim the whole project exists to make:
///
/// > Compromising an agent's operating key lets an attacker impersonate its messaging until
/// > revocation, but never lets them receive its funds, take its name, or persist past the
/// > operator's kill switch.
///
/// Each clause of that sentence is a test below. The signature side is verified in-test with
/// `ECDSA.recover` against the *resolved* key — a miniature of T4's verifier, deliberately kept
/// to the one question T3 owes: does a rotated-in key actually sign as the agent?
///
/// Nothing is mocked: real `PermissionedRegistry`, real `PermissionedResolver` behind a
/// `VerifiableFactory` proxy.
contract AgentKeyRotationTest is Test {
    PermissionedRegistry registry;
    LabelStore labelStore;
    VerifiableFactory factory;
    PermissionedResolver resolver;
    AgentSandbox sandbox;

    address operator = makeAddr("operator");
    address agent = makeAddr("agent");
    address treasury = makeAddr("treasury"); // where counterparties pay: operator-controlled

    /// @dev The agent's operating keys. These are *not* the address that owns the name — that is
    ///      `agent`. The operating key is the rotatable credential the agent signs messages with,
    ///      and the only thing an attacker gains by stealing it is the ability to sign.
    uint256 keyGenesisPk;
    address keyGenesis;
    uint256 keyRotatedPk;
    address keyRotated;
    uint256 keyAttackerPk;
    address keyAttacker;

    string constant LABEL = "agent-404";
    string constant PARENT = "operator.eth";
    string constant KEY_ENDPOINT = "agent:endpoint";

    /// @dev Read from the sandbox rather than re-declared, so a drift in the convention breaks
    ///      this file instead of silently testing a key nobody uses.
    string keyOperating;

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
        keyOperating = sandbox.OPERATING_KEY();

        vm.startPrank(operator);
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(sandbox));
        resolver.grantRootRoles(PermissionedResolverLib.ROLE_SET_TEXT_ADMIN, address(sandbox));
        vm.stopPrank();

        (keyGenesis, keyGenesisPk) = makeAddrAndKey("operating-key-genesis");
        (keyRotated, keyRotatedPk) = makeAddrAndKey("operating-key-rotated");
        (keyAttacker, keyAttackerPk) = makeAddrAndKey("operating-key-attacker");

        name = NameCoder.encode(string.concat(LABEL, ".", PARENT));
        node = NameCoder.namehash(name, 0);
        expiry = uint64(block.timestamp + 365 days);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev An agent that may publish where it lives and which key signs for it. Nothing else.
    function _allowlist() internal view returns (string[] memory keys) {
        keys = new string[](2);
        keys[0] = KEY_ENDPOINT;
        keys[1] = keyOperating;
    }

    function _provision(string memory label, address who, string[] memory keys)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(operator);
        tokenId = sandbox.provision(
            label, who, address(resolver), IRegistry(address(0)), 0, keys, expiry
        );
    }

    function _provision() internal returns (uint256 tokenId) {
        return _provision(LABEL, agent, _allowlist());
    }

    /// @dev The operator wires the address counterparties pay. The agent is never party to this
    ///      and can never become one — `provision()` grants `ROLE_SET_ADDR` to nobody.
    function _setPayoutAddress() internal {
        vm.prank(operator);
        resolver.setAddr(node, treasury);
    }

    /// @dev The agent rotates. `vm.prank(agent)` is the whole ceremony: one call, one party.
    function _rotate(address newKey) internal {
        vm.prank(agent);
        resolver.setText(node, keyOperating, Strings.toHexString(newKey));
    }

    function _publishedKey() internal view returns (string memory) {
        return resolver.text(node, keyOperating);
    }

    function _sign(uint256 pk, string memory message) internal pure returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(bytes(message));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The one question T3 owes the verifier: does this signature belong to the key the name
    ///      currently publishes? Resolve, recover, compare. T4 turns this into a client that
    ///      refuses to transact when it returns false.
    function _verifiesAsAgent(string memory message, bytes memory signature)
        internal
        view
        returns (bool)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(bytes(message));
        address recovered = ECDSA.recover(digest, signature);
        return keccak256(bytes(Strings.toHexString(recovered))) == keccak256(bytes(_publishedKey()));
    }

    function _nameResource(bytes32 forNode) internal pure returns (uint256) {
        return PermissionedResolverLib.resource(forNode, bytes32(0));
    }

    function _partResource(bytes32 forNode, string memory key) internal pure returns (uint256) {
        return PermissionedResolverLib.resource(forNode, PermissionedResolverLib.partHash(key));
    }

    function _expectUnauthorized(uint256 resource, uint256 role, address who) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector, resource, role, who
            )
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Rotation is unilateral
    ////////////////////////////////////////////////////////////////////////

    /// @notice The autonomy claim. No operator signature appears anywhere in this test after
    ///         provisioning: the agent publishes a key and replaces it on its own authority.
    function test_agentRotatesItsOperatingKeyUnilaterally() external {
        _provision();

        _rotate(keyGenesis);
        assertEq(_publishedKey(), Strings.toHexString(keyGenesis), "genesis key published");

        _rotate(keyRotated);
        assertEq(_publishedKey(), Strings.toHexString(keyRotated), "rotated without a co-signer");
    }

    /// @notice Rotation is a steady-state operation, not a one-shot: agents restart and redeploy,
    ///         and a design that survives only one rotation would be bypassed in practice.
    function test_rotationIsRepeatable() external {
        _provision();

        for (uint256 i; i < 5; ++i) {
            address key = vm.addr(uint256(keccak256(abi.encode("rotation", i))));
            _rotate(key);
            assertEq(_publishedKey(), Strings.toHexString(key), "latest rotation wins");
        }
    }

    /// @notice Rotation is opt-in per provisioning, like every other key. An agent that should
    ///         hold a fixed key simply never receives the operating key in its allowlist, and is
    ///         rejected at the resolver rather than by convention.
    function test_rotationRequiresTheOperatingKeyInTheAllowlist() external {
        string[] memory endpointOnly = new string[](1);
        endpointOnly[0] = KEY_ENDPOINT;
        _provision("agent-fixed", agent, endpointOnly);
        bytes32 fixedNode =
            NameCoder.namehash(NameCoder.encode(string.concat("agent-fixed.", PARENT)), 0);

        _expectUnauthorized(
            _nameResource(fixedNode), PermissionedResolverLib.ROLE_SET_TEXT, agent
        );
        vm.prank(agent);
        resolver.setText(fixedNode, keyOperating, Strings.toHexString(keyRotated));

        assertEq(resolver.text(fixedNode, keyOperating), "", "no key was ever published");
    }

    ////////////////////////////////////////////////////////////////////////
    // `addr()` is unchanged by rotation
    ////////////////////////////////////////////////////////////////////////

    /// @notice The boundary that makes rotation safe to delegate: the two records are separate
    ///         resources behind separate roles, so exercising one cannot disturb the other.
    ///         Asserted before *and* after, per the exit criterion.
    function test_rotationLeavesAddrUnchanged() external {
        _provision();
        _setPayoutAddress();

        address before = resolver.addr(node);
        assertEq(before, treasury, "addr() starts at the operator's payout address");

        _rotate(keyGenesis);
        _rotate(keyRotated);

        assertEq(resolver.addr(node), before, "addr() is untouched by rotation");
        assertEq(resolver.addr(node), treasury, "and still points at the treasury");

        // And rotating never becomes a route to it: the role simply is not the agent's.
        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_ADDR, agent);
        vm.prank(agent);
        resolver.setAddr(node, keyRotated);

        assertEq(resolver.addr(node), treasury, "still the treasury");
    }

    ////////////////////////////////////////////////////////////////////////
    // A rotated-in key really does sign as the agent
    ////////////////////////////////////////////////////////////////////////

    /// @notice Rotation is meaningful in both directions: the new key starts verifying and the
    ///         old one stops. Without the second half, "rotation" would only be key *addition*.
    function test_rotationPromotesTheNewKeyAndDemotesTheOld() external {
        _provision();
        string memory message = "agent-404: invoice 17 accepted";

        _rotate(keyGenesis);
        bytes memory genesisSig = _sign(keyGenesisPk, message);
        assertTrue(_verifiesAsAgent(message, genesisSig), "genesis key signs as the agent");

        _rotate(keyRotated);
        assertFalse(_verifiesAsAgent(message, genesisSig), "the retired key no longer verifies");
        assertTrue(
            _verifiesAsAgent(message, _sign(keyRotatedPk, message)),
            "the rotated-in key does"
        );
    }

    /// @notice A key the name never published does not verify, rotation or no rotation. Cheap,
    ///         but it is what stops every assertion above from passing vacuously.
    function test_anUnpublishedKeyNeverVerifies() external {
        _provision();
        _rotate(keyGenesis);

        string memory message = "agent-404: invoice 17 accepted";
        assertFalse(
            _verifiesAsAgent(message, _sign(keyAttackerPk, message)),
            "an unrelated key is not the agent"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Bounded blast radius
    ////////////////////////////////////////////////////////////////////////

    /// @notice The full-compromise case, which is the honest one: an attacker who owns the agent
    ///         process holds the agent's own key, so they can rotate the operating key to
    ///         themselves. That is the attack IDEA.md §3.3 names, and this is its ceiling —
    ///         the attacker gains the ability to *speak* as the agent and nothing else.
    function test_compromisedAgentCanRotateToItselfButCannotEscape() external {
        uint256 tokenId = _provision();
        _setPayoutAddress();

        // The compromise: every call below is `agent`, i.e. the stolen key itself.
        _rotate(keyAttacker);
        string memory message = "agent-404: pay me instead";
        assertTrue(
            _verifiesAsAgent(message, _sign(keyAttackerPk, message)),
            "the attacker can now sign as the agent - this much is conceded"
        );

        // ...but cannot move funds: `addr()` is a different role, granted to nobody.
        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_ADDR, agent);
        vm.prank(agent);
        resolver.setAddr(node, keyAttacker);
        assertEq(resolver.addr(node), treasury, "the address counterparties pay is unmoved");

        // ...nor take the name: transfer is gated on an admin nybble the ceiling withholds.
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, tokenId, agent)
        );
        vm.prank(agent);
        registry.safeTransferFrom(agent, keyAttacker, tokenId, 1, "");
        assertEq(registry.getOwner(tokenId), agent, "the name did not move");

        // ...nor repoint the resolver, which would rewrite every record at once.
        uint256 id = LibLabel.id(LABEL);
        _expectUnauthorized(
            registry.getResource(id), RegistryRolesLib.ROLE_SET_RESOLVER, agent
        );
        vm.prank(agent);
        registry.setResolver(id, keyAttacker);
        assertEq(registry.getResolver(LABEL), address(resolver), "resolver unchanged");

        // ...nor widen the allowlist it rotates within.
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

    /// @notice The weaker adversary, for completeness: someone holding only the rotated-in
    ///         operating key. It is a signing credential and confers nothing on-chain — not even
    ///         the ability to rotate itself onward.
    function test_operatingKeyHolderHasNoOnChainAuthority() external {
        uint256 tokenId = _provision();
        _setPayoutAddress();
        _rotate(keyAttacker);

        assertEq(registry.roles(tokenId, keyAttacker), 0, "no registry roles");
        assertFalse(
            resolver.hasRoles(
                _partResource(node, keyOperating),
                PermissionedResolverLib.ROLE_SET_TEXT,
                keyAttacker
            ),
            "and no resolver roles, not even over the key it is"
        );

        _expectUnauthorized(
            _nameResource(node), PermissionedResolverLib.ROLE_SET_TEXT, keyAttacker
        );
        vm.prank(keyAttacker);
        resolver.setText(node, keyOperating, Strings.toHexString(keyGenesis));

        _expectUnauthorized(
            _nameResource(node), PermissionedResolverLib.ROLE_SET_ADDR, keyAttacker
        );
        vm.prank(keyAttacker);
        resolver.setAddr(node, keyAttacker);

        _expectUnauthorized(
            registry.getResource(LibLabel.id(LABEL)), RegistryRolesLib.ROLE_UNREGISTER, keyAttacker
        );
        vm.prank(keyAttacker);
        registry.unregister(LibLabel.id(LABEL));
    }

    /// @notice "Until revocation" is the duration bound. The operator's kill switch outranks any
    ///         rotation: after `unregister()` the name has no resolver, so a counterparty
    ///         resolving it finds no operating key to check a signature against — the attacker's
    ///         signature stops being attributable to the agent at all.
    ///
    ///         The honest caveat, same shape as T2's: the record itself survives in the resolver,
    ///         because grants and records are keyed by namehash and revocation does not rotate
    ///         it. Containment here is unreachability, not deletion — which is exactly why T4's
    ///         verifier must gate on resolution rather than on reading the resolver directly.
    function test_rotatedInKeyDoesNotSurviveRevocation() external {
        uint256 tokenId = _provision();
        _rotate(keyAttacker);

        vm.prank(operator);
        registry.unregister(tokenId);

        assertEq(registry.getResolver(LABEL), address(0), "nothing to resolve the key from");
        assertEq(registry.getOwner(tokenId), address(0), "the name is gone");
        assertEq(registry.roles(tokenId, agent), 0, "and the agent's registry roles with it");

        assertEq(
            resolver.text(node, keyOperating),
            Strings.toHexString(keyAttacker),
            "the stale record survives in the orphaned resolver - unreachable, not deleted"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // The operator's levers, short of the kill switch
    ////////////////////////////////////////////////////////////////////////

    /// @notice The graduated response to a suspected key compromise, and the reason rotation does
    ///         not need rate-limiting (IDEA.md §6): the operator freezes *rotation specifically*
    ///         by revoking one key's role. The agent keeps operating — it can still say where it
    ///         is and that it is up — while the published key is pinned to its last honest value
    ///         and only the operator can move it.
    function test_operatorCanFreezeRotationWithoutSilencingTheAgent() external {
        _provision();
        _rotate(keyGenesis);

        vm.prank(operator);
        resolver.authorizeTextRoles(name, keyOperating, agent, false);

        _expectUnauthorized(_nameResource(node), PermissionedResolverLib.ROLE_SET_TEXT, agent);
        vm.prank(agent);
        resolver.setText(node, keyOperating, Strings.toHexString(keyAttacker));

        assertEq(_publishedKey(), Strings.toHexString(keyGenesis), "pinned to the honest key");

        // Surgical: the rest of the agent's surface is untouched.
        vm.prank(agent);
        resolver.setText(node, KEY_ENDPOINT, "https://agent-404.example/api");
        assertEq(
            resolver.text(node, KEY_ENDPOINT),
            "https://agent-404.example/api",
            "the agent still operates"
        );

        // And the operator can rotate on the agent's behalf while frozen.
        vm.prank(operator);
        resolver.setText(node, keyOperating, Strings.toHexString(keyRotated));
        assertEq(_publishedKey(), Strings.toHexString(keyRotated), "recovery stays possible");
    }

    /// @notice The recorded decision made testable (IDEA.md §6): rotation is loud rather than
    ///         rate-limited. `TextChanged` indexes both the node and the key, so an operator
    ///         watcher subscribes to exactly `(node, keccak256(OPERATING_KEY))` and sees every
    ///         rotation — no polling, no per-name state, and no contract in the write path.
    function test_rotationEmitsAnEventAWatcherCanFilterOn() external {
        _provision();

        vm.recordLogs();
        _rotate(keyRotated);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(resolver) ||
                logs[i].topics[0] != ITextResolver.TextChanged.selector
            ) {
                continue;
            }
            assertEq(logs[i].topics[1], node, "indexed by the agent's name");
            assertEq(
                logs[i].topics[2],
                keccak256(bytes(keyOperating)),
                "and by the operating key, so the watcher's filter is exact"
            );
            (string memory key, string memory value) =
                abi.decode(logs[i].data, (string, string));
            assertEq(key, keyOperating, "key in the payload");
            assertEq(value, Strings.toHexString(keyRotated), "the new key is in the log itself");
            found = true;
        }
        assertTrue(found, "TextChanged emitted");
    }
}
