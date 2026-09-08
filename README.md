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
| Sandbox registrar contract | not started |
| Permissioned resolver + text-key allowlist | not started |
| Counterparty verifier | not started |
| Sepolia deployment | not started |

## Layout

```
src/                       sandbox contracts (registrar, resolver config)
test/
  ForceExpiry.t.sol        operator kill switch on a live name
  SubtreeRevocation.t.sol  orchestrator revocation severs the worker subtree
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

13 tests, all passing. They run against the real `PermissionedRegistry` from
`ensdomains/contracts-v2`, not mocks.
