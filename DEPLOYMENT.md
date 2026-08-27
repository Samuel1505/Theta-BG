# Deployment — Unichain Sepolia

Live, verified, and demonstrated end to end. Everything below is a real
on-chain result, not a projection.

## Address verification

Before deploying against them, every third-party address used here was
independently confirmed to have real bytecode on Unichain Sepolia (chain id
`1301`) via `cast code <addr> --rpc-url unichain_sepolia` — not copied from
a single unverified source:

| Contract | Address | Source |
|---|---|---|
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` | [Uniswap deployments docs](https://developers.uniswap.org/docs/protocols/v4/deployments), confirmed on-chain |
| WETH9 | `0x4200000000000000000000000000000000000006` | OP-Stack predeploy address, confirmed on-chain (`symbol()` returns `"WETH"`) |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Standard "Nick's factory", confirmed on-chain |

No verified real ERC4626 yield venue (Aave v3, Morpho, or otherwise) was
found deployed on Unichain Sepolia at deployment time — see
`LIMITATIONS.md`. `DemoYieldStrategy` (a deterministic ERC4626 wrapper
around the real WETH9 above, `script/utils/DemoYieldStrategy.sol`) is
deployed in its place. Swapping in a real strategy later needs no change to
`ThetaBGHook` or `LPInsuranceVault` — only a different `strategy` address at
the next hook deployment, since it's immutable per hook instance.

## Deployed contracts

All verified on [Uniscan Sepolia](https://sepolia.uniscan.xyz):

| Contract | Address |
|---|---|
| `ThetaBGHook` | [`0x9739F9f628e06B0F1Da21A8AB841067856Fa15c8`](https://sepolia.uniscan.xyz/address/0x9739f9f628e06b0f1da21a8ab841067856fa15c8) |
| `SearcherRegistry` | [`0x19d73C0f5cceb36D08B1272E292d86275Fd4c808`](https://sepolia.uniscan.xyz/address/0x19d73c0f5cceb36d08b1272e292d86275fd4c808) |
| `LPInsuranceVault` (demo pool) | [`0x7D881A58E9231EEEf17800cA8d3dF4a6eB6f966d`](https://sepolia.uniscan.xyz/address/0x7d881a58e9231eeef17800ca8d3df4a6eb6f966d) |
| `DemoYieldStrategy` | [`0xC662DeeFdFe47a00F880dC9411ff2398601B736C`](https://sepolia.uniscan.xyz/address/0xc662deefdfe47a00f880dc9411ff2398601b736c) |
| Demo token (`tbgUSD`) | [`0xdd3F1154aeA345273BEC8C779F5B5d7410ef00b5`](https://sepolia.uniscan.xyz/address/0xdd3f1154aea345273bec8c779f5b5d7410ef00b5) |
| Searcher `DemoExecutor` | [`0x410CbE7444605f5aF0F797A49c052b74ae955163`](https://sepolia.uniscan.xyz/address/0x410cbe7444605f5af0f797a49c052b74ae955163) |
| Victim `DemoExecutor` | [`0x77d4695c60FE68533B6285B964060Bbc8FD4bC54`](https://sepolia.uniscan.xyz/address/0x77d4695c60fe68533b6285b964060bbc8fd4bc54) |
| LP `DemoExecutor` | [`0x8a8B11fF7E337A7797B8D82fe34082aEfed5F1dF`](https://sepolia.uniscan.xyz/address/0x8a8b11ff7e337a7797b8d82fe34082aefed5f1df) |

Full machine-readable record: `deployments/unichain-sepolia.json`.

**Hook parameters** (production values, not the loosened bands used in the
Foundry test suite — see `ARCHITECTURE.md`/`MECHANISM.md` for why tests use
different numbers):

| Parameter | Value |
|---|---|
| `minimumBond` | 0.01 ETH |
| `restorationThresholdBps` | 10 (0.1%) |
| `minDisplacementBps` | 50 (0.5%) |
| `priorityFeeBps` | 5 (0.05%) |
| `protocolShareBps` | 1000 (10%) |
| `protocolFeeRecipient` | deployer address |

**Demo pool**: native ETH / `tbgUSD`, fee tier 3000 (0.3%), tick spacing 60,
seeded with ~0.02 ETH of liquidity across ticks `[-6000, 6000]`.

## The demo sandwich — a real, verified slash

`script/DemoSandwich.s.sol` executed a genuine front-run → victim →
back-run sequence against the deployed pool, at the **production**
thresholds above (not the loosened 20%/0.05% bands the Foundry test suite
uses to avoid hand-solving exact CPMM math). The back-run's input amount
was computed exactly via v4's own `SqrtPriceMath.getAmount1Delta`, not
guessed — necessary to reliably land within a 0.1% restoration band.

| Leg | Tx hash |
|---|---|
| Front-run | [`0x2847228be3a9e333904a3f8f218931e3d37aba958024dceb2570bc583b06a7a0`](https://sepolia.uniscan.xyz/tx/0x2847228be3a9e333904a3f8f218931e3d37aba958024dceb2570bc583b06a7a0) |
| Victim | [`0x3a4e0d080e000168bca841b9492329349a41da075703455e84741d9762b895ca`](https://sepolia.uniscan.xyz/tx/0x3a4e0d080e000168bca841b9492329349a41da075703455e84741d9762b895ca) |
| Back-run (triggers the slash) | [`0x6ee61686984a8064439147d037542b046c751f4ede847e58ea1725cc19d1686f`](https://sepolia.uniscan.xyz/tx/0x6ee61686984a8064439147d037542b046c751f4ede847e58ea1725cc19d1686f) |

Measured on-chain result:

```
Starting sqrtPriceX96:              79228162514264337593543950336
sqrtPriceX96 after front-run:       76273363393439562819944159143   (372.9 bps displacement — clears the 50 bps floor)
sqrtPriceX96 after victim:          75336343392329472925829549405
Computed back-run input:            3790680768255798 (demo token)
Final sqrtPriceX96:                 79214546985066248574501645025   (1.72 bps deviation from start — clears the 10 bps restoration band)

Searcher bond after:                0            (fully slashed)
Searcher slash count:               1
Insurance vault available balance:  0.009 ETH    (exactly 90% of the 0.01 ETH bond)
Protocol cut:                       0.001 ETH    (exactly 10%)
```

The attacker's bond became LP insurance, on-chain, exactly as designed —
at the tight production thresholds, not a loosened demo configuration.

## Reproducing this deployment

Requires a `.env` with `PRIVATE_KEY`, `UNICHAIN_SEPOLIA_RPC_URL`, and
`ETHERSCAN_API_KEY` (see `foundry.toml`'s `[rpc_endpoints]`/`[etherscan]`
sections, which read these via env substitution).

```shell
forge script script/DeployThetaBG.s.sol   --rpc-url unichain_sepolia --broadcast --verify --private-key "$PRIVATE_KEY" --chain 1301 --etherscan-api-key "$ETHERSCAN_API_KEY" --verifier-url "https://api.etherscan.io/v2/api?chainid=1301"
forge script script/ConfigurePool.s.sol   --rpc-url unichain_sepolia --broadcast --verify --private-key "$PRIVATE_KEY" --chain 1301 --etherscan-api-key "$ETHERSCAN_API_KEY" --verifier-url "https://api.etherscan.io/v2/api?chainid=1301"
forge script script/RegisterSearcher.s.sol --rpc-url unichain_sepolia --broadcast
forge script script/DemoSandwich.s.sol    --rpc-url unichain_sepolia --broadcast
```

Each script after the first reads the addresses it needs from
`deployments/unichain-sepolia.json`, written by the one before it. Total
cost across all four scripts: ~15M gas at ~0.001 gwei ≈ 0.000015 ETH —
Unichain Sepolia's gas price is negligible; the real constraint if you're
re-running this is having enough native ETH for `minimumBond` + pool
liquidity + swap amounts, not gas.

**Note on `--verify`**: `forge script ... --broadcast --verify` in one pass
occasionally submits verification before Uniscan's indexer has the
transaction, in which case re-run the same command with `--resume` added
(no transactions are re-sent; only the verification step re-runs). That's
what happened here — see the two-step form in the actual commands run for
this deployment, `git log` for `DEPLOYMENT.md`'s introduction.
