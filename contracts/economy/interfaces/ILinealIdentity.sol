// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title ILinealIdentity
 * @notice Interfaz mínima de LinealIdentity para consumo externo.
 *         Expone únicamente las funciones de lectura necesarias para
 *         verificar grado y titularidad de perfiles.
 */
interface ILinealIdentity {
    /// @notice Score global del token (0 – 10 000).
    function overallScore(uint256 tokenId) external view returns (uint256);

    /// @notice Devuelve el tokenId asociado a una wallet.
    function walletToToken(address wallet) external view returns (uint256);

    /// @notice Devuelve la wallet propietaria de un tokenId.
    function tokenToWallet(uint256 tokenId) external view returns (address);

    /// @notice Indica si una wallet tiene perfil activo.
    function hasProfile(address wallet) external view returns (bool);
}
