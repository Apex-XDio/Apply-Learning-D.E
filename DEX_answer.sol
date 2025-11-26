// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Import the IERC20 interface for interacting with ERC-20 tokens
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract SimpleDEX {
    // --- State Variables ---
    address public immutable tokenA;
    address public immutable tokenB;
    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidity;

    // --- Events ---
    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidityMinted);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidityBurned);
    event Swap(address indexed trader, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    // --- Constructor ---
    // Task 1: Contract Setup
    constructor(address _tokenA, address _tokenB) {
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    // --- Core Functions ---

    /**
     * Task 2: Add Liquidity
     * @param amountA The amount of tokenA the user wants to deposit.
     * @param amountB The amount of tokenB the user wants to deposit.
     * @dev Allows a user to become a liquidity provider. For the first deposit, it sets the initial ratio.
     * For subsequent deposits, the provided amounts must be in the same ratio as the current reserves.
     */
    function addLiquidity(uint256 amountA, uint256 amountB) external {
        // Input validation
        require(amountA > 0 && amountB > 0, "SimpleDEX: Amounts must be greater than 0");

        (uint256 currentReserveA, uint256 currentReserveB) = getReserves();
        uint256 liquidityToMint;

        if (totalLiquidity == 0) {
            // LP-001 & LP-003: Initial liquidity - any ratio is accepted.
            liquidityToMint = _sqrt(amountA * amountB); // LP-003
        } else {
            // LP-001: Subsequent deposits must maintain the pool's ratio.
            // Check if the provided amounts are proportional to the reserves (with a 1% tolerance for practicality).
            require(
                amountA * currentReserveB == amountB * currentReserveA,
                "SimpleDEX: Provided amounts not proportional to reserves"
            );
            // LP-004: Calculate liquidity to mint proportional to existing share.
            liquidityToMint = (amountA * totalLiquidity) / currentReserveA;
            // Alternatively: liquidityToMint = (amountB * totalLiquidity) / currentReserveB; (should be equal)
        }

        // Transfer tokens from the user to the contract
        _safeTransferFrom(tokenA, msg.sender, address(this), amountA);
        _safeTransferFrom(tokenB, msg.sender, address(this), amountB);

        // LP-002: Mint liquidity tokens to the provider
        liquidity[msg.sender] += liquidityToMint;
        totalLiquidity += liquidityToMint;

        // Update reserves
        reserveA += amountA;
        reserveB += amountB;

        emit LiquidityAdded(msg.sender, amountA, amountB, liquidityToMint);
    }

    /**
     * Task 2: Remove Liquidity
     * @param liquidityAmount The amount of liquidity tokens to burn and redeem for underlying assets.
     * @dev REM-001 & REM-002: Allows a liquidity provider to withdraw their proportional share of the pool.
     */
    function removeLiquidity(uint256 liquidityAmount) external {
        // Input validation
        require(liquidityAmount > 0, "SimpleDEX: Liquidity amount must be greater than 0");
        require(liquidity[msg.sender] >= liquidityAmount, "SimpleDEX: Insufficient liquidity balance");

        // REM-002: Calculate the proportional amount of tokens to return
        uint256 amountA = (liquidityAmount * reserveA) / totalLiquidity;
        uint256 amountB = (liquidityAmount * reserveB) / totalLiquidity;

        // Burn the user's liquidity tokens
        liquidity[msg.sender] -= liquidityAmount;
        totalLiquidity -= liquidityAmount;

        // Update reserves before transferring tokens (to prevent reentrancy)
        reserveA -= amountA;
        reserveB -= amountB;

        // Transfer tokens back to the user
        _safeTransfer(tokenA, msg.sender, amountA);
        _safeTransfer(tokenB, msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB, liquidityAmount);
    }

    /**
     * Task 3: Swap Tokens
     * @param tokenIn The address of the token being sold.
     * @param amountIn The exact amount of tokenIn to sell (SWAP-001).
     * @param minAmountOut The minimum amount of output token the user expects (slippage protection).
     * @dev SWAP-002 & SWAP-003: Executes a swap using the constant product formula with a 0.3% fee.
     */
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) external {
        require(amountIn > 0, "SimpleDEX: Input amount must be greater than 0");
        require(tokenIn == tokenA || tokenIn == tokenB, "SimpleDEX: Invalid input token");

        // --- TRADING AGAINST THE POOL ---
        // Determine which token the trader is selling and which the POOL is selling
        (address tokenOut, uint256 poolReserveIn, uint256 poolReserveOut) = (tokenIn == tokenA) 
            ? (tokenB, reserveA, reserveB) 
            : (tokenA, reserveB, reserveA);

        // Calculate how much the POOL will give the trader based on POOL's reserves
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * poolReserveOut; // POOL's output reserve
        uint256 denominator = (poolReserveIn * 1000) + amountInWithFee; // POOL's input reserve
        uint256 amountOut = numerator / denominator; // Amount POOL gives to trader

        require(amountOut >= minAmountOut, "SimpleDEX: Insufficient output amount");

        // --- EXECUTE TRADE AGAINST POOL ---
        // Trader gives tokens to the POOL
        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        // POOL gives tokens to the trader
        _safeTransfer(tokenOut, msg.sender, amountOut);

        // --- UPDATE POOL'S RESERVES ---
        // The POOL now has more of the input token and less of the output token
        (uint256 newPoolReserveA, uint256 newPoolReserveB) = (tokenIn == tokenA)
            ? (reserveA + amountIn, reserveB - amountOut)  // POOL gains A, loses B
            : (reserveA - amountOut, reserveB + amountIn); // POOL loses A, gains B

        reserveA = newPoolReserveA;
        reserveB = newPoolReserveB;
        // --- TRADE COMPLETE ---

        emit Swap(msg.sender, tokenIn, amountIn, tokenOut, amountOut);
    }


    // --- View Functions ---

    /**
     * @return The current reserves of tokenA and tokenB.
     */
    function getReserves() public view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }

    /**
     * Task 3: Get Output Amount
     * @param tokenIn The address of the input token.
     * @param amountIn The amount of input token.
     * @return amountOut The estimated amount of output token.
     * @dev SWAP-002 & SWAP-003: A view function to quote the output amount for a given input, including fees.
     */
    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        require(tokenIn == tokenA || tokenIn == tokenB, "SimpleDEX: Invalid input token");
        (uint256 reserveIn, uint256 reserveOut) = (tokenIn == tokenA) ? (reserveA, reserveB) : (reserveB, reserveA);
        require(reserveIn > 0 && reserveOut > 0, "SimpleDEX: Insufficient liquidity");

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        return numerator / denominator;
    }

    /**
     * @param provider The address of the liquidity provider.
     * @return The amount of tokenA and tokenB that the provider is currently entitled to.
     */
    function getLiquidityValue(address provider) external view returns (uint256, uint256) {
        uint256 providerLiquidity = liquidity[provider];
        if (providerLiquidity == 0 || totalLiquidity == 0) {
            return (0, 0);
        }
        uint256 amountA = (providerLiquidity * reserveA) / totalLiquidity;
        uint256 amountB = (providerLiquidity * reserveB) / totalLiquidity;
        return (amountA, amountB);
    }

    // --- Internal Helper Functions ---

    /**
     * @dev Safely transfers ERC-20 tokens, checking for success.
     */
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SimpleDEX: TRANSFER_FAILED");
    }

    /**
     * @dev Safely transfers ERC-20 tokens from another address, checking for success and allowance.
     */
    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SimpleDEX: TRANSFER_FROM_FAILED");
    }

    /**
     * @dev Calculates the square root of a number (Babylonian method).
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}