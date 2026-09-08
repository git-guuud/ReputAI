// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable func-name-mixedcase, state-visibility

import {Test} from "forge-std/Test.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IStandardRegistry} from "~src/registry/interfaces/IStandardRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @notice Empirical verification of the operator kill switch assumed by IDEA.md §3.4.
///
/// The open question was whether an operator can revoke a *live* (unexpired) subname,
/// or whether they must wait for natural expiry. These tests answer it against the
/// real ENSv2 `PermissionedRegistry`, not a mock.
contract ForceExpiryTest is Test {
    PermissionedRegistry registry;
    LabelStore labelStore;

    address operator = makeAddr("operator");
    address agent = makeAddr("agent");
    address counterparty = makeAddr("counterparty");

    string constant LABEL = "agent-404";
    address constant RESOLVER = address(0xBEEF);

    /// @dev The sandboxed agent's role set: it may point its name at a subregistry
    ///      (to spawn workers) and renew, but may NOT unregister, change its resolver,
    ///      or transfer. Compare IDEA.md §3.2.
    uint256 constant AGENT_ROLES = RegistryRolesLib.ROLE_SET_SUBREGISTRY;

    uint64 expiry;

    function setUp() external {
        labelStore = new LabelStore(IContractNamer(address(0)));
        // Operator deploys the registry and holds every role at ROOT_RESOURCE.
        registry = new PermissionedRegistry(labelStore, operator, EACBaseRolesLib.ALL_ROLES);

        expiry = uint64(block.timestamp + 365 days);

        vm.prank(operator);
        registry.register(LABEL, agent, IRegistry(address(0)), RESOLVER, AGENT_ROLES, expiry);
    }

    ////////////////////////////////////////////////////////////////////////
    // Baseline: the name is live and the agent holds it
    ////////////////////////////////////////////////////////////////////////

    function test_baseline_nameIsLiveAndOwnedByAgent() external view {
        uint256 id = LibLabel.id(LABEL);
        assertEq(registry.getOwner(id), agent, "agent owns the name");
        assertEq(registry.getResolver(LABEL), RESOLVER, "resolver is set");
        assertEq(uint8(registry.getStatus(id)), uint8(IPermissionedRegistry.Status.REGISTERED));
        assertGt(registry.getExpiry(id), block.timestamp, "name is not expired");
    }

    ////////////////////////////////////////////////////////////////////////
    // The question: can an operator revoke a LIVE name?
    ////////////////////////////////////////////////////////////////////////

    /// @notice ANSWER: yes — `unregister()` force-expires a live name immediately.
    function test_operatorCanForceExpireLiveName() external {
        uint256 id = LibLabel.id(LABEL);

        // Precondition: name is live, with ~a year left.
        assertGt(registry.getExpiry(id), block.timestamp);

        vm.prank(operator);
        registry.unregister(id);

        // Expiry is slammed to `block.timestamp`, which `_isExpired` treats as expired
        // (`block.timestamp >= expiry`). No waiting period.
        assertEq(registry.getExpiry(id), uint64(block.timestamp), "expiry set to now");
        assertEq(uint8(registry.getStatus(id)), uint8(IPermissionedRegistry.Status.AVAILABLE));
        assertEq(registry.getOwner(id), address(0), "token burned");
    }

    /// @notice Revocation stops resolution in the same transaction — this is what
    ///         makes the kill switch observable to a counterparty (IDEA.md §3.5).
    function test_revocationHaltsResolutionImmediately() external {
        assertEq(registry.getResolver(LABEL), RESOLVER, "resolves before");

        vm.prank(operator);
        registry.unregister(LibLabel.id(LABEL));

        assertEq(registry.getResolver(LABEL), address(0), "resolver gone after");
        assertEq(address(registry.getSubregistry(LABEL)), address(0), "subregistry gone after");
    }

    /// @notice The agent's EAC grants do not survive revocation: `eacVersionId` is
    ///         bumped, so the resource ID the agent's roles were granted against is
    ///         no longer the resource ID the name resolves to.
    function test_revocationInvalidatesAgentRoles() external {
        uint256 id = LibLabel.id(LABEL);
        uint256 resourceBefore = registry.getResource(id);
        assertTrue(registry.hasRoles(resourceBefore, AGENT_ROLES, agent), "agent had roles");

        vm.prank(operator);
        registry.unregister(id);

        uint256 resourceAfter = registry.getResource(id);
        assertTrue(resourceBefore != resourceAfter, "EAC resource rotated");
        assertFalse(registry.hasRoles(resourceAfter, AGENT_ROLES, agent), "agent roles dead");
    }

    ////////////////////////////////////////////////////////////////////////
    // The kill switch is exclusive to the operator
    ////////////////////////////////////////////////////////////////////////

    function test_agentCannotUnregisterItself() external {
        uint256 id = LibLabel.id(LABEL);
        // Resolve the resource BEFORE pranking - an intervening call would consume the prank.
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

    function test_strangerCannotUnregister() external {
        uint256 id = LibLabel.id(LABEL);
        vm.prank(counterparty);
        vm.expectRevert();
        registry.unregister(id);
    }

    ////////////////////////////////////////////////////////////////////////
    // Why `unregister` is the ONLY force-expiry path
    ////////////////////////////////////////////////////////////////////////

    /// @notice `renew()` cannot be abused to shorten a name: expiry is monotonic.
    ///         This is why revocation needed a dedicated mechanism.
    function test_expiryCannotBeReducedViaRenew() external {
        uint256 id = LibLabel.id(LABEL);
        uint64 shorter = uint64(block.timestamp + 1 days);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.CannotReduceExpiry.selector, expiry, shorter)
        );
        registry.renew(id, shorter);
    }

    ////////////////////////////////////////////////////////////////////////
    // Sandbox boundaries (IDEA.md §3.2) — the agent cannot escalate
    ////////////////////////////////////////////////////////////////////////

    function test_agentCannotRepointItsResolver() external {
        vm.prank(agent);
        vm.expectRevert();
        registry.setResolver(LibLabel.id(LABEL), address(0xDEAD));
    }

    function test_agentCanSetSubregistry_theOneGrantedPower() external {
        vm.prank(agent);
        registry.setSubregistry(LibLabel.id(LABEL), IRegistry(address(0xCAFE)));
        assertEq(address(registry.getSubregistry(LABEL)), address(0xCAFE));
    }
}
