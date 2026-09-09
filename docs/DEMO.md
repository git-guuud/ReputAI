# Recording runbook — the four beats, live on Sepolia

Everything here has been run end-to-end against live Sepolia once already, on the throwaway label
`agent-rehearsal` (revoked at the end of the rehearsal, transactions still on-chain). The name the
recording mints, `agent-404.reputai-sandbox.eth`, has never existed — which is the point of beat 1
happening on camera.

Each beat is one command and one party. The commands print what the counterparty sees *before*
they spend anything, so the terminal alone tells the story; Etherscan is the corroboration.

---

## Before you start recording

Nothing here spends gas.

```bash
# 1. The tree is real, and it is not ours until the third line.
cast call 0x11b5BfbE9078D826b1eDBDd1cFC12f5828D9F50C "getSubregistry(string)(address)" "eth" --rpc-url sepolia
#   -> 0x67b728a792e789a8978b30cF1b3b641f19354b43   the canonical .eth registry
cast call 0x67b728a792e789a8978b30cF1b3b641f19354b43 "getSubregistry(string)(address)" "reputai-sandbox" --rpc-url sepolia
#   -> 0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b   our operator registry, registered through the real registrar

# 2. Nothing is pre-seeded: the agent's name does not exist.
cast call 0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b "getResolver(string)(address)" "agent-404" --rpc-url sepolia
#   -> 0x0000000000000000000000000000000000000000

# 3. Balances (deployer ~0.03 ETH, agent and counterparty ~0.005 each is ample; the whole
#    demo costs about 0.003 ETH of gas at 1 gwei).
cast balance 0x7aD721F362A8049Dd139764B0745657D06d9AA93 --rpc-url sepolia -e   # operator
cast balance 0x526241340F1CC21e5606c195dAB7ecCf8d725D9b --rpc-url sepolia -e   # agent
cast balance 0x23cff83468a019182baA373776E95Ee8b95301e5 --rpc-url sepolia -e   # counterparty
```

Tabs worth having open on <https://sepolia.etherscan.io>:

| What | Address |
|---|---|
| Operator registry (our subdomain registry) | `0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b` |
| `PermissionedResolver` | `0xDdb4717972E663b126f3E2D64df478Eca40f69F5` |
| `AgentSandbox` (verified) | `0x657Dc79a217eBB8aC22C5B6E9237040cd75Eabf0` |
| `CounterpartyVerifier` (verified) | `0x62BFB71dc67a2ddc4c0B3BE25fa133772b4BB05e` |
| Agent EOA | `0x526241340F1CC21e5606c195dAB7ecCf8d725D9b` |
| Counterparty EOA | `0x23cff83468a019182baA373776E95Ee8b95301e5` |
| Treasury (`addr()`, where payments land) | `0x9819C0a9Ae19Cda1B59325132eE26a5C807Ef98f` |

The three parties are separate keys, and that is the argument: watch the `From` column change.

---

## Beat 1 — provision (operator)

```bash
forge script script/03_Demo.s.sol:Beat1_Provision --rpc-url sepolia --broadcast
```

Two transactions from the operator: `AgentSandbox.provision()` mints the name, grants the agent
its role bitmap (**zero registry roles** — the tightest sandbox the ceiling allows), wires the
resolver and authorizes exactly two text keys; then the operator publishes `addr()`.

Say: the agent is being handed an identity it can operate and cannot own. `provision()` grants
`ROLE_SET_ADDR` to nobody, so the payout address is the operator's and stays the operator's.

Show: the `AgentProvisioned` event on the sandbox — the role bitmap and the two authorized keys
are in the log, so the containment is auditable from the receipt.

## Beat 2a — the agent publishes (agent)

```bash
forge script script/03_Demo.s.sol:Beat2a_Publish --rpc-url sepolia --broadcast
```

Two transactions **from the agent's own key**: its endpoint, and the key it will sign with.
No operator transaction in between, now or later in beat 2.

## Beat 2b — the counterparty pays (counterparty)

```bash
forge script script/03_Demo.s.sol:Beat2b_Pay --rpc-url sepolia --broadcast
```

The script prints the verifier's verdict *before* it sends: resolver, endpoint, operating key,
`payTo`, the address the signature recovers to, and `None (would transact)`.

Say: this counterparty was handed the ENS root address and nothing else. It walks the tree
itself, and it pays the resolved `addr()` — never an address the agent named in its message.

## Beat 2c — the agent rotates its key (agent)

```bash
forge script script/03_Demo.s.sol:Beat2c_Rotate --rpc-url sepolia --broadcast
```

One transaction, one party, no operator, no downtime. The script asserts `addr()` is unchanged
by the rotation before it exits.

## Beat 2d — the counterparty follows, and the retired key stops (counterparty)

```bash
forge script script/03_Demo.s.sol:Beat2d_PayRotated --rpc-url sepolia --broadcast
```

Second payment lands on the new key. Then the same message under the **retired** key prints
`KeyMismatch (REFUSED)` — the rotation is a rotation, not a fork.

Show: the treasury balance is now 0.002 ETH, from two payments signed by two different keys.

## Beat 3 — attempted escape (agent)

```bash
script/03b_escape.sh
```

Three transactions from the agent's own key, all reverting on-chain:

| Attempt | Revert |
|---|---|
| transfer the name to an attacker | `TransferDisallowed` — the name is soulbound: transfer is gated on `ROLE_CAN_TRANSFER_ADMIN` held by the *sender* |
| repoint the resolver | `EACUnauthorizedAccountRoles(resource = the name, role = ROLE_SET_RESOLVER)` |
| rewrite the payout address | `EACUnauthorizedAccountRoles(resource = the name-wide resource, role = ROLE_SET_ADDR)` |

The script prints the decoded reason, then sends each one with an explicit gas limit so the
failure is mined rather than caught in estimation. Open one on Etherscan: a failed transaction
from the agent, against its own name.

Say: this is a fully compromised agent — whoever holds its key holds everything it has — and the
blast radius is exactly "can speak, nothing else".

## Beat 4 — revoke (operator), and the money stops (counterparty)

```bash
forge script script/03_Demo.s.sol:Beat4_Revoke --rpc-url sepolia --broadcast
script/03c_refused.sh
```

`Beat4_Revoke` prints the verifier's verdict either side of one `unregister()`: `None (would
transact)` before, `Unresolvable (REFUSED)` after, on the same name, same key, same signature.
`03c_refused.sh` then sends the payment anyway, so the refusal is a transaction you can click:
`Refused(1, agent-404.reputai-sandbox.eth)`.

Say the honest version of it: the agent's records are **still in the resolver** — the script
prints them — and the agent never learns it was killed. What the operator removed is the path.
Containment here is unreachability, not deletion, and the verifier's exact-resolution rule
(finding 002) is what makes that enough.

---

## If a beat goes wrong mid-recording

Every beat is idempotent except beat 1, and the fix is a fresh label — nothing else has to be
redone:

```bash
export DEMO_AGENT_LABEL=agent-405     # any unused label under reputai-sandbox.eth
forge script script/03_Demo.s.sol:Beat1_Provision --rpc-url sepolia --broadcast
```

`Beat1_Provision` refuses to run against a label that already has a resolver, so it cannot
half-overwrite a previous take.

A read-only snapshot, safe to run at any point between beats:

```bash
forge script script/03_Demo.s.sol:Status --rpc-url sepolia
```

## What is mocked

One thing, and it is upstream's: rent for the `.eth` registration was paid in **MockUSDC**
(`0xD3322B29a7BdEe707D1684676f149bf41Aa3422f`), whose `mint()` is unpermissioned on testnet,
because `ETHRegistrar.register` takes ERC-20 only and there is no ETH path. That happened once,
in `01_Commit`, and it is not part of the demo. Every contract the four beats touch — root,
`.eth` registry, registrar, registry, resolver — is the real deployment.

## What is proved in tests rather than on camera

The sub-agent fleet (T5). An orchestrator's workers are attenuated in roles, text keys and
lease, and one `unregister()` at the tier above takes the whole fleet offline — asserted from
the outside with this same verifier in `test/SubAgentHierarchy.t.sol` and
`test/SubtreeRevocation.t.sol`. The recorded demo is the single-agent path, which is the one
IDEA.md §4 describes; mention the fleet, point at the tests.
