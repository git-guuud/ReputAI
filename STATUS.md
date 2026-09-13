# Status

**Last updated:** 2026-09-13
**Phase:** T1-T5 done. T6 deployed, rehearsed live, and now fronted by a four-pane terminal
control room (`./demo.sh`) that drives the same deployed contracts. The only thing left in the
whole project is recording the video.

## Completed

- **Repo scaffold.** Foundry project with `ensdomains/contracts-v2` wired in as a git
  submodule and compiling. Remappings resolved (see README for the order-sensitivity trap).
- **Finding 001 — force-expiry confirmed.** The operator kill switch works on a *live*
  subname via `unregister()`. Verified against the real `PermissionedRegistry`, not a mock.
  13 tests passing. Write-up: `docs/findings/001-force-expiry.md`.
- **IDEA.md corrected** against verified behaviour: `ROLE_UNREGISTER` named as the withheld
  role that matters, §3.4 rewritten around the real mechanism, §6 open question 1 closed.
- **T1 — sandbox registrar.** `src/AgentSandbox.sol`: one `provision()` call registers the
  subname, grants the agent a ceiling-checked role bitmap, and wires a real
  `PermissionedResolver`. 20 tests in `test/AgentSandbox.t.sol`, 33 passing repo-wide.
  Two design decisions worth remembering:
    - **Authority stays in ENS.** The sandbox holds root `ROLE_REGISTRAR` and no per-name roles —
      no owner variable. (T2 adds one more grant, root `ROLE_SET_TEXT_ADMIN` on the resolver.) Who may provision is decided by the registry's
      own EAC, and the sandbox is provably not a backdoor into names it minted.
    - **`AGENT_ROLE_CEILING` is an allowlist, not a denylist.** Currently exactly
      `ROLE_SET_SUBREGISTRY`. Any bit outside it reverts `RoleBitmapExceedsCeiling`, so a
      role added to ENSv2 later is withheld by default rather than silently grantable.

- **T2 — record-level text-key allowlist.** `provision()` now takes a `string[] textKeys`
  parameter and calls the resolver's own `authorizeTextRoles()` for each, so the agent holds
  `ROLE_SET_TEXT` at `resource(namehash, keccak256(key))` and nowhere else. 18 tests in
  `test/AgentRecords.t.sol`, 51 passing repo-wide. Worth remembering:
    - **The two tiers pull opposite ways, deliberately.** At the registry autonomy is defined by
      subtraction (`AGENT_ROLE_CEILING`); at the resolver it is defined by addition. `addr()` is
      unreachable from either direction — it needs `ROLE_SET_ADDR`, which `provision()` grants
      to nobody.
    - **The sandbox delegates a permission it does not hold.** Its resolver authority is root
      `ROLE_SET_TEXT_ADMIN` — an admin nybble, so it can hand `ROLE_SET_TEXT` to an agent for a
      named key but cannot write a record itself. Asserted, not assumed.
    - **The sandbox now needs the parent name.** The registry addresses names by labelhash and
      does not know what it is called; the resolver scopes everything by namehash. So
      `AgentSandbox` takes a DNS-encoded `parentName` at construction — the two layers cannot
      silently disagree about which name they mean.

- **T3 — operating-key rotation.** The agent publishes and replaces its own signing key with no
  operator in the loop. `AgentSandbox.OPERATING_KEY` canonicalises the text key
  (`agent:operating-key`, value = the 0x-hex address `ecrecover` returns) so agent, watcher and
  verifier cannot disagree; the sandbox gains no new authority. 11 tests in
  `test/AgentKeyRotation.t.sol`, 62 passing repo-wide. Worth remembering:
    - **Rotation had to be a text key.** `pubkey` would have been the natural home, but
      `setPubkey` checks `onlyPartRoles(node, 0, ...)` — the name-wide resource — and there is no
      `authorizePubkeyRoles`, so granting it hands the agent a permission the operator cannot
      narrow. Per-part scoping exists only where an `authorize*Roles` helper does: text, data,
      addr. Text is the one every ENS client already reads.
    - **Decision recorded: emit and watch, do not rate-limit** (IDEA.md §6). A cooldown does not
      stop the attack (one rotation is enough) and blocks the *recovery* rotation, and
      implementing it would put the sandbox in the write path holding `ROLE_SET_TEXT` — trading
      T1/T2's proven "not a backdoor" property for a speed bump. The loud half is free:
      `TextChanged` indexes both node and key.
    - **The operator's lever is graduated.** `authorizeTextRoles(..., false)` on just the
      operating key freezes rotation — key pinned to its last honest value, agent still
      publishing endpoint and status, operator still able to rotate on its behalf — with
      `unregister()` behind it. Both asserted.
    - **Blast radius is exactly "can speak, nothing else".** Tested against the maximal
      adversary: one who holds the agent's *own* key, rotates to itself, and still cannot move
      `addr()`, transfer the name, repoint the resolver, or widen its allowlist.

- **T4 — counterparty verifier.** `src/CounterpartyVerifier.sol`: resolves an agent name from the
  ENS root, reads endpoint + operating key, verifies a signature against the resolved key, and
  refuses to transact otherwise. `payAgent()` is the whole argument in one function — resolve,
  verify, pay `addr()`, or revert `Refused(reason, name)`. 17 tests in
  `test/CounterpartyVerifier.t.sol`, over a real four-tier hierarchy
  (`<root>` → `eth` → `operator` → `agent-404`). 79 passing repo-wide at that point. Worth
  remembering:
    - **Finding 002: resolution must be exact.** `LibRegistry.findResolver` inherits an ancestor's
      resolver when a name has none of its own — correct ENS behaviour — and the revoked agent's
      records are still in that resolver, because they are keyed by namehash. A verifier accepting
      an inherited resolver keeps paying a killed agent. We require `resolverOffset == 0`.
      Write-up: `docs/findings/002-inherited-resolver-survives-revocation.md`.
    - **Refusal is a value, not just a revert.** `checkAgent()` returns the same `Refusal` reason
      the transacting path reverts with, so the demo can show *why* before showing the revert.
      The reasons are distinguished deliberately (`NoOperatingKey` vs `MalformedOperatingKey`,
      `KeyMismatch` vs `NoPayoutAddress`) — collapsing them would tell a counterparty an honest
      agent is an impostor.
    - **The operating-key format gap is closed.** The record is parsed to an `address` rather than
      string-compared, so a checksummed publication verifies identically to a lowercase one.
    - **The verifier is trusted by nobody and holds nothing.** Asserted: zero roles in the registry
      and on the resolver. A counterparty can deploy its own; it needs only the ENS root address.

- **T5 — sub-agent hierarchy.** `src/SubAgentRegistrar.sol`: an orchestrator spawns workers beneath
  its own name, attenuated in three dimensions — registry roles, text keys, and lease — against its
  *live* state. 14 tests in `test/SubAgentHierarchy.t.sol` plus 2 added to
  `test/SubtreeRevocation.t.sol`; 93 passing repo-wide. Worth remembering:
    - **Finding 003: `register()` is not admin-checked.** It grants the new owner its bitmap via
      `_grantRoles(..., false)`, bypassing `canGrantRoles`. A registrar can mint a name carrying
      roles it does not hold and could not grant one transaction later. IDEA.md §2 and §3.4 both
      claimed the hierarchy enforced attenuation; both are now corrected. Attenuation is an
      application-level invariant. Write-up:
      `docs/findings/003-registration-bypasses-admin-check.md`.
    - **The registrar composes rather than reimplements.** It performs the subset proof and then
      calls a child-registry `AgentSandbox` for the actual mint, so T1's ceiling, T2's per-key
      authorization and the atomicity come along unchanged. It adds exactly one thing.
    - **The wiring is load-bearing.** The child registry's root account is the *operator*, not the
      orchestrator. If the orchestrator held root `ROLE_REGISTRAR` there it could mint unattenuated
      workers directly and every check would be decoration. Asserted, not assumed.
    - **Spawning is tied to ownership, not to an address.** `spawn()` reads `getOwner()` every
      call, so revocation and expiry both stop the fleet from growing — no extra mechanism.
    - **The fleet is proved offline from the outside**, with T4's verifier refusing to pay each of
      three workers after one `unregister()` at the tier above them.

- **T6 — deployed to Sepolia.** `script/01_Commit.s.sol` and
  `script/02_Register.s.sol`, plus `script/SepoliaConfig.sol`. 6 tests in
  `test/SepoliaDeployment.t.sol`, 101 passing repo-wide. Both questions this file previously
  left open for T6 are now answered:
    - **ENSv2 is fully deployed on Sepolia**, so we reuse the canonical tree and mint the operator
      tier down, exactly as anticipated. Addresses came from the submodule's own generated table
      (`docs/addresses/sepolia.md`, chain 11155111) and each was confirmed to hold code on-chain.
      `CounterpartyVerifier` is handed the real root, `0x11b5…F50C`.
    - **The demo is one counterparty calling `payAgent()` repeatedly**, as planned — one test per
      beat in the fork test.
    - **The fork test runs the scripts themselves, not a reimplementation of them.** A scripting
      mistake fails in CI rather than on a funded chain, and the two scripts are the artifact the
      live run will use unchanged.
    - **Registration is commit-reveal with a 60s `MIN_COMMITMENT_AGE`**, and the commitment binds
      the subregistry and resolver addresses — so both proxies are deployed in phase 1, before
      committing, and the split into two scripts is forced rather than stylistic. Phase 2
      re-derives the commitment and checks the registrar still holds it before spending gas.
    - **`02_Register` asserts the T1/T2 containment properties against the live deployment**
      before it exits. A wiring mistake fails the script instead of quietly producing a sandbox
      that is a backdoor.
    - **Live addresses** (chain 11155111, in README and `deployments/sepolia.json`): operator
      registry `0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b`, resolver
      `0xDdb4717972E663b126f3E2D64df478Eca40f69F5`, `AgentSandbox`
      `0x657Dc79a217eBB8aC22C5B6E9237040cd75Eabf0`, `CounterpartyVerifier`
      `0x62BFB71dc67a2ddc4c0B3BE25fa133772b4BB05e`. Routing was re-checked with `cast` from the
      real root rather than trusted from the script's own output.

- **T6 — demo, built and rehearsed live.** `script/03_Demo.s.sol` (one broadcastable contract per
  beat), `script/03b_escape.sh`, `script/03c_refused.sh`, and the recording runbook
  `docs/DEMO.md`. The fork test now runs the demo scripts themselves — 101 passing repo-wide,
  unchanged count, because the beats were rewritten rather than added to. Worth remembering:
    - **A beat is one command and one party.** Splitting the beats into separate script contracts
      is not cosmetic: it makes *who signs which transaction* the visible argument (operator
      provisions and revokes, agent publishes and rotates, counterparty pays), it lets the
      recording pause on Etherscan between beats, and it lets a beat be re-run in isolation
      after a fluffed take.
    - **`forge script` cannot broadcast a transaction that must revert.** It simulates first and
      aborts. Beat 3's three escape attempts and beat 4's refused payment are exactly the
      transactions worth showing, so they go through `cast send --gas-limit`, which skips
      estimation and gets the failure mined. That is why two of the eight demo commands are
      shell scripts, and it is a constraint of the tool, not a weakness of the claim.
    - **Revert reasons are decoded locally**, from selectors resolved against the submodule's own
      error definitions rather than a selector database: `TransferDisallowed` for the transfer
      (soulbound: transfer is gated on `ROLE_CAN_TRANSFER_ADMIN` held by the *sender*) and
      `EACUnauthorizedAccountRoles` for the other two, whose `resource` field shows *where* the
      check happened — the name-wide resource, never one of the agent's two authorized text keys.
    - **The whole thing was rehearsed on live Sepolia**, not just on a fork, under the throwaway
      label `agent-rehearsal`: provisioned, published, paid, rotated, paid again on the new key
      with the retired one refused, three escapes reverted on-chain, revoked, and a final payment
      refused with `Refused(1, ...)`. Total cost ~0.003 ETH at ~1 gwei.
    - **Beat 1 must mint a name that has never existed** — that is what makes "nothing
      pre-seeded" something a viewer can check rather than a claim. `agent-404` was the intended
      one and has since been minted on Sepolia in a test run (2026-09-13), so the recording needs
      a fresh label; see Pending.

- **T7 — the control room.** `cli/` (Node + viem) and `demo.sh`: four tmux panes — a live chain
  reader plus one shell per party, each holding exactly one key and refusing the other parties'
  verbs. The eight beats become eight verbs typed in the pane that signs them. Every beat was
  run end-to-end against `anvil --fork-url` before anything touched the live chain. Worth
  remembering:
    - **The presentation *is* the argument here.** The project's claim is about who may do what,
      and a wall of `forge script` output cannot show a permission boundary holding. The live
      pane's two verdict lights swapping when the agent rotates in another pane — with nobody
      touching the counterparty — is beat 2 in one glance, and both going red on `revoke` is
      beat 4.
    - **Nothing is held between frames.** Every field on the live pane is a chain read at the
      block stamped in its header, and every action prints its own Etherscan link. That is what
      keeps a nice-looking UI from reading as a mock.
    - **The revert-must-be-mined constraint disappears.** `forge script` refuses to broadcast a
      call that reverts in simulation, which is why two of the original eight commands were raw
      `cast`. In viem an explicit `gas` skips estimation, so beat 3 and the refused payments are
      the same tool as everything else.
    - **Two bugs the fork rehearsal caught,** neither of which would have been visible without
      running it: the registry and the resolver reuse bit positions for different roles
      (`1 << 0` is `ROLE_REGISTRAR` at one and `ROLE_SET_ADDR` at the other), so a revert can
      only be named correctly if the namespace is named with it; and `payAgent`'s message must
      be hex-encoded, since viem writes a plain string into a `bytes` parameter verbatim.
    - **`freeze`/`unfreeze` are new on camera, not new in the design.** IDEA.md §3.3's graduated
      lever existed only in tests. It is one `authorizeTextRoles(..., false)` call and it answers
      "so the only response is the kill switch?" before a judge asks it. Confirmed on the fork:
      the operator does hold the admin nybble needed, and a frozen agent's `rotate` reverts at
      the *name-wide* resource — the documented `onlyPartRoles` fallback, observed rather than
      assumed.
    - **The forge scripts stay.** They are what `test/SepoliaDeployment.t.sol` exercises in CI,
      and they are documented in `docs/DEMO-scripts.md` as the fallback path. The control room is
      a second front end onto the same contracts, not a replacement for the tested one.
    - **Layout, second pass.** The first version had four panes that read as one merged surface
      and three shells each scrolling their own wall of output. Both are fixed, and the fixes are
      the same idea: say each thing once, in the place that owns it.
        - Each pane's **top border is a full-width solid bar in that party's colour**, carrying
          its name *and its verbs*, so nothing has to be looked up mid-take. `pane-border-format`
          is a window option and cannot vary per pane, so the colour comes from `@bar`, a
          per-pane user option — one format, four colours. (`select-pane -P` is the wrong lever:
          it styles the pane's *contents*, not its border, and would tint the output.)
        - **Each shell clears itself on every command** and shows only its latest action. The
          running history already lives in the control room's feed, coloured by signing key, so
          a shell that also scrolled one would be the same evidence twice in the place with the
          least room for it. Per-beat output went from ~11 lines to 3-8.
        - Etherscan URLs are **OSC 8 hyperlinks** with the tx hash as the label: an 84-column
          pane cannot hold a full URL without wrapping, and a wrapped URL is neither pretty nor
          clickable.
        - The control room **stretches to its pane** (84-120 columns) instead of leaving a third
          of it blank, and its two key lights are now labelled `genesis`/`rotated` with a marker
          on whichever the name publishes right now — the same vocabulary the shells use.
    - **Two more bugs the fork rehearsal caught.** `revoke` verified against a hard-coded rotated
      key, so its "before" line read `KeyMismatch` whenever it ran without beat 2c — destroying
      the beat's whole contrast; it now asks with whatever key the name currently publishes. And
      `DEMO_ENDPOINT`/`DEMO_MESSAGE` in `.env` name a label, so a fresh label silently kept
      publishing the old one's endpoint; both now default off `DEMO_AGENT_LABEL`, and an `.env`
      value naming a different label is ignored rather than quietly printed.

## In progress

Nothing. Clean stopping point.

## Pending

**The video.** Nothing else. Follow `docs/DEMO.md`: pick an unminted label, `./demo.sh --fresh`,
then eight verbs typed into the pane belonging to the party that signs each one, against the
already-deployed contracts. Demo accounts are funded (operator ~0.032 ETH, agent and counterparty
~0.0055 each) and the run costs ~0.003 ETH.

**`agent-404` is minted on live Sepolia** as of 2026-09-13 (a test run), so it can no longer be
minted on camera and beat 1 needs a fresh label. `DEMO_AGENT_LABEL` is the only variable to set:
the endpoint and the signed message both derive from it.

## Verified protocol facts

Things established by reading/running actual code, safe to build on:

| Fact | Evidence |
|---|---|
| `unregister()` force-expires a live name immediately | `test/ForceExpiry.t.sol` |
| Root-resource roles apply to every name in a registry | `EnhancedAccessControl.sol:454` |
| `renew()` cannot shorten expiry (`CannotReduceExpiry`) | `test/ForceExpiry.t.sol` |
| Revocation increments `eacVersionId`, killing the agent's grants | `test/ForceExpiry.t.sol` |
| Revoking a parent severs the path to its whole subtree | `test/SubtreeRevocation.t.sol` |
| Child registry storage survives revocation (orphaned, not deleted) | `test/SubtreeRevocation.t.sol` |
| Per-text-key permissions exist via `authorizeTextRoles()` | `PermissionedResolver.sol:65-72` |
| Granting a role at a name resource needs its `*_ADMIN` nybble, so a role-less agent cannot self-escalate or delegate | `PermissionedRegistry._getSettableRoles`, `test/AgentSandbox.t.sol` |
| ERC1155 transfer is gated on `ROLE_CAN_TRANSFER_ADMIN` held by the *sender*, so withholding it makes the name soulbound to the agent | `PermissionedRegistry._update`, `test/AgentSandbox.t.sol` |
| `getResource()` on an unregistered/expired name returns `eacVersionId + 1` — the *next* resource, not the current one | `PermissionedRegistry._constructResource` |
| `authorizeTextRoles()` scopes `ROLE_SET_TEXT` per key, at `resource(namehash, keccak256(key))` — per-key allowlisting is a protocol feature, as §3.3 assumed | `test/AgentRecords.t.sol` |
| `onlyPartRoles` falls back to the name-wide resource, so a key with no grant reverts `EACUnauthorizedAccountRoles(resource(node, 0), …)` | `PermissionedResolver:178-187`, `test/AgentRecords.t.sol` |
| Text and `addr()` are separate roles: a text allowlist confers nothing on `addr()`, contenthash, pubkey, name, data, ABI, interface or `clearRecords` | `test/AgentRecords.t.sol` |
| Root `ROLE_SET_TEXT_ADMIN` lets an account *grant* `ROLE_SET_TEXT` without being able to write — `withAdminRolesApplied` is used only by grant checks, not `_checkRoles` | `EACBaseRolesLib:31`, `test/AgentRecords.t.sol` |
| **Resolver grants outlive `unregister()`.** They are keyed by namehash, which revocation does not rotate; only the registry-tier roles die. Containment is unreachability, not deletion — the same limit as the orphaned subtree | `test/AgentRecords.t.sol` |
| `setText` emits `TextChanged(node, indexedKey, key, value)` with **both** node and key indexed, so a watcher can filter one key on one name exactly | `PermissionedResolver.sol:488`, `test/AgentKeyRotation.t.sol` |
| Per-part scoping exists exactly where an `authorize*Roles` helper does: name, text (by key), data (by key), addr (by coin type). `pubkey`, contenthash, ABI, interface and `clearRecords` check part `0` and are name-wide only — so a rotatable credential cannot live in `pubkey` | `PermissionedResolver.sol:273-380` vs `396-469` |
| Revoking one text key leaves the agent's other keys writable *and* leaves the operator able to write the revoked key, so freezing rotation is not silencing the agent | `test/AgentKeyRotation.t.sol` |
| `register()` grants the new owner *any* bitmap without an admin check (`_grantRoles(..., false)` skips `canGrantRoles`), so cross-tier attenuation is application-level, not protocol-level | `PermissionedRegistry._register`, `test/SubAgentHierarchy.t.sol` |
| `LibRegistry.findResolver` inherits the nearest ancestor's resolver and reports where it found it (`resolverOffset`); a revoked name therefore still "resolves" through its parent | `universalResolver/libraries/LibRegistry.sol`, `test/CounterpartyVerifier.t.sol` |
| `getOwner()`, `getResolver()` and `getSubregistry()` all fall to zero the instant a name expires, so a lapsed lease is indistinguishable from a revocation to a client | `PermissionedRegistry`, `test/CounterpartyVerifier.t.sol` |
| `PermissionedResolver` implements `IExtendedResolver`, so a client can (and this one does) read records through `resolve(name, data)` rather than calling profiles directly | `PermissionedResolver.sol:205-228, 508` |
| ENSv2 is deployed on Sepolia (chain 11155111): root `0x11b5…F50C`, `.eth` registry `0x67b7…4b43`, `ETHRegistrar` `0xa444…5a30`. All confirmed to hold code | `script/SepoliaConfig.sol`, `contracts-v2/docs/addresses/sepolia.md` |
| `ETHRegistrar.register` takes payment in **ERC-20 only** — `SafeERC20.safeTransferFrom`, no `payable` path. The Sepolia oracle accepts upstream's MockUSDC, whose `mint()` is unpermissioned | `ETHRegistrar.sol:143`, `test/mocks/MockERC20.sol` |
| Registration is commit-reveal: `MIN_COMMITMENT_AGE` 60s, `MAX_COMMITMENT_AGE` 24h, and the commitment hash binds subregistry + resolver, so both must exist before committing | `ETHRegistrar.makeCommitment`, `script/01_Commit.s.sol` |
| A `.eth` name is an ERC-1155, so the owner must be a valid receiver — an EIP-7702-delegated EOA has code and reverts `ERC1155InvalidReceiver` | `test/SepoliaDeployment.t.sol` |
| User-owned subdomain registries are `UserRegistry` (UUPS) proxies deployed through `VerifiableFactory`; `PermissionedResolver` uses the same pattern | `UserRegistry.sol`, `deploy/01_UserRegistryImpl.ts` |


## Known gaps

- The video has not been recorded. That is the only thing between the current state and a
  finished submission; the beats themselves have been run live once already (`agent-rehearsal`).
- **The control room is not covered by `forge test`.** `test/SepoliaDeployment.t.sol` forks
  Sepolia and runs the *forge scripts*; the CLI is a separate front end onto the same contracts
  and was verified by running all eight beats against `anvil --fork-url` by hand. Both paths send
  the same calls from the same three keys, but only one of them fails in CI.
- **Two of the eight `forge`/`cast` demo commands are `cast`,** because their transactions must
  revert and a `forge script` broadcast refuses to send a call that reverts in simulation. The
  control room does not have this problem — an explicit gas limit in viem skips estimation — so
  this applies only to the `docs/DEMO-scripts.md` path.
- **The recorded demo is the single-agent path.** The sub-agent fleet going dark (T5) is asserted
  in tests with this same verifier, not run on camera; `docs/DEMO.md` says so and points at the
  tests rather than letting the video imply more than it shows.
- **Resolver grants and records outlive `unregister()`** (namehash is not rotated). Containment is
  unreachability, not deletion, at every tier — the agent's records, and an orphaned child
  registry's entire contents. Stated out loud in IDEA.md §3.4 and asserted in three test files
  rather than left for a judge to find. The verifier's exact-resolution rule is what makes it
  harmless in practice.
- **An orphaned child registry keeps working internally.** A revoked orchestrator that holds
  registrar rights *inside* its own subtree can still mint workers there; they are born
  unreachable. "The fleet is frozen" would be the wrong claim to make on stage — the right one is
  "nothing can route to it". Asserted in `test/SubtreeRevocation.t.sol`.
- The verifier is an on-chain contract, so it cannot follow a CCIP-Read (`OffchainLookup`)
  redirect: an off-chain resolver reads as an absent record and refuses. Acceptable — IDEA.md §6
  already rejects off-chain records for this design — but an off-chain client written for T6's
  demo should mirror the same checks, exact resolution included.
- Message semantics are out of scope by design: the verifier proves *authorship*, not that a
  message authorises a particular payment. A production integration binds the signed message to an
  amount and a nonce. Worth saying before someone asks.
