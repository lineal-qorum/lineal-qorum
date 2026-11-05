// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../../governance/LinealQorum.sol";

/// Interfaz mínima de LinealCitizens (NFT soulbound, un perfil por wallet).
interface ILinealCitizens {
    function walletToToken(address wallet) external view returns (uint256); // 0 si no tiene perfil
    function tokenCounter() external view returns (uint256);               // tokenIds secuenciales, nunca se reutilizan
}

/**
 * @title LinealMilestones by Lineal Qorum Protocol
 * @author NeoQuor - Lineal Qorum Protocol
 * @notice Hitos del proyecto validados por votación de los ciudadanos.
 *         El IDP (índice de desempeño) es la suma de los pesos de los hitos aprobados (0-100).
 *         Un ciudadano = un voto. El padrón se congela al abrir cada hito.
 *
 * @dev La creación de hitos y la cancelación de emergencia requieren quórum (LinealQorum).
 *      El cierre de la votación es permissionless una vez vencido el plazo.
 */
contract LinealMilestones is LinealQorum {
    // === TYPES ===

    enum Status { None, Voting, Approved, Rejected, Cancelled }

    struct Milestone {
        uint8 weight;           // puntos que aporta al IDP
        uint64 start;           // inicio de la votación
        uint64 end;             // fin de la votación
        uint32 votesFor;        // votos a favor
        uint32 votesAgainst;    // votos en contra
        uint32 citizensAtStart; // padrón congelado (tokenCounter al abrir)
        Status status;          // estado actual del hito
    }

    // === STATE: IMMUTABLES & CONSTANTS ===

    /// @notice Registro de ciudadanos usado para elegibilidad y padrón.
    ILinealCitizens public immutable citizens;

    /// @notice Participación mínima del padrón para considerar válida la votación (20%).
    uint256 public constant MIN_PARTICIPATION_BPS = 2_000; // 20% del padrón
    /// @notice Aprobación mínima de los votos emitidos (66%).
    uint256 public constant MIN_APPROVAL_BPS = 6_600;      // 66% de los votos emitidos
    /// @notice Duración mínima de una votación.
    uint64 public constant MIN_DURATION = 3 days;
    /// @notice Duración máxima de una votación.
    uint64 public constant MAX_DURATION = 30 days;

    // === STATE: WEIGHTS & REGISTRIES ===

    /// @notice Peso comprometido: hitos en votación + aprobados. Nunca supera 100.
    uint256 public totalWeight;
    /// @notice Peso de los hitos aprobados = IDP actual.
    uint256 public approvedWeight;

    /// @notice Hitos registrados (el id es el índice en este arreglo).
    Milestone[] public milestones;
    /// @notice Registro de votos por hito y wallet.
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // === EVENTS ===

    event MilestoneCreated(uint256 indexed id, uint8 weight, uint64 start, uint64 end, uint32 citizensAtStart);
    event Voted(uint256 indexed id, address indexed voter, bool support);
    event MilestoneFinalized(uint256 indexed id, Status status, uint32 votesFor, uint32 votesAgainst);
    event MilestoneCancelled(uint256 indexed id);

    /**
     * @notice Despliega el registro de hitos y su gobernanza multisig.
     * @param _citizens Dirección del contrato LinealCitizens.
     * @param _machines Signers de la capa máquinas.
     * @param _institutions Signers de la capa instituciones.
     * @param _humans Signers de la capa humanos.
     * @param _requiredMachines Firmas requeridas de la capa máquinas.
     * @param _requiredInstitutions Firmas requeridas de la capa instituciones.
     * @param _requiredHumans Firmas requeridas de la capa humanos.
     * @param _recoveryQuorum Firmas requeridas para recuperaciones.
     */
    constructor(
        address _citizens,
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
        require(_citizens != address(0), "Invalid citizens");
        citizens = ILinealCitizens(_citizens);
    }

    // === GOVERNANCE (QUORUM) ===

    /// @notice Abre la votación de un nuevo hito. Requiere confirmación del quórum.
    function createMilestone(uint8 weight, uint64 duration) external onlyServers {
        require(weight > 0, "Weight = 0");
        require(duration >= MIN_DURATION && duration <= MAX_DURATION, "Bad duration");
        require(totalWeight + weight <= 100, "Weights > 100");

        // El id del hito va en el hash: cada hito necesita su propia confirmación
        bytes32 txHash = _computeActionHash(
            "createMilestone",
            abi.encode(weight, duration, milestones.length)
        );
        if (!confirmServers(txHash, "createMilestone")) return;

        // Padrón congelado al abrir el hito.
        uint256 snapshot = citizens.tokenCounter();
        require(snapshot > 0, "No citizens");

        // El peso queda comprometido mientras el hito esté en votación o aprobado.
        totalWeight += weight;

        uint256 id = milestones.length;
        uint64 start = uint64(block.timestamp);
        uint64 end = start + duration;

        milestones.push(Milestone({
            weight: weight,
            start: start,
            end: end,
            votesFor: 0,
            votesAgainst: 0,
            citizensAtStart: uint32(snapshot),
            status: Status.Voting
        }));

        emit MilestoneCreated(id, weight, start, end, uint32(snapshot));
    }

    /// @notice Freno de emergencia: el quórum puede cancelar una votación abierta.
    function cancelMilestone(uint256 id) external onlyQorum {
        Milestone storage m = milestones[id];
        require(m.status == Status.Voting, "Not voting");

        bytes32 txHash = _computeActionHash("cancelMilestone", abi.encode(id));
        if (!confirmServers(txHash, "cancelMilestone")) return;

        m.status = Status.Cancelled;
        totalWeight -= m.weight; // libera el peso para volver a proponerlo

        emit MilestoneCancelled(id);
    }

    // === VOTING (CITIZENS) ===

    /// @notice Vota un hito. Elegible: perfil de LinealCitizens emitido antes de abrir el hito.
    function vote(uint256 id, bool support) external {
        Milestone storage m = milestones[id];
        require(m.status == Status.Voting && block.timestamp <= m.end, "Not open");

        // Elegible si obtuvo su perfil antes de abrir el hito (tokenId <= padrón).
        uint256 tokenId = citizens.walletToToken(msg.sender);
        require(tokenId != 0 && tokenId <= m.citizensAtStart, "Not eligible");
        require(!hasVoted[id][msg.sender], "Already voted");

        hasVoted[id][msg.sender] = true;

        if (support) {
            m.votesFor++;
        } else {
            m.votesAgainst++;
        }

        emit Voted(id, msg.sender, support);
    }

    /// @notice Cierra la votación al vencer el plazo. Cualquiera puede llamarla.
    function finalize(uint256 id) external {
        Milestone storage m = milestones[id];
        require(m.status == Status.Voting && block.timestamp > m.end, "Not ready");

        // Umbrales: participación mínima del padrón y aprobación mínima de los votos emitidos.
        uint256 votes = uint256(m.votesFor) + m.votesAgainst;
        bool participated = votes * 10_000 >= uint256(m.citizensAtStart) * MIN_PARTICIPATION_BPS;
        bool approved = votes > 0 && uint256(m.votesFor) * 10_000 >= votes * MIN_APPROVAL_BPS;

        if (participated && approved) {
            m.status = Status.Approved;
            approvedWeight += m.weight;
        } else {
            m.status = Status.Rejected;
            totalWeight -= m.weight; // libera el peso: el hito puede volver a proponerse
        }

        emit MilestoneFinalized(id, m.status, m.votesFor, m.votesAgainst);
    }

    // === VIEW FUNCTIONS ===

    /// @notice Índice de desempeño: suma de pesos de hitos aprobados (0-100). O(1).
    function idp() external view returns (uint256) {
        return approvedWeight;
    }

    /// @notice Cantidad de hitos registrados.
    function milestonesCount() external view returns (uint256) {
        return milestones.length;
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.