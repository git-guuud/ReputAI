// One function that reads the entire demo's state from chain, in one multicall.
//
// Nothing here is cached or inferred: every field the control room shows is a value the chain
// answered for at the block stamped on the frame. That is what makes the pane evidence rather
// than narration.

import {
  publicClient, abis, dnsEncode, node as toNode, textResource,
  RESOLVER_ROLE_SET_TEXT, REFUSAL, namedRoles,
} from "./chain.mjs";
import { stringToHex } from "viem";
import {
  ENS, ACTORS, deployment, label, parentName, agentName,
  endpointKey, operatingKey, message, signingKeys, treasury,
} from "./config.mjs";

/// The verifier takes the message as `bytes`, so it travels hex-encoded. The signature is over
/// the same bytes under EIP-191, which is what `signMessage` produces from the plain string.
export const messageHex = stringToHex(message);

const parentLabel = parentName.replace(/\.eth$/, "");
export const agentNode = toNode(agentName);
export const agentNameEncoded = dnsEncode(agentName);

/// EIP-191 personal-sign, the format `CounterpartyVerifier` recovers against. Signing is
/// off-chain and free: an operating key is a credential, never an on-chain authority.
export async function sign(which) {
  return signingKeys[which].signMessage({ message });
}

const ok = (r) => (r.status === "success" ? r.result : null);

export async function readState() {
  const sig = { genesis: await sign("genesis"), rotated: await sign("rotated") };

  const registry = { address: deployment.operatorRegistry, abi: abis.registry };
  const resolver = { address: deployment.resolver, abi: abis.resolver };
  const verifier = { address: deployment.verifier, abi: abis.verifier };
  const agent = ACTORS.agent.address;

  const calls = [
    // The tree walk, from the root the verifier is handed and nothing else.
    { address: ENS.root, abi: abis.registry, functionName: "getSubregistry", args: ["eth"] },
    { address: ENS.ethRegistry, abi: abis.registry, functionName: "getSubregistry", args: [parentLabel] },
    { ...registry, functionName: "getResolver", args: [label] },
    { ...registry, functionName: "findTokenId", args: [label] },
    // The records.
    { ...resolver, functionName: "text", args: [agentNode, endpointKey] },
    { ...resolver, functionName: "text", args: [agentNode, operatingKey] },
    { ...resolver, functionName: "addr", args: [agentNode] },
    // The agent's actual write surface, read as grants rather than asserted.
    { ...resolver, functionName: "roles", args: [textResource(agentName, endpointKey), agent] },
    { ...resolver, functionName: "roles", args: [textResource(agentName, operatingKey), agent] },
    // The verifier's own verdict, on each of the two operating keys.
    { ...verifier, functionName: "checkAgent", args: [agentNameEncoded, messageHex, sig.genesis] },
    { ...verifier, functionName: "checkAgent", args: [agentNameEncoded, messageHex, sig.rotated] },
  ];

  const [block, results, treasuryBal, opBal, agentBal, cpBal] = await Promise.all([
    publicClient.getBlockNumber(),
    publicClient.multicall({ contracts: calls, allowFailure: true }),
    publicClient.getBalance({ address: treasury }),
    publicClient.getBalance({ address: ACTORS.operator.address }),
    publicClient.getBalance({ address: ACTORS.agent.address }),
    publicClient.getBalance({ address: ACTORS.counterparty.address }),
  ]);

  const [ethReg, opReg, agentResolver, tokenId, ep, opKey, payTo, epRoles, keyRoles, chkG, chkR] =
    results.map(ok);

  // Registry roles and owner need the tokenId, which only exists once beat 1 has run.
  let owner = null, expiry = null, registryRoles = null;
  if (tokenId != null) {
    const more = await publicClient.multicall({
      contracts: [
        { ...registry, functionName: "getOwner", args: [tokenId] },
        { ...registry, functionName: "getExpiry", args: [tokenId] },
        { ...registry, functionName: "roles", args: [tokenId, agent] },
      ],
      allowFailure: true,
    });
    [owner, expiry, registryRoles] = more.map(ok);
  }

  const verdict = (r) =>
    r == null
      ? { reason: "unreadable", refused: true, id: null, recovered: null }
      : {
          reason: REFUSAL[Number(r[0])],
          refused: Number(r[0]) !== 0,
          id: r[1],
          recovered: r[2],
        };

  return {
    block,
    provisioned: agentResolver != null && agentResolver !== "0x0000000000000000000000000000000000000000",
    tree: { root: ENS.root, eth: ethReg, operator: opReg, resolver: agentResolver },
    exactResolver: agentResolver === deployment.resolver,
    tokenId,
    owner,
    expiry: expiry == null ? null : Number(expiry),
    registryRoles: registryRoles ?? 0n,
    registryRoleNames: namedRoles(registryRoles ?? 0n),
    records: { endpoint: ep ?? "", operatingKey: opKey ?? "", payTo },
    grants: {
      endpoint: ((epRoles ?? 0n) & RESOLVER_ROLE_SET_TEXT) === RESOLVER_ROLE_SET_TEXT,
      operatingKey: ((keyRoles ?? 0n) & RESOLVER_ROLE_SET_TEXT) === RESOLVER_ROLE_SET_TEXT,
    },
    verdicts: { genesis: verdict(chkG), rotated: verdict(chkR) },
    keys: { genesis: signingKeys.genesis.address, rotated: signingKeys.rotated.address },
    balances: {
      treasury: treasuryBal,
      operator: opBal,
      agent: agentBal,
      counterparty: cpBal,
    },
  };
}
