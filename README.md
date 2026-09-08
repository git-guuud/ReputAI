# Agent-Bound Identity Sandbox

An ENSv2 identity an autonomous agent can **operate** but cannot **own**.

Built for the ETHOnline 2026 ENSv2 track. See [IDEA.md](./IDEA.md) for the concept
document and [docs/findings/](./docs/findings/) for verified protocol behaviour.

## The idea in one paragraph

Give an agent a wallet and a name and you get a rogue asset: a compromised agent keeps
its identity forever. Keep the name yourself and co-sign every update and the agent isn't
autonomous. ENSv2's Enhanced Access Control makes a third option possible — a subname the
agent can update within a narrow, record-scoped allowlist, while the operator retains an
immediate kill switch. The agent can move around inside the box; it cannot move the box.

## Status

| Component | State |
|---|---|
| ENSv2 dependency wired, compiling | done |
| Force-expiry / kill switch verified | done — [finding 001](./docs/findings/001-force-expiry.md) |
| Subtree revocation verified | done — [finding 001](./docs/findings/001-force-expiry.md) |
| Sandbox registrar contract | done — `src/AgentSandbox.sol` (T1) |
| Permissioned resolver + text-key allowlist | done — `provision()`'s per-key allowlist (T2) |
| Operating-key rotation | done — agent rotates unilaterally, `addr()` untouched (T3) |
| Counterparty verifier | done — `src/CounterpartyVerifier.sol`, [finding 002](./docs/findings/002-inherited-resolver-survives-revocation.md) (T4) |
| Sub-agent hierarchy | done — `src/SubAgentRegistrar.sol`, [finding 003](./docs/findings/003-registration-bypasses-admin-check.md) (T5) |
| Sepolia deployment | **live** — `reputai-sandbox.eth` registered through the canonical `ETHRegistrar`, contracts verified (T6) |

101 tests, all passing, against real `ensdomains/contracts-v2` contracts. No mocks.

## Layout

```
src/
  AgentSandbox.sol         one-call provisioning: role ceiling + per-key text allowlist
  CounterpartyVerifier.sol resolves, verifies a signature, refuses to transact
  SubAgentRegistrar.sol    attenuated worker spawning beneath an orchestrator
test/
  ForceExpiry.t.sol        operator kill switch on a live name
  SubtreeRevocation.t.sol  orchestrator revocation severs the worker subtree
  AgentSandbox.t.sol       the registry tier: what an agent may not do
  AgentRecords.t.sol       the resolver tier: the text-key allowlist
  AgentKeyRotation.t.sol   unilateral key rotation and its blast radius
  CounterpartyVerifier.t.sol  the outside view, incl. revoke-mid-flow
  SubAgentHierarchy.t.sol  attenuation across tiers; one revocation kills a fleet
script/                    deployment
docs/findings/             verified protocol behaviour, with evidence
lib/contracts-v2/          ensdomains/contracts-v2 (ENSv2 sources)
```

## Setup

Requires [Foundry](https://getfoundry.sh). The ENSv2 sources come in as a git submodule
with its own nested submodules, so clone recursively:

```bash
git clone --recurse-submodules <this repo>
cd ReputAI
forge test
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

### A note on remappings

`remappings.txt` is order-sensitive. Foundry applies the **first** matching prefix, not the
longest, so the broad `@ens/contracts/=` mapping must appear *before* the narrower
`@ens/contracts/utils/LibMem/=` override — reversing them breaks resolution with a
confusing "file not found" against the project root. The context-scoped
`lib/contracts-v2/contracts/:` entries exist because the dependency ships its own
`remappings.txt` with paths relative to its own root.

## Tests

```bash
forge test                      # all
forge test --match-path test/ForceExpiry.t.sol -vv
```

101 tests, all passing. They run against the real `PermissionedRegistry` from
`ensdomains/contracts-v2`, not mocks.

`test/SepoliaDeployment.t.sol` additionally forks live Sepolia and runs the deploy scripts
themselves. It needs `SEPOLIA_RPC_URL` and skips itself without one.

## Sepolia deployment

The scripts deploy *beneath* the canonical ENSv2 deployment — they replace none of it. Every
address in `script/SepoliaConfig.sol` comes from the submodule's own generated table
(`lib/contracts-v2/contracts/docs/addresses/sepolia.md`) and was confirmed to hold code
on-chain.

Registration is commit-reveal with a 60-second `MIN_COMMITMENT_AGE`, which is why this is two
scripts rather than one: the commitment binds the subregistry and resolver addresses, so both
proxies are deployed in phase 1, before committing.

```bash
cp .env.example .env          # fill in SEPOLIA_RPC_URL and PRIVATE_KEY
export AGENT_PARENT_LABEL=reputai-sandbox

forge script script/01_Commit.s.sol:Commit \
  --rpc-url $SEPOLIA_RPC_URL --broadcast
sleep 60                      # MIN_COMMITMENT_AGE
forge script script/02_Register.s.sol:Register \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

Addresses land in `deployments/sepolia.json`. Phase 2 re-derives phase 1's commitment and
checks the registrar still holds it before spending gas, and asserts the sandbox's containment
properties against the live deployment before it exits — a wiring mistake fails the script
rather than producing a quietly broken sandbox.

Rent is paid in upstream's **MockUSDC** — the registrar accepts ERC-20 only, and that token's
`mint()` is unpermissioned on testnet. That is the single mocked component in the deployment,
and it is upstream's mock, not ours. The registration it pays for is the real registrar writing
to the real `.eth` registry.

### Deployed addresses (Sepolia, chain 11155111)

`reputai-sandbox.eth` was registered live through the canonical `ETHRegistrar` — nothing was
pre-seeded, and the label was unregistered until the run.

| Contract | Address |
|---|---|
| `reputai-sandbox.eth` operator registry (`UserRegistry` proxy) | [`0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b`](https://sepolia.etherscan.io/address/0xfeA7D49F56fFBb1ba46ee879ecdE2933FEb8E14b) |
| `PermissionedResolver` (proxy) | [`0xDdb4717972E663b126f3E2D64df478Eca40f69F5`](https://sepolia.etherscan.io/address/0xDdb4717972E663b126f3E2D64df478Eca40f69F5) |
| `AgentSandbox` (verified) | [`0x657Dc79a217eBB8aC22C5B6E9237040cd75Eabf0`](https://sepolia.etherscan.io/address/0x657Dc79a217eBB8aC22C5B6E9237040cd75Eabf0) |
| `CounterpartyVerifier` (verified) | [`0x62BFB71dc67a2ddc4c0B3BE25fa133772b4BB05e`](https://sepolia.etherscan.io/address/0x62BFB71dc67a2ddc4c0B3BE25fa133772b4BB05e) |
| Operator (deployer) | [`0x7aD721F362A8049Dd139764B0745657D06d9AA93`](https://sepolia.etherscan.io/address/0x7aD721F362A8049Dd139764B0745657D06d9AA93) |

Routing is verifiable from the real ENS root without trusting anything above:

```bash
cast call 0x11b5BfbE9078D826b1eDBDd1cFC12f5828D9F50C \
  "getSubregistry(string)(address)" "eth" --rpc-url $SEPOLIA_RPC_URL
# -> 0x67b7...4b43   the canonical .eth registry
cast call 0x67b728a792e789a8978b30cF1b3b641f19354b43 \
  "getSubregistry(string)(address)" "reputai-sandbox" --rpc-url $SEPOLIA_RPC_URL
# -> 0xfeA7...E14b   our operator registry
```
