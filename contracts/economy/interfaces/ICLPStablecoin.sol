// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ICLPStablecoin
 * @notice Interfaz para la stablecoin CLP (Peso Chileno) regulada.
 * 
 * CUMPLIMIENTO REGULATORIO:
 * - KYC/AML obligatorio mediante whitelist
 * - Blacklist para direcciones sancionadas
 * - Límites de transacción diarios
 * - Pausabilidad para emergencias
 * - Auditoría completa con trazabilidad
 * - Recuperación de fondos en casos de fraude
 * 
 * MODELO DE CIRCULACIÓN:
 * - Mint: Se acuñan tokens cuando se deposita CLP fiat verificado
 * - Burn: Se queman tokens cuando se retira CLP fiat
 * - 1 Token CLP = 1 Peso Chileno en reserva bancaria
 */
interface ICLPStablecoin is IERC20 {
    
    // === MINT & BURN ===
    
    /**
     * @notice Acuña nuevos tokens CLP respaldados por depósito fiat verificado.
     * @param to Destinatario de los tokens (debe estar en whitelist).
     * @param amount Cantidad de tokens a acuñar.
     * @param depositReference Hash de referencia del depósito bancario.
     * @param _secret Secreto post-cuántico para validación multisig.
     */
    function mint(
        address to,
        uint256 amount,
        bytes32 depositReference,
        string memory _secret
    ) external;
    
    /**
     * @notice Quema tokens CLP cuando se retira dinero fiat.
     * @param from Dirección desde donde quemar tokens.
     * @param amount Cantidad de tokens a quemar.
     * @param withdrawalReference Hash de referencia del retiro bancario.
     * @param _secret Secreto post-cuántico para validación multisig.
     */
    function burn(
        address from,
        uint256 amount,
        bytes32 withdrawalReference,
        string memory _secret
    ) external;
    
    // === COMPLIANCE ===
    
    /**
     * @notice Agrega o remueve una dirección de la whitelist (KYC).
     * @param account Dirección a modificar.
     * @param status true para agregar, false para remover.
     * @param _secret Secreto post-cuántico.
     */
    function setWhitelist(address account, bool status, string memory _secret) external;
    
    /**
     * @notice Agrega o remueve una dirección de la blacklist (sanciones).
     * @param account Dirección a modificar.
     * @param status true para blacklist, false para remover.
     * @param _secret Secreto post-cuántico.
     */
    function setBlacklist(address account, bool status, string memory _secret) external;
    
    /**
     * @notice Pausa todas las operaciones del token.
     * @param _secret Secreto post-cuántico.
     */
    function pause(string memory _secret) external;
    
    /**
     * @notice Reanuda las operaciones del token.
     * @param _secret Secreto post-cuántico.
     */
    function unpause(string memory _secret) external;
    
    /**
     * @notice Recupera fondos en caso de fraude comprobado.
     * @param from Dirección origen.
     * @param to Dirección destino (debe estar en whitelist).
     * @param amount Cantidad a recuperar.
     * @param reason Razón legal de la recuperación.
     * @param _secret Secreto post-cuántico.
     */
    function recoverFunds(
        address from,
        address to,
        uint256 amount,
        string memory reason,
        string memory _secret
    ) external;
    
    // === VIEW FUNCTIONS ===
    
    /**
     * @notice Devuelve la dirección del ReserveBank.
     * @return Dirección del banco de reserva.
     */
    function reserveBank() external view returns (address);
    
    /**
     * @notice Devuelve si una dirección está en la whitelist.
     * @param account Dirección a consultar.
     * @return true si está en whitelist.
     */
    function isWhitelisted(address account) external view returns (bool);
    
    /**
     * @notice Devuelve si una dirección está en la blacklist.
     * @param account Dirección a consultar.
     * @return true si está en blacklist.
     */
    function isBlacklisted(address account) external view returns (bool);
    
    /**
     * @notice Devuelve la cantidad total de tokens en circulación.
     * @return Total supply de tokens CLP.
     */
    function getCirculatingSupply() external view returns (uint256);
    
    /**
     * @notice Devuelve el volumen transferido hoy por una dirección.
     * @param account Dirección a consultar.
     * @return Volumen transferido en el día actual.
     */
    function getDailyTransferVolume(address account) external view returns (uint256);
    
    /**
     * @notice Devuelve el volumen de mint y burn del día actual.
     * @return minted Volumen acuñado hoy.
     * @return burned Volumen quemado hoy.
     */
    function getDailyMintBurnVolume() external view returns (uint256 minted, uint256 burned);
}
