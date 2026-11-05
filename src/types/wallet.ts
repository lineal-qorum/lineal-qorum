import { PublicClient } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createBundlerClient } from 'viem/account-abstraction';
import { createWalletClient } from 'viem';

export type EOAAccount = ReturnType<typeof privateKeyToAccount>;
export type BundlerClient = ReturnType<typeof createBundlerClient>;
export type WalletClient = ReturnType<typeof createWalletClient>;

export interface ConnectedWallet {
  smartAccount: any;
  eoaAccount: EOAAccount;
  publicClient: PublicClient;
  walletClient: WalletClient;
  bundlerClient: BundlerClient;
  exists: boolean;
  isDeployed: boolean;
  eoaAddress: string;
  smartAccountAddress: string;
}

export interface Web3AuthProvider {
  request: (params: { method: string }) => Promise<string>;
}

export interface Web3AuthConnectResult {
  provider: Web3AuthProvider;
}

export interface Web3AuthConfig {
  VERIFIER_NAME: string;
  BUNDLER_URL: string;
  WEB3AUTH_CLIENT_ID: string;
  web3AuthNetwork: string;
}
