import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useAccount, useSwitchChain, useWaitForTransactionReceipt, useWriteContract } from 'wagmi'
import { BaseError, type Abi } from 'viem'
import { useConnectModal } from '@rainbow-me/rainbowkit'
import { CHAIN_ID, explorerTx } from '../config/contracts'
import { useToast } from './Toast'

interface TxRequest {
  address: `0x${string}`
  abi: Abi
  functionName: string
  args?: readonly unknown[]
  value?: bigint
}

export function TxButton({
  request,
  children,
  variant = 'primary',
  size,
  block,
  disabled,
  disabledReason,
  successTitle = 'Confirmed',
  pendingLabel = 'Confirm in wallet…',
  onConfirmed,
}: {
  request: () => TxRequest | null
  children: ReactNode
  variant?: 'primary' | 'danger' | 'ghost' | 'default'
  size?: 'sm'
  block?: boolean
  disabled?: boolean
  disabledReason?: string
  successTitle?: string
  pendingLabel?: ReactNode
  onConfirmed?: () => void
}) {
  const { isConnected, chainId } = useAccount()
  const { openConnectModal } = useConnectModal()
  const { switchChain } = useSwitchChain()
  const toast = useToast()
  const { writeContract, data: hash, isPending, reset } = useWriteContract()
  const [submitting, setSubmitting] = useState(false)
  const notified = useRef<string | null>(null)

  const { isLoading: isMining, isSuccess, isError, error: waitError } =
    useWaitForTransactionReceipt({ hash })

  useEffect(() => {
    if (isSuccess && hash && notified.current !== hash) {
      notified.current = hash
      setSubmitting(false)
      toast.push({
        kind: 'success',
        title: successTitle,
        message: (
          <a href={explorerTx(hash)} target="_blank" rel="noreferrer">
            View transaction ↗
          </a>
        ),
      })
      onConfirmed?.()
      reset()
    }
  }, [isSuccess, hash, toast, successTitle, onConfirmed, reset])

  useEffect(() => {
    if (isError && hash && notified.current !== hash) {
      notified.current = hash
      setSubmitting(false)
      toast.push({ kind: 'error', title: 'Transaction reverted', message: friendly(waitError) })
      reset()
    }
  }, [isError, hash, waitError, toast, reset])

  const wrongChain = isConnected && chainId !== CHAIN_ID
  const busy = submitting || isPending || isMining

  const onClick = () => {
    if (!isConnected) {
      openConnectModal?.()
      return
    }
    if (wrongChain) {
      switchChain({ chainId: CHAIN_ID })
      return
    }
    const req = request()
    if (!req) return
    setSubmitting(true)
    notified.current = null
    writeContract(req, {
      onError: (err) => {
        setSubmitting(false)
        toast.push({ kind: 'error', title: 'Could not submit', message: friendly(err) })
      },
    })
  }

  const label: ReactNode = !isConnected
    ? 'Connect wallet'
    : wrongChain
      ? 'Switch to Unichain Sepolia'
      : busy
        ? isMining
          ? 'Waiting for confirmation…'
          : pendingLabel
        : children

  const cls = [
    'btn',
    variant === 'primary' && 'btn--primary',
    variant === 'danger' && 'btn--danger',
    variant === 'ghost' && 'btn--ghost',
    size === 'sm' && 'btn--sm',
    block && 'btn--block',
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <button
      className={cls}
      onClick={onClick}
      disabled={busy || (isConnected && !wrongChain && disabled)}
      title={disabled ? disabledReason : undefined}
    >
      {busy ? <span className="btn__spinner" /> : null}
      {label}
    </button>
  )
}

function friendly(err: unknown): string {
  if (!err) return 'Unknown error'
  if (err instanceof BaseError) {
    const short = err.shortMessage || err.message
    if (/User rejected|User denied/i.test(short)) return 'You rejected the request.'
    return short
  }
  if (err instanceof Error) return err.message
  return String(err)
}
