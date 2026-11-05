// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title LinealQorum
 * @author NeoQuor - Lineal Qorum Fundation
 * @notice Sistema Multi-firma tripartito para combatir la corrupción y el fraude sistémico, jake al rey.
 *
 */
abstract contract LinealQorum {
    // 1 = Machine, 2 = Institution, 3 = Human
    mapping(address => uint8) public signerType;

    address[] public machines;
    address[] public institutions;
    address[] public humans;

    uint256 public requiredMachines;
    uint256 public requiredInstitutions;
    uint256 public requiredHumans;

    address public guardian;
    address public identityContract;

    mapping(bytes32 => mapping(address => bool)) public isConfirmed;
    mapping(bytes32 => uint256) public confirmationCount;
    mapping(bytes32 => bool) public isExecuted;

    mapping(bytes32 => uint256) public machineConfirmations;
    mapping(bytes32 => uint256) public institutionConfirmations;
    mapping(bytes32 => uint256) public humanConfirmations;

    mapping(string => uint256) public actionNonce;

    uint256 public recoveryQuorum;
    uint256 public constant RECOVERY_DELAY = 2 hours;

    struct RecoveryProposal {
        address[] newMachines;
        address[] newInstitutions;
        address[] newHumans;
        uint256 newRequiredMachines;
        uint256 newRequiredInstitutions;
        uint256 newRequiredHumans;
        uint256 proposedAt;
        uint256 confirmations;
        bool executed;
        mapping(address => bool) confirmedBy;
    }

    mapping(bytes32 => RecoveryProposal) private _recoveryProposals;

    event ActionProposed(bytes32 indexed txHash, address indexed proposer, string actionType);
    event ActionConfirmed(bytes32 indexed txHash, address indexed signer);
    event ActionExecuted(bytes32 indexed txHash);
    event GuardianUpdated(address indexed newGuardian);
    event QuantumCommitmentUpdated(address indexed signer, bytes32 commitment);
    event RecoveryProposed(bytes32 indexed recoveryHash, address indexed proposer);
    event RecoveryConfirmed(bytes32 indexed recoveryHash, address indexed confirmer, uint256 confirmations);
    event RecoveryExecuted(bytes32 indexed recoveryHash);

    modifier onlyQorum() {
        require(signerType[msg.sender] != 0, "LQ: not signer");
        _;
    }

    modifier onlyServers() {
        uint8 sType = signerType[msg.sender];
        require(sType == 1 || sType == 2, "LQ: not a server layer");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "LQ: only guardian");
        _;
    }

    constructor(
        address[] memory _qorumServers,
        uint256 _requiredQorumServers,
        address[] memory _institutionsServers,
        uint256 _requiredInstitutionsServers,
        address[] memory _operators,
        uint256 _requiredOperators,
        uint256 _recoveryQuorum
    ) {
        require(_requiredQorumServers > 0 && _qorumServers.length >= _requiredQorumServers, "LQ: invalid machines req");
        require(_requiredInstitutionsServers > 0 && _institutionsServers.length >= _requiredInstitutionsServers, "LQ: invalid inst req");
        require(_recoveryQuorum > 0, "LQ: invalid recovery quorum");

        requiredMachines = _requiredQorumServers;
        requiredInstitutions = _requiredInstitutionsServers;
        recoveryQuorum = _recoveryQuorum;

        if (_operators.length > 0) {
            require(_requiredOperators > 0 && _operators.length >= _requiredOperators, "LQ: invalid humans req");
            requiredHumans = _requiredOperators;
        }

        _addSigners(_qorumServers, 1, machines);
        _addSigners(_institutionsServers, 2, institutions);
        _addSigners(_operators, 3, humans);
    }

    function proposeRecovery(
        address[] memory _newMachines,
        uint256 _newRequiredMachines,
        address[] memory _newInstitutions,
        uint256 _newRequiredInstitutions,
        address[] memory _newHumans,
        uint256 _newRequiredHumans
    ) external onlyQorum returns (bytes32 recoveryHash) {
        require(_newRequiredMachines > 0 && _newMachines.length >= _newRequiredMachines, "LQ: invalid machines");
        require(_newRequiredInstitutions > 0 && _newInstitutions.length >= _newRequiredInstitutions, "LQ: invalid inst");
        require(_newRequiredHumans > 0 && _newHumans.length >= _newRequiredHumans, "LQ: invalid humans");

        _validateAddresses(_newMachines);
        _validateAddresses(_newInstitutions);
        _validateAddresses(_newHumans);

        recoveryHash = keccak256(abi.encode(
            _newMachines,
            _newRequiredMachines,
            _newInstitutions,
            _newRequiredInstitutions,
            _newHumans,
            _newRequiredHumans,
            address(this),
            block.chainid
        ));

        RecoveryProposal storage proposal = _recoveryProposals[recoveryHash];
        require(proposal.proposedAt == 0, "LQ: proposal exists");

        proposal.newMachines = _newMachines;
        proposal.newInstitutions = _newInstitutions;
        proposal.newHumans = _newHumans;
        proposal.newRequiredMachines = _newRequiredMachines;
        proposal.newRequiredInstitutions = _newRequiredInstitutions;
        proposal.newRequiredHumans = _newRequiredHumans;
        proposal.proposedAt = block.timestamp;
        proposal.confirmations = 1;
        proposal.confirmedBy[msg.sender] = true;

        emit RecoveryProposed(recoveryHash, msg.sender);
        emit RecoveryConfirmed(recoveryHash, msg.sender, 1);
    }

    function confirmRecovery(bytes32 recoveryHash) external onlyQorum {
        RecoveryProposal storage proposal = _recoveryProposals[recoveryHash];
        require(proposal.proposedAt != 0, "LQ: proposal not found");
        require(!proposal.executed, "LQ: already executed");
        require(!proposal.confirmedBy[msg.sender], "LQ: already confirmed");

        proposal.confirmedBy[msg.sender] = true;
        proposal.confirmations++;

        emit RecoveryConfirmed(recoveryHash, msg.sender, proposal.confirmations);
    }

    function executeRecovery(bytes32 recoveryHash) external onlyQorum {
        RecoveryProposal storage proposal = _recoveryProposals[recoveryHash];
        require(proposal.proposedAt != 0, "LQ: not found");
        require(!proposal.executed, "LQ: already executed");
        require(proposal.confirmations >= recoveryQuorum, "LQ: insufficient confirmations");
        require(block.timestamp >= proposal.proposedAt + RECOVERY_DELAY, "LQ: delay not passed");

        proposal.executed = true;

        _clearSigners(machines);
        _clearSigners(institutions);
        _clearSigners(humans);

        _addSigners(proposal.newMachines, 1, machines);
        _addSigners(proposal.newInstitutions, 2, institutions);
        _addSigners(proposal.newHumans, 3, humans);

        requiredMachines = proposal.newRequiredMachines;
        requiredInstitutions = proposal.newRequiredInstitutions;
        requiredHumans = proposal.newRequiredHumans;

        emit RecoveryExecuted(recoveryHash);
    }

    function setGuardian(address _newGuardian) external virtual onlyQorum {
        require(_newGuardian != address(0), "LQ: invalid guardian");
        guardian = _newGuardian;
        emit GuardianUpdated(_newGuardian);
    }


    function confirmServers(
        bytes32 txHash,
        string memory actionType
    ) internal returns (bool) {
        require(!isExecuted[txHash], "LQ: already executed");
        uint8 sType = signerType[msg.sender];
        require(sType == 1 || sType == 2, "LQ: not a server layer");
        require(!isConfirmed[txHash][msg.sender], "LQ: already confirmed");

        isConfirmed[txHash][msg.sender] = true;

        if (sType == 1) {
            machineConfirmations[txHash]++;
        } else {
            institutionConfirmations[txHash]++;
        }

        if (confirmationCount[txHash] == 0) {
            emit ActionProposed(txHash, msg.sender, actionType);
        }

        confirmationCount[txHash]++;
        emit ActionConfirmed(txHash, msg.sender);

        if (
            machineConfirmations[txHash] >= requiredMachines &&
            institutionConfirmations[txHash] >= requiredInstitutions
        ) {
            isExecuted[txHash] = true;
            actionNonce[actionType]++;
            emit ActionExecuted(txHash);
            return true;
        }

        return false;
    }

    function confirm(
        bytes32 txHash,
        string memory actionType
    ) internal returns (bool) {
        require(!isExecuted[txHash], "LQ: already executed");
        require(signerType[msg.sender] != 0, "LQ: invalid signer");
        require(!isConfirmed[txHash][msg.sender], "LQ: already confirmed");

        isConfirmed[txHash][msg.sender] = true;
        uint8 sType = signerType[msg.sender];

        if (sType == 1) {
            machineConfirmations[txHash]++;
        } else if (sType == 2) {
            institutionConfirmations[txHash]++;
        } else if (sType == 3) {
            humanConfirmations[txHash]++;
        }

        if (confirmationCount[txHash] == 0) {
            emit ActionProposed(txHash, msg.sender, actionType);
        }

        confirmationCount[txHash]++;
        emit ActionConfirmed(txHash, msg.sender);

        if (
            machineConfirmations[txHash] >= requiredMachines &&
            institutionConfirmations[txHash] >= requiredInstitutions &&
            humanConfirmations[txHash] >= requiredHumans
        ) {
            isExecuted[txHash] = true;
            actionNonce[actionType]++;
            emit ActionExecuted(txHash);
            return true;
        }

        return false;
    }

    function _computeActionHash(
        string memory actionType,
        bytes memory params
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256(bytes(actionType)),
            address(this),
            block.chainid,
            keccak256(params),
            actionNonce[actionType]
        ));
    }

    function _isSigner(address account) public view returns (bool) {
        return signerType[account] != 0;
    }

    function _isMachine(address account) internal view returns (bool) {
        return signerType[account] == 1;
    }

    function _isInstitution(address account) internal view returns (bool) {
        return signerType[account] == 2;
    }

    function _isHuman(address account) internal view returns (bool) {
        return signerType[account] == 3;
    }

    function _addSigners(address[] memory accounts, uint8 typeId, address[] storage storageArray) private {
        for (uint256 i = 0; i < accounts.length; i++) {
            address acc = accounts[i];
            require(acc != address(0), "LQ: zero address");
            require(signerType[acc] == 0, "LQ: duplicate signer");
            signerType[acc] = typeId;
            storageArray.push(acc);
        }
    }

    function _clearSigners(address[] storage storageArray) private {
        for (uint256 i = 0; i < storageArray.length; i++) {
            signerType[storageArray[i]] = 0;
        }
        uint256 len = storageArray.length;
        for (uint256 i = 0; i < len; i++) {
            storageArray.pop();
        }
    }

    function _validateAddresses(address[] memory accounts) private pure {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "LQ: zero address proposed");
        }
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.