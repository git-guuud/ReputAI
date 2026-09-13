// One actor, one terminal, one key.
//
// The pane is cleared on every command and shows only the latest action. That is deliberate:
// the control-room pane already holds the running history of every transaction, so a shell that
// also scrolled one would be the same evidence twice, in the place with the least room for it.
// Here: who I am, what I just did, what the chain said.
//
// The shell also refuses verbs belonging to another party — not as access control (it holds the
// keys, it could do anything) but because the separation is the thing being demonstrated, and a
// demo that lets the operator type `rotate` blurs the only line that matters.

import { createInterface } from "node:readline";
import { actions, VERBS } from "./lib/actions.mjs";
import { C, bold, actorColour, pad, banner, CLEAR } from "./lib/ui.mjs";
import { decodeRevert } from "./lib/tx.mjs";
import { ACTORS, agentName } from "./lib/config.mjs";

const say = (s = "") => process.stdout.write(`${s}\n`);

export function ownerOf(verb) {
  for (const [id, verbs] of Object.entries(VERBS)) if (verb in verbs) return id;
  return null;
}

/// Verbs on one line each, dim, under the banner. Visible while the pane is idle; gone the
/// moment the actor does something.
function help(actor) {
  const c = actorColour(actor.id);
  for (const [verb, desc] of Object.entries(VERBS[actor.id])) {
    say(` ${c(pad(verb, 11))}${C.dim(desc)}`);
  }
}

function header(actor, echo) {
  process.stdout.write(CLEAR);
  say(banner(actor));
  if (echo) say(`${C.dim(" ▸")} ${bold(echo)}`);
  say();
}

export async function run(actor, verb, args = []) {
  const fn = actions[verb];
  if (!fn) {
    say(` ${C.dim(`no such verb: ${verb}`)}`);
    return;
  }
  // A verb this actor owns is always allowed; `status` is shared by all three.
  const owner = verb in VERBS[actor.id] ? actor.id : ownerOf(verb);
  if (owner && owner !== actor.id) {
    say(` ${C.bad("refused")} ${C.dim(`— "${verb}" is the`)} ${actorColour(owner)(owner)}${C.dim("'s move.")}`);
    say(` ${C.dim(`this pane holds ${ACTORS[actor.id].title.toLowerCase()}'s key and nothing else.`)}`);
    return;
  }
  try {
    await fn(actor, args);
  } catch (e) {
    // A revert here is usually the demo working: the chain refusing something. Name it.
    const r = decodeRevert(e, verb === "rotate" || verb === "publish" ? "resolver" : "registry");
    say(` ${C.bad("✗")} ${bold(r.name)}`);
    for (const a of r.args) say(`   ${C.dim(a)}`);
  }
}

export async function shell(actor) {
  const c = actorColour(actor.id);
  header(actor);
  say(` ${C.dim("acting on")} ${agentName}`);
  say();
  help(actor);
  say();

  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.setPrompt(`${c(bold(" ▸ "))}`);
  rl.prompt();

  for await (const line of rl) {
    const [verb, ...args] = line.trim().split(/\s+/).filter(Boolean);
    if (!verb) {
      rl.prompt();
      continue;
    }
    if (verb === "quit" || verb === "exit") break;
    if (verb === "help" || verb === "?") {
      header(actor);
      help(actor);
      say();
    } else {
      header(actor, [verb, ...args].join(" "));
      await run(actor, verb, args);
      say();
    }
    rl.prompt();
  }
  rl.close();
}
