// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../governance/LinealQorum.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

interface ICitizensContract {
    function owner() external view returns (address);
    function subAccountOf(address wallet) external view returns (bytes32);
}
/**
 * @author NeoQuor - Tech Artisan
 * @title LinealKernel - Lineal Qorum Finternet
 * @dev Registro de emisores, bancos oficiales, perfiles de instituciones,
 *      coins ERC20 válidas y DNS/apps autorizadas por institución.
 *      Todo cambio requiere quórum de servers.
 */
contract LinealKernel is LinealQorum {

    // ───────────── Tipos ─────────────

    struct InstitutionProfile {
        address institution;   // dirección del contrato LinealInstitution
        string name;
        string description;
        string imageUrl;
        uint256 registeredAt;
        uint256 updatedAt;
    }

    struct Coin {
        address token;
        string name;
        string symbol;
        uint8 decimals;
        uint256 registeredAt;
    }

    // ───────────── Constantes ─────────────

    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 512;
    uint256 public constant MAX_IMAGE_URL_LENGTH = 256;
    uint256 public constant MAX_ACCESS_ENTRIES = 50;   // por institución y por lista
    uint256 public constant MAX_DNS_LENGTH = 253;
    uint256 public constant MAX_APP_ID_LENGTH = 128;

    // ───────────── Estado ─────────────

    // Emisores y bancos
    mapping(address => bool) public authorizedIssuers;
    mapping(address => bool) public officialBanks;

    // Perfiles de instituciones
    mapping(address => InstitutionProfile) private _profiles;
    mapping(address => uint256) private _institutionIndex; // posición + 1 (0 = no existe)
    address[] private _institutions;

    // Coins válidas
    mapping(address => Coin) private _coins;
    mapping(address => uint256) private _coinIndex; // posición + 1 (0 = no existe)
    address[] private _coinList;

    // DNS y apps autorizadas por institución
    mapping(address => string[]) private _dnsList;
    mapping(address => mapping(bytes32 => uint256)) private _dnsIndex; // posición + 1
    mapping(address => string[]) private _appList;
    mapping(address => mapping(bytes32 => uint256)) private _appIndex; // posición + 1

    // ───────────── Eventos ─────────────

    event IssuerAuthorized(address indexed issuer);
    event IssuerDeauthorized(address indexed issuer);
    event BankRegistered(address indexed bank);
    event BankDeregistered(address indexed bank);

    event InstitutionRegistered(address indexed institution, string name, string description, string imageUrl);
    event InstitutionProfileUpdated(address indexed institution, string name, string description, string imageUrl);
    event InstitutionRemoved(address indexed institution);

    event CoinRegistered(address indexed token, string name, string symbol, uint8 decimals);
    event CoinRemoved(address indexed token);

    event DnsAuthorized(address indexed institution, string dns);
    event DnsRevoked(address indexed institution, string dns);
    event AppAuthorized(address indexed institution, string appId);
    event AppRevoked(address indexed institution, string appId);

    // ───────────── Errores ─────────────

    error InvalidAddress();
    error NotAContract();
    error InvalidName();
    error DescriptionTooLong();
    error InvalidImageUrl();
    error InstitutionAlreadyRegistered();
    error InstitutionNotFound();
    error InvalidCoin();
    error CoinAlreadyRegistered();
    error CoinNotFound();
    error InvalidDns();
    error InvalidAppId();
    error AlreadyAuthorized();
    error NotAuthorized();
    error TooManyEntries();

    constructor(
        address[] memory _machines,
        address[] memory _institutionSigners,
        address[] memory _humans,
        uint256 _requiredMachines,
        uint256 _requiredInstitutions,
        uint256 _requiredHumans,
        uint256 _recoveryQuorum
    ) LinealQorum(
    _machines,
    _requiredMachines,
    _institutionSigners,
    _requiredInstitutions,
    _humans,
    _requiredHumans,
    _recoveryQuorum
    ) {}

    // ═════════════ EMISORES ═════════════

    /// @notice Autoriza a un contrato (ej. un Liquidity Locker) a liberar tokens.
    function authorizeIssuer(address _issuer) external onlyServers {
        bytes32 txHash = _computeActionHash("authorizeIssuer", abi.encode(_issuer));
        if (!confirmServers(txHash, "authorizeIssuer")) return;
        authorizedIssuers[_issuer] = true;
        emit IssuerAuthorized(_issuer);
    }

    /// @notice Revoca la autorización de emisión.
    function deauthorizeIssuer(address _issuer) external onlyServers {
        bytes32 txHash = _computeActionHash("deauthorizeIssuer", abi.encode(_issuer));
        if (!confirmServers(txHash, "deauthorizeIssuer")) return;
        authorizedIssuers[_issuer] = false;
        emit IssuerDeauthorized(_issuer);
    }

    // ═════════════ BANCOS ═════════════

    /// @notice Registra un banco como oficial del sistema.
    function registerBank(address _bank) external onlyServers {
        bytes32 txHash = _computeActionHash("registerBank", abi.encode(_bank));
        if (!confirmServers(txHash, "registerBank")) return;
        officialBanks[_bank] = true;
        emit BankRegistered(_bank);
    }

    /// @notice Quita a un banco de la lista de oficiales.
    function deregisterBank(address _bank) external onlyServers {
        bytes32 txHash = _computeActionHash("deregisterBank", abi.encode(_bank));
        if (!confirmServers(txHash, "deregisterBank")) return;
        officialBanks[_bank] = false;
        emit BankDeregistered(_bank);
    }

    // ═════════════ PERFILES DE INSTITUCIONES ═════════════

    /**
     * @notice Registra el perfil público de una institución.
     * @param institution Dirección del contrato de la institución.
     * @param name Nombre (obligatorio, máx. 64 bytes).
     * @param description Descripción (máx. 512 bytes).
     * @param imageUrl URL o URI de la imagen (obligatoria, máx. 256 bytes).
     */
    function registerInstitution(
        address institution,
        string calldata name,
        string calldata description,
        string calldata imageUrl
    ) external onlyServers {
        if (institution == address(0)) revert InvalidAddress();
        if (institution.code.length == 0) revert NotAContract();
        if (_institutionIndex[institution] != 0) revert InstitutionAlreadyRegistered();
        _validateProfile(name, description, imageUrl);

        bytes32 txHash = _computeActionHash(
            "registerInstitution",
            abi.encode(institution, name, description, imageUrl)
        );
        if (!confirmServers(txHash, "registerInstitution")) return;

        InstitutionProfile storage p = _profiles[institution];
        p.institution = institution;
        p.name = name;
        p.description = description;
        p.imageUrl = imageUrl;
        p.registeredAt = block.timestamp;
        p.updatedAt = block.timestamp;

        _institutions.push(institution);
        _institutionIndex[institution] = _institutions.length;

        emit InstitutionRegistered(institution, name, description, imageUrl);
    }

    /// @notice Actualiza nombre, descripción e imagen de una institución registrada.
    function updateInstitutionProfile(
        address institution,
        string calldata name,
        string calldata description,
        string calldata imageUrl
    ) external onlyServers {
        if (_institutionIndex[institution] == 0) revert InstitutionNotFound();
        _validateProfile(name, description, imageUrl);

        bytes32 txHash = _computeActionHash(
            "updateInstitutionProfile",
            abi.encode(institution, name, description, imageUrl)
        );
        if (!confirmServers(txHash, "updateInstitutionProfile")) return;

        InstitutionProfile storage p = _profiles[institution];
        p.name = name;
        p.description = description;
        p.imageUrl = imageUrl;
        p.updatedAt = block.timestamp;

        emit InstitutionProfileUpdated(institution, name, description, imageUrl);
    }

    /// @notice Elimina el perfil de una institución (y sus DNS/apps autorizadas).
    function removeInstitution(address institution) external onlyServers {
        uint256 idx = _institutionIndex[institution];
        if (idx == 0) revert InstitutionNotFound();

        bytes32 txHash = _computeActionHash("removeInstitution", abi.encode(institution));
        if (!confirmServers(txHash, "removeInstitution")) return;

        // swap-and-pop
        uint256 last = _institutions.length;
        if (idx != last) {
            address moved = _institutions[last - 1];
            _institutions[idx - 1] = moved;
            _institutionIndex[moved] = idx;
        }
        _institutions.pop();
        delete _institutionIndex[institution];
        delete _profiles[institution];
        _clearAccess(institution);

        emit InstitutionRemoved(institution);
    }

    // ═════════════ COINS VÁLIDAS ═════════════

    /**
     * @notice Registra un ERC20 como coin válida del ecosistema.
     * @dev Nombre, símbolo y decimales se leen directo del token.
     */
    function registerCoin(address token) external onlyServers {
        if (token == address(0)) revert InvalidAddress();
        if (_coinIndex[token] != 0) revert CoinAlreadyRegistered();

        (string memory n, string memory s, uint8 d) = _readMetadata(token);

        bytes32 txHash = _computeActionHash("registerCoin", abi.encode(token));
        if (!confirmServers(txHash, "registerCoin")) return;

        _coins[token] = Coin({
            token: token,
            name: n,
            symbol: s,
            decimals: d,
            registeredAt: block.timestamp
        });
        _coinList.push(token);
        _coinIndex[token] = _coinList.length;

        emit CoinRegistered(token, n, s, d);
    }

    /// @notice Quita una coin de la lista de válidas.
    function removeCoin(address token) external onlyServers {
        uint256 idx = _coinIndex[token];
        if (idx == 0) revert CoinNotFound();

        bytes32 txHash = _computeActionHash("removeCoin", abi.encode(token));
        if (!confirmServers(txHash, "removeCoin")) return;

        uint256 last = _coinList.length;
        if (idx != last) {
            address moved = _coinList[last - 1];
            _coinList[idx - 1] = moved;
            _coinIndex[moved] = idx;
        }
        _coinList.pop();
        delete _coinIndex[token];
        delete _coins[token];

        emit CoinRemoved(token);
    }

    // ═════════════ DNS AUTORIZADOS ═════════════

    /// @notice Autoriza un dominio para una institución registrada.
    /// @param dns Dominio en minúsculas, sin protocolo ni ruta (ej. "app.miinstitucion.cl").
    function authorizeDns(address institution, string calldata dns) external onlyServers {
        if (_institutionIndex[institution] == 0) revert InstitutionNotFound();
        if (!_validDns(dns)) revert InvalidDns();
        bytes32 key = keccak256(bytes(dns));
        if (_dnsIndex[institution][key] != 0) revert AlreadyAuthorized();
        if (_dnsList[institution].length >= MAX_ACCESS_ENTRIES) revert TooManyEntries();

        bytes32 txHash = _computeActionHash("authorizeDns", abi.encode(institution, dns));
        if (!confirmServers(txHash, "authorizeDns")) return;

        _dnsList[institution].push(dns);
        _dnsIndex[institution][key] = _dnsList[institution].length;
        emit DnsAuthorized(institution, dns);
    }

    /// @notice Revoca un dominio.
    function revokeDns(address institution, string calldata dns) external onlyServers {
        bytes32 key = keccak256(bytes(dns));
        uint256 idx = _dnsIndex[institution][key];
        if (idx == 0) revert NotAuthorized();

        bytes32 txHash = _computeActionHash("revokeDns", abi.encode(institution, dns));
        if (!confirmServers(txHash, "revokeDns")) return;

        string[] storage list = _dnsList[institution];
        uint256 last = list.length;
        if (idx != last) {
            string memory moved = list[last - 1];
            list[idx - 1] = moved;
            _dnsIndex[institution][keccak256(bytes(moved))] = idx;
        }
        list.pop();
        delete _dnsIndex[institution][key];
        emit DnsRevoked(institution, dns);
    }

    // ═════════════ APPS AUTORIZADAS ═════════════

    /// @notice Autoriza una app para una institución registrada.
    /// @param appId Identificador de la app (bundle id, package name o URL).
    function authorizeApp(address institution, string calldata appId) external onlyServers {
        if (_institutionIndex[institution] == 0) revert InstitutionNotFound();
        if (!_validAppId(appId)) revert InvalidAppId();
        bytes32 key = keccak256(bytes(appId));
        if (_appIndex[institution][key] != 0) revert AlreadyAuthorized();
        if (_appList[institution].length >= MAX_ACCESS_ENTRIES) revert TooManyEntries();

        bytes32 txHash = _computeActionHash("authorizeApp", abi.encode(institution, appId));
        if (!confirmServers(txHash, "authorizeApp")) return;

        _appList[institution].push(appId);
        _appIndex[institution][key] = _appList[institution].length;
        emit AppAuthorized(institution, appId);
    }

    /// @notice Revoca una app.
    function revokeApp(address institution, string calldata appId) external onlyServers {
        bytes32 key = keccak256(bytes(appId));
        uint256 idx = _appIndex[institution][key];
        if (idx == 0) revert NotAuthorized();

        bytes32 txHash = _computeActionHash("revokeApp", abi.encode(institution, appId));
        if (!confirmServers(txHash, "revokeApp")) return;

        string[] storage list = _appList[institution];
        uint256 last = list.length;
        if (idx != last) {
            string memory moved = list[last - 1];
            list[idx - 1] = moved;
            _appIndex[institution][keccak256(bytes(moved))] = idx;
        }
        list.pop();
        delete _appIndex[institution][key];
        emit AppRevoked(institution, appId);
    }

    // ═════════════ INTERNAS ═════════════

    function _validateProfile(
        string calldata name,
        string calldata description,
        string calldata imageUrl
    ) internal pure {
        uint256 n = bytes(name).length;
        if (n == 0 || n > MAX_NAME_LENGTH) revert InvalidName();
        if (bytes(description).length > MAX_DESCRIPTION_LENGTH) revert DescriptionTooLong();
        uint256 u = bytes(imageUrl).length;
        if (u == 0 || u > MAX_IMAGE_URL_LENGTH) revert InvalidImageUrl();
    }

    /// @dev Verifica que sea un contrato ERC20 con metadata legible.
    function _readMetadata(address token)
    internal
    view
    returns (string memory n, string memory s, uint8 d)
    {
        if (token.code.length == 0) revert InvalidCoin();
        IERC20Metadata t = IERC20Metadata(token);
        try t.totalSupply() returns (uint256) {} catch { revert InvalidCoin(); }
        try t.name() returns (string memory _n) { n = _n; } catch { revert InvalidCoin(); }
        try t.symbol() returns (string memory _s) { s = _s; } catch { revert InvalidCoin(); }
        try t.decimals() returns (uint8 _d) { d = _d; } catch { revert InvalidCoin(); }
    }

    /// @dev Minúsculas, dígitos, '.' y '-'; sin punto al inicio o final.
    ///      Exigir minúsculas evita duplicados como "App.com" y "app.com".
    function _validDns(string calldata dns) internal pure returns (bool) {
        bytes calldata b = bytes(dns);
        uint256 n = b.length;
        if (n < 3 || n > MAX_DNS_LENGTH) return false;
        if (b[0] == 0x2E || b[n - 1] == 0x2E) return false;
        for (uint256 i; i < n; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2E;
            if (!ok) return false;
        }
        return true;
    }

    /// @dev Sin caracteres de control ni espacios.
    function _validAppId(string calldata appId) internal pure returns (bool) {
        bytes calldata b = bytes(appId);
        if (b.length == 0 || b.length > MAX_APP_ID_LENGTH) return false;
        for (uint256 i; i < b.length; i++) {
            if (uint8(b[i]) <= 0x20 || uint8(b[i]) == 0x7F) return false;
        }
        return true;
    }

    /// @dev Limpia DNS y apps de una institución (se usa al removerla).
    function _clearAccess(address institution) internal {
        string[] storage d = _dnsList[institution];
        for (uint256 i; i < d.length; i++) {
            delete _dnsIndex[institution][keccak256(bytes(d[i]))];
        }
        delete _dnsList[institution];

        string[] storage a = _appList[institution];
        for (uint256 i; i < a.length; i++) {
            delete _appIndex[institution][keccak256(bytes(a[i]))];
        }
        delete _appList[institution];
    }

    // ═════════════ VISTAS ═════════════

    /// @notice Verifica si un caller está autorizado para operar sobre la economía.
    function isAuthorized(address _account) external view returns (bool) {
        return authorizedIssuers[_account] || officialBanks[_account];
    }

    // Instituciones

    function isInstitutionRegistered(address institution) external view returns (bool) {
        return _institutionIndex[institution] != 0;
    }

    function getInstitution(address institution) external view returns (InstitutionProfile memory) {
        if (_institutionIndex[institution] == 0) revert InstitutionNotFound();
        return _profiles[institution];
    }

    function getInstitutionsCount() external view returns (uint256) {
        return _institutions.length;
    }

    /// @notice Lista paginada de perfiles para paneles y apps.
    function getInstitutions(uint256 offset, uint256 limit)
    external
    view
    returns (InstitutionProfile[] memory page)
    {
        uint256 total = _institutions.length;
        if (offset >= total) return new InstitutionProfile[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        page = new InstitutionProfile[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _profiles[_institutions[i]];
        }
    }

    // Coins

    function isValidCoin(address token) external view returns (bool) {
        return _coinIndex[token] != 0;
    }

    function getCoin(address token) external view returns (Coin memory) {
        if (_coinIndex[token] == 0) revert CoinNotFound();
        return _coins[token];
    }

    function getCoinsCount() external view returns (uint256) {
        return _coinList.length;
    }

    /// @notice Lista paginada de coins válidas.
    function getCoins(uint256 offset, uint256 limit) external view returns (Coin[] memory page) {
        uint256 total = _coinList.length;
        if (offset >= total) return new Coin[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        page = new Coin[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _coins[_coinList[i]];
        }
    }

    // DNS y apps

    function getAuthorizedDns(address institution) external view returns (string[] memory) {
        return _dnsList[institution];
    }

    function getAuthorizedApps(address institution) external view returns (string[] memory) {
        return _appList[institution];
    }

    function isDnsAuthorized(address institution, string calldata dns) external view returns (bool) {
        return _dnsIndex[institution][keccak256(bytes(dns))] != 0;
    }

    function isAppAuthorized(address institution, string calldata appId) external view returns (bool) {
        return _appIndex[institution][keccak256(bytes(appId))] != 0;
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.