// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../governance/LinealQorum.sol";
import "../economy/banks/LinealBank.sol";
import "../economy/token/LinealToken.sol";
import "../institution/LinealTender.sol";
import "../institution/LinealCitizens.sol"; // ajusta la ruta a donde esté tu archivo
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mínima interfaz del LinealEconomicKernel para validar institución y coins.
interface ILinealEconomicKernel {
    function isInstitutionRegistered(address institution) external view returns (bool);
    function isValidCoin(address token) external view returns (bool);
}

/**
 * @title LinealInstitution - NeoQuor
 * @notice Contrato estándar que representa a una Institución/Corporación en el ecosistema.
 *         Su banco custodia varios tokens ERC20; los tokens habilitados se gestionan por quórum.
 * @dev Si hay un LinealEconomicKernel enlazado, las operaciones que usan la institución o una
 *      coin validan contra él antes de pedir firmas.
 */
contract LinealInstitution is LinealQorum {

    string public institutionName;
    string public description;
    address public linealIdentity;
    address public linealCoin; // token principal (el primero de la lista inicial), por compatibilidad
    address public institutionBank;
    address public institutionTender;
    address public stableCoin;
    bytes32 public rewardsAccountId;
    bytes32 public institutionAccountId;
    uint256 public constant CREATION_FEE = 1_000_000;
    mapping(bytes32 => bool) public activeSubAccounts;
    mapping(address => bool) public isDirectiva;
    bytes32[] public subAccountIds;
    address[] private _directiva;
    address public economicKernel;

    event RewardsAccountCreated(bytes32 indexed accountId);
    event DescriptionUpdated(string newDescription);
    event SubAccountCreated(bytes32 indexed accountId, string accountName);
    event FundsMovedToSubAccount(
        bytes32 indexed fromAccount,
        bytes32 indexed toAccount,
        address indexed token,
        uint256 amount
    );
    event FundsMovedToBank(
        bytes32 indexed fromAccount,
        address indexed destBank,
        bytes32 indexed toAccount,
        address token,
        uint256 amount
    );
    event FundsReleased(
        bytes32 indexed accountId,
        address indexed to,
        address indexed token,
        uint256 amount,
        bytes32 reason
    );
    event PreFundsReleased(
        bytes32 indexed accountId,
        address indexed to,
        address indexed token,
        uint256 amount
    );
    event TokenSupportSet(address indexed token, bool supported);
    event BankLinked(address indexed bankAddress);
    event TendersLinked(address indexed tendersAddress);
    event IdentityLinked(address indexed identityAddress);
    event EconomicKernelLinked(address indexed kernel);
    event ProfileIssued(address indexed wallet, string username, string imageURI);
    event CitizenAccountCreated(address indexed wallet, bytes32 indexed accountId);
    event ProfileImageUpdated(address indexed wallet, string newImageURI);
    event TenderIssued(uint256 indexed tokenId, string title, string documentURL);
    event PaymentProcessed(address indexed wallet, uint256 amount);
    event TenderAccountCreated(uint256 indexed tokenId, bytes32 indexed accountId);
    event InstitutionAccountCreated(bytes32 indexed accountId, string accountName);

    error MintFailed();
    error PaymentFailed();
    error BankNotLinked();
    error TendersNotLinked();
    error InvalidSubAccount();
    error InvalidDestBank();
    error InvalidToken();
    error InvalidKernel();
    error InstitutionNotEnabled();
    error CoinNotValid(address token);

    constructor(
        address _stableCoin,
        uint256 _bps,
        string memory _institutionName,
        string memory _description,
        address[] memory _machines,
        address[] memory _institutions,
        address[] memory _humans,
        uint256 _requiredMachines,
        uint256 _requiredInstitutions,
        uint256 _requiredHumans,
        uint256 _recoveryQuorum
    ) LinealQorum(
    _machines,
    _requiredMachines,
    _institutions,
    _requiredInstitutions,
    _humans,
    _requiredHumans,
    _recoveryQuorum
    ) {
        institutionName = _institutionName;
        description = _description;
        stableCoin = _stableCoin;
        // La directiva son los humans definidos
        for (uint256 i; i < _humans.length; i++) {
            address h = _humans[i];
            if (h != address(0) && !isDirectiva[h]) {
                isDirectiva[h] = true;
                _directiva.push(h);
            }
        }

        // Banco: esta Institución es su owner. _bps = fee de rewards por transferencia interna.
        LinealBank bank = new LinealBank(address(this), _bps);
        institutionBank = address(bank);

        // La subcuenta "Rewards" la crea el banco en su constructor: se registra aquí también.
        bytes32 rewardsId = bank.rewardsAccountId();
        rewardsAccountId = rewardsId;
        activeSubAccounts[rewardsId] = true;
        subAccountIds.push(rewardsId);
        // Cuenta propia de la institución
        bytes32 instId = bank.createSubAccount(_institutionName);
        institutionAccountId = instId;
        activeSubAccounts[instId] = true;
        subAccountIds.push(instId);
        emit InstitutionAccountCreated(instId, _institutionName);
        emit BankLinked(institutionBank);

        // Licitaciones (NFT): esta Institución es su owner
        institutionTender = address(
            new LinealTender(
                string.concat(_institutionName, " Tenders"),
                "TENDER",
                address(this)
            )
        );
        LinealBank(institutionBank).setTokenSupport(_stableCoin, true);
        emit TendersLinked(institutionTender);
    }

    // ───────────── Tokens soportados por el banco ─────────────

    /**
     * @notice Habilita o deshabilita depósitos de un token en el banco. Requiere quórum.
     * @dev Deshabilitar no bloquea retiros ni transferencias de saldos existentes,
     *      y tampoco exige que la coin siga válida en el kernel.
     */
    function setTokenSupport(address token, bool supported) external onlyServers {
        if (institutionBank == address(0)) revert BankNotLinked();
        if (token == address(0)) revert InvalidToken();
        if (supported) _requireValidCoin(token);

        bytes32 txHash = _computeActionHash("setTokenSupport", abi.encode(token, supported));
        if (!confirmServers(txHash, "setTokenSupport")) return;

        LinealBank(institutionBank).setTokenSupport(token, supported);
        emit TokenSupportSet(token, supported);
    }

    /// @notice Vincula el LinealEconomicKernel que valida institución y coins. Requiere quórum de servers.
    function setEconomicKernel(address kernel) external onlyServers {
        if (kernel == address(0) || kernel.code.length == 0) revert InvalidKernel();

        bytes32 txHash = _computeActionHash("setEconomicKernel", abi.encode(kernel));
        if (!confirmServers(txHash, "setEconomicKernel")) return;

        economicKernel = kernel;
        emit EconomicKernelLinked(kernel);
    }

    function setPairToken(address token) external onlyServers {
        if (institutionBank == address(0)) revert BankNotLinked();
        if (token == address(0)) revert InvalidToken();
        _requireValidCoin(token);

        {
            bytes32 txHash = _computeActionHash("setPairToken", abi.encode(token));
            if (!confirmServers(txHash, "setPairToken")) return;
        }
        LinealBank(institutionBank).setTokenSupport(token, true);
        linealCoin = token;
        emit TokenSupportSet(token, true);
    }

    function setCitizensAddress(address contractAddress) external onlyServers {
        if (contractAddress == address(0)) revert InvalidToken();
        bytes32 txHash = _computeActionHash("setCitizensAddress", abi.encode(contractAddress));
        if (!confirmServers(txHash, "setCitizensAddress")) return;
        linealIdentity = contractAddress;
        emit IdentityLinked(contractAddress);
    }

    /**
     * @notice Crea una nueva subcuenta asociada a esta Institución. Requiere quorum de signers.
     * @param accountName Nombre de la subcuenta.
     */
    function createSubAccount(string calldata accountName) external onlyQorum {
        if (institutionBank == address(0)) revert BankNotLinked();

        bytes32 txHash = _computeActionHash("createSubAccount", abi.encode(accountName));
        if (!confirm(txHash, "createSubAccount")) return;

        bytes32 id = LinealBank(institutionBank).createSubAccount(accountName);
        activeSubAccounts[id] = true;
        subAccountIds.push(id);
        emit SubAccountCreated(id, accountName);
    }

    /**
     * @notice Mueve un token entre dos subcuentas del banco de esta Institución. Requiere quórum.
     */
    function moveFundsToSubAccount(
        bytes32 fromAccount,
        bytes32 toAccount,
        address token,
        uint256 amount
    ) external onlyQorum {
        if (institutionBank == address(0)) revert BankNotLinked();
        if (!activeSubAccounts[fromAccount]) revert InvalidSubAccount();
        if (!activeSubAccounts[toAccount]) revert InvalidSubAccount();
        _requireValidCoin(token);

        bytes32 txHash = _computeActionHash(
            "moveFundsToSubAccount",
            abi.encode(fromAccount, toAccount, token, amount)
        );
        if (!confirm(txHash, "moveFundsToSubAccount")) return;

        LinealBank(institutionBank).internalTransfer(fromAccount, toAccount, token, amount);
        emit FundsMovedToSubAccount(fromAccount, toAccount, token, amount);
    }

    /**
     * @notice Envía un token de una subcuenta del banco de esta Institución a una subcuenta
     *         del banco de OTRA institución. Requiere quórum de signers.
     * @dev El banco destino debe tener habilitado ese token (lo valida el banco).
     *      `toAccount` pertenece al banco destino, por eso no se valida contra `activeSubAccounts`.
     * @param fromAccount Subcuenta de origen en el banco de esta Institución.
     * @param destBank    Dirección del LinealBank destino.
     * @param toAccount   Subcuenta de destino en `destBank`.
     * @param token       Token a enviar.
     * @param amount      Monto bruto a debitar (el banco descuenta el fee de rewards).
     */
    function moveFundsToBank(
        bytes32 fromAccount,
        address destBank,
        bytes32 toAccount,
        address token,
        uint256 amount
    ) external onlyQorum {
        if (institutionBank == address(0)) revert BankNotLinked();
        if (!activeSubAccounts[fromAccount]) revert InvalidSubAccount();
        if (destBank == address(0) || destBank == institutionBank) revert InvalidDestBank();
        _requireValidCoin(token);

        bytes32 txHash = _computeActionHash(
            "moveFundsToBank",
            abi.encode(fromAccount, destBank, toAccount, token, amount)
        );
        if (!confirm(txHash, "moveFundsToBank")) return;

        LinealBank(institutionBank).transferToBank(fromAccount, destBank, toAccount, token, amount);
        emit FundsMovedToBank(fromAccount, destBank, toAccount, token, amount);
    }

    /**
     * @notice Libera un token de una subcuenta del banco hacia una dirección externa. Requiere quórum.
     * @dev No valida contra el kernel: es la salida de fondos y debe poder ejecutarse siempre.
     */
    function releaseFromBank(
        bytes32 accountId,
        address token,
        address payable to,
        uint256 amount,
        bytes32 reason
    ) external onlyQorum {
        if (institutionBank == address(0)) revert BankNotLinked();
        if (!activeSubAccounts[accountId]) revert InvalidSubAccount();

        bytes32 txHash = _computeActionHash(
            "releaseFromBank",
            abi.encode(accountId, token, to, amount, reason)
        );
        if (!confirm(txHash, "releaseFromBank")) return;

        LinealBank(institutionBank).release(accountId, token, to, amount, reason);
        emit FundsReleased(accountId, to, token, amount, reason);
    }

    /**
     * @notice Transfiere un token desde la cuenta de la institución a la subcuenta del ciudadano
     *         (preventa). Requiere quórum de servers.
     */
    function releasePreSale(
        address token,
        address payable to,
        uint256 amount
    ) external onlyServers {
        if (institutionBank == address(0)) revert BankNotLinked();
        _requireValidCoin(token);

        bytes32 txHash = _computeActionHash(
            "releasePreSale",
            abi.encode(token, to, amount)
        );
        if (!confirmServers(txHash, "releasePreSale")) return;
        bytes32 citizenAccountId = LinealCitizens(linealIdentity).subAccountOf(to);
        LinealBank(institutionBank).internalTransfer(institutionAccountId, citizenAccountId, token,  amount);
        emit PreFundsReleased(institutionAccountId, to, token, amount);
    }

    // ───────────── Licitaciones (LinealTenders) ─────────────

    function mintTender(
        string calldata title,
        string calldata tenderDescription,
        string calldata imageURI,
        string calldata documentURL,
        uint256 amount
    ) external onlyQorum {
        if (institutionTender == address(0)) revert TendersNotLinked();
        if (institutionBank == address(0)) revert BankNotLinked();
        _requireEnabled();

        {
            bytes32 txHash = _computeActionHash(
                "mintTender",
                abi.encode(title, tenderDescription, imageURI, documentURL, amount)
            );
            if (!confirm(txHash, "mintTender")) return;
        }

        // 1. Crear la subcuenta de la licitación en el banco
        bytes32 id = LinealBank(institutionBank).createSubAccount(title);
        activeSubAccounts[id] = true;
        subAccountIds.push(id);

        // 2. Mintear la licitación pasando la subcuenta como argumento
        uint256 tokenId = LinealTender(institutionTender).mintTender(
            title,
            tenderDescription,
            imageURI,
            documentURL,
            amount,
            id
        );

        emit TenderIssued(tokenId, title, documentURL);
        emit TenderAccountCreated(tokenId, id);
    }

    // ───────────── Identidad (LinealCitizens) ─────────────

    /**
     * @notice Emite un perfil soulbound en LinealCitizens. Requiere quórum de servers.
     *         Primero crea la subcuenta del ciudadano en el banco y luego mintea el perfil
     *         pasando el id de la subcuenta. Los primeros 25.000 perfiles reciben 50 unidades
     *         de linealCoin desde la cuenta de la institución.
     */
    function mintProfile(
        address wallet,
        string calldata username,
        string calldata imageURI
    ) external onlyServers {
        _requireEnabled();
        {
            bytes32 txHash = _computeActionHash(
                "mintProfile",
                abi.encode(wallet, username, imageURI)
            );
            if (!confirmServers(txHash, "mintProfile")) return;
        }
        uint256 tokenCounter = LinealCitizens(linealIdentity).tokenCounter();

        bytes32 id = LinealBank(institutionBank).createCitizenAccount(username);
        activeSubAccounts[id] = true;
        subAccountIds.push(id);

        if ((tokenCounter + 1) <= 25000) {
            _requireValidCoin(linealCoin);
            LinealBank(institutionBank).zeroFeeInternalTransfer(institutionAccountId, id, linealCoin, 50 * 1e18);
        }

        // 2. Mintear el perfil pasando la subcuenta como argumento
        LinealCitizens(linealIdentity).mintProfile(wallet, username, imageURI, id);
        emit ProfileIssued(wallet, username, imageURI);
        emit CitizenAccountCreated(wallet, id);
    }

    function updateIdentityScore(
        uint256 tokenId,
        uint256 delta,
        bool positive
    ) external onlyServers {
        bytes32 txHash = _computeActionHash(
            "updateIdentityScore",
            abi.encode(tokenId, delta, positive)
        );

        if (!confirmServers(txHash, "updateIdentityScore")) return;

        LinealCitizens(linealIdentity).updateScore(
            tokenId,
            delta,
            positive
        );
    }

    /**
     * @notice Actualiza la imagen de un perfil existente. Requiere quórum de servers.
     */
    function setProfileImageURI(address wallet, string calldata newImageURI) external onlyServers {
        bytes32 txHash = _computeActionHash(
            "setProfileImageURI",
            abi.encode(wallet, newImageURI)
        );
        if (!confirmServers(txHash, "setProfileImageURI")) return;

        LinealCitizens(linealIdentity).setImageURI(wallet, newImageURI);
        emit ProfileImageUpdated(wallet, newImageURI);
    }

    function getDirectiva() external view returns (address[] memory) {
        return _directiva;
    }

    function setDescription(string calldata newDescription) external onlyQorum {
        bytes32 txHash = _computeActionHash("setDescription", abi.encode(newDescription));
        if (!confirm(txHash, "setDescription")) return;

        description = newDescription;
        emit DescriptionUpdated(newDescription);
    }

    // ───────────── Vistas ─────────────

    /**
     * @notice Devuelve todas las subcuentas creadas por esta Institución.
     */
    function getSubAccounts() external view returns (bytes32[] memory) {
        return subAccountIds;
    }

    /**
     * @notice Devuelve la dirección del banco vinculado a esta institución.
     */
    function getInstitutionBank() external view returns (address) {
        return address(institutionBank);
    }

    /**
     * @notice Devuelve la dirección del contrato de licitaciones (LinealTenders).
     */
    function getInstitutionTender() external view returns (address) {
        return institutionTender;
    }

    /**
     * @notice Devuelve la dirección del contrato de identidad (LinealCitizens).
     */
    function getIdentity() external view returns (address) {
        return linealIdentity;
    }

    function getRewardsAccountId() external view returns (bytes32) {
        return LinealBank(institutionBank).rewardsAccountId();
    }

    /**
     * @notice Tokens registrados en el banco (habilitados o no; ver `supportedToken` en el banco).
     */
    function getBankTokens() external view returns (address[] memory) {
        return LinealBank(institutionBank).tokenList();
    }

    /**
     * @notice Saldos de una subcuenta en todos los tokens registrados del banco.
     */
    function getAccountBalances(bytes32 accountId)
    external
    view
    returns (address[] memory tokens, uint256[] memory balances)
    {
        return LinealBank(institutionBank).accountBalancesAll(accountId);
    }

    // ───────────── Validaciones contra el kernel ─────────────

    /// @dev Revierte si el kernel está enlazado y esta institución no está habilitada en él.
    function _requireEnabled() internal view {
        address k = economicKernel;
        if (k == address(0)) return;
        if (!ILinealEconomicKernel(k).isInstitutionRegistered(address(this))) revert InstitutionNotEnabled();
    }

    /// @dev Además de la institución, exige que la coin esté en la lista de válidas del kernel.
    function _requireValidCoin(address token) internal view {
        address k = economicKernel;
        if (k == address(0)) return;
        ILinealEconomicKernel kernel = ILinealEconomicKernel(k);
        if (!kernel.isInstitutionRegistered(address(this))) revert InstitutionNotEnabled();
        if (!kernel.isValidCoin(token)) revert CoinNotValid(token);
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.