import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { formatEther, parseEther, type Hex } from 'viem'
import { addresses, searcherRegistryAbi } from '../config/contracts'
import { useSearcherState, useAllSearchers } from '../hooks/useSearchers'
import { Card, Stat, KV, KVRow, Address, Tag, Callout, Empty } from '../components/primitives'
import { TxButton } from '../components/TxButton'
import { IconInfo, IconShield } from '../components/icons'
import { useProtocolConfig } from '../hooks/useProtocol'
import { formatEth, formatDuration, formatCount } from '../lib/format'

function useCountdown(unlockTime?: bigint) {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  useEffect(() => {
    const id = window.setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => window.clearInterval(id)
  }, [])
  if (!unlockTime || unlockTime === 0n) return null
  const remaining = Number(unlockTime) - now
  return remaining
}

function parseEthSafe(v: string): bigint | null {
  try {
    if (!v.trim()) return null
    const n = parseEther(v.trim() as `${number}`)
    return n > 0n ? n : null
  } catch {
    return null
  }
}

export function Searchers() {
  const { address, isConnected } = useAccount()
  const { state, refetch } = useSearcherState(address as Hex | undefined)
  const { config } = useProtocolConfig()
  const all = useAllSearchers()

  // null = the user hasn't typed anything; fall back to the required bond.
  const [registerAmtRaw, setRegisterAmt] = useState<string | null>(null)
  const [topUpAmt, setTopUpAmt] = useState('')
  const registerAmt =
    registerAmtRaw ?? (state?.requiredBond ? formatEther(state.requiredBond) : '')

  const remaining = useCountdown(state?.withdrawalUnlockTime)
  const withdrawalPending = Boolean(state?.withdrawalUnlockTime && state.withdrawalUnlockTime !== 0n)
  const canWithdrawNow = withdrawalPending && remaining !== null && remaining <= 0

  const registerValue = parseEthSafe(registerAmt)
  const topUpValue = parseEthSafe(topUpAmt)
  const registerTooLow =
    registerValue !== null && state?.requiredBond !== undefined && registerValue < state.requiredBond

  const onDone = () => {
    refetch()
    all.refetch()
    setTopUpAmt('')
  }

  return (
    <>
      <div className="grid grid--stats">
        <Stat
          label="Your bond"
          value={isConnected ? formatEth(state?.bond) : '—'}
          unit="ETH"
          sub={
            !isConnected
              ? 'connect to view'
              : state?.registered
                ? state.isActive
                  ? 'active'
                  : 'below required — inactive'
                : 'not registered'
          }
          tone={state?.isActive ? 'accent' : undefined}
          loading={isConnected && !state}
        />
        <Stat
          label="Required bond"
          value={formatEth(state?.requiredBond ?? config?.minimumBond)}
          unit="ETH"
          sub={state && state.slashCount > 0 ? `2× base (${state.slashCount} slash${state.slashCount > 1 ? 'es' : ''})` : 'base rate'}
          loading={!config}
        />
        <Stat
          label="Your slash count"
          value={isConnected ? (state?.slashCount ?? '—') : '—'}
          sub="permanent on the registry"
          tone={state && state.slashCount > 0 ? 'danger' : undefined}
          loading={isConnected && !state}
        />
        <Stat
          label="Registered searchers"
          value={formatCount(all.data?.length)}
          sub={`${all.data?.filter((s) => s.isActive).length ?? '—'} currently active`}
          loading={all.isLoading}
        />
      </div>

      <div className="grid grid--2">
        <Card title="Your searcher position" subtitle={address ? undefined : 'Wallet not connected'}>
          {!isConnected ? (
            <Empty>Connect a wallet to post or manage a bond.</Empty>
          ) : !state ? (
            <div className="empty">Loading your registry entry…</div>
          ) : (
            <div className="stack">
              <KV>
                <KVRow k="Status">
                  {state.registered ? (
                    state.isActive ? (
                      <Tag tone="accent" dot>
                        Active
                      </Tag>
                    ) : (
                      <Tag tone="warn" dot>
                        Registered · underfunded
                      </Tag>
                    )
                  ) : (
                    <Tag dot>Not registered</Tag>
                  )}
                </KVRow>
                <KVRow k="Bond posted">{formatEth(state.bond)} ETH</KVRow>
                <KVRow k="Required to stay active">{formatEth(state.requiredBond)} ETH</KVRow>
                <KVRow k="Withdrawal">
                  {!withdrawalPending ? (
                    <span className="muted">none</span>
                  ) : canWithdrawNow ? (
                    <Tag tone="accent">Unlocked</Tag>
                  ) : (
                    <Tag tone="warn">unlocks in {formatDuration(Math.max(0, remaining ?? 0))}</Tag>
                  )}
                </KVRow>
              </KV>

              {!state.registered ? (
                <div className="stack" style={{ gap: 10 }}>
                  <div className="field">
                    <label className="field__label">Bond amount (ETH)</label>
                    <input
                      className="input"
                      inputMode="decimal"
                      value={registerAmt}
                      onChange={(e) => setRegisterAmt(e.target.value)}
                      placeholder={state.requiredBond ? formatEther(state.requiredBond) : '0.01'}
                    />
                    <span className="field__hint">
                      Must be ≥ {formatEth(state.requiredBond)} ETH. Posted in native ETH.
                    </span>
                  </div>
                  <TxButton
                    block
                    disabled={!registerValue || registerTooLow}
                    disabledReason={registerTooLow ? 'Below the required bond' : 'Enter an amount'}
                    successTitle="Registered as a searcher"
                    onConfirmed={onDone}
                    request={() =>
                      registerValue
                        ? {
                            address: addresses.registry,
                            abi: searcherRegistryAbi,
                            functionName: 'register',
                            value: registerValue,
                          }
                        : null
                    }
                  >
                    Register &amp; post bond
                  </TxButton>
                </div>
              ) : (
                <div className="stack" style={{ gap: 10 }}>
                  <div className="field">
                    <label className="field__label">Top up bond (ETH)</label>
                    <div className="input-group">
                      <input
                        className="input"
                        inputMode="decimal"
                        value={topUpAmt}
                        onChange={(e) => setTopUpAmt(e.target.value)}
                        placeholder="0.01"
                      />
                      <TxButton
                        disabled={!topUpValue}
                        disabledReason="Enter an amount"
                        successTitle="Bond topped up"
                        onConfirmed={onDone}
                        request={() =>
                          topUpValue
                            ? {
                                address: addresses.registry,
                                abi: searcherRegistryAbi,
                                functionName: 'topUpBond',
                                value: topUpValue,
                              }
                            : null
                        }
                      >
                        Top up
                      </TxButton>
                    </div>
                  </div>

                  <div className="divider" />

                  {!withdrawalPending ? (
                    <TxButton
                      block
                      variant="ghost"
                      successTitle="Withdrawal cooldown started"
                      pendingLabel="Requesting…"
                      onConfirmed={onDone}
                      request={() => ({
                        address: addresses.registry,
                        abi: searcherRegistryAbi,
                        functionName: 'requestWithdrawal',
                      })}
                    >
                      Request withdrawal (starts 24h cooldown)
                    </TxButton>
                  ) : (
                    <div className="row" style={{ gap: 8 }}>
                      <TxButton
                        variant="danger"
                        disabled={!canWithdrawNow}
                        disabledReason="Cooldown has not elapsed"
                        successTitle="Bond withdrawn"
                        pendingLabel="Withdrawing…"
                        onConfirmed={onDone}
                        request={() => ({
                          address: addresses.registry,
                          abi: searcherRegistryAbi,
                          functionName: 'withdraw',
                        })}
                      >
                        {canWithdrawNow
                          ? `Withdraw ${formatEth(state.bond)} ETH`
                          : `Locked · ${formatDuration(Math.max(0, remaining ?? 0))}`}
                      </TxButton>
                      <TxButton
                        variant="ghost"
                        successTitle="Withdrawal cancelled"
                        pendingLabel="Cancelling…"
                        onConfirmed={onDone}
                        request={() => ({
                          address: addresses.registry,
                          abi: searcherRegistryAbi,
                          functionName: 'cancelWithdrawal',
                        })}
                      >
                        Cancel
                      </TxButton>
                    </div>
                  )}
                </div>
              )}
            </div>
          )}
        </Card>

        <Card title="What bonding buys" subtitle="And what it risks">
          <div className="stack">
            <Callout tone="neutral" icon={<IconShield />}>
              A bonded, active searcher gets a priority-fee lane on exact-input swaps —{' '}
              {config?.priorityFeeBps ? Number(config.priorityFeeBps) / 100 : 0.05}% of the input
              is donated to in-range LPs through v4's own fee accounting. In exchange, the{' '}
              <strong>entire bond</strong> is slashed if the hook detects a same-block sandwich
              bracketed by this searcher.
            </Callout>
            <Callout tone="warn" icon={<IconInfo />}>
              Searcher identity is the <em>direct</em> caller of{' '}
              <code>PoolManager.swap()</code>. In practice that's a searcher's own contract — an
              EOA can't implement the unlock callback. Registering from a plain wallet here is
              fine for trying the bond lifecycle, but only a contract can actually trade the
              lane.
            </Callout>
            <KV>
              <KVRow k="Base bond">{formatEth(config?.minimumBond)} ETH</KVRow>
              <KVRow k="After first slash">
                {config?.minimumBond ? formatEth(config.minimumBond * 2n) : '—'} ETH (flat 2×)
              </KVRow>
              <KVRow k="Withdrawal cooldown">
                {config?.withdrawalCooldown ? formatDuration(config.withdrawalCooldown) : '—'}
              </KVRow>
              <KVRow k="Slash goes to">
                {config?.protocolShareBps ? Number(config.protocolShareBps) / 100 : 10}% protocol ·
                rest to LP vault
              </KVRow>
            </KV>
          </div>
        </Card>
      </div>

      <Card title="All registered searchers" subtitle="Everyone who has ever bonded on this registry" flush>
        {all.isLoading ? (
          <div className="empty">Scanning registry events…</div>
        ) : !all.data || all.data.length === 0 ? (
          <Empty>No searchers have registered yet.</Empty>
        ) : (
          <div className="table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Searcher</th>
                  <th>Bond</th>
                  <th>Required</th>
                  <th>Slashes</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {[...all.data]
                  .sort((a, b) => (b.bond > a.bond ? 1 : b.bond < a.bond ? -1 : 0))
                  .map((s) => (
                    <tr key={s.address}>
                      <td>
                        <Address address={s.address} />
                        {address && s.address.toLowerCase() === address.toLowerCase() ? (
                          <Tag tone="info">you</Tag>
                        ) : null}
                      </td>
                      <td className="num">{formatEth(s.bond)} ETH</td>
                      <td className="num">{formatEth(s.requiredBond)} ETH</td>
                      <td className="num">{s.slashCount > 0 ? <span className="danger">{s.slashCount}</span> : 0}</td>
                      <td>
                        {!s.registered ? (
                          <Tag>withdrawn</Tag>
                        ) : s.isActive ? (
                          <Tag tone="accent" dot>
                            active
                          </Tag>
                        ) : (
                          <Tag tone="warn" dot>
                            underfunded
                          </Tag>
                        )}
                      </td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </>
  )
}
