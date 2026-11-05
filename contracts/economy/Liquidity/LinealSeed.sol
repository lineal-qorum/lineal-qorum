// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LinealToken} from "../token/LinealToken.sol";

/**
 * @title VestedICOERC20
 * @notice ICO cuyo pago se realiza en un token ERC20 (ej. USDC/USDT) en vez de ETH.
 *         Liberación de los tokens vendidos:
 *         - 20% reclamable apenas se finaliza la venta (TGE)
 *         - 80% reclamable tras un cliff de 6 meses desde el TGE
 *           (70% pedido + 10% restante asumido; ajustar CLIFF_BPS si corresponde)
 *
 * FLUJO:
 * 1. El owner deposita los tokens a vender (hardCap * rate) en el contrato.
 * 2. Los compradores hacen `approve` del paymentToken y llaman a `buy`.
 * 3. Al vencer el plazo (o llegar al hardCap) cualquiera llama a `finalize`.
 * 4. Si se alcanza el softCap: los compradores reclaman con `claim` y el owner
 *    retira los fondos con `withdrawFunds`.
 *    Si no se alcanza: los compradores recuperan su pago con `refund`.
 *
 * @dev El owner debe transferir al contrato los tokens a vender
 *      (hardCap * rate) antes de iniciar la venta.
 *      Los compradores deben hacer `approve` del paymentToken antes de `buy()`.
 */
contract LinealSeed is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // === VESTING PARAMETERS (basis points, 10_000 = 100%) ===

    /// @notice Base de cálculo de los basis points (100% = 10_000).
    uint256 public constant BPS = 10_000;
    /// @notice Porción liberada en el TGE (20%).
    uint256 public constant IMMEDIATE_BPS = 2_000; // 20%
    /// @notice Porción liberada tras el cliff (80%).
    uint256 public constant CLIFF_BPS = 8_000; // 80% (70% + 10% restante)
    /// @notice Duración del cliff desde el TGE.
    uint256 public constant CLIFF_DURATION = 180 days; // ~6 meses

    // === SALE CONFIGURATION ===

    /// @notice Token que se vende en la ICO.
    LinealToken public saleToken;
    /// @notice Token con el que se paga (USDC, USDT, etc.).
    IERC20 public immutable paymentToken;
    /// @notice Cantidad de saleTokens destinada a la venta.
    uint256 public totalTokenSale;

    /// @dev unidades mínimas de saleToken por 1 unidad mínima de paymentToken.
    ///      Ej: paymentToken USDC (6 dec), saleToken 18 dec, precio 0.05 USDC por token
    ///      => 1 USDC compra 20 tokens => rate = 20 * 1e18 / 1e6 = 20e12.
    uint256 public immutable rate;

    /// @notice Meta mínima para considerar la venta exitosa (unidades mínimas de paymentToken).
    uint256 public immutable softCap;
    /// @notice Tope máximo recaudable (unidades mínimas de paymentToken).
    uint256 public immutable hardCap;
    /// @notice Inicio de la venta.
    uint256 public immutable startTime;
    /// @notice Fin de la venta.
    uint256 public immutable endTime;
    /// @notice Aporte mínimo por comprador (unidades mínimas de paymentToken).
    uint256 public immutable minContribution;

    // === STATE ===

    /// @notice Total recaudado en paymentToken.
    uint256 public totalRaised;
    /// @notice Dirección que recibe los fondos y los tokens no vendidos.
    address public linealLiquidity;
    /// @notice saleTokens vendidos (unidades mínimas).
    uint256 public totalSold;
    /// @notice saleTokens ya reclamados por compradores.
    uint256 public totalClaimed;
    /// @notice Indica si la venta ya fue finalizada.
    bool public finalized;
    /// @notice Indica si la venta alcanzó el softCap.
    bool public successful;
    /// @notice Momento del TGE (inicio del vesting).
    uint256 public tgeTime;

    /// @notice paymentToken aportado por cada comprador.
    mapping(address => uint256) public contributed;
    /// @notice saleTokens comprados por cada comprador.
    mapping(address => uint256) public purchased;
    /// @notice saleTokens ya reclamados por cada comprador.
    mapping(address => uint256) public claimed;

    // === EVENTS ===

    event Purchased(address indexed buyer, uint256 paymentAmount, uint256 tokenAmount);
    event Finalized(bool successful, uint256 totalRaised, uint256 tgeTime);
    event Claimed(address indexed buyer, uint256 amount);
    event SaleTokenSet(address indexed saleToken);
    event Refunded(address indexed buyer, uint256 paymentAmount);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event UnsoldTokensWithdrawn(address indexed to, uint256 amount);

    // === ERRORS ===

    error SaleNotActive();
    error SaleTokenNotSet();
    error SaleNotEnded();
    error AlreadyFinalized();
    error NotFinalized();
    error BelowMinContribution();
    error HardCapExceeded();
    error NothingToClaim();
    error NotRefundable();
    error NotSuccessful();
    error InvalidParams();
    error FeeOnTransferNotSupported();

    /**
     * @notice Configura la venta y fija el owner (destino de los fondos).
     * @dev Valida parámetros y la consistencia del vesting (IMMEDIATE_BPS + CLIFF_BPS = BPS).
     * @param _paymentToken Token de pago (USDC/USDT).
     * @param _linealLiquidity Owner que recibe fondos y tokens no vendidos.
     * @param _totalTokenSale Cantidad de saleTokens a vender.
     * @param _saleToken Token que se vende.
     * @param _rate saleTokens por unidad mínima de paymentToken.
     * @param _softCap Meta mínima de recaudación.
     * @param _hardCap Tope máximo de recaudación.
     * @param _startTime Inicio de la venta.
     * @param _endTime Fin de la venta.
     * @param _minContribution Aporte mínimo por comprador.
     */
    constructor(
        address _paymentToken,
        address _linealLiquidity,
        uint256 _totalTokenSale,
        address _saleToken,
        uint256 _rate,
        uint256 _softCap,
        uint256 _hardCap,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _minContribution
    ) Ownable(_linealLiquidity) {
        if (
            _paymentToken == address(0) ||
            _rate == 0 ||
            _totalTokenSale == 0 ||
            _hardCap == 0 ||
            _softCap > _hardCap ||
            _startTime < block.timestamp ||
            _endTime <= _startTime ||
            IMMEDIATE_BPS + CLIFF_BPS != BPS
        ) revert InvalidParams();

        paymentToken = IERC20(_paymentToken);
        saleToken = LinealToken(_saleToken);
        linealLiquidity = _linealLiquidity;
        rate = _rate;
        softCap = _softCap;
        hardCap = _hardCap;
        startTime = _startTime;
        endTime = _endTime;
        minContribution = _minContribution;
        totalTokenSale = _totalTokenSale;
    }

    // === BUY ===

    /// @notice Compra saleTokens pagando con `paymentToken`.
    /// @param paymentAmount Monto en unidades mínimas del paymentToken.
    ///        Requiere `approve` previo a este contrato.
    function buy(uint256 paymentAmount) external nonReentrant {
        require(address(saleToken) != address(0), "CLP: Reserve bank not set");
        if (finalized || block.timestamp < startTime || block.timestamp > endTime) {
            revert SaleNotActive();
        }
        if (paymentAmount < minContribution || paymentAmount == 0) {
            revert BelowMinContribution();
        }
        if (totalRaised + paymentAmount > hardCap) revert HardCapExceeded();

        // Se verifica lo realmente recibido para rechazar tokens con comisión por transferencia
        uint256 balanceBefore = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        uint256 received = paymentToken.balanceOf(address(this)) - balanceBefore;
        if (received != paymentAmount) revert FeeOnTransferNotSupported();

        // Tokens adquiridos según la tasa configurada.
        uint256 tokenAmount = paymentAmount * rate;

        totalRaised += paymentAmount;
        totalSold += tokenAmount;
        contributed[msg.sender] += paymentAmount;
        purchased[msg.sender] += tokenAmount;

        emit Purchased(msg.sender, paymentAmount, tokenAmount);
    }

    // === FINALIZATION ===

    /// @notice Cualquiera puede finalizar al terminar el plazo o al llegar al hardCap.
    function finalize() external {
        if (finalized) revert AlreadyFinalized();
        if (block.timestamp <= endTime && totalRaised < hardCap) revert SaleNotEnded();

        finalized = true;

        // El TGE arranca el vesting solo si se alcanzó el softCap.
        if (totalRaised >= softCap) {
            successful = true;
            tgeTime = block.timestamp;
        }

        emit Finalized(successful, totalRaised, tgeTime);
    }

    // === CLAIM (VESTING) ===

    /// @notice saleTokens que el comprador puede reclamar ahora mismo.
    function claimable(address buyer) public view returns (uint256) {
        if (!finalized || !successful) return 0;

        uint256 total = purchased[buyer];
        uint256 unlocked = (total * IMMEDIATE_BPS) / BPS;

        if (block.timestamp >= tgeTime + CLIFF_DURATION) {
            unlocked = total; // 20% + 80%
        }

        return unlocked - claimed[buyer];
    }

    /// @notice Reclama la porción desbloqueada del vesting del comprador.
    function claim() external nonReentrant {
        uint256 amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();

        claimed[msg.sender] += amount;
        totalClaimed += amount;
        LinealToken(address(saleToken)).transfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    // === REFUND (SOFT CAP NOT REACHED) ===

    /// @notice Devuelve el aporte al comprador si la venta no alcanzó el softCap.
    function refund() external nonReentrant {
        if (!finalized || successful) revert NotRefundable();

        uint256 amount = contributed[msg.sender];
        if (amount == 0) revert NothingToClaim();

        uint256 tokenAmount = purchased[msg.sender];

        contributed[msg.sender] = 0;
        purchased[msg.sender] = 0;

        // Se revierte la contabilidad de la venta fallida.
        totalRaised -= amount;
        totalSold -= tokenAmount;

        // Se devuelve el mismo token con el que se pagó (paymentToken).
        paymentToken.safeTransfer(msg.sender, amount);

        emit Refunded(msg.sender, amount);
    }

    // === ADMINISTRATION ===

    /// @notice Retira el paymentToken recaudado (solo si la venta fue exitosa).
    function withdrawFunds() external onlyOwner {
        if (!finalized) revert NotFinalized();
        if (!successful) revert NotSuccessful();

        uint256 balance = paymentToken.balanceOf(address(this));
        paymentToken.safeTransfer(linealLiquidity, balance);
        emit FundsWithdrawn(linealLiquidity, balance);
    }

    /// @notice Retira saleTokens no vendidos (venta exitosa) o todos (venta fallida).
    ///         Nunca toca los tokens pendientes de reclamo de los compradores.
    function withdrawUnsoldTokens() external onlyOwner {
        if (!finalized) revert NotFinalized();

        uint256 balance = LinealToken(address(saleToken)).balanceOf(address(this));
        // Se reserva lo pendiente de reclamo; solo se libera el excedente.
        uint256 reserved = successful ? (totalSold - totalClaimed) : 0;
        uint256 free = balance > reserved ? balance - reserved : 0;

        LinealToken(address(saleToken)).transfer(linealLiquidity, free);
        emit UnsoldTokensWithdrawn(linealLiquidity, free);
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.