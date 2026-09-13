// Terminal presentation: colours, boxes, and the vocabulary the demo speaks in.
//
// The three actors have fixed colours and they are load-bearing rather than decorative — the
// argument of this project is *who signed which transaction*, so the colour of a line is the
// answer to the only question that matters about it.

const ESC = "\x1b[";
export const RESET = `${ESC}0m`;

const fg = (r, g, b) => (s) => `${ESC}38;2;${r};${g};${b}m${s}${RESET}`;
const onBg = (r, g, b) => (s) => `${ESC}48;2;${r};${g};${b}m${ESC}38;2;12;14;18m${ESC}1m${s}${RESET}`;
const bold_ = (s) => `${ESC}1m${s}${RESET}`;

/// One RGB triple per actor, used three ways — border, header bar, and the colour of every line
/// that actor's key signed. Three renderings of one fact, which is what makes a pane readable
/// at a glance instead of after reading it.
const RGB = {
  operator: [245, 166, 35],       // amber
  agent: [34, 211, 238],          // cyan
  counterparty: [192, 132, 252],  // violet
  control: [129, 140, 248],       // indigo
};

export const C = {
  operator: fg(...RGB.operator),
  agent: fg(...RGB.agent),
  counterparty: fg(...RGB.counterparty),
  ok: fg(74, 222, 128),
  bad: fg(248, 113, 113),
  warn: fg(250, 204, 21),
  dim: fg(107, 114, 128),
  text: fg(229, 231, 235),
  accent: fg(...RGB.control),
};

export const BG = {
  operator: onBg(...RGB.operator),
  agent: onBg(...RGB.agent),
  counterparty: onBg(...RGB.counterparty),
  control: onBg(...RGB.control),
};

/// tmux wants its own colour spec for the pane border, from the same source.
export const tmuxColour = (id) => `#${RGB[id].map((n) => n.toString(16).padStart(2, "0")).join("")}`;

export const bold = bold_;
export const actorColour = (id) => C[id] ?? C.text;

/// Visible length: ANSI sequences are zero-width, and every layout calculation here needs to
/// ignore them or the boxes tear.
export const vlen = (s) => s.replace(/\x1b\[[0-9;]*m/g, "").length;

export function pad(s, n) {
  const l = vlen(s);
  return l >= n ? s : s + " ".repeat(n - l);
}

export function truncate(s, n) {
  s = String(s ?? "");
  return s.length <= n ? s : `${s.slice(0, n - 1)}…`;
}

/// 84 is the narrowest the frame's columns fit; beyond that it stretches to fill its pane, so a
/// wide control room is not two thirds empty space.
export const WIDTH = Math.max(84, Math.min(process.stdout.columns || 84, 120));

export function box(title, lines, { width = WIDTH, colour = C.dim, right = "" } = {}) {
  const inner = width - 2;
  const head = title ? ` ${title} ` : "";
  const tail = right ? ` ${right} ` : "";
  const fillLen = Math.max(0, inner - vlen(head) - vlen(tail) - 2);
  const out = [
    colour("╭") + colour("─") + head + colour("─".repeat(fillLen)) + tail + colour("─") + colour("╮"),
  ];
  for (const l of lines) out.push(colour("│") + pad(` ${l}`, inner) + colour("│"));
  out.push(colour("╰" + "─".repeat(inner) + "╯"));
  return out.join("\n");
}

export function rule(label = "", width = WIDTH) {
  return C.dim(label ? `── ${label} ${"─".repeat(Math.max(0, width - vlen(label) - 5))}` : "─".repeat(width));
}

/// `0x1234…abcd` — short enough to fit a column, long enough to check against Etherscan.
export function addr(a) {
  if (!a) return C.dim("—");
  if (a === "0x0000000000000000000000000000000000000000") return C.dim("0x0000…0000");
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function eth(wei, dp = 4) {
  if (wei == null) return "—";
  return `${(Number(wei) / 1e18).toFixed(dp)} ETH`;
}

export function kv(k, v, kw = 18) {
  return `${C.dim(pad(k, kw))}${v}`;
}

/// A status dot with its label, in the colour that says whether money would move.
export function light(on, label) {
  return on ? C.ok(`● ${label}`) : C.bad(`● ${label}`);
}

/// OSC 8: clickable text with a short label. An 84-column pane cannot hold an Etherscan URL
/// without wrapping, and a wrapped URL is both ugly and unclickable. Terminals that do not
/// support this show the label as plain text, which is why the label is the tx hash.
export function hyperlink(url, label) {
  return `\x1b]8;;${url}\x1b\\${label}\x1b]8;;\x1b\\`;
}

export const CLEAR = `${ESC}H${ESC}2J`;
export const HOME = `${ESC}H`;
export const CLEAR_BELOW = `${ESC}0J`;
export const hideCursor = () => process.stdout.write(`${ESC}?25l`);
export const showCursor = () => process.stdout.write(`${ESC}?25h`);

/// A solid bar of the actor's colour, full width. Three of these stacked are impossible to
/// confuse with each other, which the thin borders were not.
export function bar(id, left, right = "") {
  const w = process.stdout.columns || 80;
  const body = ` ${left}`;
  const gap = Math.max(1, w - vlen(body) - vlen(right) - 1);
  return (BG[id] ?? BG.control)(`${body}${" ".repeat(gap)}${right} `);
}

/// Two lines, not seven: who this pane is, and one sentence on what it may do. Reprinted on
/// every command, because the pane is cleared each time.
///
/// Under tmux the pane's own border is already a solid bar of this colour, so repeating one
/// here would be the same fact twice; a coloured gutter marks the lines instead. Standalone,
/// the bar is the only thing identifying the terminal, so it stays.
export function banner(actor) {
  const c = actorColour(actor.id);
  const g = gutter(actor.id);
  return process.env.TMUX
    ? [`${g} ${c(bold(actor.title))}  ${C.dim(actor.address)}`, `${g} ${C.dim(actor.holds)}`].join("\n")
    : [bar(actor.id, actor.title, actor.address), `${C.dim(" holds")} ${C.dim(actor.holds)}`].join("\n");
}

/// Prefix marking which key a line belongs to. Cheap, and it survives a screenshot.
export const gutter = (id) => actorColour(id)("▌");
