# Tasks for you (outside coding)

Things that block progress and that I cannot do.

## Blocking T6 (Sepolia deployment)

- [x] **Sepolia RPC URL** — using the public endpoint
      `https://ethereum-sepolia-rpc.publicnode.com`, tested live and written to `.env`. No
      account needed. Fallback if it rate-limits: `https://1rpc.io/sepolia`. (`rpc.sepolia.org`
      is dead and `sepolia.drpc.org` now paywalls Sepolia — don't bother with either.)
- [x] **Deployer private key** — a throwaway account was generated and written to `.env`
      (gitignored, mode 600). Address: `0x7aD721F362A8049Dd139764B0745657D06d9AA93`.
- [x] **Etherscan API key** — in `.env`.
- [x] **Sepolia testnet ETH** — funded and spent; the deployment cost ~0.008 ETH of the 0.05
      sent. Remaining balance covers the demo transactions.
      *(original note kept for reference)* `0x7aD721F362A8049Dd139764B0745657D06d9AA93`. ~0.1 ETH is plenty: the deployment is two proxy
      deployments, two contract deployments, a registration and two grants.
      Faucets: <https://cloud.google.com/application/web3/faucet/ethereum/sepolia>,
      <https://sepoliafaucet.com>, <https://sepolia-faucet.pk910.de>.

      *Rent is not a blocker.* The registrar takes ERC-20 only, and the oracle accepts
      upstream's MockUSDC, whose `mint()` is unpermissioned on testnet — `01_Commit` mints the
      8.000021 USDC it needs. Gas is the only real cost.

## Blocking nothing yet, but needed before submission

- [x] **Which ENSv2 contracts are canonically deployed on Sepolia** — answered from the
      submodule's own generated address table (`lib/contracts-v2/contracts/docs/addresses/sepolia.md`,
      chain 11155111, deployed 2026-06-29) and each address confirmed to hold code on-chain.
      They are recorded in `script/SepoliaConfig.sol`. We register a real `.eth` name through
      the real registrar and deploy *beneath* it; we replace nothing.
- [x] **The demo's parent domain name** — `reputai-sandbox.eth`, confirmed available. Change it
      by setting `AGENT_PARENT_LABEL` before running `01_Commit`; nothing hard-codes it.
- [ ] **Record the video.** Everything it needs is built and rehearsed on live Sepolia. Follow
      [`docs/DEMO.md`](./docs/DEMO.md): eight commands, one per beat, roughly three minutes of
      transactions. `agent-404.reputai-sandbox.eth` has never been minted, so beat 1 is a live
      mint on camera. Balances are already funded (operator ~0.032 ETH, agent and counterparty
      ~0.0055 each; the whole run costs ~0.003).
