import { useQuery } from '@tanstack/react-query'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { getAbiItem, type Abi, type AbiEvent, type Hex } from 'viem'
import {
  addresses,
  DEPLOY_BLOCK,
  lpInsuranceVaultAbi,
  searcherRegistryAbi,
  thetaBGHookAbi,
  POOL_ID,
} from '../config/contracts'
import { getLogsChunked } from '../lib/logs'

export type ActivityKind =
  | 'slash'
  | 'searcher-registered'
  | 'bond-topped-up'
  | 'withdrawal-requested'
  | 'withdrawal'
  | 'priority-fee'
  | 'insurance-funded'
  | 'insurance-claimed'

export interface ActivityEvent {
  kind: ActivityKind
  blockNumber: bigint
  txHash: Hex
  logIndex: number
  timestamp?: number
  /** primary actor address, when the event has one */
  actor?: Hex
  /** secondary address (victim, LP owner) */
  counterparty?: Hex
  /** primary ETH/asset amount in wei, when relevant */
  amount?: bigint
  extra?: Record<string, bigint | string>
}

const ev = (abi: Abi, name: string) => getAbiItem({ abi, name }) as AbiEvent

export function useActivity() {
  const config = useConfig()

  return useQuery({
    queryKey: ['activity', addresses.hook],
    refetchInterval: 20_000,
    queryFn: async (): Promise<ActivityEvent[]> => {
      const client = getPublicClient(config)
      if (!client) throw new Error('no client')
      const toBlock = await client.getBlockNumber()

      const [slashes, registered, toppedUp, wRequested, withdrawn, priorityFees, funded, claimed] =
        await Promise.all([
          getLogsChunked(config, {
            address: addresses.hook,
            event: ev(thetaBGHookAbi, 'SandwichSlashed'),
            args: { poolId: POOL_ID },
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
          getLogsChunked(config, {
            address: addresses.registry,
            event: ev(searcherRegistryAbi, 'SearcherRegistered'),
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
          getLogsChunked(config, {
            address: addresses.registry,
            event: ev(searcherRegistryAbi, 'BondToppedUp'),
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
          getLogsChunked(config, {
            address: addresses.registry,
            event: ev(searcherRegistryAbi, 'WithdrawalRequested'),
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
          getLogsChunked(config, {
            address: addresses.registry,
            event: ev(searcherRegistryAbi, 'Withdrawn'),
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
          getLogsChunked(config, {
            address: addresses.hook,
            event: ev(thetaBGHookAbi, 'PriorityFeeCollected'),
            args: { poolId: POOL_ID },
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
          getLogsChunked(config, {
            address: addresses.vault,
            event: ev(lpInsuranceVaultAbi, 'InsuranceFunded'),
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
          getLogsChunked(config, {
            address: addresses.vault,
            event: ev(lpInsuranceVaultAbi, 'LPInsuranceClaimed'),
            fromBlock: DEPLOY_BLOCK,
            toBlock,
          }),
        ])

      const out: ActivityEvent[] = []
      const common = (l: { blockNumber: bigint | null; transactionHash: Hex | null; logIndex: number | null }) => ({
        blockNumber: l.blockNumber ?? 0n,
        txHash: (l.transactionHash ?? '0x') as Hex,
        logIndex: l.logIndex ?? 0,
      })

      for (const l of slashes) {
        const a = l.args as { searcher: Hex; victim: Hex; totalSlashed: bigint; protocolCut: bigint; insuranceCut: bigint }
        out.push({
          kind: 'slash',
          ...common(l),
          actor: a.searcher,
          counterparty: a.victim,
          amount: a.totalSlashed,
          extra: { protocolCut: a.protocolCut, insuranceCut: a.insuranceCut },
        })
      }
      for (const l of registered) {
        const a = l.args as { searcher: Hex; bond: bigint }
        out.push({ kind: 'searcher-registered', ...common(l), actor: a.searcher, amount: a.bond })
      }
      for (const l of toppedUp) {
        const a = l.args as { searcher: Hex; amount: bigint; newBond: bigint }
        out.push({ kind: 'bond-topped-up', ...common(l), actor: a.searcher, amount: a.amount, extra: { newBond: a.newBond } })
      }
      for (const l of wRequested) {
        const a = l.args as { searcher: Hex; unlockTime: bigint }
        out.push({ kind: 'withdrawal-requested', ...common(l), actor: a.searcher, extra: { unlockTime: a.unlockTime } })
      }
      for (const l of withdrawn) {
        const a = l.args as { searcher: Hex; amount: bigint }
        out.push({ kind: 'withdrawal', ...common(l), actor: a.searcher, amount: a.amount })
      }
      for (const l of priorityFees) {
        const a = l.args as { searcher: Hex; currency: Hex; amount: bigint }
        out.push({ kind: 'priority-fee', ...common(l), actor: a.searcher, amount: a.amount, extra: { currency: a.currency } })
      }
      for (const l of funded) {
        const a = l.args as { assetsIn: bigint; eligibleLiquidityAtSlash?: bigint; activeLiquidityAtSlash?: bigint }
        out.push({
          kind: 'insurance-funded',
          ...common(l),
          amount: a.assetsIn,
          extra: { liquidity: a.eligibleLiquidityAtSlash ?? a.activeLiquidityAtSlash ?? 0n },
        })
      }
      for (const l of claimed) {
        const a = l.args as { owner: Hex; amount: bigint }
        out.push({ kind: 'insurance-claimed', ...common(l), actor: a.owner, amount: a.amount })
      }

      // enrich with block timestamps
      const uniqueBlocks = [...new Set(out.map((e) => e.blockNumber))]
      const blocks = await Promise.all(
        uniqueBlocks.map((bn) => client.getBlock({ blockNumber: bn }).catch(() => null)),
      )
      const tsByBlock = new Map<bigint, number>()
      uniqueBlocks.forEach((bn, i) => {
        const b = blocks[i]
        if (b) tsByBlock.set(bn, Number(b.timestamp))
      })
      for (const e of out) e.timestamp = tsByBlock.get(e.blockNumber)

      return out.sort((a, b) =>
        a.blockNumber === b.blockNumber
          ? b.logIndex - a.logIndex
          : Number(b.blockNumber - a.blockNumber),
      )
    },
  })
}
