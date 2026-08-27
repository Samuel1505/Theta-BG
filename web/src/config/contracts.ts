import type { Address } from 'viem'

import { thetaBGHookAbi } from '../abis/ThetaBGHook'
import { searcherRegistryAbi } from '../abis/SearcherRegistry'
import { lpInsuranceVaultAbi } from '../abis/LPInsuranceVault'
import { poolManagerAbi } from '../abis/PoolManager'
import { erc20Abi } from '../abis/erc20'

export { thetaBGHookAbi, searcherRegistryAbi, lpInsuranceVaultAbi, poolManagerAbi, erc20Abi }

/** Unichain Sepolia. */
export const CHAIN_ID = 1301

/**
 * Live, verified deployment — see the repo's DEPLOYMENT.md. These are the
 * exact addresses the real on-chain demo sandwich + slash was executed
 * against.
 */
export const addresses = {
  hook: '0x9739F9f628e06B0F1Da21A8AB841067856Fa15c8',
  registry: '0x19d73C0f5cceb36D08B1272E292d86275Fd4c808',
  vault: '0x7D881A58E9231EEEf17800cA8d3dF4a6eB6f966d',
  poolManager: '0x00B036B58a818B1BC34d502D3fE730Db729e62AC',
  strategy: '0xC662DeeFdFe47a00F880dC9411ff2398601B736C',
  demoToken: '0xdd3F1154aeA345273BEC8C779F5B5d7410ef00b5',
  weth: '0x4200000000000000000000000000000000000006',
  searcherExecutor: '0x410CbE7444605f5aF0F797A49c052b74ae955163',
  victimExecutor: '0x77d4695c60FE68533B6285B964060Bbc8FD4bC54',
  lpExecutor: '0x8a8B11fF7E337A7797B8D82fe34082aEfed5F1dF',
} as const satisfies Record<string, Address>

/**
 * The demo pool: native ETH / tbgUSD, 0.3% fee, tick spacing 60, hooked by
 * ThetaBGHook. Matches script/ConfigurePool.s.sol exactly.
 */
export const POOL_KEY = {
  currency0: '0x0000000000000000000000000000000000000000',
  currency1: addresses.demoToken,
  fee: 3000,
  tickSpacing: 60,
  hooks: addresses.hook,
} as const satisfies {
  currency0: Address
  currency1: Address
  fee: number
  tickSpacing: number
  hooks: Address
}

/** keccak256(abi.encode(POOL_KEY)) — v4's PoolId. Verified on-chain against hook.vaults(). */
export const POOL_ID = '0x88e48e003c9070f7076ef17e48f2067b5af6d2a5b4d2a35e14a873b186f957a3' as const

/** The seed liquidity position's range (script/ConfigurePool.s.sol). */
export const LP_TICK_LOWER = -6000
export const LP_TICK_UPPER = 6000

/** Block the hook was created in — the floor for any event scan. */
export const DEPLOY_BLOCK = 60976549n

export const EXPLORER = 'https://sepolia.uniscan.xyz'

export const explorerAddress = (a: string) => `${EXPLORER}/address/${a}`
export const explorerTx = (h: string) => `${EXPLORER}/tx/${h}`

/** The real demo sandwich recorded in DEPLOYMENT.md — shown on the Mechanism page. */
export const DEMO_SANDWICH = {
  frontRun: '0x2847228be3a9e333904a3f8f218931e3d37aba958024dceb2570bc583b06a7a0',
  victim: '0x3a4e0d080e000168bca841b9492329349a41da075703455e84741d9762b895ca',
  backRun: '0x6ee61686984a8064439147d037542b046c751f4ede847e58ea1725cc19d1686f',
  startSqrtPriceX96: 79228162514264337593543950336n,
  afterFrontRunSqrtPriceX96: 76273363393439562819944159143n,
  afterVictimSqrtPriceX96: 75336343392329472925829549405n,
  finalSqrtPriceX96: 79214546985066248574501645025n,
  displacementBps: 372.9,
  finalDeviationBps: 1.72,
  bondSlashed: 10000000000000000n,
  insuranceCut: 9000000000000000n,
  protocolCut: 1000000000000000n,
} as const
