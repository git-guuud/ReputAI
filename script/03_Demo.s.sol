// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable contract-name-camelcase

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AgentSandbox} from "../src/AgentSandbox.sol";
import {CounterpartyVerifier} from "../src/CounterpartyVerifier.sol";
import {SepoliaConfig} from "./SepoliaConfig.sol";

import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";

/// @notice T6 — IDEA.md §4's four beats as live transactions against the deployed contracts.
///
/// Every beat is its own script contract, and every one is a single logical step by a single
/// party, because *who signs which transaction* is the whole argument:
///
///   - the **operator** provisions and revokes, and never touches the agent's records;
///   - the **agent** publishes and rotates its own key, with no operator transaction in between;
///   - the **counterparty** pays through `CounterpartyVerifier`, knowing only the ENS root.
///
/// Splitting them also means the recording can pause on Etherscan between beats, and that a beat
/// can be re-run in isolation without replaying the ones before it.
///
/// Beat 3 (the escape attempts) is deliberately *not* here: its three transactions must revert
/// on-chain, and `forge script` refuses to broadcast a call that reverts in simulation. It runs
/// through `script/03b_escape.sh`, which sends them with an explicit gas limit so the failures
/// land on Sepolia where a viewer can click them.
///
/// State flows through two JSON files: the deployment record written by `02_Register`, and a demo
/// record written by beat 1 and read by every later beat. Both paths are overridable so the fork
/// test can run these scripts — the real ones, not a reimplementation — without touching the
/// live records.
abstract contract DemoBase is Script {
    /// @dev Everything a beat needs. In memory rather than as locals: past about eight of these
    ///      the stack overflows, the same reason `01`/`02` use structs.
    struct Demo {
        address operatorRegistry;
        address resolver;
        address sandbox;
        address verifier;
        string parentName;
        string label;
        string agentName;
        bytes agentNameEncoded;
        bytes32 agentNode;
        uint256 tokenId;
        address agent;
        address treasury;
        string endpointKey;
        string operatingKey;
    }

    /// @dev Written by `02_Register`. Read-only here: the demo never edits the deployment record.
    function _deploymentFile() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_FILE", string("./deployments/sepolia.json"));
    }

    /// @dev Written by beat 1, read by beats 2-4 and by `03b_escape.sh`.
    function _demoFile() internal view returns (string memory) {
        return vm.envOr("DEMO_FILE", string("./deployments/demo-sepolia.json"));
    }

    function _message() internal view returns (bytes memory) {
        return bytes(
            vm.envOr(
                "DEMO_MESSAGE", string("agent-404: invoice 17, settle to my published payout address")
            )
        );
    }

    function _payment() internal view returns (uint256) {
        return vm.envOr("DEMO_PAY_WEI", uint256(0.001 ether));
    }

    /// @dev The deployment half of the state: valid from the moment `02_Register` finishes.
    function _loadDeployment() internal view returns (Demo memory d) {
        string memory json = vm.readFile(_deploymentFile());
        d.operatorRegistry = vm.parseJsonAddress(json, ".operatorRegistry");
        d.resolver = vm.parseJsonAddress(json, ".resolver");
        d.sandbox = vm.parseJsonAddress(json, ".sandbox");
        d.verifier = vm.parseJsonAddress(json, ".verifier");
        d.parentName = vm.parseJsonString(json, ".parentName");
        d.endpointKey = vm.parseJsonString(json, ".endpointKey");
        d.operatingKey = vm.parseJsonString(json, ".operatingKey");
        d.label = vm.envOr("DEMO_AGENT_LABEL", string("agent-404"));
        d.agentName = string.concat(d.label, ".", d.parentName);
        d.agentNameEncoded = NameCoder.encode(d.agentName);
        d.agentNode = NameCoder.namehash(d.agentNameEncoded, 0);
        d.agent = vm.addr(vm.envUint("DEMO_AGENT_PK"));
        d.treasury = vm.envAddress("DEMO_TREASURY");
    }

    /// @dev The full state, including what beat 1 minted. Every beat after the first needs the
    ///      token ID, which is the registry's to assign and not derivable from the label alone.
    function _load() internal view returns (Demo memory d) {
        d = _loadDeployment();
        d.tokenId = vm.parseJsonUint(vm.readFile(_demoFile()), ".tokenId");
    }

    /// @dev EIP-191 personal-sign, the format `CounterpartyVerifier` recovers against. Signing is
    ///      off-chain: an operating key is a credential, never an on-chain authority, so these
    ///      keys are never funded and never send a transaction.
    function _signMessage(uint256 pk, bytes memory message) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(message));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The verifier's own view path, printed before every payment so the recording shows the
    ///      answer a counterparty gets *before* it spends anything — and shows it change.
    function _printState(Demo memory d, bytes memory signature) internal view {
        (
            CounterpartyVerifier.Refusal reason,
            CounterpartyVerifier.AgentIdentity memory id,
            address recovered
        ) = CounterpartyVerifier(payable(d.verifier)).checkAgent(
            d.agentNameEncoded, _message(), signature
        );
        console.log("  name             :", d.agentName);
        console.log("  resolver (exact) :", id.resolver);
        console.log("  endpoint         :", id.endpoint);
        console.log("  operating key    :", id.operatingKey);
        console.log("  payTo (addr())   :", id.payTo);
        console.log("  signature recover:", recovered);
        console.log("  verifier verdict :", _reason(reason));
    }

    function _reason(CounterpartyVerifier.Refusal reason) internal pure returns (string memory) {
        if (reason == CounterpartyVerifier.Refusal.None) return "None (would transact)";
        if (reason == CounterpartyVerifier.Refusal.Unresolvable) return "Unresolvable (REFUSED)";
        if (reason == CounterpartyVerifier.Refusal.NoEndpoint) return "NoEndpoint (REFUSED)";
        if (reason == CounterpartyVerifier.Refusal.NoOperatingKey) {
            return "NoOperatingKey (REFUSED)";
        }
        if (reason == CounterpartyVerifier.Refusal.MalformedOperatingKey) {
            return "MalformedOperatingKey (REFUSED)";
        }
        if (reason == CounterpartyVerifier.Refusal.MalformedSignature) {
            return "MalformedSignature (REFUSED)";
        }
        if (reason == CounterpartyVerifier.Refusal.KeyMismatch) return "KeyMismatch (REFUSED)";
        return "NoPayoutAddress (REFUSED)";
    }
}

/// @notice Beat 1 — provision. One operator transaction mints the agent's name, grants its role
///         bitmap, wires the resolver and authorizes exactly two text keys. A second publishes
///         the payout address, which is the operator's to set and the agent's to never move.
///
/// Nothing is pre-seeded: the label does not exist on-chain until this runs, which is the point
/// of doing it on camera.
contract Beat1_Provision is DemoBase {
    function run() external {
        Demo memory d = _loadDeployment();
        uint256 operatorPk = vm.envUint("PRIVATE_KEY");
        uint64 expiry = uint64(block.timestamp + vm.envOr("DEMO_AGENT_DURATION", uint256(180 days)));

        require(
            IPermissionedRegistry(d.operatorRegistry).getResolver(d.label) == address(0),
            "label already provisioned: pick another DEMO_AGENT_LABEL"
        );

        // Hoisted, both of them. An external call inside an argument list is evaluated before the
        // call it belongs to, which under `startBroadcast` sends it as its own transaction.
        string[] memory keys = new string[](2);
        keys[0] = d.endpointKey;
        keys[1] = d.operatingKey;

        vm.startBroadcast(operatorPk);

        uint256 tokenId = AgentSandbox(d.sandbox).provision(
            d.label,
            d.agent,
            d.resolver,
            IRegistry(address(0)), // no child registry: this agent spawns no workers
            0, // no registry roles at all — the tightest sandbox the ceiling allows
            keys,
            expiry
        );

        // The payout address. Written by the operator because `provision()` grants
        // `ROLE_SET_ADDR` to nobody: the agent's whole write surface is the two text keys above.
        PermissionedResolver(d.resolver).setAddr(d.agentNode, d.treasury);

        vm.stopBroadcast();

        d.tokenId = tokenId;
        _record(d, expiry);

        console.log("beat 1 - provisioned");
        console.log("  agent name       :", d.agentName);
        console.log("  agent (operator) :", d.agent);
        console.log("  tokenId          :", tokenId);
        console.log("  payTo (treasury) :", d.treasury);
        console.log("  writable keys    :", string.concat(d.endpointKey, ", ", d.operatingKey));
    }

    function _record(Demo memory d, uint64 expiry) private {
        string memory out = "demo";
        vm.serializeString(out, "agentName", d.agentName);
        vm.serializeString(out, "label", d.label);
        vm.serializeAddress(out, "agent", d.agent);
        vm.serializeAddress(out, "treasury", d.treasury);
        vm.serializeAddress(out, "counterparty", vm.addr(vm.envUint("DEMO_COUNTERPARTY_PK")));
        vm.serializeAddress(out, "keyGenesis", vm.addr(vm.envUint("DEMO_KEY_GENESIS_PK")));
        vm.serializeAddress(out, "keyRotated", vm.addr(vm.envUint("DEMO_KEY_ROTATED_PK")));
        vm.serializeBytes32(out, "agentNode", d.agentNode);
        // DNS-encoded, because `payAgent()` takes the wire format and `cast` cannot build it.
        // `03c_refused.sh` reads it from here to send beat 4's refused payment.
        vm.serializeBytes(out, "agentNameEncoded", d.agentNameEncoded);
        vm.serializeUint(out, "expiry", expiry);
        string memory json = vm.serializeUint(out, "tokenId", d.tokenId);
        vm.writeJson(json, _demoFile());
    }
}

/// @notice Beat 2a — the agent publishes. Two transactions signed by the agent's own key: where
///         it listens, and the key it will sign with. The operator is not in the loop and could
///         not write these records if it wanted to be — it holds `ROLE_SET_TEXT` at the root,
///         which is a different resource than the agent's per-key grants, so both parties can
///         write and neither depends on the other.
contract Beat2a_Publish is DemoBase {
    function run() external {
        Demo memory d = _load();
        address keyGenesis = vm.addr(vm.envUint("DEMO_KEY_GENESIS_PK"));
        string memory endpoint =
            vm.envOr("DEMO_ENDPOINT", string("https://agent-404.reputai.example/api"));

        vm.startBroadcast(vm.envUint("DEMO_AGENT_PK"));
        PermissionedResolver(d.resolver).setText(d.agentNode, d.endpointKey, endpoint);
        PermissionedResolver(d.resolver).setText(
            d.agentNode, d.operatingKey, Strings.toHexString(keyGenesis)
        );
        vm.stopBroadcast();

        console.log("beat 2a - agent published (no operator transaction)");
        console.log("  endpoint         :", endpoint);
        console.log("  operating key    :", keyGenesis);
    }
}

/// @notice Beat 2b — the counterparty pays. It knows the ENS root and nothing else: it resolves
///         the name itself, checks the signature against the *resolved* key, and sends to the
///         resolved `addr()` rather than anything the agent claimed in its message.
contract Beat2b_Pay is DemoBase {
    function run() external {
        Demo memory d = _load();
        bytes memory sig = _signMessage(vm.envUint("DEMO_KEY_GENESIS_PK"), _message());

        console.log("beat 2b - counterparty checks before paying");
        _printState(d, sig);

        vm.startBroadcast(vm.envUint("DEMO_COUNTERPARTY_PK"));
        CounterpartyVerifier(payable(d.verifier)).payAgent{value: _payment()}(
            d.agentNameEncoded, _message(), sig
        );
        vm.stopBroadcast();

        console.log("  paid (wei)       :", _payment());
        console.log("  treasury balance :", d.treasury.balance);
    }
}

/// @notice Beat 2c — the agent rotates its operating key. One transaction, one party, no
///         operator involvement, no downtime. `addr()` is untouched by it, which is the reason
///         rotation is safe to hand to the agent in the first place.
contract Beat2c_Rotate is DemoBase {
    function run() external {
        Demo memory d = _load();
        address keyRotated = vm.addr(vm.envUint("DEMO_KEY_ROTATED_PK"));
        address payToBefore = PermissionedResolver(d.resolver).addr(d.agentNode);

        vm.startBroadcast(vm.envUint("DEMO_AGENT_PK"));
        PermissionedResolver(d.resolver).setText(
            d.agentNode, d.operatingKey, Strings.toHexString(keyRotated)
        );
        vm.stopBroadcast();

        address payToAfter = PermissionedResolver(d.resolver).addr(d.agentNode);
        require(payToBefore == payToAfter, "rotation moved the payout address");

        console.log("beat 2c - agent rotated its own key");
        console.log("  new operating key:", keyRotated);
        console.log("  payTo unchanged  :", payToAfter);
    }
}

/// @notice Beat 2d — the counterparty pays again, on the rotated key, having been told nothing.
///         It follows the rotation because it re-resolves every time. The retired key is refused
///         in the same breath, which is what makes the rotation a rotation and not a fork.
contract Beat2d_PayRotated is DemoBase {
    function run() external {
        Demo memory d = _load();
        bytes memory sigRotated = _signMessage(vm.envUint("DEMO_KEY_ROTATED_PK"), _message());
        bytes memory sigRetired = _signMessage(vm.envUint("DEMO_KEY_GENESIS_PK"), _message());

        console.log("beat 2d - counterparty follows the rotation");
        _printState(d, sigRotated);

        vm.startBroadcast(vm.envUint("DEMO_COUNTERPARTY_PK"));
        CounterpartyVerifier(payable(d.verifier)).payAgent{value: _payment()}(
            d.agentNameEncoded, _message(), sigRotated
        );
        vm.stopBroadcast();

        console.log("  paid (wei)       :", _payment());
        console.log("  treasury balance :", d.treasury.balance);
        console.log("");
        console.log("  the retired key, same message, same verifier:");
        _printState(d, sigRetired);
    }
}

/// @notice Beat 4 — revoke. One operator transaction, and the counterparty's next payment
///         refuses. Nothing about the agent changed: it still holds its key, its records are
///         still in the resolver, and it never learns it was killed. What changed is that
///         nothing can route to it — containment here is unreachability, not deletion.
contract Beat4_Revoke is DemoBase {
    function run() external {
        Demo memory d = _load();
        bytes memory sig = _signMessage(vm.envUint("DEMO_KEY_ROTATED_PK"), _message());

        console.log("beat 4 - before revocation");
        _printState(d, sig);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IPermissionedRegistry(d.operatorRegistry).unregister(d.tokenId);
        vm.stopBroadcast();

        console.log("");
        console.log("beat 4 - after revocation (same key, same signature, same message)");
        _printState(d, sig);

        // The records are still there. It is the path to them that is gone.
        console.log("");
        console.log("  records survive, unreachable:");
        console.log(
            "    resolver still holds key:",
            PermissionedResolver(d.resolver).text(d.agentNode, d.operatingKey)
        );
        console.log("    registry owner now    :", IPermissionedRegistry(d.operatorRegistry).getOwner(d.tokenId));
    }
}

/// @notice Not a beat — a read-only snapshot, for narrating between beats without spending gas.
contract Status is DemoBase {
    function run() external view {
        Demo memory d = _load();
        console.log("status");
        console.log("  parent name      :", d.parentName);
        console.log("  operator registry:", d.operatorRegistry);
        console.log("  sandbox          :", d.sandbox);
        console.log("  verifier         :", d.verifier);
        console.log("  ENS root         :", SepoliaConfig.ROOT_REGISTRY);
        console.log("");
        _printState(d, _signMessage(vm.envUint("DEMO_KEY_ROTATED_PK"), _message()));
        console.log("  treasury balance :", d.treasury.balance);
    }
}
