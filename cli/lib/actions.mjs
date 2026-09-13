// The beats, as verbs. IDEA.md §4's four beats, one function each, each belonging to exactly
// one actor — the assignment is the argument, so it is data here rather than a convention.

import { writeFileSync } from "node:fs";
import { getAddress, stringToHex, zeroAddress } from "viem";
import { publicClient, abis, dnsEncode, REFUSAL } from "./chain.mjs";
import { send, sendExpectingRevert } from "./tx.mjs";
import { readState, agentNode, agentNameEncoded, messageHex, sign } from "./state.mjs";
import { C, bold, kv, addr, eth, pad } from "./ui.mjs";
import {
  ACTORS, deployment, demoFile, demo, label, agentName, endpointKey, operatingKey,
  endpoint, message, payment, treasury, signingKeys,
} from "./config.mjs";

const say = (s = "") => process.stdout.write(`${s}\n`);
const ATTACKER = "0x000000000000000000000000000000000000baDd"; // the same 0xbadd the shell scripts use

const registry = { address: deployment.operatorRegistry, abi: abis.registry };
const resolver = { address: deployment.resolver, abi: abis.resolver };
const verifier = { address: deployment.verifier, abi: abis.verifier };
const sandbox = { address: deployment.sandbox, abi: abis.sandbox };

/// Which key the agent is signing with right now — read from the name, never assumed. This is
/// what lets the counterparty follow a rotation without being told: it re-resolves every time.
/// `retired` forces the other one, which is beat 2d's second half.
async function whichKey(arg) {
  const published = await publicClient
    .readContract({ ...resolver, functionName: "text", args: [agentNode, operatingKey] })
    .catch(() => "");
  const current =
    published.toLowerCase() === signingKeys.rotated.address.toLowerCase() ? "rotated" : "genesis";
  const other = current === "rotated" ? "genesis" : "rotated";
  return arg === "retired" || arg === "old" ? other : current;
}

/// Beats 2b, 2d and 4 all turn on the same question, asked of the chain before any money moves:
/// would the verifier transact? Printed before every payment so the recording shows the answer
/// first and the consequence second.
async function verdict(which = "rotated", { prefix = null, note = "" } = {}) {
  const sig = await sign(which);
  const [reason, id] = await publicClient.readContract({
    ...verifier,
    functionName: "checkAgent",
    args: [agentNameEncoded, messageHex, sig],
  });
  const name = REFUSAL[Number(reason)];
  const good = Number(reason) === 0;
  const signer = signingKeys[which].address;

  // Name the key by its role rather than by an index: whether it is the one the name currently
  // publishes is the fact beat 2d turns on. Once the name resolves to nothing there is no such
  // distinction to draw — calling the key "retired" there would blame the key for a revocation.
  const unresolvable = id.operatingKey === "0x0000000000000000000000000000000000000000";
  const role =
    prefix ??
    (unresolvable ? "key" : id.operatingKey.toLowerCase() === signer.toLowerCase() ? "current" : "retired");

  say(
    ` ${C.dim(pad(role, 8))}${pad(good ? C.ok(bold("would transact")) : C.bad(bold(`REFUSED · ${name}`)), 28)}` +
      C.dim(note),
  );
  // One supporting line, and only the fields that decide it. `signed by` is read from the key
  // that actually signed, not from the verifier's `recovered` — after revocation the verifier
  // stops before it recovers anything, and printing a zero there would read as a broken
  // signature rather than a name that no longer resolves.
  const published =
    id.operatingKey === "0x0000000000000000000000000000000000000000"
      ? C.bad("nothing")
      : addr(id.operatingKey);
  say(
    `   ${C.dim("name publishes")} ${pad(published, 14)}` +
      `${C.dim("signed by")} ${addr(signer)}  ` +
      `${C.dim("pays")} ${addr(id.payTo)}`,
  );
  return { good, name, sig, id };
}

async function tokenId() {
  const d = demo();
  if (d?.tokenId && d.label === label) return BigInt(d.tokenId);
  return publicClient.readContract({ ...registry, functionName: "findTokenId", args: [label] });
}

function writeDemoRecord(id, expiry, blockNumber) {
  const out = {
    agent: ACTORS.agent.address,
    agentName,
    agentNameEncoded,
    agentNode,
    counterparty: ACTORS.counterparty.address,
    expiry: Number(expiry),
    keyGenesis: signingKeys.genesis.address,
    keyRotated: signingKeys.rotated.address,
    label,
    provisionBlock: Number(blockNumber),
    tokenId: id.toString(),
    treasury,
  };
  writeFileSync(demoFile, `${JSON.stringify(out, null, 2)}\n`);
}

export const actions = {
  // ── operator ───────────────────────────────────────────────────────────────
  async provision(actor) {
    const s = await readState();
    if (s.provisioned) throw new Error(`${agentName} already exists — pick another DEMO_AGENT_LABEL`);

    const now = BigInt((await publicClient.getBlock()).timestamp);
    const expiry = now + BigInt(Number(process.env.DEMO_AGENT_DURATION ?? 180 * 86400));

    const { result: id, receipt } = await send(
      actor,
      "provision",
      {
        ...sandbox,
        functionName: "provision",
        args: [
          label,
          ACTORS.agent.address,
          deployment.resolver,
          zeroAddress,          // no child registry: this agent spawns no workers
          0n,                   // zero registry roles — the tightest sandbox the ceiling allows
          [endpointKey, operatingKey],
          expiry,
        ],
      },
      { note: `${label} → ${addr(ACTORS.agent.address)} · 0 registry roles · 2 text keys` },
    );

    // The payout address, written by the operator because `provision()` grants ROLE_SET_ADDR to
    // nobody. This is the line the agent spends the rest of the demo failing to cross.
    await send(
      actor,
      "setAddr",
      { ...resolver, functionName: "setAddr", args: [agentNode, treasury] },
      { note: `addr() → ${addr(treasury)} · the agent was granted no ROLE_SET_ADDR` },
    );

    writeDemoRecord(id, expiry, receipt.blockNumber);
  },

  async revoke(actor) {
    // Ask with whatever key the name publishes right now, not a fixed one: beat 4's contrast is
    // "would transact" → "Unresolvable", and hard-coding the rotated key turns the "before" into
    // a KeyMismatch whenever this is run without beat 2c.
    const key = await whichKey();
    await verdict(key, { prefix: "before" });
    await send(
      actor,
      "unregister",
      { ...registry, functionName: "unregister", args: [await tokenId()] },
      { note: "the kill switch — ROLE_UNREGISTER at the registry root" },
    );
    await verdict(key, { prefix: "after", note: "same name, same key, same signature" });
    // Containment here is unreachability, not deletion — better said out loud than found.
    const still = await publicClient.readContract({
      ...resolver,
      functionName: "text",
      args: [agentNode, operatingKey],
    });
    say(
      ` ${C.dim("the records survive —")} ${operatingKey} ${C.dim("is still")} ${addr(still)} ` +
        C.dim("in the resolver."),
    );
    say(` ${C.dim("the agent never learns. What the operator removed is the path, not the data.")}`);
  },

  /// The graduated lever from IDEA.md §3.3: freeze rotation without killing the name. The agent
  /// keeps publishing its endpoint; its key is pinned to the last honest value.
  async freeze(actor) {
    await send(
      actor,
      "freeze-key",
      {
        ...resolver,
        functionName: "authorizeTextRoles",
        args: [agentNameEncoded, operatingKey, ACTORS.agent.address, false],
      },
      { note: `revoke ROLE_SET_TEXT on ${operatingKey} only` },
    );
    say(` ${C.dim("rotation frozen. Endpoint still the agent's to write; the name is still live.")}`);
  },

  async unfreeze(actor) {
    await send(
      actor,
      "unfreeze-key",
      {
        ...resolver,
        functionName: "authorizeTextRoles",
        args: [agentNameEncoded, operatingKey, ACTORS.agent.address, true],
      },
      { note: `restore ROLE_SET_TEXT on ${operatingKey}` },
    );
  },

  // ── agent ──────────────────────────────────────────────────────────────────
  async publish(actor) {
    await send(
      actor,
      "setText",
      { ...resolver, functionName: "setText", args: [agentNode, endpointKey, endpoint] },
      { note: `${endpointKey} = ${endpoint}` },
    );
    await send(
      actor,
      "setText",
      {
        ...resolver,
        functionName: "setText",
        args: [agentNode, operatingKey, signingKeys.genesis.address.toLowerCase()],
      },
      { note: `${operatingKey} = ${addr(signingKeys.genesis.address)}` },
    );
  },

  async rotate(actor) {
    const before = await publicClient.readContract({ ...resolver, functionName: "addr", args: [agentNode] });
    await send(
      actor,
      "rotate-key",
      {
        ...resolver,
        functionName: "setText",
        args: [agentNode, operatingKey, signingKeys.rotated.address.toLowerCase()],
      },
      { note: `new key ${addr(signingKeys.rotated.address)}, no operator in the loop` },
    );
    const after = await publicClient.readContract({ ...resolver, functionName: "addr", args: [agentNode] });
    if (before !== after) throw new Error("rotation moved the payout address — stop the demo");
    say(`   ${C.ok("✓")} ${C.dim("payTo unchanged")} ${addr(after)} ${C.dim("— the credential moved, the money did not")}`);
  },

  /// Beat 3. A fully compromised agent — whoever holds this key holds everything the agent has.
  async escape(actor) {
    const id = await tokenId();
    const opts = { detail: false };
    await sendExpectingRevert(
      actor,
      "escape:transfer",
      { ...registry, functionName: "safeTransferFrom", args: [ACTORS.agent.address, ATTACKER, id, 1n, "0x"] },
      { ...opts, label: "transfer the name" },
    );
    await sendExpectingRevert(
      actor,
      "escape:resolver",
      { ...registry, functionName: "setResolver", args: [id, ATTACKER] },
      { ...opts, label: "repoint the resolver" },
    );
    const last = await sendExpectingRevert(
      actor,
      "escape:addr",
      { ...resolver, functionName: "setAddr", args: [agentNode, ATTACKER] },
      { ...opts, label: "rewrite addr()", space: "resolver" },
    );
    say();
    // The `resource` field is the whole point of the third one: it names *where* the check
    // happened, and it is the name-wide resource — never one of the agent's two text keys.
    if (last?.reason) {
      say(` ${C.dim("checked at the name-wide resource, never one of the agent's two text keys")}`);
    }
    const s = await readState();
    say(
      ` ${C.ok("unchanged:")} ${C.dim("owner")} ${addr(s.owner)}  ` +
        `${C.dim("resolver")} ${addr(s.tree.resolver)}  ${C.dim("addr()")} ${addr(s.records.payTo)}`,
    );
  },

  // ── counterparty ───────────────────────────────────────────────────────────
  async check(_actor, args = []) {
    await verdict(await whichKey(args[0]));
  },

  async pay(actor, args = []) {
    const which = await whichKey(args[0]);
    const before = await publicClient.getBalance({ address: treasury });
    const v = await verdict(which);
    say();

    // The refusal is sent anyway, so it is a transaction a viewer can click rather than a
    // claim the terminal makes about itself.
    if (!v.good) {
      await sendExpectingRevert(
        actor,
        "payAgent",
        { ...verifier, functionName: "payAgent", args: [agentNameEncoded, messageHex, v.sig] },
        { gas: 250000n, value: payment, label: "pay anyway", detail: false },
      );
      const after = await publicClient.getBalance({ address: treasury });
      say(` ${C.dim("treasury")} ${eth(after)} ${after === before ? C.ok("unchanged") : C.bad("MOVED")}`);
      return;
    }
    await send(
      actor,
      "payAgent",
      { ...verifier, functionName: "payAgent", args: [agentNameEncoded, messageHex, v.sig] },
      { note: `${eth(payment)} → the resolved addr(), never one the agent named`, value: payment },
    );
    const after = await publicClient.getBalance({ address: treasury });
    say(` ${C.dim("treasury")} ${eth(before)} → ${bold(eth(after))}`);
  },

  // ── anyone ─────────────────────────────────────────────────────────────────
  async status() {
    const s = await readState();
    say(` ${bold(agentName)}  ${s.provisioned ? C.ok("live") : C.dim("does not exist")}  ${C.dim(`block ${s.block}`)}`);
    say(kv("   resolver", `${addr(s.tree.resolver)} ${s.exactResolver ? C.ok("exact") : C.dim("—")}`, 18));
    say(kv("   operating key", s.records.operatingKey ? addr(s.records.operatingKey) : C.dim("—"), 18));
    say(kv("   addr()", addr(s.records.payTo), 18));
    say(kv("   registry roles", s.registryRoles === 0n ? "0x0 (none)" : s.registryRoleNames.join(" · "), 18));
    say(kv("   verdict k1/k2", `${s.verdicts.genesis.reason} / ${s.verdicts.rotated.reason}`, 18));
  },
};

/// Who may do what, in the shell. This mirrors the on-chain split rather than restating it: a
/// counterparty typing `revoke` is refused here for the same reason the chain would refuse it.
export const VERBS = {
  operator: {
    provision: "mint the agent's name and its sandbox (beat 1)",
    freeze: "revoke the agent's rotation grant; the name stays live",
    unfreeze: "restore it",
    revoke: "unregister() — the kill switch (beat 4)",
    status: "read the chain",
  },
  agent: {
    publish: "endpoint + operating key, from the agent's own key (beat 2a)",
    rotate: "rotate the operating key, no operator involved (beat 2c)",
    escape: "transfer the name, repoint the resolver, rewrite addr() (beat 3)",
    status: "read the chain",
  },
  counterparty: {
    check: "ask the verifier, spend nothing             [check retired]",
    pay: "resolve, verify, pay through the verifier   [pay retired]",
    status: "read the chain",
  },
};
