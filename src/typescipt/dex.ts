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
export class DexService {
    public api: AxiosInstance;
    public contractName: string = 'LinealDex';

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

    public functionWithMultisig(contractAddress: any, args1: any, args2: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'functionWithMultisig',
            args: [args1, args2],
        };
        return this.post('/send-operation', data);
    }

    
    public functionWithOnlySigner(contractAddress: any, args1: any, args2: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'functionWithOnlySigner',
            args: [args1, args2],
        };
        return this.post('/send-only-signer-operation', data);
    }


    
    public transactionWithoutMultisig(contractAddress: any, args1: any, args2: any): Promise<any> {
        const data = {
            contractName: this.contractName,

            contractAddress: contractAddress,
            functionName: 'transactionWithoutMultisig',
            args: [args1, args2],
        };
        return this.post('/send-operation', data);
    }

        public functionRead(contractAddress: any, args1: any, args2: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'transactionWithoutMultisig',
            args: [args1, args2],
        };
        return this.post('/send-operation', data);
    }


    // === VISTAS ===

    public getAmountOut(contractAddress: any, amountIn: any, reserveIn: any, reserveOut: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getAmountOut',
            args: [amountIn, reserveIn, reserveOut],
        };
        return this.post('/send-operation', data);
    }

    public spotPrice(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'spotPrice',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getAmountsOut(contractAddress: any, amountIn: any, path: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getAmountsOut',
            args: [amountIn, path],
        };
        return this.post('/send-operation', data);
    }

    public getTotalLiquidity(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getTotalLiquidity',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public getTotalLiquidityInIncome(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'getTotalLiquidityInIncome',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    public currentPriceCumulative(contractAddress: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'currentPriceCumulative',
            args: [],
        };
        return this.post('/send-operation', data);
    }

    // === SWAP ===

    public swapExactTokensForTokens(contractAddress: any, amountIn: any, amountOutMin: any, path: any, to: any, deadline: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'swapExactTokensForTokens',
            args: [amountIn, amountOutMin, path, to, deadline],
        };
        return this.post('/send-operation', data);
    }

    // === LIQUIDEZ ===

    public addLiquidity(contractAddress: any, tokenA: any, tokenB: any, amountADesired: any, amountBDesired: any, amountAMin: any, amountBMin: any, to: any, deadline: any): Promise<any> {
        const data = {
            contractName: this.contractName,
            contractAddress: contractAddress,
            functionName: 'addLiquidity',
            args: [tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline],
        };
        return this.post('/send-operation', data);
    }
}

export const dexService = new DexService();
