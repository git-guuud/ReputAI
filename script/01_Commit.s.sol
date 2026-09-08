// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {SepoliaConfig} from "./SepoliaConfig.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {IETHRegistrar} from "~src/registrar/interfaces/IETHRegistrar.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice T6 phase 1 of 2 — deploy the operator's own registry and resolver, then commit to the
///         `.eth` registration that will point at them.
///
/// Split from phase 2 because `ETHRegistrar.MIN_COMMITMENT_AGE` is 60 seconds on Sepolia: the
/// commitment must age between two transactions, and a Foundry script cannot wait inside one
/// broadcast. The commitment hash binds the subregistry and resolver addresses, so both proxies
/// have to exist *before* we commit — which is why they are deployed here rather than in phase 2.
///
/// Nothing here is pre-seeded: the registry and resolver are fresh proxies owned by the deployer,
/// and the name is still unregistered when this script finishes.
contract Commit is Script {
    /// @dev Where phase 1 hands addresses to phase 2. Overridable so a fork test can exercise
    ///      these scripts without clobbering a real deployment record.
    function _outFile() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_FILE", string("./deployments/sepolia.json"));
    }

    /// @dev Kept in memory rather than as locals: the commitment binds seven parameters, and
    ///      holding them all on the stack overflows it.
    struct Plan {
        address deployer;
        string label;
        uint64 duration;
        bytes32 secret;
        address operatorRegistry;
        address resolver;
        uint256 price;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Plan memory plan;
        plan.deployer = vm.addr(pk);
        plan.label = vm.envString("AGENT_PARENT_LABEL");
        plan.duration = uint64(vm.envOr("REGISTER_DURATION", uint256(365 days)));

        IETHRegistrar registrar = IETHRegistrar(SepoliaConfig.ETH_REGISTRAR);
        require(registrar.isAvailable(plan.label), "label already registered");

        // Deterministic per-deployer secret. Phase 2 must reproduce it exactly or the commitment
        // will not match, so it is derived rather than random.
        plan.secret = keccak256(abi.encode("ReputAI:T6", plan.deployer, plan.label));

        vm.startBroadcast(pk);
        _deployProxies(plan);
        _fundRent(plan, registrar);
        bytes32 commitment = _commit(plan, registrar);
        vm.stopBroadcast();

        _record(plan, commitment);
    }

    /// @dev The operator's own subdomain registry and the resolver its agents will point at.
    ///      Both must exist before the commitment, which binds their addresses.
    function _deployProxies(Plan memory plan) private {
        VerifiableFactory factory = VerifiableFactory(SepoliaConfig.VERIFIABLE_FACTORY);

        // Agents are minted into this registry, never into `.eth`. The deployer is the operator:
        // it holds every root role here, including ROLE_UNREGISTER -- the kill switch beat 4
        // depends on.
        bytes memory registryInit =
            abi.encodeCall(UserRegistry.initialize, (plan.deployer, EACBaseRolesLib.ALL_ROLES));
        plan.operatorRegistry = factory.deployProxy(
            SepoliaConfig.USER_REGISTRY_IMPL, uint256(keccak256(registryInit)), registryInit
        );

        // Root roles to the operator only. The sandbox gets its one narrow grant in phase 2, and
        // the agent gets nothing at all until `provision()` names its keys.
        bytes memory resolverInit = abi.encodeCall(
            PermissionedResolver.initialize,
            (plan.deployer, EACBaseRolesLib.ALL_ROLES, new bytes[](0))
        );
        plan.resolver = factory.deployProxy(
            SepoliaConfig.PERMISSIONED_RESOLVER_IMPL,
            uint256(keccak256(resolverInit)),
            resolverInit
        );
    }

    /// @dev Rent. MOCKED, and deliberately the only mocked thing in the deployment: upstream's own
    ///      MockUSDC has an unpermissioned `mint()` on testnet, so the rent oracle is satisfied for
    ///      free. The registration it pays for is the real registrar writing to the real `.eth`
    ///      registry.
    function _fundRent(Plan memory plan, IETHRegistrar registrar) private {
        (uint256 base, uint256 premium) = registrar.getRegisterPrice(
            plan.label, plan.duration, IERC20(SepoliaConfig.MOCK_USDC)
        );
        plan.price = base + premium;
        IMintable(SepoliaConfig.MOCK_USDC).mint(plan.deployer, plan.price);
        IERC20(SepoliaConfig.MOCK_USDC).approve(SepoliaConfig.ETH_REGISTRAR, plan.price);
    }

    function _commit(Plan memory plan, IETHRegistrar registrar)
        private
        returns (bytes32 commitment)
    {
        commitment = registrar.makeCommitment(
            plan.label,
            plan.deployer,
            plan.secret,
            IRegistry(plan.operatorRegistry),
            plan.resolver,
            plan.duration,
            bytes32(0)
        );
        registrar.commit(commitment);
    }

    function _record(Plan memory plan, bytes32 commitment) private {
        string memory out = "deployment";
        vm.serializeString(out, "label", plan.label);
        vm.serializeAddress(out, "deployer", plan.deployer);
        vm.serializeAddress(out, "operatorRegistry", plan.operatorRegistry);
        vm.serializeAddress(out, "resolver", plan.resolver);
        vm.serializeUint(out, "duration", plan.duration);
        vm.serializeUint(out, "rentPaid", plan.price);
        vm.serializeBytes32(out, "commitment", commitment);
        string memory json = vm.serializeUint(out, "committedAt", block.timestamp);
        vm.writeJson(json, _outFile());

        console.log("operator registry :", plan.operatorRegistry);
        console.log("resolver          :", plan.resolver);
        console.log("rent (MockUSDC)   :", plan.price);
        console.log("committed         :", vm.toString(commitment));
        console.log("");
        console.log("Wait 60s (MIN_COMMITMENT_AGE), then run 02_Register.s.sol");
    }
}
