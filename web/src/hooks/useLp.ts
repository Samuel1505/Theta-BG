import { useQuery } from '@tanstack/react-query'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import {
  encodePacked,
  getAbiItem,
  keccak256,
  type AbiEvent,
  type Hex,
} from 'viem'
import {
  addresses,
  DEPLOY_BLOCK,
  lpInsuranceVaultAbi,
  poolManagerAbi,
  POOL_ID,
} from '../config/contracts'
import { getLogsChunked } from '../lib/logs'

const vault = { address: addresses.vault, abi: lpInsuranceVaultAbi } as const

export interface LpPosition {
  owner: Hex
  tickLower: number
  tickUpper: number
  salt: Hex
  /** net liquidity units summed from every ModifyLiquidity by this owner on this range */
  liquidity: bigint
  claimable: bigint
  owed: bigint
}

function positionKey(owner: Hex, tickLower: number, tickUpper: number, salt: Hex): Hex {
  return keccak256(
    encodePacked(['address', 'int24', 'int24', 'bytes32'], [owner, tickLower, tickUpper, salt]),
  )
}

async function loadPositions(config: ReturnType<typeof useConfig>, owner: Hex): Promise<LpPosition[]> {
  const client = getPublicClient(config)
  if (!client) throw new Error('no client')
  const toBlock = await client.getBlockNumber()

  const logs = await getLogsChunked(config, {
    address: addresses.poolManager,
    event: getAbiItem({ abi: poolManagerAbi, name: 'ModifyLiquidity' }) as AbiEvent,
    args: { id: POOL_ID, sender: owner },
    fromBlock: DEPLOY_BLOCK,
    toBlock,
  })

  const byRange = new Map<string, LpPosition>()
  for (const l of logs) {
    const a = l.args as {
      tickLower: number
      tickUpper: number
      liquidityDelta: bigint
      salt: Hex
    }
    const k = `${a.tickLower}:${a.tickUpper}:${a.salt}`
    const cur =
      byRange.get(k) ??
      ({
        owner,
        tickLower: a.tickLower,
        tickUpper: a.tickUpper,
        salt: a.salt,
        liquidity: 0n,
        claimable: 0n,
        owed: 0n,
      } satisfies LpPosition)
    cur.liquidity += a.liquidityDelta
    byRange.set(k, cur)
  }

  const positions = [...byRange.values()]
  if (positions.length === 0) return []

  const reads = await client.multicall({
    allowFailure: true,
    contracts: positions.flatMap((p) => [
      {
        ...vault,
        functionName: 'claimable',
        args: [p.owner, p.tickLower, p.tickUpper, p.salt],
      } as const,
      {
        ...vault,
        functionName: 'positions',
        args: [positionKey(p.owner, p.tickLower, p.tickUpper, p.salt)],
      } as const,
    ]),
  })

  positions.forEach((p, i) => {
    const claimable = reads[i * 2]
    const posInfo = reads[i * 2 + 1]
    if (claimable.status === 'success') p.claimable = claimable.result as bigint
    if (posInfo.status === 'success') {
      const r = posInfo.result as readonly bigint[]
      // Deployed vault's PositionInfo getter returns [rewardDebtX128, owed].
      p.owed = r[1] ?? 0n
    }
  })

  return positions
}

export function useLpPositions(owner?: Hex) {
  const config = useConfig()
  return useQuery({
    queryKey: ['lp-positions', owner],
    enabled: Boolean(owner),
    refetchInterval: 15_000,
    queryFn: () => loadPositions(config, owner as Hex),
  })
}

/** The seeded demo LP position — always shown on the Vault page as a worked example. */
export function useDemoLpPosition() {
  const config = useConfig()
  return useQuery({
    queryKey: ['lp-positions', 'demo', addresses.lpExecutor],
    refetchInterval: 30_000,
    queryFn: () => loadPositions(config, addresses.lpExecutor),
  })
}
