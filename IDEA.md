# Agent-Bound Identity Sandbox

**Concept Document | ETHOnline 2026 — ENSv2 Track**

---

## 1. Summary

Autonomous agents need on-chain identity: a stable name, a discoverable endpoint, a way for counterparties to verify who they are talking to. Today there are only two ways to give an agent one, and both are bad.

Either the agent **owns** its identity — in which case a compromised or malfunctioning agent walks off with it, repoints it, or sells it — or the operator owns it and **co-signs every update**, in which case the agent isn't autonomous and the operator is a bottleneck on every endpoint change and key rotation.

This project builds the missing middle: an identity the agent can *operate* but cannot *own*. Using ENSv2's Enhanced Access Control and permissioned resolvers, an agent receives a subname under an operator's domain with a narrow, record-scoped write surface. It can change where it listens, what it advertises, and which key it currently signs with — autonomously, without asking anyone. It cannot transfer the name, repoint its resolver, change the address it resolves to, or escalate its own permissions. The operator retains an immediate kill switch over the name and everything beneath it.

The agent can move around inside the box. It cannot move the box.

---

## 2. Why ENSv2 Is Load-Bearing

The obvious objection to any ENS project is "couldn't you do this with a normal access-control contract?" For this design the answer is specific:

**ENSv2's roles system is what makes partial delegation possible at all.** Permissions are resource-scoped and tiered — resolver level, name level, and individual record level — so a single name can split write access across parties: one role updates all records, another only address records, another only a named text key. That tiering is exactly the primitive this project needs, and hand-rolling it securely in a hackathon window is not realistic.

Everything else follows from being inside ENS rather than beside it. The agent's identity resolves in every wallet, explorer, and contract that already speaks ENS, so a sandboxed agent is globally addressable on day one instead of being legible only to our own dApp. And hierarchical registries give attenuation and subtree revocation as protocol behaviour rather than as application logic we have to be trusted to have written correctly.

> **Note on the L1 pivot.** This design targets ENSv2 natively on Ethereum L1. In February 2026 ENS Labs cancelled the planned Namechain L2 and committed ENSv2 exclusively to mainnet, citing roughly a 99% fall in registration gas costs alongside Ethereum's gas-limit increases. Material from 2024–2025 describing Namechain, or ENSv1's Name Wrapper and fuses, is obsolete and is deliberately not used here. Hackathon deployment is on **Sepolia**, per track requirements.

---

## 3. Architecture

### 3.1 The permission split

The entire sandbox reduces to one design decision: **what may an agent say about itself, and what is said about it?** The line falls between durable identity and ephemeral operational state.

| | Controlled by | Rationale |
|---|---|---|
| Name ownership / transfer | **Operator** | The identity is leased, never owned. Withholding transfer makes the agent's name effectively soulbound to it. |
| Resolver pointer | **Operator** | Whoever can swap the resolver can rewrite every record at once. This is the escalation path and must stay closed. |
| `addr()` | **Operator** | The address counterparties pay. An agent that can redirect its own payments is not sandboxed. |
| Subregistry / subtree | **Operator** | Controls whether the agent may spawn children, and on what terms. |
| Service endpoint | **Agent** | Agents relocate, restart, and re-host constantly. Requiring a co-signature here destroys autonomy. |
| Capability manifest | **Agent** | What the agent currently offers. Self-declared by nature; counterparties verify by use, not by trust. |
| Status / liveness | **Agent** | High-frequency, low-stakes. |
| State commitment | **Agent** | A hash anchoring off-chain state, letting others detect divergence without on-chain storage. |
| Operating key | **Agent** | See §3.3 — the sharpest case, and the one that most needs the sandbox. |

The organising principle: **anything a counterparty uses to decide whether to trust the agent at all is outside the agent's reach.** Everything the agent can write is downstream of a trust decision already made.

### 3.2 Registry roles

At the registry level the agent's role set is defined mostly by subtraction. Roles such as `ROLE_SET_RESOLVER`, `ROLE_UNREGISTER`, and the transfer/admin roles are **withheld**; the operator holds them, along with renewal. `ROLE_UNREGISTER` matters most: it *is* the kill switch (see below), and an agent holding it could destroy its own identity.

This is worth stating explicitly because the intuitive reading of `ROLE_SET_RESOLVER` — "the role that lets the agent manage its records" — is wrong and dangerous. It governs *which resolver contract the name points at*, not writes into that resolver. Granting it would hand the agent the ability to repoint its name at an attacker-controlled resolver and rewrite everything, including `addr()`. It is the single permission this architecture most needs to withhold.

The agent's actual write capability lives one layer down.

### 3.3 Record-level roles on a permissioned resolver

The agent's autonomy comes from record-scoped roles on a permissioned resolver: an allowlist of specific keys it may write, with everything else — `addr()` above all — reserved to the operator. ENSv2's `PermissionedResolver` supports this natively: `authorizeTextRoles()` scopes `ROLE_SET_TEXT` to an individual key, so per-key allowlisting is a protocol feature rather than something this project has to invent.

The most interesting entry on that allowlist is the agent's **operating key**. Agents run as processes: they restart, redeploy, and rotate credentials, and a design that requires an operator signature for every rotation will simply be bypassed in practice. So the agent publishes and rotates its own signing key, while `addr()` stays locked.

This produces the security property the whole project exists to demonstrate, statable in one line:

> Compromising an agent's operating key lets an attacker impersonate its messaging until revocation — but never lets them receive its funds, take its name, or persist past the operator's kill switch.

Bounded blast radius, bounded duration. That is a sandbox doing real work rather than an access-control diagram.

An open question worth confronting rather than hiding: a *compromised* agent rotating the key to the attacker is itself the attack. The mitigation is not to remove the capability but to make it expensive or loud — rate-limiting rotations, or emitting events an operator-side watcher can act on. Left as an implementation decision.

### 3.4 Hierarchy and subtree revocation

Agents increasingly delegate to sub-agents, and this is where hierarchical registries stop being decoration. An orchestrator holding `agent-404.operator.eth` can mint `worker-1.agent-404.operator.eth` for a task-scoped child — but only with permissions that are a **subset** of its own. Attenuation is enforced by the registry hierarchy, not by our code.

Revocation inherits the same structure, and the mechanism is now **verified against the deployed contracts** rather than assumed — see [finding 001](./docs/findings/001-force-expiry.md).

An operator holding `ROLE_UNREGISTER` at the registry's root resource calls `unregister()` on a live name. In one transaction the expiry collapses to `block.timestamp`, the ERC-1155 token is burned, and `getResolver()`/`getSubregistry()` both fall to zero. Killing a misbehaving orchestrator severs the traversal edge to its whole worker fleet at once — no enumeration, no cleanup pass.

Two properties are stronger than first assumed and worth stating explicitly:

- **Grants die with the name.** `unregister()` increments the name's `eacVersionId`, and the EAC resource ID is derived from it. Every role the agent held is now scoped to a resource the name no longer maps to. Revocation is not merely "the name stops resolving" — the agent's permissions cease to exist.
- **Expiry is monotonic.** `renew()` reverts with `CannotReduceExpiry` if asked to shorten a name, so `unregister()` is the *only* revocation path. This is a deliberate protocol design, not an oversight.

One honest limit, better stated than discovered by a judge: the child registry's own storage survives. A revoked orchestrator's workers still have owners and resolvers *inside* their orphaned registry. What is destroyed is reachability from the ENS root, not the data — which is exactly the containment model of §3.5, but the distinction should be made out loud.

### 3.5 The verifier

A kill switch that nothing checks is theatre. Revoking a name does not stop the agent's wallet from signing or transacting; what dies is *discoverability*. That matters only if counterparties actually gate on resolution.

So the counterparty side is part of the deliverable, not an afterthought: a client that resolves an agent's name, reads its endpoint and current operating key, verifies the agent's signature against that key, and **refuses to transact when resolution fails or the key doesn't match**. This is what converts "the operator can revoke" into an observable consequence.

---

## 4. Demonstration

The demo is the argument, in four beats:

1. **Provision** — an agent is minted a subname live, with its role set assigned on-chain. Nothing pre-seeded.
2. **Operate** — the agent autonomously updates its endpoint and rotates its operating key. The verifier follows it across both changes without operator involvement.
3. **Attempt escape** — the agent tries to transfer its name, repoint its resolver, and rewrite `addr()`. All three revert. This is the sandbox made visible.
4. **Revoke** — the operator kills the name. The verifier's next resolution fails and it refuses to transact. If the hierarchy extension is built, the agent's workers go dark in the same transaction.

---

## 5. Track Alignment

The ENSv2 track ($4,500; $1,500 top prize) asks for projects built on ENSv2's hierarchical registry structure, naming Enhanced Access Control and permissioned resolvers directly, and awards bonus points for bringing AI agents into the mix. It requires ENSv2 features to be central rather than cosmetic, with a functional demo containing no hard-coded values.

This project uses ENSv2's permission tiers as its entire security model — remove EAC and there is no product, only the false choice of §1. The agent angle is the subject matter rather than a garnish, and the demo's central moment is a permission boundary holding under attack, which is difficult to fake.

Wildcard resolution is deliberately **not** used: per-agent EAC requires real registry entries, so wildcard resolution and record-scoped permissions pull against each other. Hierarchy is the better investment.

---

## 6. Open Questions

Deliberately unresolved, to be settled against the deployed Sepolia contracts rather than guessed at now.

- ~~**Revocation mechanism.**~~ **Resolved.** `unregister()` force-expires a live subname immediately, gated on `ROLE_UNREGISTER` held at the root resource. Verified against `ensdomains/contracts-v2` in `test/ForceExpiry.t.sol` and `test/SubtreeRevocation.t.sol`; written up as [finding 001](./docs/findings/001-force-expiry.md).
- **Exact role constants and record-level granularity.** How finely the permissioned resolver can scope writes to individual text keys in the shipped contracts, versus what the design assumes.
- **Rotation safety.** Whether to rate-limit key rotation, and what an operator-side watcher should look for.
- **Gas funding.** Record writes cost gas, so someone funds the agent's key. If that is the operator, it is a second and softer lever alongside revocation — worth naming rather than leaving for someone else to notice.
- **Off-chain records.** CCIP-Read was considered and rejected for this scope: the gas argument largely evaporated with the L1 pivot, and moving records off-chain would leave ENS holding a pointer and little else. Reasonable as future scaling, wrong as hackathon architecture.
