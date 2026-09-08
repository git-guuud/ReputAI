# Finding 002 — An inherited resolver survives revocation, so resolution must be *exact*

**Status:** Confirmed empirically
**Date:** 2026-09-08
**Affects:** IDEA.md §3.5 (the verifier) — a correctness requirement, not a preference
**Evidence:** `test/CounterpartyVerifier.t.sol::test_refusesAnInheritedResolverEvenWhenItStillHoldsTheRecords`
**Source:** `ensdomains/contracts-v2` @ `lib/contracts-v2`
(`universalResolver/libraries/LibRegistry.sol`, `registry/PermissionedRegistry.sol`)

## Question

T4's verifier gates payments on ENS resolution, so `unregister()` is supposed to stop it
transacting. Does it — if the verifier resolves the name the way ENS actually resolves names?

## Answer

**Not automatically.** A verifier that accepts whatever resolver ENS traversal hands back keeps
paying a revoked agent. Two protocol behaviours combine into a hole:

1. **Resolver lookup walks *up* the tree.** `LibRegistry.findResolver` — the function
   `UniversalResolverV2` itself uses — remembers the nearest ancestor's resolver and returns it
   when the name has none of its own:

   ```solidity
   address res = exactRegistry.getResolver(label);
   if (res != address(0)) {
       resolver = res;
       resolverOffset = offset;   // <- which label the resolver was found at
   }
   ```

   That is correct ENS behaviour (it is how inherited and wildcard resolution work), and it means
   `getResolver()` falling to zero on the revoked name does **not** make the name unresolvable.

2. **Records outlive the registry entry.** `PermissionedResolver` keys everything by *namehash*,
   which `unregister()` does not rotate — only `eacVersionId`, which scopes registry-tier roles.
   The revoked agent's `agent:operating-key`, endpoint and `addr()` are all still sitting in the
   resolver (the same limit stated for grants in IDEA.md §3.4).

In any realistic deployment the operator's own name has a resolver, and it is usually the *same*
resolver contract its agents use. So after `unregister("agent-404")`:

- traversal returns `operator.eth`'s resolver — non-zero — with `resolverOffset` pointing at the
  parent rather than at the agent;
- reading `text(namehash("agent-404.operator.eth"), "agent:operating-key")` from it returns the
  revoked agent's key, because that record was never deleted;
- a naive verifier therefore verifies the revoked agent's signature and pays it.

The kill switch would be silently defeated by a client doing the obvious, standards-compliant
thing.

## Consequence

`CounterpartyVerifier` accepts a resolver only when it is registered against the agent's *own*
name — `resolverOffset == 0` — and refuses with `Refusal.Unresolvable` otherwise. Inheritance is
not identity.

The test asserts both halves rather than just the refusal, because the refusal alone would pass
vacuously if the inheritance did not actually happen:

```solidity
(, address found, bytes32 foundNode, uint256 resolverOffset) =
    LibRegistry.findResolver(rootRegistry, name, 0);
assertEq(found, address(resolver), "inherited from operator.eth");
assertTrue(resolverOffset != 0, "but registered against an ancestor, not the agent");
assertEq(resolver.text(node, keyOperating), Strings.toHexString(keyGenesis)); // stale key readable
// ...and the verifier refuses anyway.
```

## Scope of the rule

Requiring exact resolution is right *for this design* and would be wrong for a general-purpose
ENS client:

- it deliberately gives up wildcard and inherited resolution, which IDEA.md §5 already rejects —
  per-agent EAC needs real registry entries anyway;
- it is the reason revocation is observable at all. Containment in ENSv2 is unreachability rather
  than deletion, so a client that will not gate on reachability is not gated on anything.

Anyone integrating with a sandboxed agent inherits this requirement. It is the one line of client
behaviour the whole revocation story rests on.
