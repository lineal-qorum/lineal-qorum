// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title IFeeSplitter
 * @notice Interfaz para que otros contratos (como VaultFactory) interactúen
 * con el FeeSplitter, exponiendo solo las funciones necesarias.
 */
interface IFeeSplitter {

    /**
     * @notice Otorga el rol de PRODUCT_SENDER a la dirección de un nuevo Vault.
     * @param _sender Dirección del contrato al que se le otorga el rol.
     */
    function grantProductSenderRole(address _sender) external;

    /**
     * @notice Función principal para la recolección y distribución de tarifas.
     * @param amount La cantidad de tokens a procesar.
     */
    function collectAndRouteFees(uint256 amount) external;
}