import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { IconAlert, IconCheck, IconInfo } from './icons'

type ToastKind = 'success' | 'error' | 'info'

interface Toast {
  id: number
  kind: ToastKind
  title: string
  message?: ReactNode
}

interface ToastApi {
  push: (t: Omit<Toast, 'id'>) => number
  dismiss: (id: number) => void
}

const ToastContext = createContext<ToastApi | null>(null)

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const nextId = useRef(1)

  const dismiss = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id))
  }, [])

  const push = useCallback(
    (t: Omit<Toast, 'id'>) => {
      const id = nextId.current++
      setToasts((prev) => [...prev, { ...t, id }])
      if (t.kind !== 'error') {
        window.setTimeout(() => dismiss(id), 6500)
      } else {
        window.setTimeout(() => dismiss(id), 12000)
      }
      return id
    },
    [dismiss],
  )

  const api = useMemo(() => ({ push, dismiss }), [push, dismiss])

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="toasts">
        {toasts.map((t) => (
          <div key={t.id} className={`toast toast--${t.kind}`} onClick={() => dismiss(t.id)}>
            <span
              className="toast__icon"
              style={{
                color:
                  t.kind === 'success'
                    ? 'var(--accent)'
                    : t.kind === 'error'
                      ? 'var(--danger)'
                      : 'var(--info)',
              }}
            >
              {t.kind === 'success' ? (
                <IconCheck />
              ) : t.kind === 'error' ? (
                <IconAlert />
              ) : (
                <IconInfo />
              )}
            </span>
            <div>
              <div className="toast__title">{t.title}</div>
              {t.message ? <div className="toast__msg">{t.message}</div> : null}
            </div>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  )
}

// eslint-disable-next-line react-refresh/only-export-components
export function useToast(): ToastApi {
  const ctx = useContext(ToastContext)
  if (!ctx) throw new Error('useToast must be used within ToastProvider')
  return ctx
}
