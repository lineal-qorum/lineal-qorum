// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../../core/Groth16Verifier.sol";

abstract contract LinealQantum {

    address[] public signers;
    uint256 public requiredSignatures;
    address public guardian;

    mapping(bytes32 => mapping(address => bool)) public isConfirmed;
    mapping(bytes32 => uint256) public confirmationCount;
    mapping(bytes32 => bool) public isExecuted;

    mapping(address => bytes32) public quantumCommitments;
    mapping(bytes32 => bool) public usedNullifiers;

    struct RecoveryProposal {
        address[] newSigners;
        uint256   newRequired;
        uint256   proposedAt;
        uint256   confirmations;
        bool      executed;
        mapping(address => bool) confirmedBy;
    }

    mapping(bytes32 => RecoveryProposal) private _recoveryProposals;
    uint256 public recoveryQuorum;
    uint256 public constant RECOVERY_DELAY = 2 hours;

    struct ZKProof {
        uint[2] pA;
        uint[2][2] pB;
        uint[2] pC;
        // Orden exacto que produce snarkJS para SecretVerifier():
        // output primero, luego inputs públicos en orden de declaración del component main
        // [0] nullifier       ← output
        // [1] commitment      ← public input (declarado 1º en component main)
        // [2] txHash          ← public input (declarado 2º)
        // [3] contractAddress ← public input (declarado 3º)
        // [4] chainId         ← public input (declarado 4º)
        // [5] signerAddress   ← public input (declarado 5º)
        uint[6] pubSignals;
    }

    Groth16Verifier public zkVerifier;

    event ActionProposed(bytes32 indexed txHash, address indexed proposer, string actionType);
    event ActionConfirmed(bytes32 indexed txHash, address indexed signer);
    event ActionExecuted(bytes32 indexed txHash);
    event SignersRotated(address[] newSigners, uint256 newRequired);
    event GuardianUpdated(address newGuardian);
    event QuantumCommitmentUpdated(address indexed signer, bytes32 commitment);
    event RecoveryProposed(bytes32 indexed recoveryHash, address indexed proposer);
    event RecoveryConfirmed(bytes32 indexed recoveryHash, address indexed confirmer, uint256 confirmations);
    event RecoveryExecuted(bytes32 indexed recoveryHash);

    modifier onlySigner() {
        require(_isSigner(msg.sender), "MultiSig: caller is not a signer");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "MultiSig: only guardian");
        _;
    }

    constructor(
        address[] memory _signers,
        uint256 _required,
        address _guardian,
        address _zkVerifier,
        uint256 _recoveryQuorum
    ) {
        require(_signers.length >= _required, "MultiSig: signers < required");
        require(_required > 0, "MultiSig: required must be > 0");
        require(_guardian != address(0), "MultiSig: invalid guardian");
        require(_zkVerifier != address(0), "MultiSig: invalid zkVerifier");
        require(_recoveryQuorum > 0, "MultiSig: recoveryQuorum must be > 0");

        for (uint256 i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "MultiSig: invalid signer");
            for (uint256 j = 0; j < i; j++) {
                require(_signers[i] != _signers[j], "MultiSig: duplicate signer");
            }
            signers.push(_signers[i]);
        }

        requiredSignatures = _required;
        guardian = _guardian;
        zkVerifier = Groth16Verifier(_zkVerifier);
        recoveryQuorum = _recoveryQuorum;
    }

    // ═══════════════════════════════════════════════════════════
    // BLOQUE H — RECOVERY
    // ═══════════════════════════════════════════════════════════

    function proposeRecovery(
        address[] memory _newSigners,
        uint256 _newRequired
    ) external onlyGuardian returns (bytes32 recoveryHash) {
        require(_newSigners.length >= _newRequired, "MultiSig: signers < required");
        require(_newRequired > 0, "MultiSig: required > 0");

        for (uint256 i = 0; i < _newSigners.length; i++) {
            require(_newSigners[i] != address(0), "MultiSig: invalid signer");
            for (uint256 j = 0; j < i; j++) {
                require(_newSigners[i] != _newSigners[j], "MultiSig: duplicate signer");
            }
        }

        recoveryHash = keccak256(abi.encode(
            _newSigners,
            _newRequired,
            block.timestamp,
            address(this),
            block.chainid
        ));

        RecoveryProposal storage proposal = _recoveryProposals[recoveryHash];
        require(proposal.proposedAt == 0, "MultiSig: proposal already exists");

        proposal.newSigners    = _newSigners;
        proposal.newRequired   = _newRequired;
        proposal.proposedAt    = block.timestamp;
        proposal.confirmations = 1;
        proposal.confirmedBy[msg.sender] = true;

        emit RecoveryProposed(recoveryHash, msg.sender);
        emit RecoveryConfirmed(recoveryHash, msg.sender, 1);
    }

    function confirmRecovery(bytes32 recoveryHash) external onlyGuardian {
        RecoveryProposal storage proposal = _recoveryProposals[recoveryHash];
        require(proposal.proposedAt != 0, "MultiSig: proposal not found");
        require(!proposal.executed, "MultiSig: already executed");
        require(!proposal.confirmedBy[msg.sender], "MultiSig: already confirmed");

        proposal.confirmedBy[msg.sender] = true;
        proposal.confirmations++;

        emit RecoveryConfirmed(recoveryHash, msg.sender, proposal.confirmations);
    }

    function executeRecovery(bytes32 recoveryHash) external onlyGuardian {
        RecoveryProposal storage proposal = _recoveryProposals[recoveryHash];
        require(proposal.proposedAt != 0, "MultiSig: proposal not found");
        require(!proposal.executed, "MultiSig: already executed");
        require(
            proposal.confirmations >= recoveryQuorum,
            "MultiSig: insufficient recovery confirmations"
        );
        require(
            block.timestamp >= proposal.proposedAt + RECOVERY_DELAY,
            "MultiSig: recovery delay not elapsed"
        );

        proposal.executed = true;
        signers = proposal.newSigners;
        requiredSignatures = proposal.newRequired;

        emit SignersRotated(proposal.newSigners, proposal.newRequired);
        emit RecoveryExecuted(recoveryHash);
    }

    function setGuardian(address _newGuardian) external onlyGuardian {
        require(_newGuardian != address(0), "MultiSig: invalid guardian");
        guardian = _newGuardian;
        emit GuardianUpdated(_newGuardian);
    }

    // ═══════════════════════════════════════════════
    // CORE ZK
    // ═══════════════════════════════════════════════

    function _isSigner(address account) public view returns (bool) {
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == account) return true;
        }
        return false;
    }

    function setQuantumCommitment(bytes32 _hash) external onlySigner {
        require(_hash != bytes32(0), "MultiSig: invalid hash");
        quantumCommitments[msg.sender] = _hash;
        emit QuantumCommitmentUpdated(msg.sender, _hash);
    }

    function confirmWithZK(
        bytes32 txHash,
        string memory actionType,
        ZKProof memory proof
    ) internal returns (bool) {
        return _confirmWithZKFor(txHash, msg.sender, actionType, proof);
    }

    function _confirmWithZKFor(
        bytes32 txHash,
        address signer,
        string memory actionType,
        ZKProof memory proof
    ) internal returns (bool) {
        // BLOQUE G: guard temprano
        require(!isExecuted[txHash], "ZK: action already executed");

        require(_isSigner(signer), "ZK: not a signer");
        require(quantumCommitments[signer] != bytes32(0), "ZK: commitment required");

        // [0] nullifier — anti-replay
        require(!usedNullifiers[bytes32(proof.pubSignals[0])], "ZK: nullifier already used");

        // [1] commitment — binding al secreto registrado on-chain
        require(
            quantumCommitments[signer] == bytes32(proof.pubSignals[1]),
            "ZK: commitment mismatch"
        );

        // [2] txHash — binding a la acción concreta
        require(
            txHash == bytes32(proof.pubSignals[2]),
            "ZK: txHash mismatch"
        );

        // [3] contractAddress — domain separation (CORREGIDO: era [4])
        require(
            address(this) == address(uint160(proof.pubSignals[3])),
            "ZK: contract mismatch"
        );

        // [4] chainId — domain separation (CORREGIDO: era [5])
        require(
            block.chainid == proof.pubSignals[4],
            "ZK: chainId mismatch"
        );

        // [5] signerAddress — identity binding (CORREGIDO: era [3])
        require(
            signer == address(uint160(proof.pubSignals[5])),
            "ZK: signer mismatch"
        );

        // Verificación ZK al final — operación más costosa
        require(
            zkVerifier.verifyProof(proof.pA, proof.pB, proof.pC, proof.pubSignals),
            "ZK: Invalid proof"
        );

        // Quemar nullifier después de verificación exitosa
        usedNullifiers[bytes32(proof.pubSignals[0])] = true;

        return _confirmActionFor(txHash, signer, actionType);
    }

    mapping(string => uint256) public actionNonce;

    function getActionNonce(string memory actionType) public view returns (uint256) {
        return actionNonce[actionType];
    }

    function _computeActionHash(
        string memory actionType,
        bytes memory params
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256(bytes(actionType)),
            address(this),
            block.chainid,
            params,
            keccak256(params),
            actionNonce[actionType]
        ));
    }

    function _confirmActionFor(
        bytes32 txHash,
        address signer,
        string memory actionType
    ) internal returns (bool) {
        require(!isExecuted[txHash], "MultiSig: action already executed");
        require(!isConfirmed[txHash][signer], "MultiSig: already confirmed");

        isConfirmed[txHash][signer] = true;
        confirmationCount[txHash]++;

        if (confirmationCount[txHash] == 1) {
            emit ActionProposed(txHash, signer, actionType);
        }

        emit ActionConfirmed(txHash, signer);

        if (confirmationCount[txHash] >= requiredSignatures) {
            isExecuted[txHash] = true;
            actionNonce[actionType]++;
            emit ActionExecuted(txHash);
            return true;
        }

        return false;
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.