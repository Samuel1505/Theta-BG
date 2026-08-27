import { useReadContract, useReadContracts } from 'wagmi'
import {
  addresses,
  erc20Abi,
  lpInsuranceVaultAbi,
  poolManagerAbi,
  searcherRegistryAbi,
  thetaBGHookAbi,
  POOL_ID,
} from '../config/contracts'
import { decodeSlot0, poolStateSlot } from '../lib/pool'

const hook = { address: addresses.hook, abi: thetaBGHookAbi } as const
const registry = { address: addresses.registry, abi: searcherRegistryAbi } as const
const vault = { address: addresses.vault, abi: lpInsuranceVaultAbi } as const

const POLL = 12_000

/** Immutable hook parameters + live protocol-fee balance. */
export function useProtocolConfig() {
  const q = useReadContracts({
    contracts: [
      { ...registry, functionName: 'minimumBond' },
      { ...registry, functionName: 'WITHDRAWAL_COOLDOWN' },
      { ...hook, functionName: 'restorationThresholdBps' },
      { ...hook, functionName: 'minDisplacementBps' },
      { ...hook, functionName: 'priorityFeeBps' },
      { ...hook, functionName: 'protocolShareBps' },
      { ...hook, functionName: 'BPS_DENOMINATOR' },
      { ...hook, functionName: 'protocolFeeRecipient' },
      { ...hook, functionName: 'pendingProtocolFees' },
    ],
    query: { refetchInterval: POLL },
  })

  const d = q.data
  return {
    ...q,
    config: d
      ? {
          minimumBond: d[0].result as bigint | undefined,
          withdrawalCooldown: d[1].result as bigint | undefined,
          restorationThresholdBps: d[2].result as bigint | undefined,
          minDisplacementBps: d[3].result as bigint | undefined,
          priorityFeeBps: d[4].result as bigint | undefined,
          protocolShareBps: d[5].result as bigint | undefined,
          bpsDenominator: d[6].result as bigint | undefined,
          protocolFeeRecipient: d[7].result as `0x${string}` | undefined,
          pendingProtocolFees: d[8].result as bigint | undefined,
        }
      : undefined,
  }
}

/** Self-compounding insurance vault accounting. */
export function useVaultStats() {
  const q = useReadContracts({
    contracts: [
      { ...vault, functionName: 'availableBalance' },
      { ...vault, functionName: 'principalDeposited' },
      { ...vault, functionName: 'idleAssets' },
      { ...vault, functionName: 'accInsurancePerLiquidityX128' },
    ],
    query: { refetchInterval: POLL },
  })
  const d = q.data
  return {
    ...q,
    stats: d
      ? {
          availableBalance: d[0].result as bigint | undefined,
          principalDeposited: d[1].result as bigint | undefined,
          idleAssets: d[2].result as bigint | undefined,
          accPerLiquidityX128: d[3].result as bigint | undefined,
        }
      : undefined,
  }
}

/** Live pool price + in-range liquidity, read straight from PoolManager storage. */
export function usePoolState() {
  const stateSlot = poolStateSlot(POOL_ID)
  const liquiditySlot = `0x${(BigInt(stateSlot) + 3n).toString(16).padStart(64, '0')}` as const

  const q = useReadContracts({
    contracts: [
      {
        address: addresses.poolManager,
        abi: poolManagerAbi,
        functionName: 'extsload',
        args: [stateSlot],
      },
      {
        address: addresses.poolManager,
        abi: poolManagerAbi,
        functionName: 'extsload',
        args: [liquiditySlot],
      },
    ],
    query: { refetchInterval: POLL },
  })

  const slot0Raw = q.data?.[0].result as `0x${string}` | undefined
  const liqRaw = q.data?.[1].result as `0x${string}` | undefined

  return {
    ...q,
    pool:
      slot0Raw !== undefined
        ? {
            slot0: decodeSlot0(BigInt(slot0Raw)),
            liquidity: liqRaw ? BigInt(liqRaw) & ((1n << 128n) - 1n) : undefined,
          }
        : undefined,
  }
}

export function useTokenMeta() {
  const q = useReadContracts({
    contracts: [
      { address: addresses.demoToken, abi: erc20Abi, functionName: 'symbol' },
      { address: addresses.demoToken, abi: erc20Abi, functionName: 'decimals' },
    ],
  })
  return {
    symbol: (q.data?.[0].result as string | undefined) ?? 'tbgUSD',
    decimals: (q.data?.[1].result as number | undefined) ?? 18,
  }
}

/** ETH balance held inside the vault as WETH principal in the demo strategy. */
export function useStrategyShares() {
  return useReadContract({
    address: addresses.strategy,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [addresses.vault],
    query: { refetchInterval: POLL },
  })
}
