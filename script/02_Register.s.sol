// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgentSandbox} from "../src/AgentSandbox.sol";
import {CounterpartyVerifier} from "../src/CounterpartyVerifier.sol";
import {SepoliaConfig} from "./SepoliaConfig.sol";

import {IETHRegistrar} from "~src/registrar/interfaces/IETHRegistrar.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";

/// @notice T6 phase 2 of 2 — reveal the registration and wire the sandbox.
///
/// Run at least `MIN_COMMITMENT_AGE` (60s) and at most `MAX_COMMITMENT_AGE` (24h) after phase 1.
/// The registration parameters are re-derived from `deployments/sepolia.json` and must reproduce
/// phase 1's commitment exactly, so this script recomputes the hash and asserts the registrar
/// still holds it before spending gas.
///
/// After this runs the tree is `<root>` -> `eth` -> `<label>` -> (empty operator registry), and
/// the sandbox holds exactly two grants: root ROLE_REGISTRAR on the operator registry, and root
/// ROLE_SET_TEXT_ADMIN on the resolver. Those two, and nothing else, are what let `provision()`
/// mint an agent in one call. The sandbox holds no per-name roles anywhere -- the property T1
/// asserts in tests, re-asserted here against the live deployment before the script exits.
contract Register is Script {
    /// @dev Where phase 1 hands addresses to phase 2. Overridable so a fork test can exercise
    ///      these scripts without clobbering a real deployment record.
    function _outFile() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_FILE", string("./deployments/sepolia.json"));
    }

    /// @dev Held in memory rather than as locals: the registration binds eight parameters and
    ///      the wiring assertions need most of them afterwards, which overflows the stack.
    struct Deployment {
        address deployer;
        string label;
        string parentName;
        address operatorRegistry;
        address resolver;
        uint64 duration;
        address sandbox;
        address verifier;
        uint256 tokenId;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Deployment memory d;
        d.deployer = vm.addr(pk);

        string memory json = vm.readFile(_outFile());
        d.label = vm.parseJsonString(json, ".label");
        d.operatorRegistry = vm.parseJsonAddress(json, ".operatorRegistry");
        d.resolver = vm.parseJsonAddress(json, ".resolver");
        d.duration = uint64(vm.parseJsonUint(json, ".duration"));
        d.parentName = string.concat(d.label, ".eth");

        require(
            vm.parseJsonAddress(json, ".deployer") == d.deployer, "deployer changed since commit"
        );

        bytes32 secret = keccak256(abi.encode("ReputAI:T6", d.deployer, d.label));
        _requireRipeCommitment(d, secret);

        vm.startBroadcast(pk);
        _register(d, secret);
        _wire(d);
        vm.stopBroadcast();

        _assertWiring(d);
        _record(d);
    }

    /// @dev Recompute phase 1's commitment and check the registrar still holds it, before spending
    ///      gas on a `register()` that would revert.
    function _requireRipeCommitment(Deployment memory d, bytes32 secret) private view {
        bytes32 commitment = IETHRegistrar(SepoliaConfig.ETH_REGISTRAR).makeCommitment(
            d.label,
            d.deployer,
            secret,
            IRegistry(d.operatorRegistry),
            d.resolver,
            d.duration,
            bytes32(0)
        );
        uint64 committedAt = IETHRegistrar(SepoliaConfig.ETH_REGISTRAR).commitmentAt(commitment);
        require(committedAt != 0, "no commitment: re-run 01_Commit.s.sol");
        require(block.timestamp >= committedAt + 60, "commitment too new: wait 60s");
        require(block.timestamp < committedAt + 86400, "commitment expired: re-run 01_Commit.s.sol");
    }

    /// @dev The live mint. Subregistry and resolver are set in the same call, so the operator name
    ///      is never briefly resolvable-but-unrouted.
    function _register(Deployment memory d, bytes32 secret) private {
        d.tokenId = IETHRegistrar(SepoliaConfig.ETH_REGISTRAR).register(
            d.label,
            d.deployer,
            secret,
            IRegistry(d.operatorRegistry),
            d.resolver,
            d.duration,
            IERC20(SepoliaConfig.MOCK_USDC),
            bytes32(0)
        );
    }

    function _wire(Deployment memory d) private {
        // The sandbox is bound to one registry and one parent name at construction. The registry
        // addresses names by labelhash and does not know what it is called; the resolver scopes
        // everything by namehash. Passing the DNS-encoded parent is what stops the two tiers
        // silently disagreeing about which name they mean.
        AgentSandbox sandbox = new AgentSandbox(
            IPermissionedRegistry(d.operatorRegistry), NameCoder.encode(d.parentName)
        );
        d.sandbox = address(sandbox);

        // The sandbox's entire authority, both halves of it.
        //  - ROLE_REGISTRAR on the registry: it may mint, and (holding no per-name roles) it is
        //    provably not a backdoor into what it minted.
        //  - ROLE_SET_TEXT_ADMIN on the resolver: an admin nybble, so it can *grant* an agent
        //    ROLE_SET_TEXT for a named key while being unable to write any record itself.
        IPermissionedRegistry(d.operatorRegistry).grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR, d.sandbox
        );
        PermissionedResolver(d.resolver).grantRootRoles(
            PermissionedResolverLib.ROLE_SET_TEXT_ADMIN, d.sandbox
        );

        // The counterparty's own client, deployed here only for the demo's convenience -- it is
        // trusted by nobody, holds nothing, and anyone can deploy their own. It is handed the ENS
        // *root*, never a resolver, because being handed a resolver would skip the traversal step
        // that revocation acts on.
        d.verifier = address(
            new CounterpartyVerifier(
                IRegistry(SepoliaConfig.ROOT_REGISTRY),
                SepoliaConfig.ENDPOINT_KEY,
                sandbox.OPERATING_KEY()
            )
        );
    }

    function _record(Deployment memory d) private {
        string memory out = "deployment";
        vm.serializeString(out, "label", d.label);
        vm.serializeString(out, "parentName", d.parentName);
        vm.serializeAddress(out, "deployer", d.deployer);
        vm.serializeAddress(out, "operatorRegistry", d.operatorRegistry);
        vm.serializeAddress(out, "resolver", d.resolver);
        vm.serializeAddress(out, "sandbox", d.sandbox);
        vm.serializeAddress(out, "verifier", d.verifier);
        vm.serializeString(out, "endpointKey", SepoliaConfig.ENDPOINT_KEY);
        vm.serializeString(out, "operatingKey", AgentSandbox(d.sandbox).OPERATING_KEY());
        vm.serializeUint(out, "duration", d.duration);
        string memory result = vm.serializeUint(out, "operatorTokenId", d.tokenId);
        vm.writeJson(result, _outFile());

        console.log("registered        :", d.parentName);
        console.log("operator tokenId  :", d.tokenId);
        console.log("sandbox           :", d.sandbox);
        console.log("verifier          :", d.verifier);
    }

    /// @dev The T1/T2 containment properties, re-checked against the deployed instances rather
    ///      than assumed to have survived deployment. A wiring mistake here would silently turn
    ///      the sandbox into the backdoor the whole design claims it is not.
    function _assertWiring(Deployment memory d) private view {
        IPermissionedRegistry registry = IPermissionedRegistry(d.operatorRegistry);

        require(
            registry.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, d.sandbox),
            "d.sandbox cannot mint"
        );
        // The d.sandbox may mint but may not kill, transfer, or repoint anything it minted.
        require(
            !registry.hasRootRoles(RegistryRolesLib.ROLE_UNREGISTER, d.sandbox),
            "d.sandbox holds the kill switch"
        );
        require(
            !registry.hasRootRoles(RegistryRolesLib.ROLE_SET_RESOLVER, d.sandbox),
            "d.sandbox can repoint resolvers"
        );
        // The operator keeps the kill switch. Without this, beat 4 has nothing to fire.
        require(
            registry.hasRootRoles(RegistryRolesLib.ROLE_UNREGISTER, d.deployer),
            "operator lost the kill switch"
        );
        // Admin nybble only: the d.sandbox delegates a write permission it does not itself hold.
        require(
            PermissionedResolver(d.resolver).hasRootRoles(
                PermissionedResolverLib.ROLE_SET_TEXT_ADMIN, d.sandbox
            ),
            "d.sandbox cannot authorize text keys"
        );
        require(
            !PermissionedResolver(d.resolver).hasRootRoles(
                PermissionedResolverLib.ROLE_SET_TEXT, d.sandbox
            ),
            "d.sandbox can write records"
        );
        // The d.verifier is trusted by nobody and holds nothing, on either tier.
        require(
            !registry.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, d.verifier)
                && !PermissionedResolver(d.resolver).hasRootRoles(
                    PermissionedResolverLib.ROLE_SET_TEXT, d.verifier
                ),
            "d.verifier holds authority"
        );
    }
}
