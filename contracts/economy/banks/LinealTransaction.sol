// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "./LinealQantum.sol";

/**
 * @title AdministrativeAuthorizationTransferContract
 * @notice Contrato con MultiSig estático (heredado) + MultiSig dinámico (autorizadores administrativos)
 *
 * FLUJO:
 * 1. Operador CREA transacción (NO firma, solo ingresa data) + define 3 wallets autorizadoras
 * 2. MultiSig DINÁMICO: 3/3 autorizadores administrativos deben firmar
 * 3. MultiSig ESTÁTICO: Signers institucionales/quorum firman (heredado de MultiSigBase)
 * 4. EJECUCIÓN: Cuando ambos MultiSig completos → ejecuta
 */
interface ILinealBank {
    function executeTransactionRelease(bytes32 txId) external;
}

contract LinealTransactions is LinealQantum {

    // ═════════════════════════════════════════════════════════════════════════
    // ESTRUCTURAS
    // ═════════════════════════════════════════════════════════════════════════

    struct TransactionMetadata {
        string recipientName;
        string motivo;
        string documento;
        string mensaje;
        string tipo;
    }

    struct QorumTransaction {
        address to;
        uint256 amount;
        bytes32 referenceHash;
        address createdBy;
        uint256 timestamp;
        uint256 expiresAt;
        bool executed;
        bool cancelled;

        address fromAccount;
        address tokenAddress;

        // Metadatos Institucionales
        TransactionMetadata meta;

        // MultiSig Dinámico
        address[3] administrativeAuthorizers;
        mapping(address => bool) hasAuthorized;
        uint256 adminSignatures;

        bool staticMultiSigCompleted;
    }

    uint256 public txCounter;
    mapping(bytes32 => bool) public referenceHashUsed;

    address public bankAddress;

    function setBankAddress(address _bank) external onlyGuardian {
        bankAddress = _bank;
    }

    // DEPRECATED: RolesContract removido del sistema
    // RolesContract public rolesContract;

    // Transacciones administrativas
    mapping(bytes32 => QorumTransaction) public transactions;
    bytes32[] public transactionIds;

    // Historial de transacciones ejecutadas
    struct ExecutedTransfer {
        address to;
        uint256 amount;
        bytes32 referenceHash;
        address createdBy;
        uint256 timestamp;
        TransactionMetadata meta;
    }
    ExecutedTransfer[] public transferHistory;

    // Balance simulado
    mapping(address => uint256) public entityBalance;

    // ═════════════════════════════════════════════════════════════════════════
    // EVENTOS
    // ═════════════════════════════════════════════════════════════════════════

    event TransactionCreated(
        bytes32 indexed txId,
        address indexed to,
        uint256 amount,
        bytes32 referenceHash,
        address createdBy,
        string recipientName,
        string tipo
    );

    event TransactionCancelled(bytes32 indexed txId);

    event AdministrativeAuthorized(
        bytes32 indexed txId,
        address indexed authorizer,
        uint256 adminSignatures
    );

    event StaticMultiSigCompleted(
        bytes32 indexed txId
    );

    event TransactionExecuted(
        bytes32 indexed txId,
        address indexed to,
        uint256 amount,
        bytes32 referenceHash
    );

    // ═════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    constructor(
        address[] memory _signers,
        uint256 _required,
        address _guardian,
        address _zkVerifier,
        uint256 recoveryQorum
    ) LinealQantum(_signers, _required, _guardian, _zkVerifier, recoveryQorum) {}

    // ═════════════════════════════════════════════════════════════════════════
    // FASE 1: CREACIÓN (Operador NO firma, solo crea)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Operador crea transacción y define 3 autorizadores administrativos
     * @param _to Destinatario
     * @param _amount Monto
     * @param _referenceHash Hash de referencia
     * @param _administrativeAuthorizers [3] Wallets que deben autorizar (MultiSig dinámico)
     * @return txId ID de la transacción
     */
    function createTransaction(
        address _to,
        uint256 _amount,
        bytes32 _referenceHash,
        address[3] memory _administrativeAuthorizers,
        address _fromAccount,
        address _tokenAddress,
        TransactionMetadata memory _meta
    ) external onlySigner returns (bytes32 txId) {
        require(_to != address(0), "AAC: invalid recipient");
        require(_amount > 0, "AAC: invalid amount");
        require(_referenceHash != bytes32(0), "AAC: reference required");
        require(!referenceHashUsed[_referenceHash], "AAC: reference already used");

        // Validar autorizadores administrativos y separación de deberes
        for (uint256 i = 0; i < 3; i++) {
            require(_administrativeAuthorizers[i] != address(0), "AAC: invalid authorizer");
            require(!_isSigner(_administrativeAuthorizers[i]), "AAC: authorizer cannot be static signer");
            for (uint256 j = 0; j < i; j++) {
                require(_administrativeAuthorizers[i] != _administrativeAuthorizers[j], "AAC: duplicate authorizer");
            }
        }

        // Generar ID único con contador y encode
        txId = keccak256(abi.encode(
            _to,
            _amount,
            _referenceHash,
            msg.sender,
            block.timestamp,
            txCounter++
        ));

        require(transactions[txId].timestamp == 0, "AAC: txId collision");

        // Crear transacción
        transactions[txId].to = _to;
        transactions[txId].amount = _amount;
        transactions[txId].referenceHash = _referenceHash;
        transactions[txId].createdBy = msg.sender;
        transactions[txId].timestamp = block.timestamp;
        transactions[txId].expiresAt = block.timestamp + 3 days;
        transactions[txId].administrativeAuthorizers = _administrativeAuthorizers;
        transactions[txId].fromAccount = _fromAccount;
        transactions[txId].tokenAddress = _tokenAddress;
        transactions[txId].meta = _meta;

        transactionIds.push(txId);
        referenceHashUsed[_referenceHash] = true;

        emit TransactionCreated(
            txId,
            _to,
            _amount,
            _referenceHash,
            msg.sender,
            _meta.recipientName,
            _meta.tipo
        );

        return txId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FASE 2: AUTORIZACIÓN (TODO pasa por MultiSig heredado)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Agregador de Consenso 9/9
     * Procesa 3 firmas humanas y 6 pruebas ZK de servidores en una sola transacción.
     */
    function aggregateConsensus(
        bytes32 txId,
        bytes[3] calldata humanSignatures,
        ZKProof[6] calldata serverProofs,
        address[6] calldata serverAddresses
    ) external {
        QorumTransaction storage txn = transactions[txId];
        require(txn.timestamp > 0, "AAC: not found");
        require(!txn.executed, "AAC: already executed");

        // 1. Validar Capa Humana (3/3 Administrativos)
        // El hash debe ser el txId firmado por el operador
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", txId));
        for (uint256 i = 0; i < 3; i++) {
            address authorizer = txn.administrativeAuthorizers[i];
            require(!txn.hasAuthorized[authorizer], "AAC: human already authorized");

            address signer = _recoverSigner(ethHash, humanSignatures[i]);
            require(signer == authorizer, "AAC: invalid human signature");

            txn.hasAuthorized[authorizer] = true;
            txn.adminSignatures++;
        }

        // 2. Validar Capa de Servidores (6/6 Institucionales)
        // Usamos el hash de acción estándar del contrato
        bytes32 actionHash = keccak256(abi.encode("authorizeTransaction", txId));
        for (uint256 i = 0; i < 6; i++) {
            require(_confirmWithZKFor(actionHash, serverAddresses[i], "authorizeTransaction", serverProofs[i]), "AAC: ZK validation failed");
        }

        // 3. Verificación de Quorum Estático
        if (confirmationCount[actionHash] >= requiredSignatures) {
            txn.staticMultiSigCompleted = true;
            emit StaticMultiSigCompleted(txId);
        }

        // 4. Intento de Ejecución Automática
        _tryExecute(txId);
    }

    /**
     * @notice Función de consulta para el banco
     */
    function getTransactionForBank(bytes32 txId) external view returns (
        address to,
        uint256 amount,
        bool executed,
        address fromAccount,
        address tokenAddress
    ) {
        QorumTransaction storage txn = transactions[txId];
        return (txn.to, txn.amount, txn.executed, txn.fromAccount, txn.tokenAddress);
    }

    function _recoverSigner(bytes32 _hash, bytes memory _signature) internal pure returns (address) {
        if (_signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }
        return ecrecover(_hash, v, r, s);
    }

    /**
     * @notice Autoriza transacción (SIEMPRE a través de MultiSig heredado)
     * @dev Valida que caller sea signer de red O autorizador humano definido
     * @param txId ID de la transacción
     */
    function authorizeTransaction(bytes32 txId) external {
        QorumTransaction storage txn = transactions[txId];

        require(txn.timestamp > 0, "AAC: transaction not found");
        require(!txn.executed, "AAC: already executed");
        require(!txn.cancelled, "AAC: cancelled");
        require(block.timestamp <= txn.expiresAt, "AAC: expired");

        bool isStaticSigner = _isSigner(msg.sender);
        bool isHumanAuthorizer = false;

        for (uint256 i = 0; i < 3; i++) {
            if (txn.administrativeAuthorizers[i] == msg.sender) {
                isHumanAuthorizer = true;
                break;
            }
        }

        require(
            isStaticSigner || isHumanAuthorizer,
            "AAC: unauthorized"
        );

        // BLOQUE C: Generar hash robusto con abi.encode y domain separation
        bytes32 actionHash = _computeActionHash(
            "authorizeTransaction",
            abi.encode(txId)
        );

        if (isStaticSigner) {
            // Usamos el hash único basado en txId para que cada tx tenga su propio ciclo de firmas
            if (_confirmActionFor(actionHash, msg.sender, "authorizeTransaction")) {
                txn.staticMultiSigCompleted = true;
                emit StaticMultiSigCompleted(txId);
            }
        }

        if (isHumanAuthorizer && !txn.hasAuthorized[msg.sender]) {
            txn.hasAuthorized[msg.sender] = true;
            txn.adminSignatures++;
            emit AdministrativeAuthorized(txId, msg.sender, txn.adminSignatures);
        }

        _tryExecute(txId);
    }

    /**
     * @notice Cancela una transacción. Solo por el creador o por MultiSig.
     */
    function cancelTransaction(bytes32 txId) external onlySigner {
        QorumTransaction storage txn = transactions[txId];
        require(txn.timestamp > 0, "AAC: not found");
        require(!txn.executed, "AAC: already executed");

        bool isCreator = (msg.sender == txn.createdBy);
        bool isMultiSig = false;

        // BLOQUE C: Generar hash robusto con abi.encode y domain separation
        bytes32 actionHash = _computeActionHash(
            "cancelTransaction",
            abi.encode(txId)
        );
        if (!_confirmActionFor(actionHash, msg.sender, "cancelTransaction")) return;

        if (isCreator) {
            txn.cancelled = true;
            emit TransactionCancelled(txId);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FASE 3: EJECUCIÓN (Ambos contadores completos)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Intenta ejecutar si ambos thresholds alcanzados
     * @dev 3/3 humanos + threshold de red (ambos a través de MultiSig heredado)
     */
    function _tryExecute(bytes32 txId) private {
        QorumTransaction storage txn = transactions[txId];

        if (txn.executed || txn.cancelled) return;

        // VALIDAR: 3/3 autorizadores humanos
        bool humanAuthorizersComplete = (txn.adminSignatures == 3);

        // VALIDAR: MultiSig de red completo (threshold alcanzado)
        bool networkMultiSigComplete = txn.staticMultiSigCompleted;

        // EJECUTAR solo si AMBOS completos
        if (humanAuthorizersComplete && networkMultiSigComplete) {
            txn.executed = true;

            // Registrar en historial
            transferHistory.push(ExecutedTransfer({
                to: txn.to,
                amount: txn.amount,
                referenceHash: txn.referenceHash,
                createdBy: txn.createdBy,
                timestamp: block.timestamp,
                meta: txn.meta
            }));

            // EJECUCIÓN REAL EN EL BANCO
            if (bankAddress != address(0)) {
                ILinealBank(bankAddress).executeTransactionRelease(txId);
            }

            emit TransactionExecuted(
                txId,
                txn.to,
                txn.amount,
                txn.referenceHash
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FUNCIONES DE CONSULTA
    // ═════════════════════════════════════════════════════════════════════════

    function getTransactionStatus(bytes32 txId) external view returns (
        bool exists,
        bool executed,
        uint256 adminSignatures,
        bool adminMultiSigComplete,
        bool staticMultiSigComplete,
        bool canExecute,
        address to,
        uint256 amount
    ) {
        QorumTransaction storage txn = transactions[txId];
        bool adminComplete = (txn.adminSignatures == 3);

        return (
            txn.timestamp > 0,
            txn.executed,
            txn.adminSignatures,
            adminComplete,
            txn.staticMultiSigCompleted,
            adminComplete && txn.staticMultiSigCompleted,
            txn.to,
            txn.amount
        );
    }

    function getAdministrativeAuthorizers(bytes32 txId) external view returns (address[3] memory) {
        return transactions[txId].administrativeAuthorizers;
    }

    function hasUserAuthorized(bytes32 txId, address user) external view returns (bool) {
        return transactions[txId].hasAuthorized[user];
    }

    function getTransactionIds(uint256 from, uint256 to) external view returns (bytes32[] memory) {
        require(from <= to && to < transactionIds.length, "AAC: invalid range");
        uint256 size = to - from + 1;
        bytes32[] memory result = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = transactionIds[from + i];
        }
        return result;
    }

    function getTransferHistory(uint256 from, uint256 to) external view returns (ExecutedTransfer[] memory) {
        require(from <= to && to < transferHistory.length, "AAC: invalid range");
        uint256 size = to - from + 1;
        ExecutedTransfer[] memory result = new ExecutedTransfer[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = transferHistory[from + i];
        }
        return result;
    }

    function getTransactionCount() external view returns (uint256) {
        return transactionIds.length;
    }

    function getExecutedTransferCount() external view returns (uint256) {
        return transferHistory.length;
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.