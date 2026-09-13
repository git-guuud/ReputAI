#!/usr/bin/env node
// The control room's entry point.
//
//   reput watch                 the live pane — reads the chain, signs nothing
//   reput operator              an actor's shell, interactive
//   reput agent publish         the same verb, one-shot (what the rehearsal script drives)
//
// Everything is aimed at one deployed name on Sepolia; nothing here is a simulation.

import { ACTORS } from "./lib/config.mjs";
import { C, bold, actorColour, pad } from "./lib/ui.mjs";
import { VERBS } from "./lib/actions.mjs";
import { shell, run } from "./shell.mjs";

const [, , first, ...rest] = process.argv;
const say = (s = "") => process.stdout.write(`${s}\n`);

function usage() {
  say();
  say(`  ${bold("reput")} ${C.dim("— terminal control room for the agent-bound identity sandbox")}`);
  say();
  say(`  ${pad("reput watch", 30)}${C.dim("live chain state, refreshed every few seconds")}`);
  for (const id of Object.keys(VERBS)) {
    say(`  ${actorColour(id)(pad(`reput ${id}`, 30))}${C.dim(`${ACTORS[id].title.toLowerCase()} shell`)}`);
  }
  say(`  ${pad("reput <actor> <verb> [args]", 30)}${C.dim("run one verb without the shell")}`);
  say();
}

if (!first || first === "help" || first === "--help") {
  usage();
} else if (first === "watch") {
  await import("./watch.mjs");
} else if (ACTORS[first]) {
  const actor = ACTORS[first];
  if (!actor.account) {
    say(`  ${C.bad("no key for")} ${first} ${C.dim("— check .env")}`);
    process.exit(1);
  }
  if (rest.length) {
    await run(actor, rest[0], rest.slice(1));
  } else {
    await shell(actor);
  }
} else {
  say(`  ${C.bad(`unknown command: ${first}`)}`);
  usage();
  process.exit(1);
}
