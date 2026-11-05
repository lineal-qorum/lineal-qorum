// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../../governance/LinealQorum.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LinealToken - NeoQuor
 * @notice Stablecoin regulada respaldada 1:1 por moneda FIAT (CLP).
 *
 * MODELO DE CUMPLIMIENTO:
 * - KYC en la entrada: solo se puede acuñar (mint) hacia direcciones en whitelist.
 * - Circulación libre: transfer y transferFrom no exigen whitelist.
 * - Control reactivo: blacklist administrada por quórum bloquea envíos y recepciones.
 * - Recuperación: solo desde cuentas en blacklist, con quórum, razón obligatoria
 *   y registro público (recoveryHistory).
 * - Pausa de emergencia y límites diarios de transferencia, mint y burn.
 * - Gobernanza multisig de 3 capas mediante LinealQorum.
 * - Auditoría on-chain: mintHistory, burnHistory y recoveryHistory.
 *
 * @dev El mint y el burn solo los puede ejecutar linealLiquidityAddress.
 *      El KYC del cliente final se verifica fuera de la cadena antes de whitelistear.
 */
contract LinealToken is ERC20, LinealQorum, Pausable {
    // === STATE: ROLES & FLAGS ===

    /// @notice Banco que respalda la moneda FIAT (custodia del respaldo).
    address public reserveBank;
    /// @notice Contrato autorizado a ejecutar mint y burn (liquidez del sistema).
    address public linealLiquidityAddress;
    /// @notice Indica si el lanzamiento de la fase seed (launchSeed) ya se ejecutó.
    bool public launched = false;
    /// @notice Bandera de estado reservada para la fase seed; no interviene en la lógica actual.
    bool public seedLaunched;

    address public linealEconomyAddress;

    // === COMPLIANCE & REGULATORY ===

    /// @notice Direcciones que pasaron KYC; solo ellas pueden recibir mint o realizar burn.
    mapping(address => bool) public isWhitelisted;

    /// @notice Direcciones bloqueadas: no pueden enviar ni recibir tokens.
    mapping(address => bool) public isBlacklisted;

    /// @notice Límite diario de transferencias por dirección emisora (18 decimales).
    uint256 public dailyTransferLimit = 27_000_000 * 10**18;
    /// @notice Límite diario global de tokens acuñados.
    uint256 public dailyMintLimit = 100_000_000 * 10**18;
    /// @notice Límite diario global de tokens quemados.
    uint256 public dailyBurnLimit = 100_000_000 * 10**18;

    struct DailyVolume {
        /// @dev Día (timestamp / 1 days) al que corresponde este registro.
        uint256 date;
        /// @dev Total acuñado en el día.
        uint256 minted;
        /// @dev Total quemado en el día.
        uint256 burned;
        /// @dev Volumen transferido en el día, por dirección emisora.
        mapping(address => uint256) transferred;
    }

    /// @notice Volumen diario indexado por día (block.timestamp / 1 days).
    mapping(uint256 => DailyVolume) private _dailyVolumes;

    // === AUDIT TRAIL: STRUCTS ===

    struct MintRecord {
        address to;
        uint256 amount;
        uint256 timestamp;
        address authorizedBy;
    }

    struct BurnRecord {
        address from;
        uint256 amount;
        uint256 timestamp;
        address authorizedBy;
    }

    struct RecoveryRecord {
        uint256 id;
        address from;
        address to;
        uint256 amount;
        string reason;
        uint256 timestamp;
        address authorizedBy;
    }

    // === AUDIT TRAIL: REGISTRIES ===

    /// @notice Registro de cada mint.
    MintRecord[] public mintHistory;
    /// @notice Registro de cada burn.
    BurnRecord[] public burnHistory;
    /// @notice Registro público de cada recuperación de fondos.
    RecoveryRecord[] public recoveryHistory;

    // === EVENTS ===

    event AddressWhitelisted(address indexed account, bool status);
    event Minted(address indexed to, uint256 amount, address indexed authorizedBy, uint256 timestamp);
    event Burned(address indexed from, uint256 amount, address indexed authorizedBy, uint256 timestamp);
    event ReserveBankSet(address indexed newReserveBank);
    event AddressBlacklisted(address indexed account, bool status);
    event DailyLimitsUpdated(uint256 transferLimit, uint256 mintLimit, uint256 burnLimit);
    event FundsRecovered(
        uint256 indexed id,
        address indexed from,
        address indexed to,
        uint256 amount,
        string reason,
        address authorizedBy,
        uint256 timestamp
    );

    /**
     * @notice Inicializa el token y la gobernanza multisig de 3 capas.
     * @param name Nombre del token ERC20.
     * @param symbol Símbolo del token ERC20.
     * @param _machines Signers de la capa máquinas.
     * @param _institutions Signers de la capa instituciones.
     * @param _humans Signers de la capa humanos.
     * @param _requiredMachines Firmas requeridas de la capa máquinas.
     * @param _requiredInstitutions Firmas requeridas de la capa instituciones.
     * @param _requiredHumans Firmas requeridas de la capa humanos.
     * @param _recoveryQuorum Firmas requeridas para recuperaciones.
     */
    constructor(
        address memory _linealEconomy,
        string memory name,
        string memory symbol,
        address[] memory _machines,
        address[] memory _institutions,
        address[] memory _humans,
        uint256 _requiredMachines,
        uint256 _requiredInstitutions,
        uint256 _requiredHumans,
        uint256 _recoveryQuorum
    ) LinealQorum(_machines, _requiredMachines, _institutions, _requiredInstitutions, _humans, _requiredHumans, _recoveryQuorum)
    ERC20(name, symbol) {
        linealEconomyAddress = _linealEconomy;
    }

    // === MODIFIERS ===

    /// @dev Exige que la cuenta haya pasado KYC (whitelist).
    modifier onlyWhitelisted(address account) {
        require(isWhitelisted[account], "CLP: Address not whitelisted (KYC required)");
        _;
    }

    /// @dev Exige que la cuenta no esté bloqueada por compliance.
    modifier notBlacklisted(address account) {
        require(!isBlacklisted[account], "CLP: Address is blacklisted");
        _;
    }

    // === EMERGENCY CONTROLS ===

    /// @notice Pausa el token (transfer, mint y burn). Requiere quórum.
    function pause() external onlyServers {
        bytes32 txHash = _computeActionHash("pause", abi.encode(""));
        if (!confirm(txHash, "pause")) return;
        _pause();
    }

    /// @notice Reactiva el token. Requiere quórum.
    function unpause() external onlyServers {
        bytes32 txHash = _computeActionHash("unpause", abi.encode(""));
        if (!confirm(txHash, "unpause")) return;
        _unpause();
    }

    // === COMPLIANCE MANAGEMENT ===

    /// @notice Agrega o quita una dirección de la whitelist KYC.
    function setWhitelist(address account, bool status) external onlyServers {
        bytes32 txHash = _computeActionHash("setWhitelist", abi.encode(account, status));
        if (!confirmServers(txHash, "setWhitelist")) return;
        isWhitelisted[account] = status;
        emit AddressWhitelisted(account, status);
    }

    /// @notice Agrega o quita una dirección de la blacklist.
    function setBlacklist(address account, bool status) external onlyServers {
        bytes32 txHash = _computeActionHash("setBlacklist", abi.encode(account, status));
        if (!confirmServers(txHash, "setBlacklist")) return;
        isBlacklisted[account] = status;
        emit AddressBlacklisted(account, status);
    }

    /// @notice Define el contrato de liquidez y acuña el suministro inicial del pre-seed.
    /// @dev Solo puede ejecutarse una vez (linealLiquidityAddress debe ser cero).
    function launchPreSeed(address _linealLiquidity, uint256 totalAmount) external onlyServers {
        bytes32 txHash = _computeActionHash("launchPreSeed", abi.encode(_linealLiquidity, totalAmount));
        if (!confirmServers(txHash, "launchPreSeed")) return;
        require(linealLiquidityAddress == address(0), "Already Launched");
        linealLiquidityAddress = _linealLiquidity;
        _mint(_linealLiquidity, totalAmount * 1e18);
    }

    /// @notice Acuña el suministro de la ronda seed y marca el token como lanzado.
    /// @dev Solo puede ejecutarse una vez (launched debe ser false).
    function launchSeed(address _linealLiquidity, uint256 totalAmount) external onlyServers {
        require(launched == false, "Already Launched");
        bytes32 txHash = _computeActionHash("launchSeed", abi.encode(_linealLiquidity, totalAmount));
        if (!confirmServers(txHash, "launchSeed")) return;
        launched = true;
        _mint(_linealLiquidity, totalAmount * 1e18);
    }

    /// @notice Actualiza los límites diarios de transferencia, mint y burn.
    function setDailyLimits(
        uint256 _transferLimit,
        uint256 _mintLimit,
        uint256 _burnLimit
    ) external onlyServers {
        bytes32 txHash = _computeActionHash("setDailyLimits", abi.encode(_transferLimit, _mintLimit, _burnLimit));
        if (!confirmServers(txHash, "setDailyLimits")) return;
        dailyTransferLimit = _transferLimit;
        dailyMintLimit = _mintLimit;
        dailyBurnLimit = _burnLimit;
        emit DailyLimitsUpdated(_transferLimit, _mintLimit, _burnLimit);
    }

    // === RESERVE BANK MANAGEMENT ===

    /// @notice Vincula el banco de reserva. Solo puede fijarse una vez.
    function setReserveBank(address _reserveBank) external onlyServers {
        require(reserveBank == address(0), "CLP: Reserve bank already set");
        require(_reserveBank != address(0), "CLP: Invalid reserve bank address");

        bytes32 txHash = _computeActionHash("setReserveBank", abi.encode(_reserveBank));
        if (!confirmServers(txHash, "setReserveBank")) return;
        reserveBank = _reserveBank;
        emit ReserveBankSet(_reserveBank);
    }

    // === MINT & BURN (BACKED BY FIAT) ===

    /**
     * @notice Acuña tokens contra respaldo FIAT.
     * @dev Solo el contrato de liquidez puede acuñar, hacia direcciones con KYC
     *      y fuera de blacklist. Aplica el límite diario global de mint.
     * @param to Destino de los tokens.
     * @param amount Cantidad a acuñar (18 decimales).
     */
    function mint(
        address to,
        uint256 amount
    ) external whenNotPaused onlyWhitelisted(to) notBlacklisted(to) {
        require(reserveBank != address(0), "CLP: Bank not linked");
        require(msg.sender == linealLiquidityAddress, "CLP: Sender is not Authorized Bank");
        require(to != address(0), "CLP: Invalid recipient");
        require(amount > 0, "CLP: Amount must be > 0");

        // Volumen del día actual (se reinicia si cambió el día).
        uint256 today = block.timestamp / 1 days;
        DailyVolume storage volume = _dailyVolumes[today];
        if (volume.date != today) {
            volume.date = today;
            volume.minted = 0;
        }
        require(volume.minted + amount <= dailyMintLimit, "CLP: Daily mint limit exceeded");

        volume.minted += amount;

        // Auditoría on-chain.
        mintHistory.push(MintRecord({
            to: to,
            amount: amount,
            timestamp: block.timestamp,
            authorizedBy: msg.sender
        }));

        _mint(to, amount);
        emit Minted(to, amount, msg.sender, block.timestamp);
    }

    /**
     * @notice Quema tokens contra retiro de respaldo FIAT.
     * @dev Solo el contrato de liquidez puede quemar, desde direcciones con KYC
     *      y fuera de blacklist. Aplica el límite diario global de burn.
     * @param from Dirección de la que se queman los tokens.
     * @param amount Cantidad a quemar (18 decimales).
     */
    function burn(
        address from,
        uint256 amount
    ) external whenNotPaused onlyWhitelisted(from) notBlacklisted(from) {
        require(reserveBank != address(0), "CLP: Reserve bank not set");
        require(msg.sender == linealLiquidityAddress, "CLP: Sender is not Authorized Bank");
        require(from != address(0), "CLP: Invalid address");
        require(amount > 0, "CLP: Amount must be > 0");
        require(balanceOf(from) >= amount, "CLP: Insufficient balance");

        // Volumen del día actual (se reinicia si cambió el día).
        uint256 today = block.timestamp / 1 days;
        DailyVolume storage volume = _dailyVolumes[today];
        if (volume.date != today) {
            volume.date = today;
            volume.burned = 0;
        }
        require(volume.burned + amount <= dailyBurnLimit, "CLP: Daily burn limit exceeded");

        volume.burned += amount;

        // Auditoría on-chain.
        burnHistory.push(BurnRecord({
            from: from,
            amount: amount,
            timestamp: block.timestamp,
            authorizedBy: msg.sender
        }));

        _burn(from, amount);
        emit Burned(from, amount, msg.sender, block.timestamp);
    }

    // === FRAUD RECOVERY ===

    /**
     * @notice Recupera fondos desde una cuenta en blacklist hacia una cuenta limpia.
     * @dev Requiere quórum y una razón no vacía; deja registro público en recoveryHistory.
     * @param from Cuenta origen (debe estar en blacklist).
     * @param to Cuenta destino (no puede estar en blacklist).
     * @param amount Cantidad a mover.
     * @param reason Justificación de la recuperación (obligatoria).
     */
    function recoverFunds(
        address from,
        address to,
        uint256 amount,
        string memory reason
    ) external onlyQorum whenNotPaused {
        require(from != address(0) && to != address(0), "CLP: Invalid addresses");
        require(from != to, "CLP: Same address");
        require(isBlacklisted[from], "CLP: Source is not blacklisted");
        require(!isBlacklisted[to], "CLP: Recipient is blacklisted");
        require(amount > 0 && balanceOf(from) >= amount, "CLP: Invalid amount");
        require(bytes(reason).length > 0, "CLP: Reason required");

        bytes32 txHash = _computeActionHash(
            "recoverFunds",
            abi.encode(from, to, amount, reason)
        );
        if (!confirm(txHash, "recoverFunds")) return;

        uint256 id = recoveryHistory.length;

        recoveryHistory.push(RecoveryRecord({
            id: id,
            from: from,
            to: to,
            amount: amount,
            reason: reason,
            timestamp: block.timestamp,
            authorizedBy: msg.sender
        }));

        _transfer(from, to, amount);
        emit FundsRecovered(id, from, to, amount, reason, msg.sender, block.timestamp);
    }

    // === OVERRIDES FOR COMPLIANCE ===

    /// @notice Transferencia con control de blacklist, pausa y límite diario del emisor.
    function transfer(address to, uint256 amount)
        public
        override
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(to)
        returns (bool)
    {
        _checkAndRecordDailyTransfer(msg.sender, amount);
        return super.transfer(to, amount);
    }

    /// @notice Transferencia con allowance, con control de blacklist, pausa y límite diario del origen.
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        whenNotPaused
        notBlacklisted(from)
        notBlacklisted(to)
        returns (bool)
    {
        _checkAndRecordDailyTransfer(from, amount);
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Valida y acumula el volumen transferido del día para `account`.
     *      Reinicia el registro cuando cambia el día.
     */
    function _checkAndRecordDailyTransfer(address account, uint256 amount) internal {
        uint256 today = block.timestamp / 1 days;
        DailyVolume storage volume = _dailyVolumes[today];

        if (volume.date != today) {
            volume.date = today;
        }

        require(
            volume.transferred[account] + amount <= dailyTransferLimit,
            "CLP: Daily transfer limit exceeded"
        );

        volume.transferred[account] += amount;
    }

    // === VIEW FUNCTIONS ===

    /// @notice Suministro total en circulación.
    function getCirculatingSupply() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice Cantidad de registros de mint.
    function getMintHistoryLength() external view returns (uint256) {
        return mintHistory.length;
    }

    /// @notice Cantidad de registros de burn.
    function getBurnHistoryLength() external view returns (uint256) {
        return burnHistory.length;
    }

    /// @notice Volumen transferido hoy por una dirección.
    function getDailyTransferVolume(address account) external view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        DailyVolume storage volume = _dailyVolumes[today];
        return volume.date == today ? volume.transferred[account] : 0;
    }

    /// @notice Volumen acuñado y quemado hoy (global).
    function getDailyMintBurnVolume() external view returns (uint256 minted, uint256 burned) {
        uint256 today = block.timestamp / 1 days;
        DailyVolume storage volume = _dailyVolumes[today];
        if (volume.date == today) {
            return (volume.minted, volume.burned);
        }
        return (0, 0);
    }

    // === TRANSPARENCY (RECOVERY HISTORY) ===

    /// @notice Cantidad de recuperaciones registradas.
    function getRecoveryHistoryLength() external view returns (uint256) {
        return recoveryHistory.length;
    }

    /// @notice Devuelve una página del historial de recuperaciones.
    /// @param offset Índice inicial dentro del historial.
    /// @param limit Cantidad máxima de registros a devolver.
    function getRecoveries(uint256 offset, uint256 limit)
        external
        view
        returns (RecoveryRecord[] memory page)
    {
        uint256 total = recoveryHistory.length;
        if (offset >= total) return new RecoveryRecord[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        page = new RecoveryRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = recoveryHistory[i];
        }
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.