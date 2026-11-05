// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../token/LinealToken.sol";

/**
 * @title LinealBank
 * @author NeoQuor - Lineal Qorum Fundation
 * @notice Custodia de tokens ERC20 por subcuentas para una Institución.
 * Cada subcuenta lleva un saldo independiente por token.
 * Cada transferencia interna paga un fee (en bps) que se acredita a la subcuenta de rewards,
 * en el mismo token que se transfiere.
 * Las cuentas personales de ciudadanos solo pueden ser movidas por su dueño.
 *
 * FLUJOS PRINCIPALES:
 * - Depósitos: solo tokens habilitados por la Institución (whitelist de tokens).
 * - Retiros: liberación hacia el exterior (institución o ciudadano dueño de la cuenta).
 * - Transferencias internas: entre subcuentas del mismo banco, con fee de rewards.
 * - Transferencias entre bancos: acreditadas vía `deposit` del banco destino.
 *
 * @dev Solo se aceptan DEPÓSITOS de tokens habilitados por la Institución (lista blanca).
 * Deshabilitar un token bloquea depósitos nuevos, pero NO bloquea retiros ni transferencias:
 * los saldos existentes siempre se pueden mover. Evita habilitar tokens con rebase,
 * con callbacks (ERC777) o que puedan pausar/bloquear transferencias a voluntad.
 */
contract LinealBank is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // === STATE: CONSTANTS & IMMUTABLES ===

    /// @notice Base de cálculo de los basis points (100% = 10000 bps).
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Institución dueña de este banco.
    address public immutable institutionAddress;

    /// @notice Porcentaje de fee sobre cada transferencia interna (basis points, base 10000).
    uint256 public immutable rewardsBps;

    // === STATE: ACCOUNTS & TOKEN WHITELIST ===

    /// @notice Subcuenta que recibe el fee de rewards.
    bytes32 public rewardsAccountId;

    /// @notice Saldo por subcuenta y token, en unidades del token.
    mapping(bytes32 => mapping(address => uint256)) public accountBalances;

    /// @notice Tokens habilitados para depósito.
    mapping(address => bool) public supportedToken;
    /// @dev Registro interno de tokens ya agregados a `_tokenList`.
    mapping(address => bool) private _listed;
    /// @dev Tokens registrados (habilitados o no).
    address[] private _tokenList;

    /// @notice Subcuentas activas del banco.
    mapping(bytes32 => bool) public activeSubAccounts;
    /// @notice Listado de subcuentas creadas (para paneles y apps).
    bytes32[] public subAccountIds;

    /// @notice Subcuentas personales de ciudadanos (la directiva no puede moverlas).
    mapping(bytes32 => bool) public personalAccount;

    // === STATE: TRANSACTION MANAGER ===

    /// @notice Dirección autorizada a ejecutar liberaciones basadas en transacciones.
    address public transactionManager;

    // === EVENTS ===

    event TokenSupportChanged(address indexed token, bool supported);
    event TokenDeposited(bytes32 indexed accountId, address indexed depositor, address indexed token, uint256 amount);
    event RewardsFeeCharged(bytes32 indexed fromAccount, bytes32 indexed rewardsAccount, address indexed token, uint256 fee);
    event RewardsAccountSet(bytes32 indexed accountId);
    event TokenReleased(bytes32 indexed accountId, address caller, address indexed to, address indexed token, uint256 amount, bytes32 reason);
    event InternalTransfer(bytes32 indexed fromAccount, bytes32 indexed toAccount, address indexed token, uint256 amount);
    event SubAccountCreated(bytes32 indexed accountId, string accountName);
    event PersonalAccountCreated(bytes32 indexed accountId);
    event TransactionManagerSet(address indexed manager);
    event CitizenTransfer(
        address indexed citizen,
        bytes32 indexed fromAccount,
        bytes32 indexed toAccount,
        address token,
        uint256 amount
    );
    event BankTransfer(
        bytes32 indexed fromAccount,
        address indexed destBank,
        bytes32 indexed toAccount,
        address token,
        uint256 amount,
        uint256 fee
    );

    // === ERRORS ===

    error InvalidSubAccount();
    error Bank_Unauthorized();
    error Bank_InvalidAccount();
    error Bank_InvalidAddress();
    error Bank_InvalidToken();
    error Bank_InvalidBps();
    error Bank_ZeroAmount();
    error Bank_InsufficientBalance();
    error Bank_TransactionNotExecuted();
    error Bank_IdentityNotLinked();
    error Bank_NoAccount();
    error Bank_PersonalAccount();
    error Bank_TokenNotSupported();

    /**
     * @notice Despliega el banco y crea su subcuenta de rewards.
     * @param _institutionAddress Dueño del banco.
     * @param _rewardsBps         Fee de rewards por transferencia interna (ej. 100 = 1%).
     */
    constructor(
        address _institutionAddress,
        uint256 _rewardsBps
    ) Ownable(_institutionAddress) {
        if (_institutionAddress == address(0)) revert Bank_InvalidAddress();
        if (_rewardsBps > BPS_DENOMINATOR) revert Bank_InvalidBps();

        institutionAddress = _institutionAddress;
        rewardsBps = _rewardsBps;

        // Subcuenta de rewards creada junto con el banco
        bytes32 id = _createSubAccount("Rewards");
        rewardsAccountId = id;
        emit RewardsAccountSet(id);
    }

    // === TOKEN SUPPORT ===

    /// @notice Habilita o deshabilita depósitos de un token. Los saldos existentes no se afectan.
    function setTokenSupport(address tokenAddr, bool supported) external onlyOwner {
        _setTokenSupport(tokenAddr, supported);
    }

    /// @dev Registra el token en `_tokenList` la primera vez y actualiza el flag de soporte.
    function _setTokenSupport(address tokenAddr, bool supported) internal {
        if (tokenAddr == address(0)) revert Bank_InvalidToken();
        supportedToken[tokenAddr] = supported;
        if (!_listed[tokenAddr]) {
            _listed[tokenAddr] = true;
            _tokenList.push(tokenAddr);
        }
        emit TokenSupportChanged(tokenAddr, supported);
    }

    /// @notice Para otros bancos: indica si este banco acepta depósitos de ese token.
    function isTokenSupported(address tokenAddr) external view returns (bool) {
        return supportedToken[tokenAddr];
    }

    // === ACCOUNT CREATION ===

    /// @notice Crea una subcuenta de la institución (movible por el quórum).
    function createSubAccount(string calldata accountName) external onlyOwner returns (bytes32 accountId) {
        return _createSubAccount(accountName);
    }

    /// @notice Crea la cuenta personal de un ciudadano (solo su dueño puede moverla).
    function createCitizenAccount(string calldata accountName) external onlyOwner returns (bytes32 accountId) {
        accountId = _createSubAccount(accountName);
        personalAccount[accountId] = true;
        emit PersonalAccountCreated(accountId);
    }

    /// @dev Genera un ID determinístico y lo registra como subcuenta activa.
    function _createSubAccount(string memory accountName) internal returns (bytes32 accountId) {
        accountId = keccak256(
            abi.encodePacked(accountName, address(this), block.timestamp, subAccountIds.length)
        );
        require(!activeSubAccounts[accountId], "Account ID collision");
        activeSubAccounts[accountId] = true;
        subAccountIds.push(accountId);
        emit SubAccountCreated(accountId, accountName);
    }

    // === CONFIGURATION ===

    /**
     * @notice Cambia la subcuenta que recibe los rewards (debe existir y no ser personal).
     */
    function setRewardsAccount(bytes32 accountId) external onlyOwner {
        if (!activeSubAccounts[accountId]) revert InvalidSubAccount();
        if (personalAccount[accountId]) revert Bank_PersonalAccount();
        rewardsAccountId = accountId;
        emit RewardsAccountSet(accountId);
    }

    /// @notice Define la dirección autorizada a ejecutar `executeTransactionRelease`.
    function setTransactionManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert Bank_InvalidAddress();
        transactionManager = _manager;
        emit TransactionManagerSet(_manager);
    }

    // === DEPOSITS ===

    /**
     * @notice Deposita un token ERC20 habilitado en una subcuenta del banco.
     * @dev El depositante debe haber hecho `approve` previamente a este contrato.
     * Se acredita la cantidad realmente recibida (soporta tokens con comisión por transferencia).
     * No cobra fee de rewards.
     */
    function deposit(bytes32 accountId, address tokenAddr, uint256 amount) external nonReentrant {
        if (!activeSubAccounts[accountId]) revert InvalidSubAccount();
        if (!supportedToken[tokenAddr]) revert Bank_TokenNotSupported();
        if (amount == 0) revert Bank_ZeroAmount();

        IERC20 t = IERC20(tokenAddr);
        // Se mide el delta real: algunos tokens descuentan comisión en el transfer.
        uint256 balanceBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - balanceBefore;

        if (received == 0) revert Bank_ZeroAmount();

        accountBalances[accountId][tokenAddr] += received;
        emit TokenDeposited(accountId, msg.sender, tokenAddr, received);
    }

    // === WITHDRAWALS (RELEASE) ===

    /**
     * @notice Libera tokens de una subcuenta de la institución hacia el exterior.
     * El quórum ya se valida en LinealInstitution.releaseFromBank.
     * No puede usarse sobre cuentas personales de ciudadanos.
     */
    function release(
        bytes32 accountId,
        address tokenAddr,
        address to,
        uint256 amount,
        bytes32 reason
    ) external onlyOwner nonReentrant {
        if (!activeSubAccounts[accountId]) revert InvalidSubAccount();
        if (personalAccount[accountId]) revert Bank_PersonalAccount();
        _release(accountId, tokenAddr, to, amount, reason);
    }

    /// @notice El ciudadano retira un token desde SU subcuenta hacia cualquier address.
    function releaseFromMyAccount(address tokenAddr, address to, uint256 amount) external nonReentrant {
        bytes32 accountId = accountOf(msg.sender);
        _release(accountId, tokenAddr, to, amount, bytes32("citizen"));
    }

    /// @dev Debita el saldo interno y transfiere el token al destino.
    function _release(
        bytes32 accountId,
        address tokenAddr,
        address to,
        uint256 amount,
        bytes32 reason
    ) internal {
        if (to == address(0)) revert Bank_InvalidAddress();
        if (amount == 0) revert Bank_ZeroAmount();
        if (accountBalances[accountId][tokenAddr] < amount) revert Bank_InsufficientBalance();

        accountBalances[accountId][tokenAddr] -= amount;

        IERC20(tokenAddr).safeTransfer(to, amount);

        emit TokenReleased(accountId, msg.sender, to, tokenAddr, amount, reason);
    }

    // === INTERNAL TRANSFERS ===

    /**
     * @notice Mueve tokens entre dos subcuentas, ordenado por la Institución (multisig).
     * @dev Cobra `rewardsBps` sobre `amount`: la cuenta destino recibe `amount - fee` y la
     * cuenta de rewards recibe `fee`, ambos en el mismo token. No se cobra fee si origen o destino
     * es la cuenta de rewards. El origen no puede ser una cuenta personal.
     */
    function internalTransfer(
        bytes32 fromAccount,
        bytes32 toAccount,
        address tokenAddr,
        uint256 amount
    ) external onlyOwner {
        if (personalAccount[fromAccount]) revert Bank_PersonalAccount();
        _internalTransfer(fromAccount, toAccount, tokenAddr, amount);
    }

    /// @notice Igual que `internalTransfer` pero sin fee de rewards.
    function zeroFeeInternalTransfer(
        bytes32 fromAccount,
        bytes32 toAccount,
        address tokenAddr,
        uint256 amount
    ) external onlyOwner {
        if (personalAccount[fromAccount]) revert Bank_PersonalAccount();
        _zeroFeeInternalTransfer(fromAccount, toAccount, tokenAddr, amount);
    }

    /**
     * @notice El ciudadano mueve fondos desde SU subcuenta (la de su perfil NFT).
     * @dev Aplica el mismo fee de rewards que `internalTransfer`.
     */
    function moveFromMyAccount(bytes32 toAccount, address tokenAddr, uint256 amount) external nonReentrant {
        bytes32 fromAccount = accountOf(msg.sender);
        _internalTransfer(fromAccount, toAccount, tokenAddr, amount);
        emit CitizenTransfer(msg.sender, fromAccount, toAccount, tokenAddr, amount);
    }

    /// @notice Subcuenta del perfil de `wallet`, leída desde LinealCitizens.
    function accountOf(address wallet) public view returns (bytes32) {
        address identity = IInstitutionIdentity(institutionAddress).getIdentity();
        if (identity == address(0)) revert Bank_IdentityNotLinked();
        bytes32 id = ICitizensAccounts(identity).subAccountOf(wallet);
        if (id == bytes32(0)) revert Bank_NoAccount();
        return id;
    }

    /// @dev Transferencia interna con fee de rewards (excepto si participa la cuenta de rewards).
    function _internalTransfer(
        bytes32 fromAccount,
        bytes32 toAccount,
        address tokenAddr,
        uint256 amount
    ) internal {
        if (!activeSubAccounts[fromAccount] || !activeSubAccounts[toAccount]) revert InvalidSubAccount();
        require(fromAccount != toAccount, "ReserveBank: same account");
        if (amount == 0) revert Bank_ZeroAmount();
        if (accountBalances[fromAccount][tokenAddr] < amount) revert Bank_InsufficientBalance();

        // El fee solo aplica entre cuentas que no sean la de rewards.
        uint256 fee = 0;
        if (fromAccount != rewardsAccountId && toAccount != rewardsAccountId) {
            fee = (amount * rewardsBps) / BPS_DENOMINATOR;
        }

        accountBalances[fromAccount][tokenAddr] -= amount;
        accountBalances[toAccount][tokenAddr] += amount - fee;

        if (fee > 0) {
            accountBalances[rewardsAccountId][tokenAddr] += fee;
            emit RewardsFeeCharged(fromAccount, rewardsAccountId, tokenAddr, fee);
        }

        emit InternalTransfer(fromAccount, toAccount, tokenAddr, amount);
    }

    /// @dev Transferencia interna sin fee de rewards.
    function _zeroFeeInternalTransfer(
        bytes32 fromAccount,
        bytes32 toAccount,
        address tokenAddr,
        uint256 amount
    ) internal {
        if (!activeSubAccounts[fromAccount] || !activeSubAccounts[toAccount]) revert InvalidSubAccount();
        require(fromAccount != toAccount, "ReserveBank: same account");
        if (amount == 0) revert Bank_ZeroAmount();
        if (accountBalances[fromAccount][tokenAddr] < amount) revert Bank_InsufficientBalance();

        accountBalances[fromAccount][tokenAddr] -= amount;
        accountBalances[toAccount][tokenAddr] += amount;

        emit InternalTransfer(fromAccount, toAccount, tokenAddr, amount);
    }

    // === CROSS-BANK TRANSFERS ===

    /**
     * @notice Envía fondos de una subcuenta de ESTE banco a una subcuenta de OTRO banco.
     * @dev Ordenado por la Institución (multisig). El banco destino debe tener habilitado el token.
     * Se cobra el mismo fee de rewards que en una transferencia interna (queda en este banco);
     * el banco destino recibe `amount - fee` mediante su `deposit`, que acredita lo realmente
     * recibido. El origen no puede ser una cuenta personal.
     * @param fromAccount Subcuenta de origen en este banco.
     * @param destBank    Dirección del contrato LinealBank destino.
     * @param toAccount   Subcuenta de destino en `destBank`.
     * @param tokenAddr   Token a enviar.
     * @param amount      Monto bruto a debitar de `fromAccount`.
     */
    function transferToBank(
        bytes32 fromAccount,
        address destBank,
        bytes32 toAccount,
        address tokenAddr,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (destBank == address(0) || destBank == address(this)) revert Bank_InvalidAddress();
        if (!activeSubAccounts[fromAccount]) revert InvalidSubAccount();
        if (personalAccount[fromAccount]) revert Bank_PersonalAccount();
        if (amount == 0) revert Bank_ZeroAmount();
        if (accountBalances[fromAccount][tokenAddr] < amount) revert Bank_InsufficientBalance();
        if (!IBankDeposit(destBank).isTokenSupported(tokenAddr)) revert Bank_TokenNotSupported();

        uint256 fee = 0;
        if (fromAccount != rewardsAccountId) {
            fee = (amount * rewardsBps) / BPS_DENOMINATOR;
        }
        uint256 net = amount - fee;
        if (net == 0) revert Bank_ZeroAmount();

        // Efectos primero
        accountBalances[fromAccount][tokenAddr] -= amount;
        if (fee > 0) {
            accountBalances[rewardsAccountId][tokenAddr] += fee;
            emit RewardsFeeCharged(fromAccount, rewardsAccountId, tokenAddr, fee);
        }

        // Interacción: aprobar solo `net`, depositar en el banco destino y limpiar la aprobación
        IERC20 t = IERC20(tokenAddr);
        t.forceApprove(destBank, net);
        IBankDeposit(destBank).deposit(toAccount, tokenAddr, net);
        t.forceApprove(destBank, 0);

        emit BankTransfer(fromAccount, destBank, toAccount, tokenAddr, amount, fee);
    }

    /**
     * @notice El ciudadano envía fondos desde SU subcuenta de ESTE banco a otro banco.
     * @dev Aplica el mismo fee de rewards que `transferToBank`. Resuelve la subcuenta de origen
     * a partir del perfil del `msg.sender`.
     */
    function individualTransferToBank(
        address destBank,
        bytes32 toAccount,
        address tokenAddr,
        uint256 amount
    ) external nonReentrant {
        if (destBank == address(0) || destBank == address(this)) revert Bank_InvalidAddress();
        if (amount == 0) revert Bank_ZeroAmount();
        bytes32 fromAccount = accountOf(msg.sender);
        if (!activeSubAccounts[fromAccount]) revert InvalidSubAccount();
        if (!IBankDeposit(destBank).isTokenSupported(tokenAddr)) revert Bank_TokenNotSupported();
        if (accountBalances[fromAccount][tokenAddr] < amount) revert Bank_InsufficientBalance();

        uint256 fee = 0;
        if (fromAccount != rewardsAccountId) {
            fee = (amount * rewardsBps) / BPS_DENOMINATOR;
        }
        uint256 net = amount - fee;
        if (net == 0) revert Bank_ZeroAmount();

        // Efectos primero
        accountBalances[fromAccount][tokenAddr] -= amount;
        if (fee > 0) {
            accountBalances[rewardsAccountId][tokenAddr] += fee;
            emit RewardsFeeCharged(fromAccount, rewardsAccountId, tokenAddr, fee);
        }

        // Interacción: aprobar solo `net`, depositar en el banco destino y limpiar la aprobación
        IERC20 t = IERC20(tokenAddr);
        t.forceApprove(destBank, net);
        IBankDeposit(destBank).deposit(toAccount, tokenAddr, net);
        t.forceApprove(destBank, 0);

        emit BankTransfer(fromAccount, destBank, toAccount, tokenAddr, amount, fee);
    }

    // === TRANSACTION MANAGER EXECUTION ===

    /**
     * @notice Ejecuta la liberación basada en una transacción validada por el gestor.
     * Solo puede ser llamada por el transactionManager.
     * No puede mover fondos de cuentas personales.
     */
    function executeTransactionRelease(bytes32 txId) external nonReentrant {
        if (msg.sender != transactionManager) revert Bank_Unauthorized();

        (address to, address tokenAddr, uint256 amount, bool executed, bytes32 fromAccount) =
            ILinealTransactions(transactionManager).getTransactionForBank(txId);

        if (!executed) revert Bank_TransactionNotExecuted();
        if (personalAccount[fromAccount]) revert Bank_PersonalAccount();
        if (to == address(0)) revert Bank_InvalidAddress();
        if (accountBalances[fromAccount][tokenAddr] < amount) revert Bank_InsufficientBalance();

        accountBalances[fromAccount][tokenAddr] -= amount;

        IERC20(tokenAddr).safeTransfer(to, amount);

        emit TokenReleased(fromAccount, msg.sender, to, tokenAddr, amount, txId);
    }

    // === VIEW FUNCTIONS ===

    /// @notice Saldo de una subcuenta para un token específico.
    function accountBalance(bytes32 accountId, address tokenAddr) external view returns (uint256) {
        return accountBalances[accountId][tokenAddr];
    }

    /// @notice Saldos de una subcuenta en todos los tokens registrados (para paneles y apps).
    function accountBalancesAll(bytes32 accountId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances)
    {
        uint256 n = _tokenList.length;
        tokens = new address[](n);
        balances = new uint256[](n);
        for (uint256 i; i < n; i++) {
            tokens[i] = _tokenList[i];
            balances[i] = accountBalances[accountId][_tokenList[i]];
        }
    }

    /// @notice Tokens registrados (habilitados o no); consulta `supportedToken` para el estado.
    function tokenList() external view returns (address[] memory) {
        return _tokenList;
    }

    /// @notice Total de un token que custodia el banco.
    function totalReserveBalance(address tokenAddr) external view returns (uint256) {
        return IERC20(tokenAddr).balanceOf(address(this));
    }
}

// === MINIMAL INTERFACES ===

/// @notice Mínima interfaz de LinealTransactions para leer transacciones validadas.
interface ILinealTransactions {
    function getTransactionForBank(bytes32 txId) external view returns (
        address to,
        address token,
        uint256 amount,
        bool executed,
        bytes32 fromAccount
    );
}

/// @notice Mínima interfaz de LinealInstitution para resolver la identidad vinculada.
interface IInstitutionIdentity {
    function getIdentity() external view returns (address);
}

/// @notice Mínima interfaz de LinealCitizens para resolver la subcuenta de un perfil.
interface ICitizensAccounts {
    function subAccountOf(address wallet) external view returns (bytes32);
}

/// @notice Mínima interfaz de otro LinealBank para recibir fondos.
interface IBankDeposit {
    function isTokenSupported(address token) external view returns (bool);
    function deposit(bytes32 accountId, address token, uint256 amount) external;
}

/// @notice Low Life, High Tech - Todos los derechos reservados.