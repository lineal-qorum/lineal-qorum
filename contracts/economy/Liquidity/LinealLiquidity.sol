// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../../governance/LinealQorum.sol";
import "../../institution/LinealInstitution.sol";
import "../paymasters/LinealRouter.sol";
import "../token/LinealToken.sol";
import "./LinealDex.sol";
import "./LinealMilestones.sol";
import "./LinealSeed.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import {LinealBank} from "../banks/LinealBank.sol";

/**
 * @title Lineal Liquidity by Lineal Qorum Protocol
 * @author NeoQuor - Lineal Qorum Protocol
 * @notice Orquestador de liquidez del protocolo: lanza las rondas seed/pre-seed, ejecuta la
 * Política LCL (Ley de la conservación de la Liquidez) y calcula el desbloqueo de emisión según el el ratio alpha y
 *
 * RESPONSABILIDADES:
 * - Configurar y lanzar seed y pre-seed (aprobando y depositando tokens en el banco).
 * - Medir el índice Alpha (liquidez vs. suministro circulante).
 * - Ejecutar Buyback & Burn cuando Alpha cae bajo el umbral crítico.
 * - Liberar (mint) la emisión calculada por la calculadora LCL/IDP.
 *
 * @dev Toda acción administrativa pasa por la gobernanza multisig de LinealQorum.
 */
contract LinealLiquidity is LinealQorum, Pausable {
    // === STATE: IMMUTABLES & PARAMETERS ===

    /// @notice Token del ecosistema (QORUM).
    LinealToken public immutable qorumToken;
    /// @notice Banco institucional donde se deposita el suministro del pre-seed.
    LinealBank public immutable institutionalBank;
    /// @notice Institución dueña de este contrato.
    LinealInstitution public immutable institutionAddress;
    /// @notice Precio inicial del token (fijado en el lanzamiento del pre-seed).
    uint256 public initialPriceToken;
    /// @notice Precio inicial del NFT (fijado en el lanzamiento del pre-seed).
    uint256 public initialPriceNft;
    /// @notice Bandera de lanzamiento de la ronda seed.
    bool public isSeedLaunched = false;
    /// @notice Bandera de lanzamiento del pre-seed.
    bool public isPreSeedLaunched = false;

    // === EVENTS ===

    event UnlockExecuted(uint256 amount, uint256 alpha, uint256 idp);
    event BuybackAndBurn(uint256 incomeSpent, uint256 qorumsBurned);

    /**
     * @notice Despliega el orquestador de liquidez y su gobernanza multisig.
     * @param _institutionAddress Institución dueña del contrato.
     * @param _bankAddress Banco institucional asociado.
     * @param _machines Signers de la capa máquinas.
     * @param _institutions Signers de la capa instituciones.
     * @param _humans Signers de la capa humanos.
     * @param _requiredMachines Firmas requeridas de la capa máquinas.
     * @param _requiredInstitutions Firmas requeridas de la capa instituciones.
     * @param _requiredHumans Firmas requeridas de la capa humanos.
     * @param _recoveryQuorum Firmas requeridas para recuperaciones.
     */
    constructor(
        address _institutionAddress,
        address _bankAddress,
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
        institutionalBank = LinealBank(_bankAddress);
        institutionAddress = LinealInstitution(_institutionAddress);
    }

    // === SECURITY & ADMINISTRATION ===

    /// @notice Pausa el contrato. Requiere quórum.
    function pause() public onlyQorum {
        bytes32 txHash = _computeActionHash("pause", abi.encode(""));
        if (!confirmServers(txHash, "pause")) return;
        _pause();
    }

    /// @notice Reactiva el contrato. Requiere quórum.
    function unpause() public onlyQorum {
        bytes32 txHash = _computeActionHash("pause", abi.encode(""));
        if (!confirmServers(txHash, "pause")) return;
        _unpause();
    }

    /**
     * @notice Lanza la ronda seed: aprueba y transfiere el suministro en venta al contrato LinealSeed.
     * @dev Solo puede ejecutarse una vez.
     * @param _linealSeed Dirección del contrato LinealSeed.
     */
    function launchSeed(
        address _linealSeed
    ) external onlyServers {
        require(isSeedLaunched == false, "Launched");
        bytes32 txHash = _computeActionHash("launchSeed", abi.encode(_linealSeed));
        if (!confirmServers(txHash, "launchSeed")) return;
        address linealToken = institutionAddress.linealCoin();
        uint256 totalTokenSale = LinealSeed(_linealSeed).totalTokenSale();
        LinealToken(linealToken).approve(_linealSeed, totalTokenSale);
        LinealToken(linealToken).transfer(_linealSeed, totalTokenSale);
        isSeedLaunched = true;
    }

    /**
     * @notice Lanza el pre-seed: fija precios iniciales y deposita el suministro en el banco institucional.
     * @dev Solo puede ejecutarse una vez.
     * @param totalAmount Suministro del pre-seed (en unidades enteras de token).
     * @param _initialPriceToken Precio inicial del token.
     * @param _initialPriceNft Precio inicial del NFT.
     */
    function launchPreSeed(
        uint256 totalAmount,
        uint256 _initialPriceToken,
        uint256 _initialPriceNft
    ) external onlyServers {
        require(isPreSeedLaunched == false, "Launched");
        bytes32 txHash = _computeActionHash("launchPreSeed", abi.encode(totalAmount));
        if (!confirmServers(txHash, "launchPreSeed")) return;
        bytes32 institutionalId = institutionAddress.institutionAccountId();
        address linealToken = institutionAddress.linealCoin();
        initialPriceToken = _initialPriceToken;
        initialPriceNft = _initialPriceNft;
        LinealToken(linealToken).approve(address(institutionalBank), totalAmount * 1e18);
        institutionalBank.deposit(institutionalId, linealToken, totalAmount * 1e18);
        isPreSeedLaunched = true;
    }

    /**
     * @notice Retira del contrato LinealSeed los tokens no vendidos y los deposita en el banco institucional.
     * @param _linealSeed Dirección del contrato LinealSeed.
     */
    function withdrawUnsoldTokens(address _linealSeed) external onlyServers {
        bytes32 txHash = _computeActionHash("withdrawUnsoldTokens", abi.encode(_linealSeed));
        if (!confirmServers(txHash, "withdrawUnsoldTokens")) return;
        LinealToken saleToken = LinealSeed(_linealSeed).saleToken();
        LinealSeed(_linealSeed).withdrawUnsoldTokens();
        uint256 balance = saleToken.balanceOf(address(this));
        bytes32 id = institutionAddress.institutionAccountId();
        institutionalBank.deposit(id, address(saleToken), balance);
    }

    // === CORE LCL / IDP CALCULATOR ===

    /**
     * @notice Implementa la lógica LCL/IDP del documento técnico con precisión escalada.
     * @param _baseEmission Emisión base propuesta para el ciclo.
     * @param _alpha Índice Alpha escalado a 18 decimales (ej. 0.93 = 93e16).
     * @param _idp Índice IDP (porcentaje de desempeño 0-100+).
     */
    function _calculateUnlock(
        uint256 _baseEmission,
        uint256 _alpha,
        uint256 _idp
    )
        internal
        pure
        returns (uint256)
    {
        // 1. Componente IDP (Porcentaje Base de Desbloqueo)
        uint256 idpBasePercent;
        if (_idp >= 100) {
            idpBasePercent = 75; // 75%
        } else if (_idp > 66) {
            idpBasePercent = 30; // 30%
        } else {
            idpBasePercent = 0;
        }

        // 2. Componente LCL (Factor de Ajuste basado en el documento técnico)
        // Umbrales escalados a 18 decimales: 0.93 = 93e16 | 1.2 = 120e16
        uint256 lclAdjustment = 100; // Neutro (1.0x representado como 100)

        if (_alpha < 93e16) {
            lclAdjustment = 50;  // Reduce emisión al 50% por debajo del umbral de seguridad (alpha < 0.93)
        } else if (_alpha >= 120e16) {
            lclAdjustment = 110; // Aumenta un 10% si la liquidez supera 1.2[cite: 55]
        }

        // 3. Cálculo Final evitando pérdida por división entera: (Base * IDP% * LCL%) / 10000
        // idpBasePercent está en base 100 y lclAdjustment en base 100 -> 100 * 100 = 10000
        uint256 finalUnlock = (_baseEmission * idpBasePercent * lclAdjustment) / 10000;

        return finalUnlock;
    }

    /**
     * @notice Ejecuta un ciclo de desbloqueo: mide Alpha/IDP y acuña la emisión correspondiente.
     * @dev Requiere quórum. Aplica la política LCL antes de validar los umbrales mínimos.
     * @param _recipient Destino de los tokens desbloqueados (router de ingresos).
     * @param _baseEmissionAmount Emisión base propuesta para el ciclo.
     * @param _tokenAddress Token que se acuña.
     * @param _milestoneAddress Contrato de hitos que provee el IDP.
     * @param _linealSwap DEX usado para medir Alpha y ejecutar el buyback.
     * @param _incomeToken Token de ingresos usado como reserva del buyback.
     * @param _availableIncomeForBuyback Ingreso disponible para el buyback (informativo).
     */
    function unlockAndMint(
        address payable _recipient,
        uint256 _baseEmissionAmount,
        address _tokenAddress,
        address _milestoneAddress,
        address _linealSwap,
        address _incomeToken,
        uint256 _availableIncomeForBuyback
    )
        public
        onlyServers
        whenNotPaused
    {
        bytes32 txHash = _computeActionHash("unlockAndMint", abi.encode(_recipient, _baseEmissionAmount));
        if (!confirmServers(txHash, "unlockAndMint")) return;

        uint256 _alpha = _calculateAlpha(_linealSwap, _tokenAddress);
        uint256 _idp = LinealMilestones(_milestoneAddress).idp();

        // 1. Ejecutar política de defensa LCL de forma interna si Alpha es bajo
        if (_alpha < 93e16) {
            _enforceLCLPolicy(_linealSwap, _tokenAddress, _incomeToken);
        }

        // 2. Validaciones estrictas de emisión y desempeño
        require(_alpha >= 93e16, "LCL: Liquidez insuficiente (alpha < 0.93).");
        require(_idp >= 66, "IDP: Desempeno bajo (IDP < 0.66).");

        // 3. Calcular el monto final de desbloqueo con la escala corregida
        uint256 unlockAmount = _calculateUnlock(_baseEmissionAmount, _alpha, _idp);

        // 4. Liberar tokens si el resultado es mayor a cero
        if (unlockAmount > 0) {
            LinealToken(_tokenAddress).mint(_recipient, unlockAmount);
            LinealRouter(_recipient).distributeRevenue(unlockAmount);
        }

        emit UnlockExecuted(unlockAmount, _alpha, _idp);
    }

    /**
     * @notice Controlador LCL interno: evalúa Alpha y usa el balance del propio contrato
     * como reserva para Buyback & Burn.
     * @dev Si Alpha cae del umbral crítico se gasta el 5% de la reserva de ingresos.
     * @param _linealSwap DEX usado para medir Alpha y ejecutar el swap.
     * @param _tokenAddress Token del protocolo (se quema en el buyback).
     * @param _incomeToken Token de ingresos usado como reserva.
     */
    function _enforceLCLPolicy(
        address _linealSwap,
        address _tokenAddress,
        address _incomeToken
    ) internal {
        uint256 _alpha = _calculateAlpha(_linealSwap, _tokenAddress);

        // Si Alpha cae por debajo del umbral crítico (0.93 escalado a 18 decimales: 93e16)[cite: 15]
        if (_alpha < 93e16) {
            // El contrato mismo es la reserva, consultamos su propio balance disponible
            uint256 contractBalance = IERC20(_incomeToken).balanceOf(address(this));

            if (contractBalance > 0) {
                // Opcional: puedes definir un porcentaje de uso del balance (ej. 5% como especifica el LCL Controller en el paper)[cite: 13, 14]
                // o usar el total disponible según la severidad de la caída.
                uint256 incomeToSpend = (contractBalance * 5) / 100; // 5% de la reserva disponible

                if (incomeToSpend > 0) {
                    _executeBuybackAndBurn(incomeToSpend, _tokenAddress, _linealSwap, _incomeToken);
                }
            }
        }
    }

    /**
     * @dev Compra tokens QORUMS y los quema (Buyback & Burn).
     * @param incomeAmount Ingreso a gastar en el swap.
     * @param _tokenAddress Token del protocolo a quemar.
     * @param dexRouter DEX donde se ejecuta el swap.
     * @param _incomeToken Token de ingresos entregado en el swap.
     */
    function _executeBuybackAndBurn(
        uint256 incomeAmount,
        address _tokenAddress,
        address dexRouter,
        address _incomeToken
    ) internal {
        address[] memory path = new address[](2);
        path[0] = address(_incomeToken);
        path[1] = address(_tokenAddress);

        uint256[] memory amounts = LinealDex(dexRouter).swapExactTokensForTokens(
            incomeAmount,
            1, // amountOutMin (tolerancia de deslizamiento baja para MVP — revisar antes de producción)
            path,
            address(this),
            block.timestamp
        );

        uint256 qorumsToReturn = amounts[amounts.length - 1];

        if (qorumsToReturn > 0) {
            LinealToken(_tokenAddress).burn(address(this), qorumsToReturn);
            emit BuybackAndBurn(incomeAmount, qorumsToReturn);
        }
    }

    /**
     * @notice Calcula el índice Alpha (liquidez de ingresos vs. suministro circulante).
     * @dev Alpha se expresa con 18 decimales; retorna 0 si falta información de liquidez.
     * @param _linealSwap DEX del que se leen reservas y precio acumulado.
     * @param _linealToken Token del protocolo (para el suministro circulante).
     */
    function _calculateAlpha(
        address _linealSwap,
        address _linealToken
    ) internal view returns (uint256 _alpha) {
        (
            uint256 reserveIncome,
            uint256 reserveToken,
            uint256 totalShares
        ) = LinealDex(_linealSwap).getTotalLiquidity();

        (
            uint256 cumulative,
            uint256 timestamp
        ) = LinealDex(_linealSwap).currentPriceCumulative();

        uint256 circulatingSupply = LinealToken(_linealToken).getCirculatingSupply();

        // Evitar divisiones por cero.
        if (
            circulatingSupply == 0 ||
            cumulative == 0 ||
            reserveIncome == 0 ||
            reserveToken == 0
        ) {
            return 0;
        }

        // No calcular alpha con un acumulador TWAP sin un periodo
        // de observación definido.
        timestamp;

        uint256 spotPrice = (reserveIncome * 1e18) / reserveToken;

        _alpha = (reserveIncome * 1e18) / circulatingSupply;

        // Variables recuperadas para mantener explícita la interfaz.
        totalShares;
        cumulative;
        spotPrice;
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.