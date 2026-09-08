# Status

**Last updated:** 2026-09-08
**Phase:** Scaffold + protocol verification

## Completed

- **Repo scaffold.** Foundry project with `ensdomains/contracts-v2` wired in as a git
  submodule and compiling. Remappings resolved (see README for the order-sensitivity trap).
- **Finding 001 — force-expiry confirmed.** The operator kill switch works on a *live*
  subname via `unregister()`. Verified against the real `PermissionedRegistry`, not a mock.
  13 tests passing. Write-up: `docs/findings/001-force-expiry.md`.
- **IDEA.md corrected** against verified behaviour: `ROLE_UNREGISTER` named as the withheld
  role that matters, §3.4 rewritten around the real mechanism, §6 open question 1 closed.

## In progress

Nothing. Clean stopping point.

## Pending

Next task is `T1` in TODO.md — the sandbox registrar. Everything after that is unstarted;
no contract in `src/` yet.

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

## Known gaps

- Nothing deployed to Sepolia yet; blocked on RPC + key (see `myTasks.md`).
- The counterparty verifier (IDEA.md §3.5) is unstarted and is what makes the kill
  switch demonstrable. Do not leave it to the last day.
