export interface SDKConfig {
    signerUrl: string;
    rpcUrl: string;
    contracts: {
        roles: string;
        networkTransfer: string;
        reserveBank: string;
    };
}
export interface AuthResponse {
    token: string;
    expiresAt: number;
}
export interface TransactionResult {
    hash: string;
    status: 'success' | 'reverted';
    blockNumber: bigint;
}
export interface ParticipantInfo {
    role: string;
    groupId: string;
    isActive: boolean;
}
export * from './wallet';
