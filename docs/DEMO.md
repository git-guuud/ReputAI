# Recording runbook — the control room

Four panes, three keys, one deployed name on Sepolia. The control room reads the chain and signs
nothing; each pane beside it holds exactly one party's key. **Which pane a transaction comes from
is the argument of this project**, so the layout is the demo rather than decoration for it.

```
▛▀▀ CONTROL ROOM ▀▀▀▀▀▀▀▀▀▀▀▀▀▜▛▀▀ OPERATOR · provision · freeze · revoke ▀▀▜
▌                             ▐▌  latest action only                       ▐
▌  the walk from the ENS root ▐▙▄▄ AGENT · publish · rotate · escape ▄▄▄▄▄▄▄▟
▌  records, and who may write ▐▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜
▌  the agent's role bitmap    ▐▌  latest action only                       ▐
▌  the verifier's verdict on  ▐▙▄▄ COUNTERPARTY · check · pay ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟
▌    each of two keys         ▐▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜
▌  every transaction, in the  ▐▌  latest action only                       ▐
▌  colour of the key that     ▐▌                                           ▐
▌  signed it                  ▐▌                                           ▐
▙▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟▙▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟
```

Each pane's top border is a solid bar in that party's colour, carrying its name and the verbs it
may type — so the verbs are always on screen and you never need to look one up mid-take.

**The shells show only their latest action.** Each clears itself on every command. The running
history of every transaction lives in the control room's feed, in the colour of the key that
signed it, so the same evidence is never in two places and no pane fills with scrollback.

Nothing in the control room is held in memory between frames: every value on it is what the
chain answered at the block stamped in its header. When the operator revokes in one pane, the
verdict in another goes red on its own, with nobody typing.

---

## Before you start recording

```bash
cd cli && npm install && cd ..     # once
export DEMO_AGENT_LABEL=agent-407  # any label not yet minted — see below
./demo.sh --fresh                  # clears the transaction feed, then opens the four panes
```

> **Pick an unminted label.** `agent-404` was minted on live Sepolia during a test run, so beat 1
> can no longer mint it on camera. Any unused label under `reputai-sandbox.eth` works, and one
> variable is enough: the endpoint and the signed message both default off the label, and `.env`
> values naming a *different* label are ignored rather than quietly printed. Check a candidate
> before you record:
>
> ```bash
> cast call 0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b \
>   "getResolver(string)(address)" "agent-407" --rpc-url sepolia   # want 0x0…0
> ```

Terminal wants to be **at least 180 columns** — the control room needs 84 and stretches to fill
whatever it is given, and it says so if it has fewer. `./demo.sh` alone re-attaches to a running
session; `./demo.sh --kill` tears it down.

Nothing above spends gas. Three checks worth doing on camera before beat 1:

```bash
node cli/reput.mjs counterparty status
```

- the tree resolves `root → eth → reputai-sandbox`, all three canonical addresses;
- the agent's name **does not exist** — the control room says so in as many words, which is what
  makes "nothing is pre-seeded" checkable rather than claimed;
- both verifier lights are red, `Unresolvable`.

Balances: operator ~0.032 ETH, agent and counterparty ~0.005 each. The whole run costs about
0.003 ETH at 1 gwei.

Etherscan tabs worth having open:

| What | Address |
|---|---|
| Operator registry | `0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b` |
| `PermissionedResolver` | `0xDdb4717972E663b126f3E2D64df478Eca40f69F5` |
| `AgentSandbox` (verified) | `0x657Dc79a217eBB8aC22C5B6E9237040cd75Eabf0` |
| `CounterpartyVerifier` (verified) | `0x62BFB71dc67a2ddc4c0B3BE25fa133772b4BB05e` |

Every action prints its own Etherscan link, so the tabs are corroboration rather than navigation.

---

## Beat 1 — provision · **operator pane**

```
provision
```

Two transactions from the operator's key. `AgentSandbox.provision()` mints the name, grants the
agent its role bitmap — **zero registry roles**, the tightest the ceiling allows — wires the
resolver and authorizes exactly two text keys. Then the operator publishes `addr()`, because
`provision()` grants `ROLE_SET_ADDR` to nobody.

Watch the control room: the fourth line of the tree fills in, `addr()` appears against
`operator`, and `THE BOX` reads `registry roles 0x0 — none at all`.

Say: the agent is being handed an identity it can operate and cannot own.

## Beat 2a — the agent publishes · **agent pane**

```
publish
```

Two transactions from the **agent's own key** — its endpoint and the key it will sign with. No
operator transaction in between, now or later in beat 2. The control room's `writable by` column
now says `agent` against both text keys, and `operator` against `addr()`, and its first verdict
light turns green on its own.

## Beat 2b — the counterparty pays · **counterparty pane**

```
pay
```

It prints the verifier's verdict *before* it spends — the key the name publishes, the key it
signed with, the address the money would reach, and `would transact`. Then it pays.

Say: this counterparty was handed the ENS root address and nothing else. It walks the tree
itself, and it pays the resolved `addr()` — never an address the agent named in its message.

## Beat 2c — the agent rotates its own key · **agent pane**

```
rotate
```

One transaction, one party, no operator, no downtime. It asserts `addr()` is unchanged before it
returns. **Watch the control room while you say this**: the two verifier lights swap, and the
`← the name publishes this one` marker moves, without anyone touching the counterparty.

## Beat 2d — the counterparty follows · **counterparty pane**

```
pay
pay retired
```

The first re-resolves and pays on the new key, having been told nothing — `pay` always signs
with whatever key the name currently publishes, which is why it follows a rotation without being
told. The second forces the **retired** key and is refused `KeyMismatch` — a rotation, not a
fork. The refusal is sent anyway, so it is a transaction you can click.

## Beat 3 — attempted escape · **agent pane**

```
escape
```

Three transactions from the agent's own key, all reverting on-chain, each printed with its
decoded reason before it is sent:

| Attempt | Revert |
|---|---|
| transfer the name | `TransferDisallowed` — soulbound: transfer is gated on `ROLE_CAN_TRANSFER_ADMIN` held by the *sender* |
| repoint the resolver | `EACUnauthorized · ROLE_SET_RESOLVER` |
| rewrite addr() | `EACUnauthorized · ROLE_SET_ADDR` |

Three lines, one per attempt, each with the role that was missing and a clickable hash. The
line under them is worth reading out: the check happened at the **name-wide resource**, never at
one of the agent's two authorized text keys — text grants confer nothing on `addr()`.

Say: this is a fully compromised agent — whoever holds its key holds everything it has — and the
blast radius is exactly "can speak, nothing else". The control room has not moved.

## Beat 4 — revoke · **operator pane**, then **counterparty pane**

```
revoke                # operator
pay                   # counterparty
```

`revoke` prints the verdict either side of one `unregister()`: `would transact` before,
`Unresolvable` after, on the same name, same key, same signature. Then the control room goes red
on its own.

The counterparty then sends the payment anyway, so the refusal is on-chain and clickable:
`Refused(Unresolvable, agent-404.reputai-sandbox.eth)`.

Say the honest version: the agent's records are **still in the resolver** — `revoke` prints the
operating key still sitting there — and the agent never learns it was killed. What the operator removed is the path. Containment
here is unreachability, not deletion, and the verifier's exact-resolution rule
([finding 002](./findings/002-inherited-resolver-survives-revocation.md)) is what makes that
enough.

---

## Optional beat — the graduated lever

Worth 20 seconds if the pacing allows, because it answers "so the only response is the kill
switch?" before a judge asks it. In the **operator pane**:

```
freeze
```

Revokes `ROLE_SET_TEXT` on the operating key *only*. The agent then types `rotate` and is refused
`EACUnauthorizedAccountRoles` — the key is pinned to its last honest value, while the name is
still live and the endpoint is still the agent's to write. `unfreeze` restores it. This is
IDEA.md §3.3's middle option, between doing nothing and `unregister()`.

---

## If a beat goes wrong mid-recording

Every beat is idempotent except beat 1, and the fix is a fresh label:

```bash
export DEMO_AGENT_LABEL=agent-408     # any unused label under reputai-sandbox.eth
./demo.sh --kill && ./demo.sh --fresh
```

`provision` refuses to run against a label that already has a resolver, so it cannot
half-overwrite a previous take. `status`, in any pane, is a free read-only snapshot.

## Rehearsing without spending anything

The whole run works against a Sepolia fork, which is how it was tested:

```bash
anvil --fork-url "$SEPOLIA_RPC_URL" --port 8546 &
export SEPOLIA_RPC_URL=http://127.0.0.1:8546
export DEMO_FILE=/tmp/demo-fork.json DEMO_FEED=/tmp/feed-fork.jsonl
for a in $DEPLOYER_ADDRESS $DEMO_AGENT_ADDRESS $DEMO_COUNTERPARTY_ADDRESS; do
  cast rpc anvil_setBalance "$a" 0xDE0B6B3A7640000 --rpc-url $SEPOLIA_RPC_URL
done
./demo.sh --fresh
```

Same contracts, same calls, same output — the fork is the real deployment.

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

## The same beats without the control room

`docs/DEMO-scripts.md` drives the identical transactions through `forge script` and `cast`, one
command per beat. Those scripts are what `test/SepoliaDeployment.t.sol` exercises on a fork in
CI. The control room is a second front end onto the same deployed contracts — it sends the same
calls from the same three keys — and it is the one to record, because a wall of `forge` output
cannot show a permission boundary holding.
