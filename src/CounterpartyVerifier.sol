// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {LibRegistry} from "~src/universalResolver/libraries/LibRegistry.sol";

/// @title CounterpartyVerifier
/// @notice The other half of the sandbox (IDEA.md §3.5): a counterparty that resolves an agent's
///         ENS name, reads its endpoint and current operating key, verifies the agent's signature
///         against that key, and **refuses to transact** when any of that fails.
///
/// Everything before this contract is the agent's side of the argument. A kill switch nothing
/// checks is theatre: `unregister()` does not stop the agent's process from signing messages or
/// its wallet from sending transactions — what dies is *discoverability*. That only matters if
/// counterparties gate on resolution, so the gate is part of the deliverable.
///
/// The verifier holds no roles, owns nothing, and is not trusted by the operator or the agent.
/// It is deliberately written as a contract rather than a script so the refusal is enforced where
/// the money moves: `payAgent()` either resolves-verifies-pays in one transaction or reverts.
///
/// Two decisions are load-bearing and easy to get wrong:
///
///   - **Resolution must be exact.** `LibRegistry.findResolver` walks the registry tree and, in
///     normal ENS fashion, falls back to the nearest *ancestor's* resolver when a name has none
///     of its own. That inheritance is correct for ENS and fatal here: a revoked agent's records
///     survive in the resolver (they are keyed by namehash, which `unregister()` does not rotate
///     — IDEA.md §3.4), so accepting an inherited resolver would let a killed agent keep
///     verifying out of a shared resolver. This contract accepts a resolver only when it is
///     registered against the agent's own name (`resolverOffset == 0`).
///
///   - **Refusal is the default.** Every failure path — no resolver, no endpoint, no key, an
///     unparseable key, a bad signature, a key mismatch, no payout address — refuses. There is no
///     branch that transacts on a partially resolved identity.
///
/// What the verifier checks is *authorship*: this message was signed by the key the name
/// currently publishes. What the message *means* — an invoice, a quote, a delivery receipt, and
/// whether it authorises this particular payment — is the counterparty's own business, and a
/// production integration binds the message to the amount and a nonce. That is application
/// semantics layered on top; the identity question is the one ENS answers.
contract CounterpartyVerifier {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice Why the verifier would refuse to transact, or `None` if it would not.
    ///
    /// @dev Ordered as the checks run, so the first failure is the reported one. Returned by the
    ///      view path (`checkAgent`) and carried in the `Refused` error on the transacting path,
    ///      so a demo UI and a reverting transaction give the same answer for the same reason.
    enum Refusal {
        /// @dev The verifier would transact.
        None,
        /// @dev No resolver is registered against the name itself — it was never provisioned, has
        ///      expired, or the operator revoked it. This is what the kill switch looks like from
        ///      the outside. An ancestor's inherited resolver does not satisfy the check.
        Unresolvable,
        /// @dev The name resolves but publishes no endpoint: there is nowhere to talk to it.
        NoEndpoint,
        /// @dev The name publishes no operating key, so no signature can be attributed to it.
        NoOperatingKey,
        /// @dev The operating key record is not a 20-byte hex address.
        MalformedOperatingKey,
        /// @dev The signature is not recoverable (wrong length, malleable `s`, invalid `v`).
        MalformedSignature,
        /// @dev The signature recovers to a key that is *not* the one the name publishes: a
        ///      retired key after a rotation, or an impersonator.
        KeyMismatch,
        /// @dev The name publishes no `addr()`, so there is no address to pay.
        NoPayoutAddress
    }

    /// @notice Everything the verifier needs about an agent, as resolved from ENS.
    /// @param resolver The resolver registered against the agent's own name.
    /// @param node The namehash of the agent's name.
    /// @param endpoint Where the agent listens (the agent writes this itself).
    /// @param operatingKey The key the agent currently signs with (the agent rotates this itself).
    /// @param payTo The address `addr()` resolves to — the operator's, never the agent's to move.
    struct AgentIdentity {
        address resolver;
        bytes32 node;
        string endpoint;
        address operatingKey;
        address payTo;
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENS root registry every lookup starts from.
    ///
    /// @dev The verifier's only configuration that matters: it trusts ENS and nothing else. It
    ///      is never handed a resolver address, because being handed one would skip exactly the
    ///      step revocation acts on.
    IRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice The text key carrying the agent's service endpoint.
    /// @dev A parameter, not a constant: the counterparty decides which records it reads, and the
    ///      track forbids hard-coded values. `bytes`-backed, so it cannot be `immutable`.
    string public ENDPOINT_KEY;

    /// @notice The text key carrying the agent's current operating key.
    /// @dev Must match `AgentSandbox.OPERATING_KEY` for the agents this verifier deals with —
    ///      asserted in the tests rather than imported, because a counterparty does not depend on
    ///      the operator's registrar contract. The value is read as `(0x)?[0-9a-fA-F]{40}` and
    ///      parsed to an address, so an EIP-55 checksummed publication verifies identically to a
    ///      lowercase one.
    string public OPERATING_KEY;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice A payment was made to an agent whose signature verified.
    /// @param node The namehash of the agent's name.
    /// @param payTo The `addr()` the payment went to.
    /// @param amount The amount paid.
    /// @param operatingKey The key the message verified against.
    event AgentPaid(
        bytes32 indexed node, address indexed payTo, uint256 amount, address operatingKey
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The verifier refused to transact.
    /// @param reason Which check failed.
    /// @param name The DNS-encoded name it refused on.
    error Refused(Refusal reason, bytes name);

    /// @notice The agent's payout address rejected the transfer.
    error PaymentFailed(address payTo, uint256 amount);

    /// @notice A text key the verifier reads must not be empty.
    error EmptyTextKey();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The ENS root registry to resolve against.
    /// @param endpointKey The text key the agent publishes its endpoint under.
    /// @param operatingKey The text key the agent publishes its operating key under.
    constructor(IRegistry rootRegistry, string memory endpointKey, string memory operatingKey) {
        if (bytes(endpointKey).length == 0 || bytes(operatingKey).length == 0) {
            revert EmptyTextKey();
        }
        ROOT_REGISTRY = rootRegistry;
        ENDPOINT_KEY = endpointKey;
        OPERATING_KEY = operatingKey;
    }

    ////////////////////////////////////////////////////////////////////////
    // Resolution
    ////////////////////////////////////////////////////////////////////////

    /// @notice Resolve an agent's identity from ENS, without deciding anything about it.
    /// @param name The DNS-encoded agent name.
    /// @return reason `Unresolvable` if the name has no resolver of its own, else `None`.
    /// @return id What the name publishes. Zero/empty fields where a record is absent.
    ///
    /// @dev Non-reverting on purpose: a client that wants to *display* an agent's state — and the
    ///      demo, which wants to show the moment resolution goes dark — needs to read a failure
    ///      rather than catch one.
    function resolveAgent(bytes calldata name)
        public
        view
        returns (Refusal reason, AgentIdentity memory id)
    {
        (, address resolver, bytes32 node, uint256 resolverOffset) =
            LibRegistry.findResolver(ROOT_REGISTRY, name, 0);

        // `resolverOffset != 0` means the resolver was inherited from an ancestor rather than
        // registered against this name. See the contract docs: accepting it would survive
        // revocation, because the agent's records outlive the registry entry that pointed here.
        if (resolver == address(0) || resolverOffset != 0) {
            return (Refusal.Unresolvable, id);
        }

        id.resolver = resolver;
        id.node = node;
        id.endpoint = _text(resolver, name, node, ENDPOINT_KEY);
        (, id.operatingKey) = Strings.tryParseAddress(_text(resolver, name, node, OPERATING_KEY));
        id.payTo = _addr(resolver, name, node);
    }

    ////////////////////////////////////////////////////////////////////////
    // Verification
    ////////////////////////////////////////////////////////////////////////

    /// @notice Would the verifier transact with this agent on this signed message?
    /// @param name The DNS-encoded agent name.
    /// @param message The message the agent signed, as an EIP-191 personal-sign payload.
    /// @param signature The agent's 65-byte signature over `message`.
    /// @return reason `None` if every check passes, else the first that failed.
    /// @return id The resolved identity, as far as resolution got.
    /// @return recovered The address the signature recovers to, or `address(0)` if unrecoverable.
    ///
    /// @dev The whole gate, in one view call. `payAgent()` is this plus the transfer, so the
    ///      answer a counterparty sees before sending is the answer it gets when it sends.
    function checkAgent(bytes calldata name, bytes calldata message, bytes calldata signature)
        public
        view
        returns (Refusal reason, AgentIdentity memory id, address recovered)
    {
        (reason, id) = resolveAgent(name);
        if (reason != Refusal.None) {
            return (reason, id, address(0));
        }
        if (bytes(id.endpoint).length == 0) {
            return (Refusal.NoEndpoint, id, address(0));
        }
        // An unparseable record and an absent one are different failures to an operator reading
        // logs, so they are distinguished here rather than collapsed into "no key". A record that
        // parses to the zero address counts as malformed: no signature ever recovers to it.
        if (id.operatingKey == address(0)) {
            reason = bytes(_text(id.resolver, name, id.node, OPERATING_KEY)).length == 0
                ? Refusal.NoOperatingKey
                : Refusal.MalformedOperatingKey;
            return (reason, id, address(0));
        }

        ECDSA.RecoverError recoverError;
        (recovered, recoverError, ) = ECDSA.tryRecover(
            MessageHashUtils.toEthSignedMessageHash(message), signature
        );
        if (recoverError != ECDSA.RecoverError.NoError) {
            return (Refusal.MalformedSignature, id, address(0));
        }
        if (recovered != id.operatingKey) {
            return (Refusal.KeyMismatch, id, recovered);
        }
        if (id.payTo == address(0)) {
            return (Refusal.NoPayoutAddress, id, recovered);
        }
        return (Refusal.None, id, recovered);
    }

    /// @notice Did this message come from the key the name currently publishes?
    /// @param name The DNS-encoded agent name.
    /// @param message The message the agent signed.
    /// @param signature The agent's signature over `message`.
    /// @return True only if the name resolves and the signature recovers to its published key.
    function verifyAgent(bytes calldata name, bytes calldata message, bytes calldata signature)
        external
        view
        returns (bool)
    {
        (Refusal reason, , ) = checkAgent(name, message, signature);
        // `NoPayoutAddress` is a payment problem, not an identity one: the signature is the
        // agent's either way, and a counterparty that is not sending money should be told so.
        return reason == Refusal.None || reason == Refusal.NoPayoutAddress;
    }

    ////////////////////////////////////////////////////////////////////////
    // Transacting
    ////////////////////////////////////////////////////////////////////////

    /// @notice Pay an agent, but only if ENS still vouches for it.
    /// @param name The DNS-encoded agent name.
    /// @param message The message the agent signed to solicit this payment.
    /// @param signature The agent's signature over `message`.
    /// @return payTo The address paid — always `addr()`, resolved fresh in this transaction.
    ///
    /// @dev The point of the whole project, in one function: the payment goes to the address ENS
    ///      publishes for the name, *not* to anything the agent said in `message`, and only after
    ///      the agent proved it holds the key the name currently publishes. An agent that rotates
    ///      its key keeps getting paid with no operator involvement (demo beat 2); a revoked one
    ///      stops being payable in the same block as `unregister()` (beat 4), because resolution
    ///      is redone here rather than cached.
    function payAgent(bytes calldata name, bytes calldata message, bytes calldata signature)
        external
        payable
        returns (address payTo)
    {
        (Refusal reason, AgentIdentity memory id, ) = checkAgent(name, message, signature);
        if (reason != Refusal.None) {
            revert Refused(reason, name);
        }
        payTo = id.payTo;
        emit AgentPaid(id.node, payTo, msg.value, id.operatingKey);
        (bool ok, ) = payTo.call{value: msg.value}("");
        if (!ok) {
            revert PaymentFailed(payTo, msg.value);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Reading records
    ////////////////////////////////////////////////////////////////////////

    /// @dev Read a text record the way a real client does: through `IExtendedResolver.resolve()`
    ///      when the resolver supports it (which is how ENSv2 resolvers expect to be called, and
    ///      what makes aliasing work), falling back to a direct `text()` call when it does not.
    ///      A resolver that reverts or returns nothing yields the empty string, which every
    ///      caller above treats as a refusal rather than a pass. A resolver returning bytes that
    ///      are not a valid ABI encoding reverts the decode instead — still a refusal on the
    ///      transacting path, but it costs the view path its reason code. Acceptable: the
    ///      resolver was found by walking ENS from the root, so it is the operator's choice.
    function _text(address resolver, bytes calldata name, bytes32 node, string memory key)
        private
        view
        returns (string memory value)
    {
        (bool ok, bytes memory result) =
            _call(resolver, name, abi.encodeCall(ITextResolver.text, (node, key)));
        if (ok && result.length >= 64) {
            value = abi.decode(result, (string));
        }
    }

    /// @dev Read `addr()`. Same failure-is-empty discipline as `_text`.
    function _addr(address resolver, bytes calldata name, bytes32 node)
        private
        view
        returns (address value)
    {
        (bool ok, bytes memory result) =
            _call(resolver, name, abi.encodeCall(IAddrResolver.addr, (node)));
        if (ok && result.length == 32) {
            value = abi.decode(result, (address));
        }
    }

    /// @dev Dispatch one resolver profile call, unwrapping `resolve()` if the resolver is an
    ///      `IExtendedResolver`. Offchain (CCIP-Read) resolvers revert with `OffchainLookup` and
    ///      therefore read as absent records: an on-chain verifier cannot follow that redirect,
    ///      and IDEA.md §6 already rejects off-chain records for this design.
    function _call(address resolver, bytes calldata name, bytes memory data)
        private
        view
        returns (bool ok, bytes memory result)
    {
        bool extended =
            ERC165Checker.supportsInterface(resolver, type(IExtendedResolver).interfaceId);
        (ok, result) = resolver.staticcall(
            extended ? abi.encodeCall(IExtendedResolver.resolve, (name, data)) : data
        );
        if (ok && extended) {
            // `resolve()` returns the profile's own return data, ABI-encoded as `bytes`.
            if (result.length < 64) {
                return (false, "");
            }
            result = abi.decode(result, (bytes));
        }
    }
}
