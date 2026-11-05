// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "../../governance/LinealQorum.sol";
import "../../economy/interfaces/IQorumsToken.sol";
import "../../economy/interfaces/IIncomeToken.sol";

/**
 * @title PaymentRouter
 * @notice Splitter de ingresos genérico y estándar (no ligado a roles fijos).
 * El multisig define post-despliegue N destinatarios, cada uno con:
 *   - un porcentaje (basis points, base 10000)
 *   - un tipo de acción: TRANSFER (transferencia directa) o BUYBACK_BURN (swap + burn)
 * Este contrato debe tener el BURNER_ROLE en QorumsToken.
 */
contract LinealRouter is LinealQorum, Pausable {

    IQorumsToken public immutable QORUMS;
    IIncomeToken public immutable INCOME_TOKEN; // Ej. USDC

    address public linealLiquidity; // Contrato autorizado para enviar fondos

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_RECIPIENTS = 20; // límite de seguridad para evitar gas-DoS en el loop

    struct Recipient {
        address account; // ignorado cuando distType == BUYBACK_BURN
        uint256 bps;
        string label;    // etiqueta legible, informativa (ej. "Founder", "Rewards Pool", "Protocol Burn")
    }

    // Tokenomics vigente, 100% configurable por el multisig vía setDistribution()
    Recipient[] public recipients;

    event RevenueDistributed(uint256 incomeAmount, uint256 recipientsCount);
    event RecipientPaid(uint256 indexed index, address indexed account, uint256 amount);
    event DistributionUpdated(uint256 recipientsCount);

    constructor(
        address[] memory _machines,
        address[] memory _institutions,
        address[] memory _humans,
        uint256 _requiredMachines,
        uint256 _requiredInstitutions,
        uint256 _requiredHumans,
        uint256 _recoveryQuorum,
        address _qorumsTokenAddress,
        address _incomeTokenAddress
    ) LinealQorum(_machines, _requiredMachines, _institutions, _requiredInstitutions, _humans, _requiredHumans, _recoveryQuorum) {
        QORUMS = IQorumsToken(_qorumsTokenAddress);
        INCOME_TOKEN = IIncomeToken(_incomeTokenAddress);
    }

    // --- SEGURIDAD Y ADMINISTRACIÓN MULTISIG ---

    function setFeeSplitter(address _linealLiquidity) public onlyServers {
        bytes32 txHash = keccak256(abi.encodePacked("setFeeSplitter", _linealLiquidity,
            actionNonce["setFeeSplitter"]));
        if (confirmServers(txHash, "setFeeSplitter")) {
            linealLiquidity = _linealLiquidity;
        }
    }

    /**
     * @notice Redefine por completo el tokenomics de distribución. Estándar y genérico:
     * el multisig puede definir cualquier número de destinatarios (hasta MAX_RECIPIENTS),
     * cada uno con su propio porcentaje y tipo de acción.
     * @dev Los `bps` deben sumar exactamente 10000. Para entradas TRANSFER, `accounts[i]`
     * es la dirección destino. Para BUYBACK_BURN, `accounts[i]` se ignora (pasar address(0)).
     * Requiere confirmServeración multisig, igual que el resto de funciones administrativas.
     */
    function setDistribution(
        address[] calldata accounts,
        uint256[] calldata bpsValues,
        string[] calldata labels
    ) public onlyServers {
        uint256 len = accounts.length;
        require(len > 0 && len <= MAX_RECIPIENTS, "PayMaster: invalid recipients length");
        require(
            bpsValues.length == len && labels.length == len,
            "PayMaster: array length mismatch"
        );

        uint256 totalBps;
        for (uint256 i = 0; i < len; i++) {
            totalBps += bpsValues[i];
        }
        require(totalBps == BPS_DENOMINATOR, "PayMaster: bps must sum to 10000");

        bytes32 txHash = keccak256(
            abi.encodePacked(
                "setDistribution",
                keccak256(abi.encode(accounts, bpsValues)),
                actionNonce["setDistribution"]
            )
        );
        if (confirmServers(txHash, "setDistribution")) {
            delete recipients;
            for (uint256 i = 0; i < len; i++) {
                recipients.push(Recipient(accounts[i], bpsValues[i], labels[i]));
            }
            emit DistributionUpdated(len);
        }
    }

    function pause() public onlyServers {
        bytes32 txHash = keccak256(abi.encodePacked("pause", actionNonce["pause"]));
        if (confirmServers(txHash, "pause")) {
            _pause();
        }
    }

    function unpause() public onlyServers {
        bytes32 txHash = keccak256(abi.encodePacked("unpause", actionNonce["unpause"]));
        if (confirmServers(txHash, "unpause")) {
            _unpause();
        }
    }

    // --- LECTURA DE TOKENOMICS ---

    function getRecipientsCount() external view returns (uint256) {
        return recipients.length;
    }

    function getAllRecipients() external view returns (Recipient[] memory) {
        return recipients;
    }

    // --- LÓGICA CENTRAL DE DISTRIBUCIÓN ---

    /**
     * @notice Recibe una cantidad de tokens de ingreso y la reparte según el array
     * `recipients` vigente, 100% definido por el multisig vía setDistribution().
     * @dev Asume que los tokens de ingreso ya han sido transferidos al PaymentRouter,
     * usualmente desde el FeeSplitter o directamente por el Admin.
     */
    function distributeRevenue(uint256 incomeAmount) public whenNotPaused {
        require(msg.sender == linealLiquidity, "PaymentRouter: Only authorized FeeSplitter");
        require(INCOME_TOKEN.balanceOf(address(this)) >= incomeAmount, "Insufficient income balance");

        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            Recipient memory r = recipients[i];
            uint256 amount = (incomeAmount * r.bps) / BPS_DENOMINATOR;
            if (amount == 0) continue;
            INCOME_TOKEN.transfer(r.account, amount);
            emit RecipientPaid(i, r.account, amount);
        }

        emit RevenueDistributed(incomeAmount, len);
    }

    receive() external payable {}
}

/// @notice Low Life, High Tech - Todos los derechos reservados.
