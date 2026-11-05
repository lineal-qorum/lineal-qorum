import { Web3AuthConfig } from '../types';
export declare class Configuration {
    readonly tokenUrlBase: string;
    readonly authUrlBase: string;
    readonly getQorumServer: any;
}
export declare const configBank: {
    ekklesia: string;
    namos: string;
    nomial: string;
};
export declare const testSigners: {
    machines: {
        name: string;
        walletAddress: string;
    }[];
    onlyMachinesAddress: string[];
    institutions: {
        name: string;
        walletAddress: string;
    }[];
    humans: string[];
};
export declare const endPoints: {
    authentication: {
        base: string;
        createOrGetWallet: string;
        getJwtToken: string;
    };
    deployments: {
        base: string;
        seedInfrastructure: string;
        deployIdentity: string;
    };
    identity: {
        base: string;
        createIdentity: string;
        updateScore: string;
        addDimension: string;
    };
};
export declare const contracts: {
    verifierAddress: string;
    verifierTx: string;
    factoryAddress: string;
    factoryTx: string;
};
export declare const web3AuthConfig: Web3AuthConfig;
export declare const serverList: {
    name: string;
    port: string;
    institution: string;
    dns: string;
}[];
export declare const institutionalServerList: {
    name: string;
    port: string;
    institution: string;
    dns: string;
}[];
export declare const coreContracts: {
    DeployFactory: string;
    GuardianCouncil: string;
    RolesContract: string;
    NetWorkTransferContract: string;
    AdministrativeAuthorizationTransferContract: string;
};
