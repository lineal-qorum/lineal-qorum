import { Logger } from '@nestjs/common';
import {
  toMetaMaskSmartAccount,
  Implementation,
  type ToMetaMaskSmartAccountReturnType,
} from '@metamask/smart-accounts-kit';
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  type PublicClient,
  toHex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createBundlerClient } from 'viem/account-abstraction';
import { baseSepolia } from 'viem/chains';
import { Web3Auth } from '@web3auth/node-sdk';
import {
  ConnectedWallet,
  type WalletClient,
  type BundlerClient,
  type EOAAccount,
  Web3AuthConnectResult, Web3AuthConfig,
} from '../types';
import { web3AuthConfig } from "./config";
import Token from './token.ts';

export class ServerWallet {
  private serverId: string;
  private isInitialized = false;
  private serverWallet: ConnectedWallet;
  private serverSmartAccount: ToMetaMaskSmartAccountReturnType<Implementation.Hybrid>;
  private serverEoaAccount: EOAAccount;
  private serverBundlerClient: BundlerClient;
  private serverWalletClient: WalletClient;
  private serverPublicClient: PublicClient;
  private serverWalletPublicInfo;
  private isDeployed: boolean;
  private readonly logger = new Logger(ServerWallet.name);
  private web3auth: Web3Auth;
  private config: Web3AuthConfig;
  private readonly tokenService: Token = new Token();

  constructor() {
    this.config = web3AuthConfig;
  }

  /**
   * Initialize Web3Auth connection.
   * Called from main.ts AFTER app.listen() to ensure JWKS endpoint is available.
   */
  async initializeWeb3Auth(serverId: string): Promise<void> {
    if (this.isInitialized) {
      this.logger.log('Web3Auth already initialized');
      return;
    }

    this.serverId = serverId;
    this.logger.log(`🚀 Initializing wallet for ID: ${this.serverId}`);

    this.web3auth = new Web3Auth({
      clientId: this.config.WEB3AUTH_CLIENT_ID,
      web3AuthNetwork: 'sapphire_devnet',
    });

    // Initialize Web3Auth before connecting
    await this.web3auth.init();

    this.logger.log(
        'Server is listening. Initializing Web3Auth wallet connection...',
    );
    await this._delay(500);

    await this._ensureWalletConnectionWithRetry();
  }

  private _delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  private async _ensureWalletConnectionWithRetry(
      maxRetries = 3,
  ): Promise<void> {
    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        await this._ensureWalletConnection();
        return;
      } catch (error) {
        this.logger.warn(
            `Web3Auth connection attempt ${attempt}/${maxRetries} failed: ${error.message}`,
        );
        if (attempt < maxRetries) {
          const delayMs = attempt * 2000; // 2s, 4s, 6s
          this.logger.log(`Retrying in ${delayMs / 1000} seconds...`);
          await this._delay(delayMs);
        } else {
          this.logger.error('All Web3Auth connection attempts failed');
          throw error;
        }
      }
    }
  }

  private async connectWallet(tokenId: string) {
    const token: string = await this.tokenService.getWalletToken(tokenId);
    let smartAccount;
    const result = (await this.web3auth.connect({
      idToken: token,
      authConnectionId: this.config.VERIFIER_NAME,
    })) as Web3AuthConnectResult;

    const privateKeyHex = await result.provider.request({
      method: 'private_key',
    });

    const eoaAccount = privateKeyToAccount(`0x${privateKeyHex}`);

    const publicClient = this._initCreatePublicClient();
    const walletClient = createWalletClient({
      account: eoaAccount,
      chain: baseSepolia,
      transport: http(),
    });
    const bundlerClient = createBundlerClient({
      client: publicClient,
      transport: http(this.config.BUNDLER_URL),
      chain: baseSepolia,
    });
    const salt = keccak256(toHex(tokenId));

    // Primero calculamos la dirección counterfactual
    const counterfactualSmartAccount = await toMetaMaskSmartAccount({
      client: publicClient,
      implementation: Implementation.Hybrid,
      deployParams: [eoaAccount.address, [], [], []],
      deploySalt: salt,
      signer: { account: eoaAccount },
    });

    const address: `0x${string}` = counterfactualSmartAccount?.address;

    // Verificar si ya está desplegada
    const code = (await publicClient.getCode({
      address: address,
    })) as `0x${string}`;

    const _isDeployed = code && code !== '0x';

    if (_isDeployed) {
      // Si ya está desplegada, usar la opción address para evitar incluir initCode
      this.logger.log(
          `📍 SmartAccount ${counterfactualSmartAccount.address} ya desplegada, creando instancia sin initCode...`,
      );
      smartAccount = await toMetaMaskSmartAccount({
        client: publicClient,
        implementation: Implementation.Hybrid,
        address: counterfactualSmartAccount.address,
        signer: { account: eoaAccount },
      });
    } else {
      smartAccount = counterfactualSmartAccount;
    }
    const wallet = {
      isDeployed: _isDeployed,
      exists: true,
      smartAccount: smartAccount,
      publicClient: publicClient,
      bundlerClient: bundlerClient,
      walletClient: walletClient,
      eoaAccount: eoaAccount,
      eoaAddress: eoaAccount.address,
      smartAccountAddress: smartAccount.address,
    };
    const walletPublicInfo = {
      eoaAddress: eoaAccount.address,
      smartAccountAddress: smartAccount.address,
    };
    this.isInitialized = true;

    return {
      walletInfo: wallet,
      serverWalletPublicInfo: walletPublicInfo,
    };
  }


  private _initCreatePublicClient() {
    return createPublicClient({
      chain: baseSepolia,
      transport: http(),
    }) as PublicClient;
  }

  private async _ensureWalletConnection() {
    if (!this.isInitialized || !this.serverWallet) {
      const wallet = await this.connectWallet(this.serverId);
      const serverWallet = wallet.walletInfo;

      this.isDeployed = serverWallet.isDeployed;
      this.serverPublicClient = serverWallet.publicClient;
      this.serverBundlerClient = serverWallet.bundlerClient;
      this.serverWalletClient = serverWallet.walletClient;
      this.serverEoaAccount = serverWallet.eoaAccount;
      this.serverSmartAccount = serverWallet.smartAccount;
      this.serverWallet = {
        isDeployed: this.isDeployed,
        exists: true,
        smartAccount: this.serverSmartAccount,
        publicClient: this.serverPublicClient,
        bundlerClient: this.serverBundlerClient,
        walletClient: this.serverWalletClient,
        eoaAccount: this.serverEoaAccount,
        eoaAddress: this.serverEoaAccount.address,
        smartAccountAddress: this.serverSmartAccount.address,
      };
      this.serverWalletPublicInfo = {
        serverId: this.serverId,
        eoaAddress: this.serverEoaAccount.address,
        smartAccountAddress: this.serverSmartAccount.address,
      };
      this.isInitialized = true;
    }
  }


  public async getWalletInfo(): Promise<any> {
    await this._ensureWalletConnection();
    return this.serverWalletPublicInfo;
  }

  public async getServerWallet(): Promise<ConnectedWallet> {
    await this._ensureWalletConnection();
    return this.serverWallet;
  }
}

