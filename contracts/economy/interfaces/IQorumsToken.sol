// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPopcornsToken
 * @notice Interfaz para el token POPCORNS con supply fijo de 1B.
 * 
 * MODELO DE CIRCULACIÓN:
 * - Supply Total: 1,000,000,000 POPCORNS (FIJO, NUNCA CAMBIA)
 * - "Liberar" = Transferir desde RESERVA → Circulación
 * - "Retornar" = Transferir desde Circulación → RESERVA
 * 
 * NO HAY MINT NI BURN REAL - Solo transferencias desde/hacia la reserva.
 */
interface IQorumsToken is IERC20 {
    /**
     * @notice Libera tokens desde la reserva hacia un destinatario.
     * @param to Destinatario de los tokens.
     * @param amount Cantidad de tokens a liberar.
     */
    function releaseFromReserve(address to, uint256 amount) external;
    
    /**
     * @notice Retorna tokens a la reserva (simula "burn" retirando de circulación).
     * @param amount Cantidad de tokens a retornar a la reserva.
     */
    function returnToReserve(uint256 amount) external;
    
    /**
     * @notice Devuelve la dirección de la wallet de reserva.
     * @return Dirección de la reserva.
     */
    function reserve() external view returns (address);
    
    /**
     * @notice Devuelve la cantidad de tokens en la reserva (fuera de circulación).
     * @return Balance de la wallet de reserva.
     */
    function getReserveBalance() external view returns (uint256);
    
    /**
     * @notice Devuelve la cantidad de tokens en circulación.
     * @return Total supply menos balance de reserva.
     */
    function getCirculatingSupply() external view returns (uint256);
}