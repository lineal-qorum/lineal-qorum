import DeviceInfo from 'react-native-device-info';

import axios, {
    AxiosInstance,
    InternalAxiosRequestConfig,
    AxiosResponse,
    AxiosError
} from 'axios';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { MICROSERVICES_BASE_URL } from '../config';


/**
 * Clase de servicio API con tipado fuerte.
 */
// =============================================================================
// DEV NOTE — DOS SISTEMAS DE TOKENS, NO INTERCAMBIABLES:
//
//  1. soulBoundToken (Web3 / Wallet)
//     → Generado por Web3Auth vía auth.qorum.cl/.well-known/test-token
//     → Identifica la Soul Wallet del usuario en la blockchain
//     → Se usa SOLO para llamadas a auth.diggitaly.cl (genesis-server)
//     → Obtenido con: authService.getTokenFromApi() → soulBoundToken
//
//  2. sessionToken (JWT de usuario / App)
//     → Generado por el microservicio de usuarios al hacer login
//     → Identifica al usuario dentro de la plataforma (app, posts, tiendas, etc.)
//     → Se usa para llamadas a MICROSERVICES_BASE_URL (casts, users, stores, etc.)
//     → Almacenado en: AsyncStorage.getItem('authToken')
//
//  Mezclarlos causará 401/404. Cada AxiosInstance usa su propio interceptor.
// =============================================================================
export class LinealInstitution {
    public api: AxiosInstance;
    public contractName: string = 'LinealInstitution';

    constructor() {
        this.api = axios.create({
            baseURL: `${MICROSERVICES_BASE_URL}/api/v1/institution`,
            headers: { 'Content-Type': 'application/json' },
        });
        this.setupInterceptors();
    }
    private setupInterceptors(): void {
        this.api.interceptors.request.use(
            async (config: InternalAxiosRequestConfig): Promise<InternalAxiosRequestConfig> => {
                // 1. Token de sesión
                try {
                    const token = await AsyncStorage.getItem('authToken');
                    const deviceId = await DeviceInfo.getUniqueId();

                    if (token) {
                        config.headers.Authorization = `Bearer ${token}`;
                        config.headers['x-api-key'] = deviceId;

                    } else {
                        delete config.headers.Authorization;
                    }
                } catch (error) {
                    console.error('[InstitutionService] Error reaching AsyncStorage:', error);
                    delete config.headers.Authorization;
                }

                return config;
            },
            (error: AxiosError): Promise<AxiosError> => Promise.reject(error),
        );
    }

    /**
     * Realiza una petición POST tipada.
     */
    public async post<T>(endpoint: string, data: unknown): Promise<T> {
        const instance = this.api;
        const _user: any = await AsyncStorage.getItem('user');
        const parsedUser = JSON.parse(_user);
        console.log('[InstitutionService] post AsyncStorage:', parsedUser);
        const config: any = {};

        // Si es FormData, eliminamos el Content-Type para que Axios use multipart/form-data con boundary
        if (data instanceof FormData) {
            config.headers = { 'Content-Type': undefined };
        }
        let body: any = data;

        try {
            const response: AxiosResponse<T> = await instance.post<T>(endpoint, body, config);
            return response.data;
        } catch (error) {
            throw this.processError(error as AxiosError, `POST ${endpoint}`);
        }
    }

    /**
     * Realiza una petición GET tipada.
     */
    public async get<T>(
        endpoint: string,
        params: any = {},
        timeout: number = 60000 // 60 s por defecto
    ): Promise<T> {
        try {
            const response: AxiosResponse<T> = await this.api.get<T>(endpoint, {
                params,
                timeout,
            });
            return response.data;
        } catch (error) {
            throw this.processError(error as AxiosError, `GET ${endpoint}`);
        }
    }

    private processError(error: AxiosError, context: string): Error {
        const status = error.response?.status;
        // Silenciamos el log si es un error 500 (Internal Server Error) según solicitado
        if (status !== 500) {
            console.error(`[InstitutionService] Error in ${context}:`, error.response?.data || error.message);
        }
        return error;
    }

    public setTokenSupport(contractAddress: any, token: any, supported: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'setTokenSupport',
            args: [token, supported],
        };
        return this.post('/send-only-signer-operation', data);
    }

    public setPairToken(contractAddress: any, token: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'setPairToken',
            args: [token],
        };
        return this.post('/send-only-signer-operation', data);
    }

    public setCitizensAddress(contractAddress: any, citizensAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'setCitizensAddress',
            args: [citizensAddress],
        };
        return this.post('/send-only-signer-operation', data);
    }

    // === SUBCUENTAS ===

    public createSubAccount(contractAddress: any, accountName: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'createSubAccount',
            args: [accountName],
        };
        return this.post('/send-operation', data);
    }

    public moveFundsToSubAccount(contractAddress: any, fromAccount: any, toAccount: any, token: any, amount: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'moveFundsToSubAccount',
            args: [fromAccount, toAccount, token, amount],
        };
        return this.post('/send-operation', data);
    }

    public moveFundsToBank(contractAddress: any, fromAccount: any, destBank: any, toAccount: any, token: any, amount: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'moveFundsToBank',
            args: [fromAccount, destBank, toAccount, token, amount],
        };
        return this.post('/send-operation', data);
    }

    public releaseFromBank(contractAddress: any, accountId: any, token: any, to: any, amount: any, reason: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'releaseFromBank',
            args: [accountId, token, to, amount, reason],
        };
        return this.post('/send-operation', data);
    }

    public releasePreSale(contractAddress: any, token: any, to: any, amount: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'releasePreSale',
            args: [token, to, amount],
        };
        return this.post('/send-only-signer-operation', data);
    }

    // === LICITACIONES ===

    public mintTender(contractAddress: any, title: any, tenderDescription: any, imageURI: any, documentURL: any, amount: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'mintTender',
            args: [title, tenderDescription, imageURI, documentURL, amount],
        };
        return this.post('/send-operation', data);
    }

    // === IDENTIDAD ===

    public mintProfile(contractAddress: any, wallet: any, username: any, imageURI: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'mintProfile',
            args: [wallet, username, imageURI],
        };
        return this.post('/send-only-signer-operation', data);
    }

    public updateIdentityScore(contractAddress: any, tokenId: any, delta: any, positive: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'updateIdentityScore',
            args: [tokenId, delta, positive],
        };
        return this.post('/send-only-signer-operation', data);
    }

    public setProfileImageURI(contractAddress: any, wallet: any, newImageURI: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'setProfileImageURI',
            args: [wallet, newImageURI],
        };
        return this.post('/send-only-signer-operation', data);
    }

    public setDescription(contractAddress: any, newDescription: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'setDescription',
            args: [newDescription],
        };
        return this.post('/send-operation', data);
    }

    // === VISTAS ===

    public getDirectiva(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getDirectiva',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getSubAccounts(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getSubAccounts',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getInstitutionBank(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getInstitutionBank',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getInstitutionTender(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getInstitutionTender',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getIdentity(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getIdentity',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getRewardsAccountId(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getRewardsAccountId',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getBankTokens(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getBankTokens',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getAccountBalances(contractAddress: any, accountId: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getAccountBalances',
            args: [accountId],
        };
        return this.post('/send-operation', data);
    }

}

export const linealInstitution = new LinealInstitution();
