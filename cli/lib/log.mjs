// A single append-only feed shared by all four panes.
//
// The actor shells write to it; the watcher tails it. That is what lets one pane show three
// keys acting — the colour of each line is the party that signed it.

import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "./config.mjs";

export const FEED = process.env.DEMO_FEED ?? join(ROOT, "deployments", ".control-room.jsonl");

export function record(entry) {
  appendFileSync(FEED, `${JSON.stringify({ t: Date.now(), ...entry })}\n`);
}

export function tail(n = 8) {
  if (!existsSync(FEED)) return [];
  const entries = readFileSync(FEED, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);

  // A transaction is logged twice — once when broadcast, once when mined — so the feed can show
  // it while it is pending. Collapse to the latest state of each, in first-seen order.
  const latest = new Map();
  for (const e of entries) {
    const key = e.hash ?? `${e.actor}:${e.verb}:${e.t}`;
    latest.set(key, { ...latest.get(key), ...e });
  }
  return [...latest.values()].slice(-n);
}
