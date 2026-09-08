# Finding 001 — Operator force-expiry of a live subname

**Status:** Confirmed empirically
**Date:** 2026-09-08
**Resolves:** IDEA.md §6, open question 1
**Evidence:** `test/ForceExpiry.t.sol`, `test/SubtreeRevocation.t.sol` (13/13 passing)
**Source:** `ensdomains/contracts-v2` @ `lib/contracts-v2` (`PermissionedRegistry.sol`)

## Question

Can an operator revoke a *live* (unexpired) subname, or must they wait for natural
expiry? The kill switch in §3.4 depends on the answer.

## Answer

**Yes — via `unregister()`.** It is the only path, and it is immediate.

```solidity
function unregister(uint256 anyId) public {
    (uint256 tokenId, Entry storage entry) =
        _checkExpiryAndTokenRoles(anyId, RegistryRolesLib.ROLE_UNREGISTER);
    emit LabelUnregistered(tokenId, msg.sender);
    address owner = super.ownerOf(tokenId);
    if (owner != address(0)) {
        _burn(owner, tokenId, 1);
        ++entry.eacVersionId;
        ++entry.tokenVersionId;
    }
    entry.expiry = uint64(block.timestamp);
}
```

Four things happen atomically:

1. **Expiry collapses to now.** `_isExpired` is `block.timestamp >= expiry`, so setting
   `expiry = block.timestamp` expires the name in the same transaction. No grace period.
2. **The ERC-1155 token is burned.** `getOwner()` returns `address(0)` immediately.
3. **`eacVersionId` is incremented.** The EAC resource ID is derived from the labelhash
   plus this counter, so every role the agent held is granted against a resource ID that
   the name no longer maps to. The agent's permissions die with the name rather than
   lingering for a future re-registration.
4. **Resolution stops.** `getResolver()` and `getSubregistry()` both short-circuit to
   zero when expired.

## Authorisation

`ROLE_UNREGISTER` (nybble 3, `1 << 12`) is documented "Root or token". `EnhancedAccessControl`
resolves an account's effective roles as:

```solidity
_getRoles(ROOT_RESOURCE, account) | _getRoles(resource, account)
```

Root-resource roles therefore apply to every name in the registry. An operator holding
`ROLE_UNREGISTER` at `ROOT_RESOURCE` can revoke **any** name it contains, including one
owned by someone else. This is exactly the kill switch the design assumes, and it needs
no cooperation from the token owner.

Confirmed by test: the agent (token owner, without the role) reverts with
`EACUnauthorizedAccountRoles(resource, 4096, agent)`; a third party reverts likewise.

## Why `unregister` and not `renew`

`renew()` enforces monotonic expiry:

```solidity
if (newExpiry < expiry) revert CannotReduceExpiry(expiry, newExpiry);
```

So expiry cannot be walked backwards to fake a revocation. A dedicated mechanism was
required, and `unregister` is it.

## Subtree behaviour

Confirmed: revoking a parent severs the traversal edge to everything beneath it.
`getSubregistry(label)` returns `address(0)` once expired, so resolution of
`*.agent-404.operator.eth` dead-ends at the parent registry in the same transaction —
no enumeration of children, no cleanup pass.

**Caveat worth stating in the demo rather than hiding.** The child registry's own storage
is untouched: `worker-1` still has an owner and a resolver *inside* the orphaned registry.
What is destroyed is reachability from the ENS root, not the data. This matches §3.5 —
containment is loss of discoverability, not deletion — but a judge asking "is the worker
really gone?" deserves the precise answer.

## Consequences for IDEA.md

- §3.4 stands as written; the mechanism is `unregister()`, not expiry manipulation.
- §3.2 should list `ROLE_UNREGISTER` explicitly among withheld roles. It was implied
  under "ownership/transfer" but it is a distinct role and the most important one to withhold.
- The role-invalidation behaviour (`eacVersionId` bump) is a stronger property than the
  document claimed and is worth stating: revocation is not just "the name stops resolving",
  it is "the agent's grants cease to exist".
