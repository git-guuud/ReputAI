// Configuration for the control room: environment, deployment records, and the three actors.
//
// Everything here is read from the same sources the forge scripts use — `.env`, the deployment
// record written by `02_Register`, and the demo record written by beat 1 — so the CLI and the
// scripts can never disagree about which name, which keys, or which contracts they mean.

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/// Canonical ENSv2 Sepolia addresses, mirroring `script/SepoliaConfig.sol`.
export const ENS = {
  chain: sepolia,
  root: "0x11b5BfbE9078D826b1eDBDd1cFC12f5828D9F50C",
  ethRegistry: "0x67b728a792e789a8978b30cF1b3b641f19354b43",
};

function parseEnv(path) {
  const env = {};
  if (!existsSync(path)) return env;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let v = m[2].trim();
    if (
      (v.startsWith('"') && v.endsWith('"')) ||
      (v.startsWith("'") && v.endsWith("'"))
    ) {
      v = v.slice(1, -1);
    }
    env[m[1]] = v;
  }
  return env;
}

export const env = { ...parseEnv(join(ROOT, ".env")), ...process.env };

export function json(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export const deploymentFile = env.DEPLOYMENT_FILE ?? join(ROOT, "deployments", "sepolia.json");
export const demoFile = env.DEMO_FILE ?? join(ROOT, "deployments", "demo-sepolia.json");

export const deployment = json(deploymentFile);

/// The demo record only exists once beat 1 has run. Every later beat needs the tokenId, which is
/// the registry's to assign and not derivable from the label.
export function demo() {
  return existsSync(demoFile) ? json(demoFile) : null;
}

export const label = env.DEMO_AGENT_LABEL ?? "agent-404";
export const parentName = deployment.parentName;
export const agentName = `${label}.${parentName}`;
export const endpointKey = deployment.endpointKey;
export const operatingKey = deployment.operatingKey;
/// Both default off the label. A recording that needs a fresh label (because the previous one
/// is already minted) should then be a single variable to change, not three that can disagree —
/// and `.env` values referring to an older label are ignored rather than quietly printed.
const forThisLabel = (value, fallback) =>
  value && !/agent-[\w-]+/.test(value.replace(label, "")) ? value : fallback;

export const endpoint = forThisLabel(env.DEMO_ENDPOINT, `https://${label}.reputai.example/api`);
export const message = forThisLabel(
  env.DEMO_MESSAGE,
  `${label}: invoice 17, settle to my published payout address`,
);
export const payment = BigInt(env.DEMO_PAY_WEI ?? 10n ** 15n); // 0.001 ETH
export const treasury = env.DEMO_TREASURY;
export const rpcUrl = env.SEPOLIA_RPC_URL;

/// The three parties, each with its own key. Which of these signs a transaction is the whole
/// argument of the demo, so the colour is part of the actor's identity, not decoration.
export const ACTORS = {
  operator: {
    id: "operator",
    title: "OPERATOR",
    colour: "amber",
    pk: env.PRIVATE_KEY,
    holds: "ROLE_REGISTRAR + ROLE_UNREGISTER at the registry root",
  },
  agent: {
    id: "agent",
    title: "AGENT",
    colour: "cyan",
    pk: env.DEMO_AGENT_PK,
    holds: `ROLE_SET_TEXT on exactly two keys: ${endpointKey}, ${operatingKey}`,
  },
  counterparty: {
    id: "counterparty",
    title: "COUNTERPARTY",
    colour: "magenta",
    pk: env.DEMO_COUNTERPARTY_PK,
    holds: "nothing. It knows the ENS root address and no more",
  },
};

for (const a of Object.values(ACTORS)) {
  a.account = a.pk ? privateKeyToAccount(a.pk) : null;
  a.address = a.account?.address;
}

/// Operating keys are credentials, not authorities: never funded, never a transaction sender.
export const signingKeys = {
  genesis: privateKeyToAccount(env.DEMO_KEY_GENESIS_PK),
  rotated: privateKeyToAccount(env.DEMO_KEY_ROTATED_PK),
};

export const explorer = "https://sepolia.etherscan.io";
