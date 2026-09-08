# Finding 003 — `register()` is not admin-checked, so attenuation is application-level

**Status:** Confirmed empirically
**Date:** 2026-09-08
**Corrects:** IDEA.md §3.4 — "Attenuation is enforced by the registry hierarchy, not by our code"
**Evidence:** `test/SubAgentHierarchy.t.sol::test_finding_registrationGrantsRolesTheRegistrarCannotOtherwiseGrant`
**Source:** `ensdomains/contracts-v2` @ `lib/contracts-v2`
(`registry/PermissionedRegistry.sol`, `access-control/EnhancedAccessControl.sol`)

## Question

T5 assumed the registry hierarchy makes a sub-agent's permissions a subset of its parent's for
free. Does ENSv2 enforce that, or does it have to be written?

## Answer

**It has to be written.** Registration grants roles without the admin check that governs every
other grant.

Every *post-registration* grant runs through the `canGrantRoles` modifier, which requires the
caller to hold the matching `*_ADMIN` nybble — this is the mechanism T1 relies on to prove a
role-less agent cannot escalate:

```solidity
function grantRoles(uint256 resource, uint256 roleBitmap, address account)
    public canGrantRoles(resource, roleBitmap) returns (bool)
{ ... _grantRoles(resource, roleBitmap, account, true); }
```

Registration does not:

```solidity
// PermissionedRegistry._register
if (checkRoles) {
    _checkRoles(ROOT_RESOURCE, RegistryRolesLib.ROLE_REGISTRAR, msg.sender);
}
...
_grantRoles(resource, roleBitmap, owner, false);   // no canGrantRoles, no admin nybbles
```

The only authorisation checked is root `ROLE_REGISTRAR`. The bitmap itself is unconstrained: a
registrar can mint a name carrying `ROLE_SET_RESOLVER | ROLE_UNREGISTER` while holding neither,
and would be refused if it tried to grant the very same roles to the very same account one
transaction later. Asserted both ways in the test.

This is a defensible protocol decision — a registrar's whole job is minting fully-powered names,
and requiring it to hold every role it ever issues would make a general-purpose registrar
implausible. But it means **"a worker's roles are a subset of its orchestrator's" is an invariant
someone has to enforce**, and in a hierarchy of agents that someone is the contract standing
between the orchestrator and the child registry.

## Consequence

`src/SubAgentRegistrar.sol` is that contract. It checks, against the orchestrator's *current*
state in the parent registry (not a snapshot from provisioning time):

| Dimension | Check | Error |
|---|---|---|
| Registry roles | `requested & ~roles(orchestratorName, orchestrator) == 0` | `RolesExceedOrchestrator` |
| Record keys | orchestrator holds `ROLE_SET_TEXT` at `resource(orchestratorNode, keccak256(key))` for every requested key | `TextKeyExceedsOrchestrator` |
| Lease | `expiry <= orchestrator's expiry` | `ExpiryExceedsOrchestrator` |

Root roles are excluded from the first check on purpose: what an orchestrator may delegate is its
grant over *its own name*, never any registry-wide authority it happens to hold.

## The wiring this depends on

The registrar is only binding if it is the sole route into the child registry. If the orchestrator
also holds root `ROLE_REGISTRAR` there, it can mint unattenuated workers directly and the checks
above are decoration. So the operator — not the orchestrator — is the root account of the child
registry, and the orchestrator's ability to spawn comes entirely from being the *owner of the
parent name* (`SubAgentRegistrar` reads `getOwner()` on every call, which is also why revocation
stops the fleet from growing).

Asserted in `test_orchestratorCannotMintDirectly`. It is the kind of deployment detail that is
invisible in a diagram and fatal in practice.
