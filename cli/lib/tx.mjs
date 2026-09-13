// Sending a transaction, out loud.
//
// Two paths, because the demo needs both. `send()` is the ordinary one: simulate, broadcast,
// wait, report. `sendExpectingRevert()` is for the transactions whose *failure* is the point —
// it names the revert reason from an `eth_call` first, then broadcasts with an explicit gas
// limit so estimation is skipped and the failure is mined where a viewer can click it.

import { BaseError, ContractFunctionRevertedError, hexToString } from "viem";
import { publicClient, walletFor, allErrors, REFUSAL, namedRoles } from "./chain.mjs";
import { explorer } from "./config.mjs";
import { C, bold, actorColour, pad, hyperlink } from "./ui.mjs";
import { record } from "./log.mjs";

const say = (s) => process.stdout.write(`${s}\n`);

/// Pull a named custom error out of whatever viem wrapped it in.
export function decodeRevert(err, space = "registry") {
  if (err instanceof BaseError) {
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert?.data?.errorName) {
      return { name: revert.data.errorName, args: explain(revert.data.errorName, revert.data.args ?? [], space) };
    }
    if (revert?.reason) return { name: revert.reason, args: [] };
  }
  return { name: err.shortMessage ?? err.message ?? "unknown", args: [] };
}

export function describeRevert(r) {
  return r.args.length ? `${r.name}(${r.args.join(", ")})` : r.name;
}

/// Revert arguments the demo actually needs to read out loud. A refusal reason is an enum and a
/// DNS-encoded name; an EAC failure's first argument is the *resource*, which is the whole point
/// of showing it — it says where the check happened, and it is never one of the agent's keys.
function explain(errorName, args, space) {
  if (errorName === "Refused") {
    const [reason, name] = args;
    return [`reason: ${REFUSAL[Number(reason)]}`, `name:   ${decodeDnsName(name)}`];
  }
  if (errorName === "EACUnauthorizedAccountRoles") {
    const [resource, roles, account] = args;
    const named = namedRoles(BigInt(roles), space);
    return [
      `resource: 0x${BigInt(resource).toString(16)}  (the name itself, not a text key)`,
      `roles:    ${named.length ? named.join(" · ") : `0x${BigInt(roles).toString(16)}`}`,
      `account:  ${account}`,
    ];
  }
  return args.map((a) => String(a));
}

/// DNS wire format back to a readable name, so a revert names the agent rather than a byte string.
function decodeDnsName(hex) {
  try {
    const bytes = Buffer.from(String(hex).slice(2), "hex");
    const parts = [];
    for (let i = 0; i < bytes.length && bytes[i] !== 0; ) {
      const len = bytes[i];
      parts.push(bytes.subarray(i + 1, i + 1 + len).toString());
      i += 1 + len;
    }
    return parts.join(".");
  } catch {
    return String(hex);
  }
}

/// `EACUnauthorizedAccountRoles` says nothing on its own; the role it was missing says
/// everything. Compress to the form that carries the argument.
function shortName(reason) {
  if (reason.name === "EACUnauthorizedAccountRoles") {
    const role = reason.args.find((a) => a.startsWith("roles:"));
    return role ? `EACUnauthorized · ${role.replace(/^roles:\s*/, "")}` : reason.name;
  }
  if (reason.name === "Refused") {
    const why = reason.args.find((a) => a.startsWith("reason:"));
    return why ? `Refused · ${why.replace(/^reason:\s*/, "")}` : reason.name;
  }
  return reason.name;
}

function link(hash) {
  return C.dim(hyperlink(`${explorer}/tx/${hash}`, `${hash.slice(0, 10)}…${hash.slice(-6)}`));
}

/// One transaction, two lines: what is being sent, and what the chain did with it. The full
/// hash is an Etherscan link on the second line, so it stays clickable while the first line
/// stays readable.
export async function send(actor, verb, call, { note = "", value } = {}) {
  const c = actorColour(actor.id);
  say(` ${c("→")} ${bold(pad(verb, 12))}${C.dim(note)}`);

  const { request, result } = await publicClient.simulateContract({
    ...call,
    account: actor.account,
    value,
  });
  const hash = await walletFor(actor).writeContract(request);
  record({ actor: actor.id, verb, hash, status: "sent", note });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  const good = receipt.status === "success";
  say(`   ${good ? C.ok("✓ mined") : C.bad("✗ reverted")}  ${link(hash)}`);
  record({ actor: actor.id, verb, hash, status: good ? "ok" : "reverted", note });
  return { hash, receipt, result };
}

/// For the three escapes and the refused payment: the transaction must reach the chain and fail
/// there. `forge script` cannot do this — it aborts on the simulation — which is why two of the
/// original eight demo commands were raw `cast`. Here it is the same tool as everything else.
/// For the three escapes and the refused payments: the transaction must reach the chain and fail
/// there. `forge script` cannot do this — it aborts on the simulation — which is why two of the
/// original eight demo commands were raw `cast`. Here it is the same tool as everything else.
///
/// `label` is what the attempt is trying to do in English; the revert name is what the chain
/// called it. Both on one line, because three of these run back to back.
export async function sendExpectingRevert(
  actor,
  verb,
  call,
  { gas = 150000n, value, space = "registry", label = verb, detail = true } = {},
) {
  let reason;
  try {
    await publicClient.simulateContract({
      ...call,
      abi: [...call.abi, ...allErrors],
      account: actor.account,
      value,
    });
    say(` ${C.bad(bold("!!! DID NOT REVERT — containment is broken, stop the demo"))}`);
    return { broken: true };
  } catch (err) {
    reason = decodeRevert(err, space);
  }

  // Explicit gas: skip estimation, so the failure is mined rather than caught client-side.
  const hash = await walletFor(actor).writeContract({ ...call, gas, value, account: actor.account });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  const reverted = receipt.status === "reverted";

  say(
    ` ${reverted ? C.bad("✗") : C.warn("!")} ${pad(label, 22)}${pad(C.warn(shortName(reason)), 40)}` +
      link(hash),
  );
  if (detail) for (const a of reason.args) say(`   ${C.dim(a)}`);
  if (!reverted) say(` ${C.bad("   succeeded — that is a bug, stop the demo")}`);

  record({ actor: actor.id, verb, hash, status: reverted ? "reverted" : "ok", note: reason.name });
  return { hash, receipt, reason };
}
