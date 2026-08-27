import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { unichainSepolia } from 'wagmi/chains'
import { http } from 'wagmi'

/**
 * WalletConnect project id. Optional for injected/browser wallets (MetaMask,
 * Rabby, etc. work without it); only the WalletConnect QR path needs one.
 * Set VITE_WALLETCONNECT_PROJECT_ID in web/.env to enable it.
 */
const walletConnectProjectId =
  import.meta.env.VITE_WALLETCONNECT_PROJECT_ID ?? 'theta_bg_console_local'

const rpcUrl =
  import.meta.env.VITE_UNICHAIN_SEPOLIA_RPC_URL ?? 'https://sepolia.unichain.org'

export const wagmiConfig = getDefaultConfig({
  appName: 'Theta-BG Console',
  projectId: walletConnectProjectId,
  chains: [unichainSepolia],
  transports: {
    [unichainSepolia.id]: http(rpcUrl, { batch: true }),
  },
  ssr: false,
})

export { unichainSepolia }
