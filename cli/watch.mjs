// The control room's live pane: the chain's answer, re-read every few seconds.
//
// Nothing in this file sends a transaction or holds state between frames beyond what it needs to
// notice a change. When the operator revokes in another pane, this one goes red on its own.

import { readState } from "./lib/state.mjs";
import { tail } from "./lib/log.mjs";
import {
  C, bold, box, kv, addr, eth, pad, truncate, vlen, actorColour,
  HOME, CLEAR, CLEAR_BELOW, hideCursor, showCursor, WIDTH,
} from "./lib/ui.mjs";
import { agentName, endpointKey, operatingKey, parentName, label, deployment } from "./lib/config.mjs";

// Column budgets, derived from the frame rather than assumed. A wide pane should show more of
// the endpoint and more of each transaction's note, not the same 84 columns with padding.
const ENDPOINT_W = WIDTH - 62;
const NOTE_W = WIDTH - 62;

const parentLabel = parentName.replace(/\.eth$/, "");
const INTERVAL = Number(process.env.DEMO_POLL_MS ?? 4000);

let previous = null;

function verdictLine(name, key, v, published) {
  const good = !v.refused;
  const dot = good ? C.ok("●") : C.bad("●");
  const verdict = good ? C.ok(bold("WOULD TRANSACT")) : C.bad(`REFUSED · ${v.reason}`);
  // Marking which key the name publishes right now is what ties this pane to the shells, where
  // the same two keys are called "current" and "retired".
  const mark = published ? C.dim("   ← the name publishes this one") : "";
  return `  ${dot} ${pad(C.dim(name), 22)}${pad(addr(key), 14)}${pad(verdict, 24)}${mark}`;
}

function frame(s) {
  const L = [];
  const yes = C.ok("✓");
  const no = C.bad("✗");

  L.push("");
  L.push(`  ${bold(C.text(agentName))}   ${s.provisioned ? C.ok("live") : C.dim("does not exist yet")}`);
  L.push("");

  L.push(C.dim("  RESOLUTION") + C.dim("        walked from the ENS root every frame"));
  L.push(`    ${pad("root", 24)}${addr(s.tree.root)}`);
  L.push(`    └ ${pad("eth", 22)}${addr(s.tree.eth)}  ${C.dim("canonical .eth registry")}`);
  L.push(`      └ ${pad(parentLabel, 20)}${addr(s.tree.operator)}  ${C.dim("operator registry")}`);
  L.push(
    `        └ ${pad(label, 18)}${addr(s.tree.resolver)}  ` +
      (s.provisioned
        ? s.exactResolver
          ? `${yes} ${C.dim("exact, not inherited")}`
          : `${no} ${C.bad("inherited — would be refused")}`
        : C.dim("no resolver")),
  );
  L.push("");

  L.push(C.dim("  RECORDS") + C.dim(" ".repeat(ENDPOINT_W + 21) + "writable by"));
  L.push(
    `    ${pad(endpointKey, 24)}${pad(truncate(s.records.endpoint || "—", ENDPOINT_W), ENDPOINT_W + 2)}` +
      (s.grants.endpoint ? C.agent("agent") : C.dim("—")),
  );
  L.push(
    `    ${pad(operatingKey, 24)}${pad(s.records.operatingKey ? addr(s.records.operatingKey) : "—", ENDPOINT_W + 2)}` +
      (s.grants.operatingKey ? C.agent("agent") : C.dim("—")),
  );
  L.push(
    `    ${pad("addr()", 24)}${pad(addr(s.records.payTo), ENDPOINT_W + 2)}` +
      C.operator("operator") + C.dim("  ← where money goes"),
  );
  L.push("");

  L.push(C.dim("  THE BOX"));
  L.push(
    kv("    registry roles", s.registryRoles === 0n
      ? `0x0  ${C.dim("— none at all")}`
      : C.warn(s.registryRoleNames.join(" · ") || `0x${s.registryRoles.toString(16)}`), 22),
  );
  L.push(kv("    withheld", C.dim("transfer · setResolver · setAddr · unregister · other keys"), 22));
  L.push("");

  const pub = (s.records.operatingKey || "").toLowerCase();
  L.push(C.dim("  VERIFIER") + C.dim("          CounterpartyVerifier.checkAgent(), same message, two keys"));
  L.push(verdictLine("genesis key", s.keys.genesis, s.verdicts.genesis, pub === s.keys.genesis.toLowerCase()));
  L.push(verdictLine("rotated key", s.keys.rotated, s.verdicts.rotated, pub === s.keys.rotated.toLowerCase()));
  L.push("");
  L.push(
    `  ${C.dim("treasury")} ${bold(eth(s.balances.treasury))}` +
      `   ${C.dim("gas left:")} ${C.operator(eth(s.balances.operator, 3))} ` +
      `${C.agent(eth(s.balances.agent, 3))} ${C.counterparty(eth(s.balances.counterparty, 3))}`,
  );

  const head = box(bold("REPUTAI · CONTROL ROOM"), L, {
    colour: C.accent,
    right: C.dim(`sepolia · block ${s.block}`),
  });

  const feed = tail(7).map((e) => {
    const c = actorColour(e.actor);
    const mark = e.status === "ok" ? C.ok("✓") : e.status === "reverted" ? C.bad("✗") : C.dim("·");
    return `${pad(c(e.actor), 15)}${pad(e.verb, 16)}${pad(C.dim(e.hash ? `${e.hash.slice(0, 10)}…` : ""), 13)}${mark} ${C.dim(truncate(e.note ?? "", NOTE_W))}`;
  });
  const feedBox = box(
    C.dim("TRANSACTIONS"),
    feed.length ? feed : [C.dim("nothing yet — the panes on the right sign for themselves")],
    { colour: C.dim },
  );

  previous = s;
  return `${head}\n${feedBox}\n`;
}

/// The frame is laid out for a fixed 84 columns. Narrower than that and the columns tear, which
/// looks like a bug in the demo rather than a pane that needs dragging, so say so instead.
function tooNarrow() {
  const cols = process.stdout.columns || 84;
  return cols < 84
    ? box(C.warn("PANE TOO NARROW"), [
        C.dim(`this pane is ${cols} columns; the control room needs 84.`),
        C.dim("widen the terminal or the pane and it will redraw."),
      ], { colour: C.warn, width: Math.max(24, cols - 1) })
    : null;
}

async function loop() {
  hideCursor();
  process.stdout.write(CLEAR);
  for (;;) {
    let out;
    try {
      out = tooNarrow() ?? frame(await readState());
    } catch (e) {
      out = box(C.bad("READ FAILED"), [C.dim(String(e.shortMessage ?? e.message).slice(0, 200))], {
        colour: C.bad,
      });
    }
    process.stdout.write(HOME + out + CLEAR_BELOW);
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

process.on("SIGINT", () => {
  showCursor();
  process.exit(0);
});

loop();
