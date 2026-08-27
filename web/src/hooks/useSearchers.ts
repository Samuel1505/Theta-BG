import { useQuery } from '@tanstack/react-query'
import { useConfig, useReadContracts } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { getAbiItem, type AbiEvent, type Hex } from 'viem'
import { addresses, DEPLOY_BLOCK, searcherRegistryAbi } from '../config/contracts'
import { getLogsChunked } from '../lib/logs'

const registry = { address: addresses.registry, abi: searcherRegistryAbi } as const

export interface SearcherState {
  bond: bigint
  slashCount: number
  withdrawalUnlockTime: bigint
  registered: boolean
  requiredBond: bigint
  isActive: boolean
}

export function useSearcherState(address?: Hex) {
  const enabled = Boolean(address)
  const q = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...registry, functionName: 'searchers', args: [address ?? '0x0000000000000000000000000000000000000000'] },
      { ...registry, functionName: 'requiredBond', args: [address ?? '0x0000000000000000000000000000000000000000'] },
      { ...registry, functionName: 'isActiveSearcher', args: [address ?? '0x0000000000000000000000000000000000000000'] },
    ],
    query: { enabled, refetchInterval: 12_000 },
  })

  let state: SearcherState | undefined
  if (q.data) {
    const [s, requiredBond, isActive] = q.data as [
      readonly [bigint, number, bigint, boolean],
      bigint,
      boolean,
    ]
    state = {
      bond: s[0],
      slashCount: Number(s[1]),
      withdrawalUnlockTime: s[2],
      registered: s[3],
      requiredBond,
      isActive,
    }
  }
  return { ...q, state }
}

export interface SearcherRow extends SearcherState {
  address: Hex
  registeredAt?: number
}

export function useAllSearchers() {
  const config = useConfig()

  return useQuery({
    queryKey: ['all-searchers', addresses.registry],
    refetchInterval: 30_000,
    queryFn: async (): Promise<SearcherRow[]> => {
      const client = getPublicClient(config)
      if (!client) throw new Error('no client')
      const toBlock = await client.getBlockNumber()

      const logs = await getLogsChunked(config, {
        address: addresses.registry,
        event: getAbiItem({ abi: searcherRegistryAbi, name: 'SearcherRegistered' }) as AbiEvent,
        fromBlock: DEPLOY_BLOCK,
        toBlock,
      })

      const seen = new Map<Hex, bigint>()
      for (const l of logs) {
        const a = l.args as { searcher: Hex }
        if (!seen.has(a.searcher)) seen.set(a.searcher, l.blockNumber ?? 0n)
      }
      const list = [...seen.keys()]
      if (list.length === 0) return []

      const reads = await client.multicall({
        allowFailure: false,
        contracts: list.flatMap((addr) => [
          { ...registry, functionName: 'searchers', args: [addr] } as const,
          { ...registry, functionName: 'requiredBond', args: [addr] } as const,
          { ...registry, functionName: 'isActiveSearcher', args: [addr] } as const,
        ]),
      })

      const blockNums = [...new Set(seen.values())]
      const blocks = await Promise.all(
        blockNums.map((bn) => client.getBlock({ blockNumber: bn }).catch(() => null)),
      )
      const tsByBlock = new Map<bigint, number>()
      blockNums.forEach((bn, i) => {
        const b = blocks[i]
        if (b) tsByBlock.set(bn, Number(b.timestamp))
      })

      return list.map((addr, i) => {
        const s = reads[i * 3] as readonly [bigint, number, bigint, boolean]
        const requiredBond = reads[i * 3 + 1] as bigint
        const isActive = reads[i * 3 + 2] as boolean
        return {
          address: addr,
          bond: s[0],
          slashCount: Number(s[1]),
          withdrawalUnlockTime: s[2],
          registered: s[3],
          requiredBond,
          isActive,
          registeredAt: tsByBlock.get(seen.get(addr)!),
        }
      })
    },
  })
}
