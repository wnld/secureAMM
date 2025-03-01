// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

interface IPriceOracle {
    function getTWAP(address tokenIn, address tokenOut) external view returns (uint256);
}

contract SecureAMM is ReentrancyGuard, ERC20Burnable {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    IPriceOracle public immutable oracle;

    uint256 public reserveA;
    uint256 public reserveB;

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB);
    event Swap(address indexed trader, address tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address _tokenA, address _tokenB, address _oracle) ERC20("LP Token", "LPT") {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        oracle = IPriceOracle(_oracle);
    }

    /**
     * @notice Adds liquidity and mints LP tokens
     */
    function addLiquidity(uint256 amountA, uint256 amountB) external nonReentrant {
        require(amountA > 0 && amountB > 0, "Amounts must be > 0");

        uint256 _reserveA = reserveA;
        uint256 _reserveB = reserveB;

        // Fee-on-transfer token support: Get real received amounts
        uint256 beforeA = tokenA.balanceOf(address(this));
        uint256 beforeB = tokenB.balanceOf(address(this));

        tokenA.transferFrom(msg.sender, address(this), amountA);
        tokenB.transferFrom(msg.sender, address(this), amountB);

        uint256 realAmountA = tokenA.balanceOf(address(this)) - beforeA;
        uint256 realAmountB = tokenB.balanceOf(address(this)) - beforeB;

        // LP Token Minting (Proportional to liquidity added)
        uint256 liquidity;
        if (_reserveA == 0 && _reserveB == 0) {
            liquidity = realAmountA + realAmountB;
        } else {
            liquidity = (realAmountA * totalSupply()) / _reserveA;
        }

        _mint(msg.sender, liquidity);

        reserveA += realAmountA;
        reserveB += realAmountB;

        emit LiquidityAdded(msg.sender, realAmountA, realAmountB);
    }

    /**
     * @notice Removes liquidity and burns LP tokens
     */
    function removeLiquidity(uint256 amount) external nonReentrant {
        uint256 totalLPTokens = totalSupply();
        require(balanceOf(msg.sender) >= amount, "Not enough LP tokens");

        uint256 amountA = (amount * reserveA) / totalLPTokens;
        uint256 amountB = (amount * reserveB) / totalLPTokens;

        _burn(msg.sender, amount);
        reserveA -= amountA;
        reserveB -= amountB;

        tokenA.transfer(msg.sender, amountA);
        tokenB.transfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB);
    }

    /**
     * @notice Swaps tokenA for tokenB or vice versa, using TWAP pricing
     */
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) external nonReentrant returns (uint256 amountOut) {
        require(tokenIn == address(tokenA) || tokenIn == address(tokenB), "Invalid token");

        bool isTokenA = tokenIn == address(tokenA);
        IERC20 inToken = isTokenA ? tokenA : tokenB;
        IERC20 outToken = isTokenA ? tokenB : tokenA;

        uint256 reserveIn = isTokenA ? reserveA : reserveB;
        uint256 reserveOut = isTokenA ? reserveB : reserveA;

        require(amountIn > 0, "Amount must be > 0");
        require(reserveOut > 0, "Not enough liquidity");

        // Get TWAP price from Oracle
        uint256 marketPrice = oracle.getTWAP(address(inToken), address(outToken));

        // Apply 0.3% fee and prevent manipulation by flash loans
        uint256 amountInWithFee = (amountIn * 997) / 1000;
        uint256 expectedOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);

        require(expectedOut >= minAmountOut, "Slippage too high");
        require(expectedOut <= marketPrice, "Price manipulation detected");

        uint256 beforeOut = outToken.balanceOf(msg.sender);
        inToken.transferFrom(msg.sender, address(this), amountIn);
        outToken.transfer(msg.sender, expectedOut);
        uint256 receivedOut = outToken.balanceOf(msg.sender) - beforeOut;

        require(receivedOut >= minAmountOut, "Slippage exceeded after transfer");

        // Update reserves
        if (isTokenA) {
            reserveA += amountIn;
            reserveB -= expectedOut;
        } else {
            reserveB += amountIn;
            reserveA -= expectedOut;
        }

        emit Swap(msg.sender, tokenIn, amountIn, expectedOut);
    }
}
