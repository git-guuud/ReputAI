// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable func-name-mixedcase, state-visibility

import {Test} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {AgentSandbox} from "../src/AgentSandbox.sol";
import {CounterpartyVerifier} from "../src/CounterpartyVerifier.sol";
import {Commit} from "../script/01_Commit.s.sol";
import {Register} from "../script/02_Register.s.sol";
import {
    Beat1_Provision,
    Beat2a_Publish,
    Beat2b_Pay,
    Beat2c_Rotate,
    Beat2d_PayRotated,
    Beat4_Revoke
} from "../script/03_Demo.s.sol";
import {SepoliaConfig} from "../script/SepoliaConfig.sol";

import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";

/// @notice T6 — the deployment scripts, run against a fork of real Sepolia.
///
/// This is the rehearsal. Everything the live run will touch is the genuine article at its
/// canonical address: the ENS root, the `.eth` registry, the commit-reveal registrar, the rent
/// oracle, `VerifiableFactory`, and the two implementation contracts our proxies point at. The
/// only thing simulated is the passage of the registrar's 60-second commitment age, and the only
/// mocked component anywhere is upstream's own MockUSDC (its `mint()` is unpermissioned on
/// testnet, so rent is free).
///
/// It runs `01_Commit` and `02_Register` themselves rather than a reimplementation of them, so a
/// mistake in the scripts fails here rather than on a funded chain. Then it plays IDEA.md §4's
/// four beats through the deployed contracts, which is the T6 exit criterion.
///
/// Skipped automatically when `SEPOLIA_RPC_URL` is unset, so `forge test` stays offline-clean.
contract SepoliaDeploymentTest is Test {
    /// @dev Derived per run rather than hard-coded. The rehearsal registers a name against real
    ///      Sepolia state, so a fixed label collides with the live deployment the moment T6 is
    ///      actually run -- which is exactly what happened with `reputai-sandbox`.
    string LABEL;

    string constant AGENT = "agent-404";
    string constant ENDPOINT = "https://agent-404.example/api";

    uint256 deployerPk;
    address deployer;

    address agent;
    uint256 agentPk;
    address treasury = makeAddr("treasury");
    address counterparty;
    uint256 counterpartyPk;

    /// @dev What each `payAgent()` sends. Small on purpose: the live run spends real testnet ETH.
    uint256 constant PAYMENT = 0.001 ether;

    uint256 keyGenesisPk;
    address keyGenesis;
    uint256 keyRotatedPk;
    address keyRotated;

    IPermissionedRegistry operatorRegistry;
    PermissionedResolver resolver;
    AgentSandbox sandbox;
    CounterpartyVerifier verifier;

    /// @dev Cached in `setUp`. Read inline it would be an external staticcall in an argument
    ///      list, which consumes a one-shot `vm.prank` before the call it was meant for.
    string operatingKey;

    bytes agentName;
    bytes32 agentNode;
    uint64 agentExpiry;

    bytes message = bytes("agent-404: invoice 17, settle to my published payout address");

    function setUp() external {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);

        require(block.chainid == SepoliaConfig.CHAIN_ID, "not sepolia");

        LABEL = string.concat("reputai-fork-", vm.toString(block.number));

        (deployer, deployerPk) = makeAddrAndKey("reputai-t6-deployer");
        (agent, agentPk) = makeAddrAndKey("agent");
        (counterparty, counterpartyPk) = makeAddrAndKey("counterparty");
        (keyGenesis, keyGenesisPk) = makeAddrAndKey("operating-key-genesis");
        (keyRotated, keyRotatedPk) = makeAddrAndKey("operating-key-rotated");

        // The name is an ERC-1155, so the operator must be a valid receiver. A plain EOA is;
        // an EIP-7702-delegated EOA is not, and several well-known test keys are delegated on
        // live Sepolia -- which is a real deployment constraint, not a test artifact.
        require(deployer.code.length == 0, "deployer has code: cannot receive the name token");

        vm.deal(deployer, 10 ether);
        vm.setEnv("PRIVATE_KEY", vm.toString(deployerPk));
        vm.setEnv("AGENT_PARENT_LABEL", LABEL);
        vm.setEnv("DEPLOYMENT_FILE", "./deployments/fork-test.json");

        // The demo scripts read their whole cast from the environment, so the rehearsal supplies
        // fork-local keys and reads the same variables the live run will. Nothing about a beat
        // differs between here and Sepolia except which keys are behind these names.
        vm.setEnv("DEMO_FILE", "./deployments/fork-demo.json");
        vm.setEnv("DEMO_AGENT_LABEL", AGENT);
        vm.setEnv("DEMO_AGENT_PK", vm.toString(agentPk));
        vm.setEnv("DEMO_COUNTERPARTY_PK", vm.toString(counterpartyPk));
        vm.setEnv("DEMO_KEY_GENESIS_PK", vm.toString(keyGenesisPk));
        vm.setEnv("DEMO_KEY_ROTATED_PK", vm.toString(keyRotatedPk));
        vm.setEnv("DEMO_TREASURY", vm.toString(treasury));
        vm.setEnv("DEMO_MESSAGE", string(message));
        vm.setEnv("DEMO_ENDPOINT", ENDPOINT);
        vm.setEnv("DEMO_PAY_WEI", vm.toString(PAYMENT));

        // Block-derived, so this should never fire. If it does, the fork is pinned to a block
        // whose label was already taken -- a false negative, not a real failure.
        require(
            _registrarSaysAvailable(LABEL), "fork label already registered on sepolia"
        );

        new Commit().run();

        // The registrar's MIN_COMMITMENT_AGE. The only thing this test simulates.
        vm.warp(block.timestamp + 61);

        new Register().run();

        string memory out = vm.readFile("./deployments/fork-test.json");
        operatorRegistry = IPermissionedRegistry(vm.parseJsonAddress(out, ".operatorRegistry"));
        resolver = PermissionedResolver(vm.parseJsonAddress(out, ".resolver"));
        sandbox = AgentSandbox(vm.parseJsonAddress(out, ".sandbox"));
        verifier = CounterpartyVerifier(payable(vm.parseJsonAddress(out, ".verifier")));

        operatingKey = sandbox.OPERATING_KEY();

        agentName = NameCoder.encode(string.concat(AGENT, ".", LABEL, ".eth"));
        agentNode = NameCoder.namehash(agentName, 0);
        agentExpiry = uint64(block.timestamp + 180 days);

        vm.deal(counterparty, 10 ether);
    }

    function _registrarSaysAvailable(string memory label) private view returns (bool ok) {
        (bool success, bytes memory data) = SepoliaConfig.ETH_REGISTRAR.staticcall(
            abi.encodeWithSignature("isAvailable(string)", label)
        );
        return success && abi.decode(data, (bool));
    }

    function _allowlist() private view returns (string[] memory keys) {
        keys = new string[](2);
        keys[0] = SepoliaConfig.ENDPOINT_KEY;
        keys[1] = operatingKey;
    }

    function _sign(uint256 pk) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(message));
        return abi.encodePacked(r, s, v);
    }

    ////////////////////////////////////////////////////////////////////////
    // The deployment itself
    ////////////////////////////////////////////////////////////////////////

    /// @notice The operator name is routable from the real ENS root, through the real `.eth`
    ///         registry, into our own registry. Nothing was pre-seeded: it did not exist at the
    ///         start of `setUp`.
    function test_operatorNameIsRoutableFromTheRealRoot() external view {
        IRegistry ethRegistry =
            IRegistry(SepoliaConfig.ROOT_REGISTRY).getSubregistry("eth");
        assertEq(
            address(ethRegistry),
            SepoliaConfig.ETH_REGISTRY,
            "root does not route eth to the canonical .eth registry"
        );
        assertEq(
            address(ethRegistry.getSubregistry(LABEL)),
            address(operatorRegistry),
            "eth does not route our label into our registry"
        );
        assertEq(
            operatorRegistry.getOwner(uint256(keccak256(bytes(LABEL)))),
            address(0),
            "label minted inside itself"
        );
    }

    /// @notice The sandbox holds exactly the two grants it needs and nothing more. The deployment
    ///         script asserts this too; asserting it here as well means a wiring regression fails
    ///         in CI rather than only at deploy time.
    function test_sandboxIsNotABackdoor() external view {
        assertTrue(
            operatorRegistry.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(sandbox))
        );
        assertFalse(
            operatorRegistry.hasRootRoles(RegistryRolesLib.ROLE_UNREGISTER, address(sandbox))
        );
        assertFalse(
            operatorRegistry.hasRootRoles(RegistryRolesLib.ROLE_SET_RESOLVER, address(sandbox))
        );
        assertTrue(
            operatorRegistry.hasRootRoles(RegistryRolesLib.ROLE_UNREGISTER, deployer),
            "operator must keep the kill switch"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // IDEA.md section 4, the four beats, on forked Sepolia
    //
    // Beats 1, 2 and 4 run `script/03_Demo.s.sol` itself -- the same contracts the live run
    // broadcasts, driven by the same environment variables -- so a mistake in a demo script
    // fails here rather than on camera. Beat 3 is the exception and stays inline: its three
    // transactions must revert, and a `forge script` broadcast refuses to send a reverting
    // call, so live it runs through `script/03b_escape.sh`. The assertions are the same either
    // way.
    ////////////////////////////////////////////////////////////////////////

    /// @notice Beat 1 — provision. One operator call mints the agent's name, grants its role
    ///         bitmap, wires the resolver and authorizes its two text keys; a second publishes
    ///         the payout address the agent may never move.
    function test_beat1_provision() external {
        new Beat1_Provision().run();
        uint256 tokenId = _tokenId();

        assertEq(operatorRegistry.getOwner(tokenId), agent, "agent does not own its name");
        assertEq(operatorRegistry.getResolver(AGENT), address(resolver), "resolver not wired");
        assertEq(resolver.addr(agentNode), treasury, "payout address not published");

        // Provisioning grants the write surface; it publishes nothing. Beat 2 is the agent's.
        assertEq(bytes(resolver.text(agentNode, operatingKey)).length, 0, "key pre-seeded");
        assertEq(
            bytes(resolver.text(agentNode, SepoliaConfig.ENDPOINT_KEY)).length,
            0,
            "endpoint pre-seeded"
        );
    }

    /// @notice Beat 2 — operate. The agent publishes, then rotates its operating key, with no
    ///         operator transaction in between. The verifier follows it across the rotation and
    ///         pays on the new key while refusing the retired one.
    function test_beat2_operateAndRotate() external {
        new Beat1_Provision().run();
        new Beat2a_Publish().run();

        assertEq(resolver.text(agentNode, SepoliaConfig.ENDPOINT_KEY), ENDPOINT);
        assertEq(resolver.text(agentNode, operatingKey), Strings.toHexString(keyGenesis));

        new Beat2b_Pay().run();
        assertEq(treasury.balance, PAYMENT, "first payment did not land");

        // The agent rotates. No operator involvement, one transaction, one party.
        new Beat2c_Rotate().run();
        assertEq(resolver.text(agentNode, operatingKey), Strings.toHexString(keyRotated));

        new Beat2d_PayRotated().run();
        assertEq(treasury.balance, 2 * PAYMENT, "verifier did not follow the rotation");

        // The retired key stops working in the same breath.
        vm.prank(counterparty);
        vm.expectRevert(
            abi.encodeWithSelector(
                CounterpartyVerifier.Refused.selector,
                CounterpartyVerifier.Refusal.KeyMismatch,
                agentName
            )
        );
        verifier.payAgent{value: PAYMENT}(agentName, message, _sign(keyGenesisPk));
    }

    /// @notice Beat 3 — attempted escape. The three moves that would break containment, all
    ///         reverting against the live registry and resolver. Inline rather than scripted
    ///         because these calls must fail; `03b_escape.sh` sends the same three live.
    function test_beat3_escapeAttemptsAllRevert() external {
        new Beat1_Provision().run();
        new Beat2a_Publish().run();
        uint256 tokenId = _tokenId();

        vm.startPrank(agent);

        vm.expectRevert();
        operatorRegistry.safeTransferFrom(agent, address(0xBAD), tokenId, 1, "");

        vm.expectRevert();
        operatorRegistry.setResolver(tokenId, address(0xBAD));

        vm.expectRevert();
        resolver.setAddr(agentNode, address(0xBAD));

        vm.stopPrank();

        // Unchanged after all three.
        assertEq(operatorRegistry.getOwner(tokenId), agent);
        assertEq(operatorRegistry.getResolver(AGENT), address(resolver));
        assertEq(resolver.addr(agentNode), treasury, "payout address moved");
    }

    /// @notice Beat 4 — revoke. One operator call, and the counterparty's next payment refuses.
    ///         Nothing about the agent changed: it still holds its key and its records still
    ///         exist. What changed is that nothing can route to them.
    function test_beat4_revocationStopsTheMoney() external {
        new Beat1_Provision().run();
        new Beat2a_Publish().run();
        new Beat2b_Pay().run();
        assertEq(treasury.balance, PAYMENT, "agent was not live before revocation");

        new Beat2c_Rotate().run();
        new Beat4_Revoke().run();

        assertEq(operatorRegistry.getOwner(_tokenId()), address(0), "name survived unregister()");

        (CounterpartyVerifier.Refusal reason,,) = verifier.checkAgent(
            agentName, message, _sign(keyRotatedPk)
        );
        assertEq(
            uint256(reason),
            uint256(CounterpartyVerifier.Refusal.Unresolvable),
            "revoked agent still resolves"
        );

        vm.prank(counterparty);
        vm.expectRevert(
            abi.encodeWithSelector(
                CounterpartyVerifier.Refused.selector,
                CounterpartyVerifier.Refusal.Unresolvable,
                agentName
            )
        );
        verifier.payAgent{value: PAYMENT}(agentName, message, _sign(keyRotatedPk));

        assertEq(treasury.balance, PAYMENT, "money moved after revocation");

        // The records outlive the registry entry -- unreachability, not deletion. Said out loud
        // here so the demo does not have to claim more than the mechanism delivers.
        assertEq(
            resolver.text(agentNode, operatingKey),
            Strings.toHexString(keyRotated),
            "records were expected to survive revocation"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev What beat 1 recorded. The registry assigns the token ID, so every later beat -- and
    ///      `03b_escape.sh` -- reads it back from the demo record rather than deriving it.
    function _tokenId() private view returns (uint256) {
        return vm.parseJsonUint(vm.readFile("./deployments/fork-demo.json"), ".tokenId");
    }
}
