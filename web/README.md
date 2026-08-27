# Theta-BG Console

A live, read-and-write frontend for the Theta-BG Uniswap v4 hook deployed on
**Unichain Sepolia** (chain `1301`). Everything on screen is read straight
from chain — contract state via multicall, pool price via `extsload` on the
packed `Slot0`, and history via `eth_getLogs` from the hook's deployment
block.

## Stack

- Vite + React 19 + TypeScript
- wagmi 2 + viem 2 + RainbowKit for wallet + contract calls
- `@tanstack/react-query` for caching / polling
- react-router for the five views
- Plain CSS design system (`src/index.css`), no UI framework

## Views

| Route | What it does |
|---|---|
| `/` Overview | The pitch, headline live numbers, and links to the real on-chain demo slash |
| `/dashboard` Protocol | Live pool price & liquidity, vault accounting, hook parameters, full on-chain activity feed, slash ledger |
| `/searchers` Searchers | Connected-wallet bond lifecycle — `register` / `topUpBond` / `requestWithdrawal` / `cancelWithdrawal` / `withdraw` — plus a table of every registered searcher |
| `/vault` LP Vault | Auto-discovers your liquidity positions from `ModifyLiquidity` logs and lets you `claimInsuranceYield`; shows the seeded demo LP position as a worked example |
| `/mechanism` Mechanism | The five-condition predicate, bond economics, and a stage-by-stage walkthrough of the verified demo sandwich with transaction links |

## Run

```shell
npm install
npm run dev        # http://localhost:5173
npm run build      # tsc -b && vite build  → dist/
npm run preview
```

No env vars are required. See `.env.example` for optional overrides
(WalletConnect project id, a faster RPC endpoint).

## Contract addresses

Hard-coded in `src/config/contracts.ts` from the repo's `DEPLOYMENT.md` /
`deployments/unichain-sepolia.json`. The ABIs in `src/abis/` are the
**deployed** versions (the live vault predates the `LIQUIDITY_MATURATION_BLOCKS`
change in `src/`); regenerate them from `out/` only against a matching
redeploy.

## Notes

- Detection is same-block and cross-transaction — the console reflects that
  scope; see the Mechanism page and the repo's `LIMITATIONS.md`.
- Registering as a searcher from a plain EOA works for exercising the bond
  lifecycle, but only a contract can actually trade the priority lane
  (searcher identity is the direct `PoolManager.swap()` caller).
