import { createConfig, http } from 'wagmi'
import { arbitrumSepolia } from 'wagmi/chains'
import { connectorsForWallets } from '@rainbow-me/rainbowkit'
import {
  metaMaskWallet,
  coinbaseWallet,
  walletConnectWallet,
  rabbyWallet,
} from '@rainbow-me/rainbowkit/wallets'

const connectors = connectorsForWallets(
  [
    {
      groupName: 'Recommended',
      wallets: [metaMaskWallet, rabbyWallet, coinbaseWallet],
    },
    {
      groupName: 'More',
      wallets: [walletConnectWallet],
    },
  ],
  {
    appName: 'Baraka Protocol',
    projectId: 'baraka-protocol-testnet', // WalletConnect project ID (free)
  }
)

export const config = createConfig({
  chains: [arbitrumSepolia],
  connectors,
  transports: {
    [arbitrumSepolia.id]: http(
      process.env.NEXT_PUBLIC_ALCHEMY_RPC || 'https://arb-sepolia.g.alchemy.com/v2/<ALCHEMY_KEY>'
    ),
  },
})
