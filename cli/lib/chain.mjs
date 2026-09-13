// Clients and ABIs. ABIs are loaded from Foundry's own build output rather than hand-copied
// fragments, so the CLI cannot drift from the contracts it is driving.

import { createPublicClient, createWalletClient, http } from "viem";
import { keccak256, toBytes, encodeAbiParameters, namehash } from "viem";
import { packetToBytes } from "viem/ens";
import { ENS, rpcUrl, ROOT, json } from "./config.mjs";
import { join } from "node:path";

const artifact = (name, file = name) =>
  json(join(ROOT, "out", `${file}.sol`, `${name}.json`)).abi;

export const abis = {
  sandbox: artifact("AgentSandbox"),
  verifier: artifact("CounterpartyVerifier"),
  registry: artifact("PermissionedRegistry"),
  resolver: artifact("PermissionedResolver"),
};

/// Every custom error the demo can hit, in one list, so a revert decodes to a name and its
/// arguments instead of a selector.
export const allErrors = Object.values(abis).flat().filter((f) => f.type === "error");

export const publicClient = createPublicClient({
  chain: ENS.chain,
  transport: http(rpcUrl),
});

export function walletFor(actor) {
  return createWalletClient({
    account: actor.account,
    chain: ENS.chain,
    transport: http(rpcUrl),
  });
}

/// DNS wire format — what `CounterpartyVerifier` and the resolver's authorize* helpers take.
export function dnsEncode(name) {
  return `0x${Buffer.from(packetToBytes(name)).toString("hex")}`;
}

export const node = (name) => namehash(name);

/// `PermissionedResolverLib.resource(node, partHash(key))` — where a per-key `ROLE_SET_TEXT`
/// grant actually lands. Recomputed here so the control room can show the grant, not assert it.
export function textResource(name, key) {
  return BigInt(
    keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "bytes32" }],
        [namehash(name), keccak256(toBytes(key))],
      ),
    ),
  );
}

/// Registry role bits, mirroring `RegistryRolesLib`. Used to name what the agent holds and,
/// more to the point, what it does not.
export const REGISTRY_ROLES = {
  ROLE_REGISTRAR: 1n << 0n,
  ROLE_REGISTER_RESERVED: 1n << 4n,
  ROLE_SET_PARENT: 1n << 8n,
  ROLE_UNREGISTER: 1n << 12n,
  ROLE_RENEW: 1n << 16n,
  ROLE_SET_SUBREGISTRY: 1n << 20n,
  ROLE_SET_RESOLVER: 1n << 24n,
  ROLE_CAN_TRANSFER_ADMIN: (1n << 28n) << 128n,
  ROLE_SET_URI: 1n << 36n,
};

/// Resolver role bits, mirroring `PermissionedResolverLib`. Kept apart from the registry's
/// table on purpose: the two contracts reuse the same bit positions for different permissions —
/// `1 << 0` is `ROLE_REGISTRAR` at the registry and `ROLE_SET_ADDR` at the resolver — so a
/// revert can only be named correctly if the namespace is named with it.
export const RESOLVER_ROLES = {
  ROLE_SET_ADDR: 1n << 0n,
  ROLE_SET_TEXT: 1n << 4n,
  ROLE_SET_CONTENTHASH: 1n << 8n,
  ROLE_SET_PUBKEY: 1n << 12n,
  ROLE_SET_ABI: 1n << 16n,
  ROLE_SET_INTERFACE: 1n << 20n,
  ROLE_SET_NAME: 1n << 24n,
  ROLE_SET_ALIAS: 1n << 28n,
  ROLE_CLEAR: 1n << 32n,
  ROLE_SET_DATA: 1n << 36n,
};

export const RESOLVER_ROLE_SET_TEXT = RESOLVER_ROLES.ROLE_SET_TEXT;

export function namedRoles(bitmap, space = "registry") {
  const table = space === "resolver" ? RESOLVER_ROLES : REGISTRY_ROLES;
  const held = [];
  for (const [name, bit] of Object.entries(table)) {
    if ((bitmap & bit) === bit) held.push(name);
  }
  return held;
}

/// The verifier's `Refusal` enum, in order. Index is the on-chain value.
export const REFUSAL = [
  "None",
  "Unresolvable",
  "NoEndpoint",
  "NoOperatingKey",
  "MalformedOperatingKey",
  "MalformedSignature",
  "KeyMismatch",
  "NoPayoutAddress",
];
