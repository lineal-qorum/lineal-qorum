// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Mock AMM de producto constante (x*y=k) con un solo par INCOME_TOKEN/TOKEN.
contract LinealDex is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable TOKEN;
    address public immutable INCOME_TOKEN;

    uint256 public reserveToken;
    uint256 public reserveIncome;

    // TWAP (acumulador de precio estilo Uniswap V2)
    uint256 public priceCumulativeLast; // INCOME por TOKEN (1e18) * segundos
    uint256 public blockTimestampLast;

    uint256 public constant FEE_BPS = 30; // 0.3%, queda en el pool y sube k

    // Participación de liquidez (simplificada, sin ERC20 de LP)
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    event Swap(address indexed to, address tokenIn, uint256 amountIn, uint256 amountOut);
    event LiquidityAdded(address indexed to, uint256 amountIncome, uint256 amountToken, uint256 shares);
    event LiquidityRemoved(address indexed from, uint256 amountIncome, uint256 amountToken, uint256 shares);

    constructor(address _token, address _income) {
        TOKEN = _token;
        INCOME_TOKEN = _income;
    }

    // ───────────── Vistas ─────────────

    /// Cantidad de salida según reservas y fee (la fórmula de Uniswap V2).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
    public pure returns (uint256)
    {
        require(amountIn > 0, "Mock: zero input");
        require(reserveIn > 0 && reserveOut > 0, "Mock: no liquidity");
        uint256 inWithFee = amountIn * (10_000 - FEE_BPS);
        return (inWithFee * reserveOut) / (reserveIn * 10_000 + inWithFee);
    }

    /// Precio spot: unidades de TOKEN por 1 unidad de INCOME_TOKEN (escala 1e18).
    function spotPrice() external view returns (uint256) {
        require(reserveIncome > 0, "Mock: no liquidity");
        return (reserveToken * 1e18) / reserveIncome;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
    external view returns (uint256[] memory amounts)
    {
        require(path.length == 2, "Mock: invalid path");
        (uint256 rIn, uint256 rOut) = _reservesFor(path[0], path[1]);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = getAmountOut(amountIn, rIn, rOut);
    }

    // ───────────── Swap ─────────────

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "Mock: expired");
        require(path.length == 2, "Mock: invalid path");

        (uint256 rIn, uint256 rOut) = _reservesFor(path[0], path[1]);
        uint256 amountOut = getAmountOut(amountIn, rIn, rOut);
        require(amountOut >= amountOutMin, "Mock: Swap failed (slippage)");
        _update();   // <-- aquí también
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).safeTransfer(to, amountOut);

        // Actualiza reservas: el precio se mueve aquí
        if (path[0] == INCOME_TOKEN) {
            reserveIncome += amountIn;
            reserveToken -= amountOut;
        } else {
            reserveToken += amountIn;
            reserveIncome -= amountOut;
        }

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
        emit Swap(to, path[0], amountIn, amountOut);
    }

    // ───────────── Liquidez ─────────────

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(block.timestamp <= deadline, "Mock: expired");
        require(
            (tokenA == INCOME_TOKEN && tokenB == TOKEN) || (tokenA == TOKEN && tokenB == INCOME_TOKEN),
            "Mock: invalid pair"
        );
        _update();   // <-- aquí también
        // Normaliza a (income, token)
        bool aIsIncome = tokenA == INCOME_TOKEN;
        uint256 dIncome = aIsIncome ? amountADesired : amountBDesired;
        uint256 dToken  = aIsIncome ? amountBDesired : amountADesired;
        uint256 minIncome = aIsIncome ? amountAMin : amountBMin;
        uint256 minToken  = aIsIncome ? amountBMin : amountAMin;

        uint256 aIncome;
        uint256 aToken;
        if (reserveIncome == 0 && reserveToken == 0) {
            // Primer depósito: fija el precio inicial
            (aIncome, aToken) = (dIncome, dToken);
        } else {
            // Respeta la proporción actual para no mover el precio
            uint256 optToken = (dIncome * reserveToken) / reserveIncome;
            if (optToken <= dToken) {
                require(optToken >= minToken, "Mock: insufficient token amount");
                (aIncome, aToken) = (dIncome, optToken);
            } else {
                uint256 optIncome = (dToken * reserveIncome) / reserveToken;
                require(optIncome <= dIncome && optIncome >= minIncome, "Mock: insufficient income amount");
                (aIncome, aToken) = (optIncome, dToken);
            }
        }

        IERC20(INCOME_TOKEN).safeTransferFrom(msg.sender, address(this), aIncome);
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), aToken);

        if (totalShares == 0) {
            liquidity = _sqrt(aIncome * aToken);
        } else {
            uint256 s1 = (aIncome * totalShares) / reserveIncome;
            uint256 s2 = (aToken * totalShares) / reserveToken;
            liquidity = s1 < s2 ? s1 : s2;
        }
        require(liquidity > 0, "Mock: zero liquidity");

        reserveIncome += aIncome;
        reserveToken += aToken;
        totalShares += liquidity;
        sharesOf[to] += liquidity;

        (amountA, amountB) = aIsIncome ? (aIncome, aToken) : (aToken, aIncome);
        emit LiquidityAdded(to, aIncome, aToken, liquidity);
    }

    /// Extra para tests: retirar liquidez.
    function _reservesFor(address tokenIn, address tokenOut)
    internal view returns (uint256 rIn, uint256 rOut)
    {
        if (tokenIn == INCOME_TOKEN && tokenOut == TOKEN) return (reserveIncome, reserveToken);
        if (tokenIn == TOKEN && tokenOut == INCOME_TOKEN) return (reserveToken, reserveIncome);
        revert("Mock: Invalid path");
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) {
            z = 1;
        }
    }

    /// Liquidez total del pool: reservas de cada token y participaciones emitidas.
    /// Valor total del pool expresado en INCOME_TOKEN.
    /// Al precio spot, ambos lados valen lo mismo, así que el total es 2 * reserveIncome.
    function getTotalLiquidity()
    external
    view
    returns (
        uint256 ingreso,
        uint256 token,
        uint256 participaciones
    )
    {
        return (reserveIncome, reserveToken, totalShares);
    }

    function getTotalLiquidityInIncome()
    external
    view
    returns (uint256)
    {
        return reserveIncome * 2;
    }
    function _update() private {
        uint256 dt = block.timestamp - blockTimestampLast;
        if (dt > 0 && reserveToken > 0 && reserveIncome > 0) {
            priceCumulativeLast += (reserveIncome * 1e18 / reserveToken) * dt;
        }
        blockTimestampLast = block.timestamp;
    }

    /// Acumulador al instante actual, sin necesidad de que alguien opere.
    function currentPriceCumulative() public view returns (uint256 cumulative, uint256 timestamp) {
        cumulative = priceCumulativeLast;
        uint256 dt = block.timestamp - blockTimestampLast;
        if (dt > 0 && reserveToken > 0 && reserveIncome > 0) {
            cumulative += (reserveIncome * 1e18 / reserveToken) * dt;
        }
        timestamp = block.timestamp;
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.