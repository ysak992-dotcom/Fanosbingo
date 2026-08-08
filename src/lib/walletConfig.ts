import { createAppKit } from '@reown/appkit/react'
import { WagmiAdapter } from '@reown/appkit-adapter-wagmi'
import { bsc, bscTestnet } from 'viem/chains'
import { QueryClient } from '@tanstack/react-query'

const projectId = import.meta.env.VITE_REOWN_PROJECT_ID || 'YOUR_PROJECT_ID'

/**
 * WHICH CHAIN THIS BUILD TALKS TO.
 *
 * This file used to `import { bsc }` and hardcode `networks: [bsc]`. `bsc` is
 * chain 56 -- BNB Smart Chain MAINNET -- in every build, including dev.
 *
 * Everything on the server side of dev is testnet: SSM publishes chain_id 97, the
 * RPC is data-seed-prebsc, and the functions service verifies the RPC's chain id
 * against SSM at boot and refuses to start on a mismatch. Only the wallet the
 * PLAYER connects with was pointed somewhere else.
 *
 * The consequence would have arrived at contract-deployment time, not before.
 * Deploy to testnet 97, publish the address, and a player's wallet -- connected to
 * mainnet -- is handed a contract address that exists only on testnet. On mainnet
 * that address holds no code and nobody holds its key, because it is a CREATE
 * address derived from deployer and nonce. Real BNB sent there is not stuck, it is
 * gone.
 *
 * services/functions/src/index.js warns about exactly this class of thing:
 * "the day something signs from the wrong one, the mistake is silent on testnet
 * and expensive on mainnet". Here the direction is reversed -- the app on mainnet,
 * the contract on testnet -- and the loss lands on players rather than on us.
 *
 * SOURCED FROM THE BUILD, NOT FROM THE `settings` TABLE, deliberately. VITE_
 * variables are compile-time and the deploy workflow reads this one from the same
 * SSM parameter Terraform writes and the backend reads, so all three agree by
 * construction. `settings` is application data that admin UI can write, and the
 * functions service is explicit that it must never decide what a transaction
 * commits to. `settings.deposit_contract_chain_id` currently says 56 in dev, which
 * is precisely why it is not consulted here.
 *
 * DEFAULTS TO TESTNET. If the variable is missing or malformed the safe failure is
 * a build that cannot touch real money, not one that can.
 */
const CHAIN_BY_ID = { 56: bsc, 97: bscTestnet } as const

const rawChainId = import.meta.env.VITE_BSC_CHAIN_ID
const parsedChainId = Number(rawChainId)
const activeChain = CHAIN_BY_ID[parsedChainId as keyof typeof CHAIN_BY_ID] ?? bscTestnet

if (!CHAIN_BY_ID[parsedChainId as keyof typeof CHAIN_BY_ID]) {
  // Loud, because silently defaulting is how the original problem survived. A
  // build that meant to be mainnet and fell back to testnet should be obvious.
  console.warn(
    `[walletConfig] VITE_BSC_CHAIN_ID is ${JSON.stringify(rawChainId)}; ` +
      `expected "56" or "97". Falling back to BSC testnet (97).`,
  )
}

export const ACTIVE_CHAIN = activeChain
export const ACTIVE_CHAIN_ID = activeChain.id

export const wagmiAdapter = new WagmiAdapter({
  networks: [activeChain],
  projectId,
  ssr: false
})

export const queryClient = new QueryClient()

export const modal = createAppKit({
  adapters: [wagmiAdapter],
  networks: [activeChain],
  projectId,
  features: {
    analytics: false,
  },
  metadata: {
    name: 'BingoNovaa',
    description: 'Multiplayer Bingo Game with BNB Payments',
    url: import.meta.env.VITE_APP_URL || 'https://fanosbingo.com',
    icons: ['https://fanosbingo.com/icon.png']
  }
})

export const config = wagmiAdapter.wagmiConfig

export const DEPOSIT_CONTRACT_ABI = [
  {
    "inputs": [{"internalType": "address", "name": "user", "type": "address"}, {"internalType": "uint256", "name": "amount", "type": "uint256"}],
    "name": "addWinCredits",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [{"internalType": "uint256", "name": "amount", "type": "uint256"}],
    "name": "withdraw",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [{"internalType": "address", "name": "", "type": "address"}],
    "name": "credits",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getContractBalance",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "minWithdraw",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "maxDaily",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "maxWeekly",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"internalType": "address", "name": "user", "type": "address"}],
    "name": "getRemainingLimits",
    "outputs": [
      {"internalType": "uint256", "name": "dailyRemaining", "type": "uint256"},
      {"internalType": "uint256", "name": "weeklyRemaining", "type": "uint256"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"internalType": "address", "name": "", "type": "address"}],
    "name": "dailyWithdrawn",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"internalType": "address", "name": "", "type": "address"}],
    "name": "weeklyWithdrawn",
    "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"internalType": "string", "name": "userId", "type": "string"}],
    "name": "deposit",
    "outputs": [],
    "stateMutability": "payable",
    "type": "function"
  }
] as const
