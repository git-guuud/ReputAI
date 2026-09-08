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

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {LibRegistry} from "~src/universalResolver/libraries/LibRegistry.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @notice T4 — the counterparty verifier (IDEA.md §3.5). The half of the argument that makes
///         every other half observable.
///
/// Up to now the sandbox has been proved from the inside: the agent tries something and the
/// registry or the resolver reverts. That is a permission diagram holding. What a judge — or a
/// counterparty — actually cares about is the outside view: *does the money stop?* So this file
/// resolves the agent's name the way any ENS client would, from a root registry down through the
/// hierarchy, and gates a real value transfer on the result.
///
/// The hierarchy is the real thing, three registries deep, no mocks anywhere:
///
///   <root>            -> rootRegistry
///     eth             -> ethRegistry
///       operator      -> operatorRegistry   (resolver set: the operator's own name resolves)
///         agent-404   -> minted by AgentSandbox, resolver set, agent owns nothing
///
/// The demo beats this file covers: 2 (the verifier follows a rotation with no operator in the
/// loop) and 4 (the operator revokes; the verifier's next call refuses).
contract CounterpartyVerifierTest is Test {
    LabelStore labelStore;
    PermissionedRegistry rootRegistry;
    PermissionedRegistry ethRegistry;
    PermissionedRegistry operatorRegistry;
    VerifiableFactory factory;
    PermissionedResolver resolver;
    AgentSandbox sandbox;
    CounterpartyVerifier verifier;

    address root = makeAddr("root");
    address operator = makeAddr("operator");
    address agent = makeAddr("agent");
    address treasury = makeAddr("treasury"); // the operator's payout address: `addr()`
    address counterparty = makeAddr("counterparty"); // pays through the verifier

    uint256 keyGenesisPk;
    address keyGenesis;
    uint256 keyRotatedPk;
    address keyRotated;
    uint256 keyAttackerPk;
    address keyAttacker;

    string constant LABEL = "agent-404";
    string constant PARENT = "operator.eth";
    string constant ENDPOINT = "https://agent-404.example/api";

    string keyEndpoint = "agent:endpoint";
    string keyOperating;

    bytes name;
    bytes32 node;
    uint64 expiry;

    bytes message = bytes("agent-404: invoice 17, please pay 0.5 ETH");

    function setUp() external {
        labelStore = new LabelStore(IContractNamer(address(0)));
        rootRegistry = new PermissionedRegistry(labelStore, root, EACBaseRolesLib.ALL_ROLES);
        ethRegistry = new PermissionedRegistry(labelStore, root, EACBaseRolesLib.ALL_ROLES);
        operatorRegistry = new PermissionedRegistry(
            labelStore, operator, EACBaseRolesLib.ALL_ROLES
        );

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

        // <root> -> eth -> operator. The operator's own name carries a resolver, exactly as a
        // real deployment would; `test_refusesAnInheritedResolver` depends on it being there.
        vm.startPrank(root);
        rootRegistry.register(
            "eth", root, IRegistry(address(ethRegistry)), address(0), 0, expiry
        );
        ethRegistry.register(
            "operator",
            operator,
            IRegistry(address(operatorRegistry)),
            address(resolver),
            0,
            expiry
        );
        vm.stopPrank();

        sandbox = new AgentSandbox(
            IPermissionedRegistry(address(operatorRegistry)), NameCoder.encode(PARENT)
        );
        keyOperating = sandbox.OPERATING_KEY();

        vm.startPrank(operator);
        operatorRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(sandbox));
        resolver.grantRootRoles(PermissionedResolverLib.ROLE_SET_TEXT_ADMIN, address(sandbox));
        vm.stopPrank();

        // The counterparty's own client. It is handed the ENS root and the two record keys it
        // reads — never a resolver address, because being handed one would skip the step
        // revocation acts on.
        verifier = new CounterpartyVerifier(
            IRegistry(address(rootRegistry)), keyEndpoint, keyOperating
        );

        (keyGenesis, keyGenesisPk) = makeAddrAndKey("operating-key-genesis");
        (keyRotated, keyRotatedPk) = makeAddrAndKey("operating-key-rotated");
        (keyAttacker, keyAttackerPk) = makeAddrAndKey("operating-key-attacker");

        name = NameCoder.encode(string.concat(LABEL, ".", PARENT));
        node = NameCoder.namehash(name, 0);

        vm.deal(counterparty, 100 ether);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _allowlist() internal view returns (string[] memory keys) {
        keys = new string[](2);
        keys[0] = keyEndpoint;
        keys[1] = keyOperating;
    }

    function _provision() internal returns (uint256 tokenId) {
        vm.prank(operator);
        tokenId = sandbox.provision(
            LABEL, agent, address(resolver), IRegistry(address(0)), 0, _allowlist(), expiry
        );
    }

    /// @dev A live, fully wired agent: name minted, payout address set by the operator, endpoint
    ///      and operating key published by the agent itself.
    function _liveAgent() internal returns (uint256 tokenId) {
        tokenId = _provision();
        vm.prank(operator);
        resolver.setAddr(node, treasury);
        vm.startPrank(agent);
        resolver.setText(node, keyEndpoint, ENDPOINT);
        resolver.setText(node, keyOperating, Strings.toHexString(keyGenesis));
        vm.stopPrank();
    }

    function _rotate(address newKey) internal {
        vm.prank(agent);
        resolver.setText(node, keyOperating, Strings.toHexString(newKey));
    }

    function _sign(uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(message));
        return abi.encodePacked(r, s, v);
    }

    function _check(bytes memory signature) internal view returns (CounterpartyVerifier.Refusal) {
        (CounterpartyVerifier.Refusal reason, , ) = verifier.checkAgent(name, message, signature);
        return reason;
    }

    function _pay(bytes memory signature) internal returns (address) {
        vm.prank(counterparty);
        return verifier.payAgent{value: 0.5 ether}(name, message, signature);
    }

    function _expectRefusal(CounterpartyVerifier.Refusal reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(CounterpartyVerifier.Refused.selector, reason, name)
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Resolution
    ////////////////////////////////////////////////////////////////////////

    /// @notice The first exit criterion: a client that starts from nothing but the ENS root and a
    ///         name comes back with the endpoint and the operating key.
    function test_resolvesEndpointAndOperatingKeyFromTheRoot() external {
        _liveAgent();

        (CounterpartyVerifier.Refusal reason, CounterpartyVerifier.AgentIdentity memory id) =
            verifier.resolveAgent(name);

        assertEq(uint256(reason), uint256(CounterpartyVerifier.Refusal.None), "resolves");
        assertEq(id.resolver, address(resolver), "found the agent's own resolver");
        assertEq(id.node, node, "namehash built by the traversal, not passed in");
        assertEq(id.endpoint, ENDPOINT, "endpoint read");
        assertEq(id.operatingKey, keyGenesis, "operating key read and parsed to an address");
        assertEq(id.payTo, treasury, "and the address it would actually pay");
    }

    /// @notice The verifier is a bystander, not a participant: it holds no roles anywhere and
    ///         needs none. Cheap to assert, and it is the reason a counterparty can run its own.
    function test_verifierHoldsNoAuthority() external {
        uint256 tokenId = _liveAgent();
        assertEq(operatorRegistry.roles(tokenId, address(verifier)), 0, "no registry roles");
        assertEq(
            resolver.roles(
                PermissionedResolverLib.resource(node, bytes32(0)), address(verifier)
            ),
            0,
            "no resolver roles"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Verification
    ////////////////////////////////////////////////////////////////////////

    /// @notice The second exit criterion, in its simplest form.
    function test_verifiesASignatureAgainstTheResolvedKey() external {
        _liveAgent();
        assertTrue(verifier.verifyAgent(name, message, _sign(keyGenesisPk)), "the agent signed");
        assertEq(uint256(_check(_sign(keyGenesisPk))), 0, "and nothing else refuses");
    }

    /// @notice Impersonation, refused. Without this the check above passes for anybody.
    function test_refusesASignatureFromAKeyTheNameDoesNotPublish() external {
        _liveAgent();
        assertFalse(verifier.verifyAgent(name, message, _sign(keyAttackerPk)), "not the agent");
        assertEq(
            uint256(_check(_sign(keyAttackerPk))),
            uint256(CounterpartyVerifier.Refusal.KeyMismatch),
            "and it says why"
        );

        _expectRefusal(CounterpartyVerifier.Refusal.KeyMismatch);
        _pay(_sign(keyAttackerPk));
    }

    /// @notice Demo beat 2: the agent rotates its key with no operator in the loop, and the
    ///         counterparty follows it across the change — same name, same call, no
    ///         reconfiguration. The retired key stops being accepted in the same transaction.
    function test_followsARotationWithNoOperatorInvolvement() external {
        _liveAgent();
        bytes memory genesisSig = _sign(keyGenesisPk);
        assertTrue(verifier.verifyAgent(name, message, genesisSig), "verifies before rotation");

        _rotate(keyRotated); // one call, one party: the agent

        assertEq(
            uint256(_check(genesisSig)),
            uint256(CounterpartyVerifier.Refusal.KeyMismatch),
            "the retired key is refused immediately"
        );
        assertTrue(
            verifier.verifyAgent(name, message, _sign(keyRotatedPk)),
            "and the rotated-in key is accepted, with no operator transaction anywhere"
        );
        assertEq(_pay(_sign(keyRotatedPk)), treasury, "the counterparty keeps paying");
    }

    /// @notice The convention gap flagged in STATUS.md, closed: the operating key is compared as
    ///         an *address*, so an EIP-55 checksummed publication verifies identically to a
    ///         lowercase one. Publishing it the other way would otherwise make a healthy agent
    ///         look like a key mismatch — a refusal for a formatting difference.
    function test_aChecksumCasedOperatingKeyVerifies() external {
        _liveAgent();
        vm.prank(agent);
        resolver.setText(node, keyOperating, Strings.toChecksumHexString(keyRotated));

        assertTrue(
            verifier.verifyAgent(name, message, _sign(keyRotatedPk)),
            "case is not part of the identity"
        );
    }

    /// @notice A record that is not an address at all is a refusal, not a parse revert — and a
    ///         *different* refusal from publishing nothing, because the two mean different things
    ///         to whoever is reading the logs.
    function test_refusesAMalformedOperatingKey() external {
        _liveAgent();
        vm.prank(agent);
        resolver.setText(node, keyOperating, "steal-my-money");

        assertEq(
            uint256(_check(_sign(keyGenesisPk))),
            uint256(CounterpartyVerifier.Refusal.MalformedOperatingKey),
            "malformed, and named as such"
        );
        _expectRefusal(CounterpartyVerifier.Refusal.MalformedOperatingKey);
        _pay(_sign(keyGenesisPk));
    }

    /// @notice Garbage in the signature slot refuses rather than reverting somewhere unhelpful.
    function test_refusesAMalformedSignature() external {
        _liveAgent();
        assertEq(
            uint256(_check(hex"deadbeef")),
            uint256(CounterpartyVerifier.Refusal.MalformedSignature),
            "not a signature"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Refusing to transact
    ////////////////////////////////////////////////////////////////////////

    /// @notice The money goes where *ENS* says, not where the message says. The agent can write
    ///         its endpoint and its key; it can write neither the payout address nor anything the
    ///         verifier treats as one.
    function test_paysTheResolvedAddressAndNotTheAgent() external {
        _liveAgent();

        uint256 treasuryBefore = treasury.balance;
        uint256 agentBefore = agent.balance;

        assertEq(_pay(_sign(keyGenesisPk)), treasury, "paid the resolved addr()");

        assertEq(treasury.balance, treasuryBefore + 0.5 ether, "the operator's address received");
        assertEq(agent.balance, agentBefore, "the agent received nothing");
        assertEq(counterparty.balance, 99.5 ether, "and the counterparty is out 0.5");
    }

    /// @notice A name that was never provisioned. Note this is the *sibling* case of revocation:
    ///         `ghost.operator.eth` inherits the operator's resolver through normal ENS fallback,
    ///         and the verifier still refuses, because inheritance is not identity.
    function test_refusesANameThatWasNeverProvisioned() external {
        bytes memory ghost = NameCoder.encode(string.concat("ghost.", PARENT));
        (CounterpartyVerifier.Refusal reason, ) = verifier.resolveAgent(ghost);
        assertEq(
            uint256(reason), uint256(CounterpartyVerifier.Refusal.Unresolvable), "no such agent"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CounterpartyVerifier.Refused.selector,
                CounterpartyVerifier.Refusal.Unresolvable,
                ghost
            )
        );
        vm.prank(counterparty);
        verifier.payAgent{value: 0.5 ether}(ghost, message, _sign(keyGenesisPk));
    }

    /// @notice A provisioned agent that has not published yet is not transactable. Both halves
    ///         of the first exit criterion are load-bearing: an agent you cannot reach is refused
    ///         even when its signature is good.
    function test_refusesWhenTheAgentPublishedNoEndpointOrKey() external {
        _provision();
        vm.prank(operator);
        resolver.setAddr(node, treasury);

        assertEq(
            uint256(_check(_sign(keyGenesisPk))),
            uint256(CounterpartyVerifier.Refusal.NoEndpoint),
            "nowhere to talk to it"
        );

        vm.prank(agent);
        resolver.setText(node, keyEndpoint, ENDPOINT);
        assertEq(
            uint256(_check(_sign(keyGenesisPk))),
            uint256(CounterpartyVerifier.Refusal.NoOperatingKey),
            "and nothing to attribute a signature to"
        );
    }

    /// @notice An agent with no `addr()` is verifiable but not payable, and the two answers are
    ///         reported separately: the signature really is the agent's, there is just nowhere to
    ///         send money. Collapsing them would tell a counterparty the agent is an impostor.
    function test_refusesToPayAnAgentWithNoPayoutAddress() external {
        _provision();
        vm.startPrank(agent);
        resolver.setText(node, keyEndpoint, ENDPOINT);
        resolver.setText(node, keyOperating, Strings.toHexString(keyGenesis));
        vm.stopPrank();

        assertTrue(verifier.verifyAgent(name, message, _sign(keyGenesisPk)), "identity is fine");
        _expectRefusal(CounterpartyVerifier.Refusal.NoPayoutAddress);
        _pay(_sign(keyGenesisPk));
    }

    ////////////////////////////////////////////////////////////////////////
    // The integration test: revoke mid-flow
    ////////////////////////////////////////////////////////////////////////

    /// @notice Demo beat 4, and the exit criterion this whole file exists for. A counterparty in
    ///         an ongoing relationship — it paid this agent a moment ago — is cut off by the
    ///         operator between one call and the next. Nothing about the agent changed: same key,
    ///         same signature, same endpoint, still able to sign. What changed is that ENS no
    ///         longer vouches for it, and that is enough to stop the money.
    function test_revokeMidFlow_theNextCallRefuses() external {
        uint256 tokenId = _liveAgent();
        bytes memory signature = _sign(keyGenesisPk);

        assertEq(_pay(signature), treasury, "the first payment goes through");

        // The operator pulls the kill switch (finding 001).
        vm.prank(operator);
        operatorRegistry.unregister(tokenId);

        (CounterpartyVerifier.Refusal reason, ) = verifier.resolveAgent(name);
        assertEq(
            uint256(reason),
            uint256(CounterpartyVerifier.Refusal.Unresolvable),
            "resolution goes dark in the same block"
        );
        assertFalse(verifier.verifyAgent(name, message, signature), "the signature stops counting");

        uint256 treasuryBefore = treasury.balance;
        _expectRefusal(CounterpartyVerifier.Refusal.Unresolvable);
        _pay(signature);
        assertEq(treasury.balance, treasuryBefore, "and nothing moved");
    }

    /// @notice The sharp edge underneath that test, worth its own assertions because getting it
    ///         wrong would silently defeat the kill switch.
    ///
    ///         `unregister()` does not delete the agent's records: they are keyed by namehash,
    ///         which revocation does not rotate (IDEA.md §3.4). Meanwhile ENS resolution normally
    ///         *inherits* an ancestor's resolver when a name has none of its own — and here the
    ///         ancestor is `operator.eth`, pointing at the very same resolver contract. A verifier
    ///         that accepted an inherited resolver would therefore read a revoked agent's stale
    ///         key straight out of it and keep paying.
    ///
    ///         Both halves are asserted: the stale record really is still readable through the
    ///         inherited resolver, and the verifier still refuses.
    function test_refusesAnInheritedResolverEvenWhenItStillHoldsTheRecords() external {
        uint256 tokenId = _liveAgent();

        vm.prank(operator);
        operatorRegistry.unregister(tokenId);

        // ENS itself still finds a resolver for the name - the parent's.
        (, address found, bytes32 foundNode, uint256 resolverOffset) =
            LibRegistry.findResolver(IRegistry(address(rootRegistry)), name, 0);
        assertEq(found, address(resolver), "inherited from operator.eth");
        assertEq(foundNode, node, "for the agent's own namehash");
        assertTrue(resolverOffset != 0, "but registered against an ancestor, not the agent");

        // ...and the revoked agent's records are still sitting in it.
        assertEq(
            resolver.text(node, keyOperating),
            Strings.toHexString(keyGenesis),
            "the stale key survives revocation - unreachable, not deleted"
        );
        assertEq(resolver.addr(node), treasury, "as does addr()");

        // The verifier refuses anyway: a resolver inherited from an ancestor is not the agent's.
        (CounterpartyVerifier.Refusal reason, ) = verifier.resolveAgent(name);
        assertEq(
            uint256(reason),
            uint256(CounterpartyVerifier.Refusal.Unresolvable),
            "inheritance is not identity"
        );
        _expectRefusal(CounterpartyVerifier.Refusal.Unresolvable);
        _pay(_sign(keyGenesisPk));
    }

    /// @notice The other way a lease ends. Revocation is the operator acting; expiry is the
    ///         operator *not* acting, and the verifier must treat them the same.
    function test_refusesAfterTheLeaseExpires() external {
        _liveAgent();
        bytes memory signature = _sign(keyGenesisPk);
        assertTrue(verifier.verifyAgent(name, message, signature), "live until it is not");

        vm.warp(expiry + 1);

        (CounterpartyVerifier.Refusal reason, ) = verifier.resolveAgent(name);
        assertEq(
            uint256(reason),
            uint256(CounterpartyVerifier.Refusal.Unresolvable),
            "an expired name resolves to nothing"
        );
        _expectRefusal(CounterpartyVerifier.Refusal.Unresolvable);
        _pay(signature);
    }

    /// @notice The graduated lever from T3, seen from the counterparty's side: freezing rotation
    ///         does not take the agent offline. Payments keep flowing against the pinned key
    ///         while the operator decides whether to escalate to `unregister()`.
    function test_frozenRotationKeepsTheAgentPayableOnItsLastHonestKey() external {
        _liveAgent();

        vm.prank(operator);
        resolver.authorizeTextRoles(name, keyOperating, agent, false);

        vm.expectRevert();
        _rotate(keyAttacker);

        assertEq(_pay(_sign(keyGenesisPk)), treasury, "still trading on the honest key");
        assertEq(
            uint256(_check(_sign(keyAttackerPk))),
            uint256(CounterpartyVerifier.Refusal.KeyMismatch),
            "and the attacker's key never got published"
        );
    }

    /// @notice Fuzzed: no key other than the published one is ever accepted, and the agent's own
    ///         name-owning key is not special - it signs messages no better than a stranger.
    function testFuzz_onlyThePublishedKeyIsAccepted(uint256 pk) external {
        pk = bound(pk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        _liveAgent();

        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(message));
        bytes memory signature = abi.encodePacked(r, s, v);

        assertEq(
            verifier.verifyAgent(name, message, signature),
            vm.addr(pk) == keyGenesis,
            "accepted if and only if it is the published key"
        );
    }
}
