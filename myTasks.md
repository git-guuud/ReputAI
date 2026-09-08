# Tasks for you (outside coding)

Things that block progress and that I cannot do.

## Blocking T6 (Sepolia deployment)

- [ ] **Sepolia RPC URL** — Alchemy/Infura/public endpoint. Put it in `.env` as
      `SEPOLIA_RPC_URL`. Copy `.env.example` to `.env` first.
- [ ] **Sepolia testnet ETH** for the deployer address. A faucet is fine; deployment plus
      a live demo mint needs very little.
- [ ] **Deployer private key** in `.env` as `PRIVATE_KEY`. Use a throwaway key — never one
      holding real funds. `.env` is gitignored.
- [ ] **Etherscan API key** (`ETHERSCAN_API_KEY`) — optional, only for contract verification.
      Worth having: judges clicking through to verified source is cheap credibility.

## Blocking nothing yet, but needed before submission

- [ ] Confirm which ENSv2 contracts are canonically deployed on Sepolia, and whether the
      track expects us to register under an existing test parent or deploy our own registry.
      Worth asking in the ETHGlobal ENS channel early — the answer changes T6.
- [ ] Decide the demo's parent domain name.
