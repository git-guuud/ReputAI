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

Everything else follows from being inside ENS rather than beside it. The agent's identity resolves in every wallet, explorer, and contract that already speaks ENS, so a sandboxed agent is globally addressable on day one instead of being legible only to our own dApp. And hierarchical registries give **subtree revocation** as protocol behaviour rather than as application logic we have to be trusted to have written correctly: killing a parent severs the path to everything beneath it in one transaction, with no enumeration. (Attenuation between tiers turned out *not* to come for free — see §3.4 and [finding 003](./docs/findings/003-registration-bypasses-admin-check.md). The hierarchy gives us the revocation half; the subsetting half is ours to write, and is written in one contract.)

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

The agent's autonomy comes from record-scoped roles on a permissioned resolver: an allowlist of specific keys it may write, with everything else — `addr()` above all — reserved to the operator. ENSv2's `PermissionedResolver` supports this natively: `authorizeTextRoles()` scopes `ROLE_SET_TEXT` to an individual key, so per-key allowlisting is a protocol feature rather than something this project has to invent. **Verified** — the role lands at `resource(namehash, keccak256(key))`, and a key that was never allowlisted has no role holder at all, so `setText` falls through to the name-wide resource the agent is absent from (`test/AgentRecords.t.sol`).

The two tiers therefore pull in opposite directions on purpose: at the registry the agent's powers are defined by *subtraction*, at the resolver by *addition*. `addr()` is unreachable from either — it is gated on `ROLE_SET_ADDR`, a different role that provisioning grants to nobody.

The most interesting entry on that allowlist is the agent's **operating key**. Agents run as processes: they restart, redeploy, and rotate credentials, and a design that requires an operator signature for every rotation will simply be bypassed in practice. So the agent publishes and rotates its own signing key, while `addr()` stays locked.

This produces the security property the whole project exists to demonstrate, statable in one line:

> Compromising an agent's operating key lets an attacker impersonate its messaging until revocation — but never lets them receive its funds, take its name, or persist past the operator's kill switch.

Bounded blast radius, bounded duration. That is a sandbox doing real work rather than an access-control diagram.

An open question worth confronting rather than hiding: a *compromised* agent rotating the key to the attacker is itself the attack. The mitigation is not to remove the capability but to make it expensive or loud. **Decided: loud, not expensive** — rotations are unrestricted and observable, never rate-limited. Reasoning in §6; the mechanism is ENSv2's own `TextChanged` event, indexed by both node and key, plus per-key revocation as the operator's graduated response short of the kill switch. Verified end to end in `test/AgentKeyRotation.t.sol`.

The rotatable credential is published as a **text key** (`agent:operating-key`, canonicalised on `AgentSandbox.OPERATING_KEY`) rather than in the `pubkey` record, and that is forced rather than stylistic. `pubkey` is the obvious home for a signing credential and is unusable here: `setPubkey` checks the *name-wide* resource (`onlyPartRoles(node, 0, ROLE_SET_PUBKEY)`) and the resolver ships no `authorizePubkeyRoles` to narrow it, so granting it would hand the agent a permission the operator cannot scope. ENSv2 offers per-part scoping only where an `authorize*Roles` helper exists — text by key, data by key, addr by coin type — and text is the one of those every ENS client already reads.

### 3.4 Hierarchy and subtree revocation

Agents increasingly delegate to sub-agents, and this is where hierarchical registries stop being decoration. An orchestrator holding `agent-404.operator.eth` mints `worker-1.agent-404.operator.eth` for a task-scoped child — but only with permissions that are a **subset** of its own.

**Correction, against the deployed contracts.** This section previously claimed attenuation was "enforced by the registry hierarchy, not by our code". That is false, and finding it was T5's real content — see [finding 003](./docs/findings/003-registration-bypasses-admin-check.md). `PermissionedRegistry.register()` grants the new owner its role bitmap via `_grantRoles(..., false)`, bypassing the `canGrantRoles` admin check that governs every *later* grant. A caller holding nothing but root `ROLE_REGISTRAR` can therefore mint a name carrying roles it does not hold and could not grant a second afterwards. Subsetting between tiers is an **application-level invariant** in ENSv2, not a protocol-level one.

So it is written down, once, in `src/SubAgentRegistrar.sol`, and checked against the orchestrator's *live* state rather than a provisioning-time snapshot: registry roles must be a subset of the orchestrator's roles at its own name (root roles excluded — what is delegable is its grant over itself), every text key must be one the orchestrator may write (T2's tier, inherited), and a worker's lease may not outlive its parent's. The registrar holds no roles of its own and acts only for the current owner of the parent name, so `unregister()` also stops the fleet from growing. What the hierarchy *does* give for free is the part below — revocation.

Revocation inherits the same structure, and the mechanism is now **verified against the deployed contracts** rather than assumed — see [finding 001](./docs/findings/001-force-expiry.md).

An operator holding `ROLE_UNREGISTER` at the registry's root resource calls `unregister()` on a live name. In one transaction the expiry collapses to `block.timestamp`, the ERC-1155 token is burned, and `getResolver()`/`getSubregistry()` both fall to zero. Killing a misbehaving orchestrator severs the traversal edge to its whole worker fleet at once — no enumeration, no cleanup pass.

Two properties are stronger than first assumed and worth stating explicitly:

- **Grants die with the name.** `unregister()` increments the name's `eacVersionId`, and the EAC resource ID is derived from it. Every role the agent held is now scoped to a resource the name no longer maps to. Revocation is not merely "the name stops resolving" — the agent's permissions cease to exist.
- **Expiry is monotonic.** `renew()` reverts with `CannotReduceExpiry` if asked to shorten a name, so `unregister()` is the *only* revocation path. This is a deliberate protocol design, not an oversight.

The same limit applies one tier down, and is worth stating before a judge finds it: **resolver grants outlive revocation**. They are keyed by namehash, which `unregister()` does not rotate, so a revoked agent still holds `ROLE_SET_TEXT` on its allowlisted keys and can keep writing them. Nothing reads those writes — the name no longer points at the resolver — which is precisely why §3.5's verifier is load-bearing rather than decorative. An operator wanting the grants gone as well revokes them explicitly with `authorizeTextRoles(..., false)`, which also works per key as a softer, surgical lever.

One honest limit, better stated than discovered by a judge: the child registry's own storage survives. A revoked orchestrator's workers still have owners and resolvers *inside* their orphaned registry. What is destroyed is reachability from the ENS root, not the data — which is exactly the containment model of §3.5, but the distinction should be made out loud.

### 3.5 The verifier

A kill switch that nothing checks is theatre. Revoking a name does not stop the agent's wallet from signing or transacting; what dies is *discoverability*. That matters only if counterparties actually gate on resolution.

So the counterparty side is part of the deliverable, not an afterthought: `src/CounterpartyVerifier.sol` resolves an agent's name from the ENS root, reads its endpoint and current operating key, verifies the agent's signature against that key, and **refuses to transact when resolution fails or the key doesn't match**. It is a contract rather than a script so the refusal is enforced where the money moves: `payAgent()` either resolves-verifies-pays in one transaction or reverts with the reason it refused. It holds no roles and is trusted by nobody. This is what converts "the operator can revoke" into an observable consequence — verified end to end in `test/CounterpartyVerifier.t.sol`, including the revoke-mid-flow case where a counterparty that paid the agent a moment ago is cut off between one call and the next.

One requirement turned out to be load-bearing and non-obvious ([finding 002](./docs/findings/002-inherited-resolver-survives-revocation.md)): **resolution must be exact**. ENS resolver lookup walks *up* the tree and inherits an ancestor's resolver when a name has none of its own — correct ENS behaviour — while the revoked agent's records survive in that same resolver, because they are keyed by namehash and `unregister()` does not rotate it (§3.4). A verifier accepting an inherited resolver therefore reads a revoked agent's stale key and keeps paying it. The verifier accepts a resolver only when it is registered against the agent's own name. Inheritance is not identity.

What the verifier checks is *authorship* — this message was signed by the key the name publishes right now. What the message means, and whether it authorises this particular payment, is the counterparty's own business; a production integration binds the message to an amount and a nonce. The identity half is the half ENS answers, and it is the half the kill switch acts on. The payment always goes to the `addr()` ENS publishes, never to anything the agent said.

---

## 4. Demonstration

The demo is the argument, in four beats:

1. **Provision** — an agent is minted a subname live, with its role set assigned on-chain. Nothing pre-seeded.
2. **Operate** — the agent autonomously updates its endpoint and rotates its operating key. The verifier follows it across both changes without operator involvement.
3. **Attempt escape** — the agent tries to transfer its name, repoint its resolver, and rewrite `addr()`. All three revert. This is the sandbox made visible.
4. **Revoke** — the operator kills the name. The verifier's next resolution fails and it refuses to transact, and the orchestrator's whole worker fleet goes dark in the same transaction. Both halves are built and asserted (`test/CounterpartyVerifier.t.sol`, `test/SubAgentHierarchy.t.sol`); what remains for T6 is running them on Sepolia.

Beats 2 and 4 both hang on the same call — `CounterpartyVerifier.payAgent()` — so the demo is one counterparty repeatedly trying to pay one agent: it follows a rotation without noticing, and stops dead at revocation.

---

## 5. Track Alignment

The ENSv2 track ($4,500; $1,500 top prize) asks for projects built on ENSv2's hierarchical registry structure, naming Enhanced Access Control and permissioned resolvers directly, and awards bonus points for bringing AI agents into the mix. It requires ENSv2 features to be central rather than cosmetic, with a functional demo containing no hard-coded values.

This project uses ENSv2's permission tiers as its entire security model — remove EAC and there is no product, only the false choice of §1. The agent angle is the subject matter rather than a garnish, and the demo's central moment is a permission boundary holding under attack, which is difficult to fake.

Wildcard resolution is deliberately **not** used: per-agent EAC requires real registry entries, so wildcard resolution and record-scoped permissions pull against each other. Hierarchy is the better investment.

---

## 6. Open Questions

Deliberately unresolved, to be settled against the deployed Sepolia contracts rather than guessed at now.

- ~~**Revocation mechanism.**~~ **Resolved.** `unregister()` force-expires a live subname immediately, gated on `ROLE_UNREGISTER` held at the root resource. Verified against `ensdomains/contracts-v2` in `test/ForceExpiry.t.sol` and `test/SubtreeRevocation.t.sol`; written up as [finding 001](./docs/findings/001-force-expiry.md).
- ~~**Exact role constants and record-level granularity.**~~ **Resolved.** The shipped resolver scopes exactly as assumed: `ROLE_SET_TEXT` per `(namehash, key)` pair, with `addr()`, contenthash, pubkey, name, data, ABI and interface each behind their own role. `ROLE_SET_TEXT_ADMIN` delegates the write permission without conferring it, which is what lets the sandbox provision an allowlist while remaining unable to write a record itself. Verified in `test/AgentRecords.t.sol`; the surviving-grants caveat is in §3.4.
- ~~**Rotation safety.**~~ **Resolved: emit and watch, do not rate-limit.** Three reasons, in order of weight.

  *A cooldown does not stop the attack and does obstruct the recovery.* An attacker needs exactly one rotation; a cooldown delays them by at most one window and then **locks their key in**, because the honest operator's counter-rotation is what the timer is now blocking. It penalises the defender strictly more than the attacker.

  *It would cost a verified security property.* Rate-limiting needs per-name rotation state and a contract in the write path — meaning `AgentSandbox` would have to hold `ROLE_SET_TEXT` and rotate on the agent's behalf. That is precisely the "the sandbox is not a backdoor" property T1/T2 established by giving it only admin nybbles. Trading a proven containment guarantee for a speed bump is a bad trade.

  *The loud half is already free.* `setText` emits `TextChanged(node, indexedKey, key, value)` with **both** the namehash and the key hash indexed, so an operator watcher subscribes to exactly `(namehash(agent.operator.eth), keccak256("agent:operating-key"))` and sees every rotation, with the new key in the log payload — no polling, no enumeration, no added contract. What it looks for: any rotation the operator's own control plane did not initiate, and rotation bursts (a rate *alarm*, which is the useful half of rate-limiting, without the part that jams recovery).

  The operator's response is graduated, not binary: `authorizeTextRoles(name, "agent:operating-key", agent, false)` freezes rotation alone — pinning the published key to its last honest value while the agent keeps publishing its endpoint and status, and leaving the operator able to rotate on its behalf — with `unregister()` still there as the kill switch. Both levers asserted in `test/AgentKeyRotation.t.sol`.
- **Gas funding.** Record writes cost gas, so someone funds the agent's key. If that is the operator, it is a second and softer lever alongside revocation — worth naming rather than leaving for someone else to notice.
- **Off-chain records.** CCIP-Read was considered and rejected for this scope: the gas argument largely evaporated with the L1 pivot, and moving records off-chain would leave ENS holding a pointer and little else. Reasonable as future scaling, wrong as hackathon architecture.
