# Task breakdown

One bounded task per session. Do not start the next until exit criteria pass.

---

## T1 — Sandbox registrar

Mint an agent subname with the §3.2 role split baked in, so provisioning is one call
rather than a sequence a demo could get wrong.

**Exit criteria — DONE** (`src/AgentSandbox.sol`, `test/AgentSandbox.t.sol`, 20 tests)
- [x] `src/AgentSandbox.sol` exposes a single entrypoint that registers a subname,
      assigns the agent's role bitmap, and wires the permissioned resolver.
- [x] Agent receives exactly the intended roles — asserted role-by-role, not just "it worked".
- [x] Test proves the agent cannot: transfer, `setResolver`, `unregister`, or grant itself roles.
- [x] Operator can still `unregister()` the result (reuse the finding-001 assertions).
- [x] No hard-coded label or address; everything a parameter (track requirement).

---

## T2 — Permissioned resolver with a text-key allowlist

The record-level tier from IDEA.md §3.3. This is the part that distinguishes the project
from "we set some registry roles".

**Exit criteria — DONE** (`src/AgentSandbox.sol`, `test/AgentRecords.t.sol`, 18 tests)
- [x] Agent can write its allowlisted keys (endpoint, capability manifest, status, state hash).
- [x] Agent is rejected writing a non-allowlisted key.
- [x] Agent is rejected writing `addr()` — assert explicitly, this is the headline boundary.
- [x] Operator can write anything.
- [x] Allowlist is configurable at provision time, not a constant.

Beyond the criteria, because they were cheap once the harness existed: the agent is rejected on
every *other* profile (contenthash, pubkey, name, data, ABI, interface, `clearRecords`), cannot
widen its own allowlist or delegate a key, and cannot touch a sibling agent's records on the
shared resolver. The sandbox itself is proved unable to write anything.

---

## T3 — Operating-key rotation

IDEA.md §3.3's sharpest feature. T2 already gives the mechanism: pass the operating-key text
key in `provision()`'s allowlist. What is left is the rotation *semantics* and the blast-radius
proof.

**Exit criteria — DONE** (`src/AgentSandbox.sol`, `test/AgentKeyRotation.t.sol`, 11 tests)
- [x] Agent rotates its published operating key unilaterally — one call, one party, repeatable.
- [x] `addr()` is unchanged by rotation — asserted before and after, plus the agent rejected
      on `setAddr` so rotation never becomes a route to it.
- [x] Test demonstrating the bounded-blast-radius claim: a rotated-in key verifies as the agent
      (`ECDSA.recover` against the *resolved* key) while the retired one stops; the fully
      compromised agent cannot move `addr()`, transfer the name, repoint the resolver, or widen
      its allowlist; and `unregister()` leaves nothing to resolve the key from.
- [x] Decided and recorded in IDEA.md §3.3 and §6: **emit and watch, do not rate-limit.**

Beyond the criteria: rotation is opt-in per provisioning (an agent without the key in its
allowlist is rejected at the resolver); a holder of the operating key alone has no on-chain
authority at all; and the operator can freeze rotation specifically — pinning the key while the
agent keeps publishing everything else — as the graduated response short of the kill switch.

---

## T4 — Counterparty verifier

Without this the kill switch demonstrates nothing (IDEA.md §3.5). **Do not defer.**

**Exit criteria — DONE** (`src/CounterpartyVerifier.sol`, `test/CounterpartyVerifier.t.sol`, 17 tests)
- [x] Client resolves an agent name, reads endpoint + operating key — walking a real four-tier
      hierarchy (`<root>` → `eth` → `operator` → `agent-404`) with `LibRegistry.findResolver`,
      the same traversal `UniversalResolverV2` uses. It is handed the ENS root, never a resolver.
- [x] Verifies an agent signature against the resolved key. The key is parsed to an address, so a
      checksummed publication verifies identically to a lowercase one (closing the convention gap
      STATUS.md flagged).
- [x] **Refuses to transact** — `payAgent()` reverts `Refused(reason, name)` on unresolvable, no
      endpoint, no key, malformed key, malformed signature, key mismatch, or no `addr()`. The
      matching view (`checkAgent`) returns the same reason without reverting, so a demo can show
      the refusal before it happens.
- [x] Integration test: revoke mid-flow, verifier's next call refuses — a counterparty that paid
      the agent one call earlier is cut off, with nothing about the agent changed.

Beyond the criteria: payment always goes to the resolved `addr()` and never to anything the agent
said; a lapsed lease refuses exactly like a revocation; a frozen rotation keeps the agent payable
on its last honest key; and a fuzz test asserts no key but the published one is ever accepted.

**Finding 002** ([write-up](./docs/findings/002-inherited-resolver-survives-revocation.md)):
resolution must be **exact**. ENS inherits an ancestor's resolver when a name has none of its own,
and a revoked agent's records survive in that same resolver — so a standards-compliant verifier
would keep paying a killed agent. The verifier requires `resolverOffset == 0`.

---

## T5 — Sub-agent hierarchy

Optional but the strongest track differentiator. Blocked on T1.

**Exit criteria — DONE** (`src/SubAgentRegistrar.sol`, `test/SubAgentHierarchy.t.sol`, 14 tests;
`test/SubtreeRevocation.t.sol` extended to 6)
- [x] Orchestrator mints workers with a role bitmap provably a subset of its own — asserted as a
      subset relation read back from the registry (`workerRoles & ~orchestratorRoles == 0`), not
      as equality with what the test asked for.
- [x] Attempt to grant a worker a role the orchestrator lacks reverts `RolesExceedOrchestrator`,
      naming the offending bits. Checked against *live* state: the operator narrowing the
      orchestrator narrows what it can delegate in the same transaction.
- [x] Revoking the orchestrator takes the fleet offline — proved from the outside with T4's
      verifier (three live workers, all refused after one `unregister()`), and in
      `SubtreeRevocation.t.sol` for a four-worker fleet.

Beyond the criteria, because the same subset argument applies at every tier: text keys are
attenuated too (an orchestrator cannot delegate a key it may not write itself — T2's tier,
inherited), a worker's lease cannot outlive its parent's, only the *current owner* of the parent
name may spawn (so revocation and expiry both stop the fleet growing), and minting into a detached
subtree is refused rather than producing unreachable names.

**Finding 003** ([write-up](./docs/findings/003-registration-bypasses-admin-check.md)) is the
task's real content and corrects IDEA.md §2 and §3.4: `register()` grants roles through
`_grantRoles(..., false)`, skipping the `canGrantRoles` admin check, so a registrar can mint a name
carrying roles it does not hold and could not grant one transaction later. **Attenuation is an
application-level invariant in ENSv2, not a protocol-level one** — which is why this contract
exists. Its binding force depends on the orchestrator *not* holding root `ROLE_REGISTRAR` in its
own child registry; the operator keeps that, and the test asserts it.

---

## T6 — Sepolia deployment + demo

Deployed. `reputai-sandbox.eth` is live on Sepolia and both of our contracts are verified on
Etherscan. What remains is the recorded demo.

**Exit criteria**
- [x] Deploy script — `script/01_Commit.s.sol` + `script/02_Register.s.sol`, split because
      `MIN_COMMITMENT_AGE` is 60s and the commitment binds the subregistry and resolver
      addresses, so both proxies must exist before committing. README documents the run;
      the addresses table is filled in after it.
- [x] Rehearsed: `test/SepoliaDeployment.t.sol` forks live Sepolia and runs the two scripts
      themselves — not a reimplementation — so a scripting mistake fails in CI rather than on
      a funded chain. 6 tests, 101 passing repo-wide.
- [x] **Live mint on Sepolia** — nothing pre-seeded (track requirement). `reputai-sandbox.eth`
      was unregistered until the run and was registered through the canonical `ETHRegistrar`
      commit-reveal, token
      `82014684042502907806827642409189172684607278140570247175654264894634632151040`.
      Routing verified independently with `cast` from the real ENS root: root -> `eth` ->
      `0xfeA7…E14b` (our operator registry). Addresses in README and `deployments/sepolia.json`.
- [x] Contracts verified on Etherscan (`AgentSandbox`, `CounterpartyVerifier`).
- [x] The four demo beats from IDEA.md §4 run end-to-end against real Sepolia state, one test
      per beat, through the real root / `.eth` registry / commit-reveal registrar.
- [ ] **Run the four beats as live transactions** against the deployed contracts. The fork test
      proves they work against real state; a scripted live run (`script/03_Demo.s.sol`) is what
      the video records, and provisioning the agent on camera is what makes "nothing
      pre-seeded" visible. **Next session.**
- [ ] Video recorded.

Worth remembering:

- **ENSv2 is fully deployed on Sepolia**, which settles the open question in STATUS.md: we
  reuse the canonical tree and mint the operator tier down. `script/SepoliaConfig.sol` holds
  the addresses, taken from the submodule's own generated table and each confirmed to hold
  code on-chain.
- **Rent is ERC-20 only — there is no ETH path** through `ETHRegistrar.register`. The oracle
  accepts upstream's MockUSDC, whose `mint()` is unpermissioned on testnet, so rent costs
  nothing but gas. Marked explicitly in the script: it is the one mocked component, and it is
  upstream's mock.
- **The operator must be a valid ERC-1155 receiver.** The name is a token. This surfaced as a
  fork-test failure using the well-known `0xA11CE` test key, which someone has EIP-7702-
  delegated on live Sepolia — so it has code and the mint reverted `ERC1155InvalidReceiver`.
  A real constraint, not a test artifact: an operator on a smart account or a delegated EOA
  needs `onERC1155Received`. The fork test asserts `deployer.code.length == 0` with that
  message.
- **The fork test derives its label from the block number.** It was hard-coded to
  `reputai-sandbox`, which passed right up until T6 registered that name for real — then the
  rehearsal started failing against its own deployment. A test that registers a name against
  live state cannot share a label with the live run.
- **Arguments evaluate before the call, so an external call in an argument list eats a
  one-shot `vm.prank`.** Surfaced as `NotRegistrar(DefaultSender)` — `sandbox.OPERATING_KEY()`
  sat in `provision()`'s argument list and consumed the prank meant for `provision` itself. The
  operating key and the allowlist are both hoisted out in `setUp` for this reason.
