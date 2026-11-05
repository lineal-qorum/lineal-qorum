"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.coreContracts = exports.institutionalServerList = exports.serverList = exports.web3AuthConfig = exports.contracts = exports.endPoints = exports.testSigners = exports.configBank = exports.Configuration = void 0;
class Configuration {
    tokenUrlBase = 'https://auth.qorum.cl/';
    authUrlBase = 'https://auth.qorum.one/ekklesia';
    getQorumServer = {
        genesis: 'namos',
        demos: this.authUrlBase,
        agora: 'agora',
        kritos: 'kritos',
    };
}
exports.Configuration = Configuration;
exports.configBank = {
    ekklesia: 'ekklesia',
    namos: 'namos',
    nomial: 'nomia',
};
exports.testSigners = {
    machines: [
        {
            name: "demos",
            walletAddress: "0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2"
        },
        {
            name: "agora",
            walletAddress: "0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db",
        },
        {
            name: "kritos",
            walletAddress: "0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB",
        }
    ],
    onlyMachinesAddress: ["0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2", "0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db", "0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB"],
    institutions: [
        {
            name: "ekklesia",
            walletAddress: "0x6c99Fbd115b79Af000d45c0D1d77217a986903Ea"
        },
        {
            name: "namos",
            walletAddress: "0xc5B99Bc09DfF30b803A66E74B3E6215eC6fa2BC3",
        },
        {
            name: "nomia",
            walletAddress: "0xce9B8C91C5FC11aC360E54aA8C5D394a7308A470",
        }
    ],
    humans: ["0x2cC0d23B371b3F0cC2BA9c3EABbF30E66f005Be2", "0x14723A09ACff6D2A60DcdF7aA4AFf308FDDC160C", "0x4d5a7F339610240094FF6482cA726fb8c6D0cb1C"]
};
exports.endPoints = {
    authentication: {
        base: '/authentication',
        createOrGetWallet: '/create-or-get?todenId=',
        getJwtToken: '/.well-known/test-token?tokenId=',
    },
    deployments: {
        base: '/deploy',
        seedInfrastructure: '/seed-infrastructure',
        deployIdentity: '/identity',
    },
    identity: {
        base: '/identity',
        createIdentity: '/create-identity',
        updateScore: '/update-score',
        addDimension: '/add-dimension',
    }
};
exports.contracts = {
    verifierAddress: "0x0e3ff64654e524b3c4ebbea5137e809b9323f2fc",
    verifierTx: "0xefd571003d1dda505e546eb84de63c1b99e04bde3b808083c73c3beddf32d73a",
    factoryAddress: "0x408ce7b7c78c3b273256a0f27f2185daa114ce44",
    factoryTx: "0x3841699cf7d704c0da7f06edbb4b3ccd8605a3511e6a8e8ced7c316c76f97287",
};
exports.web3AuthConfig = {
    VERIFIER_NAME: 'qorum',
    BUNDLER_URL: `https://api.pimlico.io/v2/84532/rpc?apikey=pim_RoMqKkBUa1UaYxeg9NhxEv`,
    WEB3AUTH_CLIENT_ID: 'BFsWNcLGnBBS7NHMI-iFBdVuaNOEoIkNsl9YRI4E6aD02bM__Ulgl9QfoXkqnvHLBsxHj0_Rg9RKEOK94vWzDkA',
    web3AuthNetwork: 'sapphire_devnet',
};
exports.serverList = [
    {
        name: 'demos',
        port: '4000',
        institution: 'quorum',
        dns: 'http://localhost:',
    },
    {
        name: 'agora',
        port: '4001',
        institution: 'quorum',
        dns: 'http://localhost:',
    },
    {
        name: 'namos',
        port: '4002',
        institution: 'quorum',
        dns: 'http://localhost:',
    },
    {
        name: 'kritos',
        port: '4003',
        institution: 'quorum',
        dns: 'http://localhost:',
    },
];
exports.institutionalServerList = [
    {
        name: 'ekklesia',
        port: '4007',
        institution: 'institution',
        dns: 'http://localhost:',
    },
    {
        name: 'nomia',
        port: '4008',
        institution: 'institution',
        dns: 'http://localhost:',
    },
    {
        name: 'logos',
        port: '4009',
        institution: 'institution',
        dns: 'http://localhost:',
    },
];
exports.coreContracts = {
    DeployFactory: '0x3a0397b325730c172a27e3345efcc7cbd731366d',
    GuardianCouncil: '0x9f473A0209d1dDf430D13558697cd6684Fe7e2f0',
    RolesContract: '0x03a999A89C3B853B4F80a5319167369cbD8E243D',
    NetWorkTransferContract: '0xB43898bD625CcF67c1947315d34aF5f527268ABF',
    AdministrativeAuthorizationTransferContract: '0x7BeD0154D1061d5CD10dE1281F3ea6446197E713',
};
//# sourceMappingURL=config.js.map