# Task breakdown

One bounded task per session. Do not start the next until exit criteria pass.

---

## T1 — Sandbox registrar

Mint an agent subname with the §3.2 role split baked in, so provisioning is one call
rather than a sequence a demo could get wrong.

**Exit criteria**
- [ ] `src/AgentSandbox.sol` exposes a single entrypoint that registers a subname,
      assigns the agent's role bitmap, and wires the permissioned resolver.
- [ ] Agent receives exactly the intended roles — asserted role-by-role, not just "it worked".
- [ ] Test proves the agent cannot: transfer, `setResolver`, `unregister`, or grant itself roles.
- [ ] Operator can still `unregister()` the result (reuse the finding-001 assertions).
- [ ] No hard-coded label or address; everything a parameter (track requirement).

---

## T2 — Permissioned resolver with a text-key allowlist

The record-level tier from IDEA.md §3.3. This is the part that distinguishes the project
from "we set some registry roles".

**Exit criteria**
- [ ] Agent can write its allowlisted keys (endpoint, capability manifest, status, state hash).
- [ ] Agent is rejected writing a non-allowlisted key.
- [ ] Agent is rejected writing `addr()` — assert explicitly, this is the headline boundary.
- [ ] Operator can write anything.
- [ ] Allowlist is configurable at provision time, not a constant.

---

## T3 — Operating-key rotation

IDEA.md §3.3's sharpest feature.

**Exit criteria**
- [ ] Agent rotates its published operating key unilaterally.
- [ ] `addr()` is unchanged by rotation — assert before and after.
- [ ] Test demonstrating the bounded-blast-radius claim: holder of a rotated-in key can
      sign as the agent, but cannot move funds, take the name, or survive revocation.
- [ ] Decide and record: rate-limit rotations, or emit an event for an operator watcher?
      Write the decision into IDEA.md §6 either way.

---

## T4 — Counterparty verifier

Without this the kill switch demonstrates nothing (IDEA.md §3.5). **Do not defer.**

**Exit criteria**
- [ ] Client resolves an agent name, reads endpoint + operating key.
- [ ] Verifies an agent signature against the resolved key.
- [ ] **Refuses to transact** when resolution fails or the key mismatches.
- [ ] Integration test: revoke mid-flow, verifier's next call refuses.

---

## T5 — Sub-agent hierarchy

Optional but the strongest track differentiator. Blocked on T1.

**Exit criteria**
- [ ] Orchestrator mints workers with a role bitmap provably a subset of its own.
- [ ] Attempt to grant a worker a role the orchestrator lacks reverts.
- [ ] Revoking the orchestrator takes the fleet offline (extend `SubtreeRevocation.t.sol`).

---

## T6 — Sepolia deployment + demo

Blocked on `myTasks.md`.

**Exit criteria**
- [ ] Deploy script, addresses recorded in README.
- [ ] Live mint on Sepolia — nothing pre-seeded (track requirement).
- [ ] The four demo beats from IDEA.md §4 run end-to-end on testnet.
- [ ] Video recorded.
