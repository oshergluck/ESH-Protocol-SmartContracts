// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IUniswapV2Router {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline) external payable returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function WETH() external pure returns (address);
}

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
    
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);
}

interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }
    
    function getAmountsOut(uint amountIn, Route[] memory routes) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, Route[] calldata routes, address to, uint deadline) external returns (uint[] memory amounts);
}

contract EnhancedMultiDEXAggregator {
    address public owner;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    
    // V2 Router addresses on Base
    address public constant BASESWAP_ROUTER = 0x327Df1E6de05895d2ab08513aaDD9313Fe505d86;
    address public constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address public constant SUSHISWAP_ROUTER = 0x6BDED42c6DA8FBf0d2bA55B2fa120C5e0c8D7891;
    address public constant SWAPBASED_ROUTER = 0xaaa3b1F1bd7BCc97fD1917c18ADE665C5D31F066;
    address public constant HORIZONDEX_ROUTER = 0x99AEC509174Cbf06F8F7E15dDEeB7bcC32363827;
    
    // V3 Router addresses on Base
    address public constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant UNISWAP_V3_QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    
    // Aerodrome (Base's largest DEX)
    address public constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    
    // Common intermediate tokens for routing
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address public constant DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address public constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    
    // V3 fee tiers
    uint24 public constant FEE_LOW = 500;      // 0.05%
    uint24 public constant FEE_MEDIUM = 3000;  // 0.3%
    uint24 public constant FEE_HIGH = 10000;   // 1%
    
    // Slippage protection (in basis points)
    uint256 public constant MAX_SLIPPAGE = 300; // 3%
    uint256 public constant DEFAULT_SLIPPAGE = 100; // 1%
    
    struct RouteInfo {
        address router;
        uint256 amountOut;
        address[] path;
        bool isValid;
        string routerName;
        uint8 routerType; // 0 = V2, 1 = V3, 2 = Aerodrome
        uint24 fee; // for V3 routes
        bytes v3Path; // for V3 multi-hop
    }
    
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        address recipient;
        uint256 deadline;
        uint256 slippageBPS; // basis points (100 = 1%)
    }
    
    // Cache for V3 quotes to avoid state modification in view functions
    mapping(bytes32 => uint256) private v3QuoteCache;
    mapping(bytes32 => uint256) private quoteCacheTime;
    uint256 private constant CACHE_DURATION = 300; // 5 minutes
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address router,
        string routerName,
        uint256 gasUsed
    );
    
    event RouteOptimized(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 bestAmountOut,
        string bestRouter,
        uint256 totalRoutesChecked
    );
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier validAddress(address addr) {
        require(addr != address(0), "Invalid address");
        _;
    }
    
    modifier validAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than 0");
        _;
    }
    
    constructor() {
        owner = msg.sender;
    }
    
    // Main function compatible with your existing component
    function getOptimalAmountOut(
        address tokenA, 
        address tokenB, 
        uint256 amountIn
    ) external view validAddress(tokenA) validAddress(tokenB) validAmount(amountIn) 
      returns (uint256 bestAmountOut, address[] memory bestPath) {
        RouteInfo memory bestRoute = findBestRoute(tokenA, tokenB, amountIn);
        return (bestRoute.amountOut, bestRoute.path);
    }
    
    function findBestRoute(
        address tokenA, 
        address tokenB, 
        uint256 amountIn
    ) public view returns (RouteInfo memory bestRoute) {
        RouteInfo[] memory allRoutes = getAllRouteQuotes(tokenA, tokenB, amountIn);
        
        bestRoute.amountOut = 0;
        bestRoute.isValid = false;
        
        for (uint i = 0; i < allRoutes.length; i++) {
            if (allRoutes[i].isValid && allRoutes[i].amountOut > bestRoute.amountOut) {
                bestRoute = allRoutes[i];
            }
        }
    }
    
    function getAllRouteQuotes(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) public view returns (RouteInfo[] memory routes) {
        // Estimate max routes: 6 V2 routers * 6 paths + cached V3 routes = ~40 max
        routes = new RouteInfo[](40);
        uint256 routeIndex = 0;
        
        // V2 Router addresses and names
        address[] memory v2Routers = new address[](5);
        string[] memory v2Names = new string[](5);
        
        v2Routers[0] = BASESWAP_ROUTER;     v2Names[0] = "BaseSwap";
        v2Routers[1] = UNISWAP_V2_ROUTER;   v2Names[1] = "Uniswap V2";
        v2Routers[2] = SUSHISWAP_ROUTER;    v2Names[2] = "SushiSwap";
        v2Routers[3] = SWAPBASED_ROUTER;    v2Names[3] = "SwapBased";
        v2Routers[4] = HORIZONDEX_ROUTER;   v2Names[4] = "HorizonDEX";
        
        // Check all V2 routers with all paths
        for (uint i = 0; i < v2Routers.length; i++) {
            RouteInfo[] memory v2Routes = getV2RouteInfo(tokenA, tokenB, amountIn, v2Routers[i], v2Names[i]);
            for (uint j = 0; j < v2Routes.length && routeIndex < routes.length; j++) {
                if (v2Routes[j].isValid) {
                    routes[routeIndex] = v2Routes[j];
                    routeIndex++;
                }
            }
        }
        
        // Check cached V3 routes
        RouteInfo[] memory v3Routes = getCachedV3Routes(tokenA, tokenB, amountIn);
        for (uint i = 0; i < v3Routes.length && routeIndex < routes.length; i++) {
            if (v3Routes[i].isValid) {
                routes[routeIndex] = v3Routes[i];
                routeIndex++;
            }
        }
        
        // Resize array to actual used routes
        RouteInfo[] memory finalRoutes = new RouteInfo[](routeIndex);
        for (uint i = 0; i < routeIndex; i++) {
            finalRoutes[i] = routes[i];
        }
        
        return finalRoutes;
    }
    
    function getV2RouteInfo(
        address tokenA,
        address tokenB,
        uint256 amountIn,
        address routerAddress,
        string memory routerName
    ) public view returns (RouteInfo[] memory routes) {
        address[][] memory paths = generateV2Paths(tokenA, tokenB);
        routes = new RouteInfo[](paths.length);
        
        for (uint i = 0; i < paths.length; i++) {
            routes[i].router = routerAddress;
            routes[i].routerName = routerName;
            routes[i].routerType = 0; // V2
            routes[i].amountOut = 0;
            routes[i].isValid = false;
            routes[i].path = paths[i];
            
            try IUniswapV2Router(routerAddress).getAmountsOut(amountIn, paths[i]) returns (uint[] memory amounts) {
                if (amounts.length > 0 && amounts[amounts.length - 1] > 0) {
                    routes[i].amountOut = amounts[amounts.length - 1];
                    routes[i].isValid = true;
                }
            } catch {
                // Route not available
            }
        }
    }
    
    // Function to update V3 quotes (non-view function)
    function updateV3Quotes(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) external {
        uint24[] memory fees = new uint24[](3);
        fees[0] = FEE_LOW;
        fees[1] = FEE_MEDIUM;
        fees[2] = FEE_HIGH;
        
        // Update direct V3 routes
        for (uint i = 0; i < fees.length; i++) {
            bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB, fees[i], amountIn));
            
            try IUniswapV3Quoter(UNISWAP_V3_QUOTER).quoteExactInputSingle(
                tokenA,
                tokenB,
                fees[i],
                amountIn,
                0
            ) returns (uint256 amountOut) {
                if (amountOut > 0) {
                    v3QuoteCache[key] = amountOut;
                    quoteCacheTime[key] = block.timestamp;
                }
            } catch {
                // Pool doesn't exist for this fee tier
                v3QuoteCache[key] = 0;
                quoteCacheTime[key] = block.timestamp;
            }
        }
        
        // Update multi-hop V3 routes through WETH and USDC
        address[] memory intermediates = new address[](2);
        intermediates[0] = WETH;
        intermediates[1] = USDC;
        
        for (uint i = 0; i < intermediates.length; i++) {
            if (intermediates[i] != tokenA && intermediates[i] != tokenB) {
                bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB, intermediates[i], amountIn, "multihop"));
                uint256 amountOut = getV3MultiHopQuoteInternal(tokenA, tokenB, amountIn, intermediates[i]);
                v3QuoteCache[key] = amountOut;
                quoteCacheTime[key] = block.timestamp;
            }
        }
    }
    
    function getCachedV3Routes(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) public view returns (RouteInfo[] memory routes) {
        uint24[] memory fees = new uint24[](3);
        fees[0] = FEE_LOW;
        fees[1] = FEE_MEDIUM;
        fees[2] = FEE_HIGH;
        
        // Maximum possible V3 routes
        routes = new RouteInfo[](5); // 3 direct + 2 multi-hop
        uint256 routeIndex = 0;
        
        // Direct V3 routes from cache
        for (uint i = 0; i < fees.length; i++) {
            bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB, fees[i], amountIn));
            
            if (quoteCacheTime[key] + CACHE_DURATION > block.timestamp && v3QuoteCache[key] > 0) {
                routes[routeIndex].router = UNISWAP_V3_ROUTER;
                routes[routeIndex].routerName = string(abi.encodePacked("Uniswap V3 (", feeToString(fees[i]), ")"));
                routes[routeIndex].routerType = 1; // V3
                routes[routeIndex].fee = fees[i];
                routes[routeIndex].amountOut = v3QuoteCache[key];
                routes[routeIndex].isValid = true;
                
                routes[routeIndex].path = new address[](2);
                routes[routeIndex].path[0] = tokenA;
                routes[routeIndex].path[1] = tokenB;
                
                routeIndex++;
            }
        }
        
        // Multi-hop V3 routes from cache
        address[] memory intermediates = new address[](2);
        intermediates[0] = WETH;
        intermediates[1] = USDC;
        
        for (uint i = 0; i < intermediates.length; i++) {
            if (intermediates[i] != tokenA && intermediates[i] != tokenB) {
                bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB, intermediates[i], amountIn, "multihop"));
                
                if (quoteCacheTime[key] + CACHE_DURATION > block.timestamp && v3QuoteCache[key] > 0) {
                    routes[routeIndex].router = UNISWAP_V3_ROUTER;
                    routes[routeIndex].routerName = string(abi.encodePacked("Uniswap V3 Multi (", getTokenSymbol(intermediates[i]), ")"));
                    routes[routeIndex].routerType = 1;
                    routes[routeIndex].fee = FEE_MEDIUM;
                    routes[routeIndex].amountOut = v3QuoteCache[key];
                    routes[routeIndex].isValid = true;
                    
                    routes[routeIndex].path = new address[](3);
                    routes[routeIndex].path[0] = tokenA;
                    routes[routeIndex].path[1] = intermediates[i];
                    routes[routeIndex].path[2] = tokenB;
                    
                    routes[routeIndex].v3Path = abi.encodePacked(tokenA, FEE_MEDIUM, intermediates[i], FEE_MEDIUM, tokenB);
                    
                    routeIndex++;
                }
            }
        }
        
        // Resize to actual routes
        RouteInfo[] memory finalRoutes = new RouteInfo[](routeIndex);
        for (uint i = 0; i < routeIndex; i++) {
            finalRoutes[i] = routes[i];
        }
        
        return finalRoutes;
    }
    
    function getV3MultiHopQuoteInternal(
        address tokenA,
        address tokenB,
        uint256 amountIn,
        address intermediate
    ) internal returns (uint256 amountOut) {
        try IUniswapV3Quoter(UNISWAP_V3_QUOTER).quoteExactInputSingle(
            tokenA, intermediate, FEE_MEDIUM, amountIn, 0
        ) returns (uint256 intermediateAmount) {
            if (intermediateAmount > 0) {
                try IUniswapV3Quoter(UNISWAP_V3_QUOTER).quoteExactInputSingle(
                    intermediate, tokenB, FEE_MEDIUM, intermediateAmount, 0
                ) returns (uint256 finalAmount) {
                    return finalAmount;
                } catch {
                    return 0;
                }
            }
        } catch {
            return 0;
        }
        return 0;
    }
    
    function getAerodromeRouteInfo(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) public pure returns (RouteInfo[] memory routes) {
        // Placeholder for Aerodrome implementation
        // Actual implementation would require Aerodrome's specific interface
        return new RouteInfo[](0);
    }
    
    function generateV2Paths(address tokenA, address tokenB) public pure returns (address[][] memory paths) {
        address[] memory intermediateTokens = new address[](5);
        intermediateTokens[0] = WETH;
        intermediateTokens[1] = USDC;
        intermediateTokens[2] = USDT;
        intermediateTokens[3] = DAI;
        intermediateTokens[4] = CBETH;
        
        paths = new address[][](6); // Direct + 5 intermediate paths max
        
        // Direct path
        paths[0] = new address[](2);
        paths[0][0] = tokenA;
        paths[0][1] = tokenB;
        
        // Paths through intermediate tokens
        uint pathIndex = 1;
        for (uint i = 0; i < intermediateTokens.length && pathIndex < paths.length; i++) {
            if (intermediateTokens[i] != tokenA && intermediateTokens[i] != tokenB) {
                paths[pathIndex] = new address[](3);
                paths[pathIndex][0] = tokenA;
                paths[pathIndex][1] = intermediateTokens[i];
                paths[pathIndex][2] = tokenB;
                pathIndex++;
            }
        }
        
        // Resize to actual paths
        address[][] memory finalPaths = new address[][](pathIndex);
        for (uint i = 0; i < pathIndex; i++) {
            finalPaths[i] = paths[i];
        }
        
        return finalPaths;
    }
    
    // Enhanced swap functions with better error handling and slippage protection
    function swapExactTokensForTokens(
        address tokenA,
        address tokenB,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external validAddress(tokenA) validAddress(tokenB) validAddress(to) validAmount(amountIn) 
      returns (uint256 amountOut) {
        require(deadline >= block.timestamp, "Transaction expired");
        
        RouteInfo memory bestRoute = findBestRoute(tokenA, tokenB, amountIn);
        require(bestRoute.isValid, "No valid route found");
        require(bestRoute.amountOut >= amountOutMin, "Insufficient output amount");
        
        uint256 gasStart = gasleft();
        
        // Transfer tokens from user
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountIn);
        
        if (bestRoute.routerType == 0) {
            // V2 Router
            IERC20(tokenA).approve(bestRoute.router, amountIn);
            IUniswapV2Router router = IUniswapV2Router(bestRoute.router);
            uint[] memory amounts = router.swapExactTokensForTokens(
                amountIn,
                amountOutMin,
                bestRoute.path,
                to,
                deadline
            );
            amountOut = amounts[amounts.length - 1];
        } else if (bestRoute.routerType == 1) {
            // V3 Router
            IERC20(tokenA).approve(bestRoute.router, amountIn);
            
            if (bestRoute.v3Path.length > 0) {
                // Multi-hop V3
                IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
                    path: bestRoute.v3Path,
                    recipient: to,
                    deadline: deadline,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin
                });
                amountOut = IUniswapV3Router(bestRoute.router).exactInput(params);
            } else {
                // Single-hop V3
                IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: tokenA,
                    tokenOut: tokenB,
                    fee: bestRoute.fee,
                    recipient: to,
                    deadline: deadline,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin,
                    sqrtPriceLimitX96: 0
                });
                amountOut = IUniswapV3Router(bestRoute.router).exactInputSingle(params);
            }
        }
        
        uint256 gasUsed = gasStart - gasleft();
        emit SwapExecuted(msg.sender, tokenA, tokenB, amountIn, amountOut, bestRoute.router, bestRoute.routerName, gasUsed);
    }
    
    function swapExactETHForTokens(
        address tokenB,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external payable validAddress(tokenB) validAddress(to) validAmount(msg.value) 
      returns (uint256 amountOut) {
        require(deadline >= block.timestamp, "Transaction expired");
        
        RouteInfo memory bestRoute = findBestRoute(WETH, tokenB, msg.value);
        require(bestRoute.isValid, "No valid route found");
        require(bestRoute.amountOut >= amountOutMin, "Insufficient output amount");
        
        uint256 gasStart = gasleft();
        
        if (bestRoute.routerType == 0) {
            // V2 Router
            IUniswapV2Router router = IUniswapV2Router(bestRoute.router);
            uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
                amountOutMin,
                bestRoute.path,
                to,
                deadline
            );
            amountOut = amounts[amounts.length - 1];
        } else {
            // V3 Router - need to wrap ETH first and handle differently
            revert("ETH swaps for V3 require WETH conversion");
        }
        
        uint256 gasUsed = gasStart - gasleft();
        emit SwapExecuted(msg.sender, WETH, tokenB, msg.value, amountOut, bestRoute.router, bestRoute.routerName, gasUsed);
    }
    
    function swapExactTokensForETH(
        address tokenA,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external validAddress(tokenA) validAddress(to) validAmount(amountIn) 
      returns (uint256 amountOut) {
        require(deadline >= block.timestamp, "Transaction expired");
        
        RouteInfo memory bestRoute = findBestRoute(tokenA, WETH, amountIn);
        require(bestRoute.isValid, "No valid route found");
        require(bestRoute.amountOut >= amountOutMin, "Insufficient output amount");
        
        uint256 gasStart = gasleft();
        
        // Transfer tokens from user
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountIn);
        
        if (bestRoute.routerType == 0) {
            // V2 Router
            IERC20(tokenA).approve(bestRoute.router, amountIn);
            IUniswapV2Router router = IUniswapV2Router(bestRoute.router);
            uint[] memory amounts = router.swapExactTokensForETH(
                amountIn,
                amountOutMin,
                bestRoute.path,
                to,
                deadline
            );
            amountOut = amounts[amounts.length - 1];
        } else {
            // V3 Router implementation
            revert("ETH swaps for V3 require WETH conversion");
        }
        
        uint256 gasUsed = gasStart - gasleft();
        emit SwapExecuted(msg.sender, tokenA, WETH, amountIn, amountOut, bestRoute.router, bestRoute.routerName, gasUsed);
    }
    
    // Enhanced comparison function (non-view to allow event emission)
    function compareAllRoutes(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) external returns (
        uint256[] memory amountsOut,
        address[] memory routers,
        string[] memory routerNames,
        bool[] memory validRoutes,
        uint8[] memory routerTypes
    ) {
        // First update V3 quotes
        this.updateV3Quotes(tokenA, tokenB, amountIn);
        
        RouteInfo[] memory allRoutes = getAllRouteQuotes(tokenA, tokenB, amountIn);
        
        // Filter out only the best route per router to avoid clutter
        RouteInfo[] memory bestPerRouter = getBestRoutePerRouter(allRoutes);
        
        uint256 routeCount = bestPerRouter.length;
        amountsOut = new uint256[](routeCount);
        routers = new address[](routeCount);
        routerNames = new string[](routeCount);
        validRoutes = new bool[](routeCount);
        routerTypes = new uint8[](routeCount);
        
        for (uint i = 0; i < routeCount; i++) {
            amountsOut[i] = bestPerRouter[i].amountOut;
            routers[i] = bestPerRouter[i].router;
            routerNames[i] = bestPerRouter[i].routerName;
            validRoutes[i] = bestPerRouter[i].isValid;
            routerTypes[i] = bestPerRouter[i].routerType;
        }
        
        emit RouteOptimized(tokenA, tokenB, amountIn, bestPerRouter.length > 0 ? bestPerRouter[0].amountOut : 0, 
                           bestPerRouter.length > 0 ? bestPerRouter[0].routerName : "None", allRoutes.length);
    }
    
    // View version of compareAllRoutes for frontend
    function compareAllRoutesView(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) external view returns (
        uint256[] memory amountsOut,
        address[] memory routers,
        string[] memory routerNames,
        bool[] memory validRoutes,
        uint8[] memory routerTypes
    ) {
        RouteInfo[] memory allRoutes = getAllRouteQuotes(tokenA, tokenB, amountIn);
        
        // Filter out only the best route per router to avoid clutter
        RouteInfo[] memory bestPerRouter = getBestRoutePerRouter(allRoutes);
        
        uint256 routeCount = bestPerRouter.length;
        amountsOut = new uint256[](routeCount);
        routers = new address[](routeCount);
        routerNames = new string[](routeCount);
        validRoutes = new bool[](routeCount);
        routerTypes = new uint8[](routeCount);
        
        for (uint i = 0; i < routeCount; i++) {
            amountsOut[i] = bestPerRouter[i].amountOut;
            routers[i] = bestPerRouter[i].router;
            routerNames[i] = bestPerRouter[i].routerName;
            validRoutes[i] = bestPerRouter[i].isValid;
            routerTypes[i] = bestPerRouter[i].routerType;
        }
    }
    
    function getBestRoutePerRouter(RouteInfo[] memory allRoutes) internal pure returns (RouteInfo[] memory bestRoutes) {
        // Find unique router names first
        string[] memory uniqueRouterNames = new string[](20); // Max expected routers
        uint256 routerCount = 0;
        
        // Collect unique router names
        for (uint i = 0; i < allRoutes.length; i++) {
            if (!allRoutes[i].isValid) continue;
            
            string memory currentRouterName = allRoutes[i].routerName;
            bool routerExists = false;
            
            // Check if we've seen this router before
            for (uint j = 0; j < routerCount; j++) {
                if (keccak256(bytes(uniqueRouterNames[j])) == keccak256(bytes(currentRouterName))) {
                    routerExists = true;
                    break;
                }
            }
            
            if (!routerExists) {
                uniqueRouterNames[routerCount] = currentRouterName;
                routerCount++;
            }
        }
        
        // Find best route for each unique router
        bestRoutes = new RouteInfo[](routerCount);
        uint256 resultIndex = 0;
        
        for (uint i = 0; i < routerCount; i++) {
            string memory targetRouterName = uniqueRouterNames[i];
            RouteInfo memory bestForRouter;
            bestForRouter.amountOut = 0;
            bestForRouter.isValid = false;
            
            // Find best route for this router
            for (uint j = 0; j < allRoutes.length; j++) {
                if (keccak256(bytes(allRoutes[j].routerName)) == keccak256(bytes(targetRouterName)) && 
                    allRoutes[j].isValid && 
                    allRoutes[j].amountOut > bestForRouter.amountOut) {
                    bestForRouter = allRoutes[j];
                }
            }
            
            if (bestForRouter.isValid) {
                bestRoutes[resultIndex] = bestForRouter;
                resultIndex++;
            }
        }
        
        // Resize to actual count
        RouteInfo[] memory finalBestRoutes = new RouteInfo[](resultIndex);
        for (uint i = 0; i < resultIndex; i++) {
            finalBestRoutes[i] = bestRoutes[i];
        }
        
        return finalBestRoutes;
    }
    
    // Price impact calculation
    function calculatePriceImpact(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) external view returns (uint256 priceImpactBPS) {
        // Get quote for small amount (0.1% of input)
        uint256 smallAmount = amountIn / 1000;
        if (smallAmount == 0) smallAmount = 1;
        
        RouteInfo memory smallRoute = findBestRoute(tokenA, tokenB, smallAmount);
        RouteInfo memory largeRoute = findBestRoute(tokenA, tokenB, amountIn);
        
        if (!smallRoute.isValid || !largeRoute.isValid) return 10000; // 100% impact
        
        uint256 smallPrice = (smallRoute.amountOut * 1e18) / smallAmount;
        uint256 largePrice = (largeRoute.amountOut * 1e18) / amountIn;
        
        if (smallPrice > largePrice) {
            return ((smallPrice - largePrice) * 10000) / smallPrice;
        }
        return 0;
    }
    
    // Quote with slippage protection
    function getQuoteWithSlippage(
        address tokenA,
        address tokenB,
        uint256 amountIn,
        uint256 slippagePercent // e.g., 50 = 0.5%
    ) external view returns (uint256 amountOutWithSlippage) {
        RouteInfo memory bestRoute = findBestRoute(tokenA, tokenB, amountIn);
        if (!bestRoute.isValid) return 0;
        
        uint256 slippageAmount = (bestRoute.amountOut * slippagePercent) / 10000;
        return bestRoute.amountOut - slippageAmount;
    }
    
    // Utility functions
    function feeToString(uint24 fee) internal pure returns (string memory) {
        if (fee == 500) return "0.05%";
        if (fee == 3000) return "0.3%";
        if (fee == 10000) return "1%";
        return "Custom";
    }
    
    function getTokenSymbol(address token) internal view returns (string memory) {
        if (token == WETH) return "WETH";
        if (token == USDC) return "USDC";
        if (token == USDT) return "USDT";
        if (token == DAI) return "DAI";
        if (token == CBETH) return "cbETH";
        
        try IERC20(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "UNKNOWN";
        }
    }
    
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    // Admin functions
    function emergencyWithdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner).transfer(address(this).balance);
        } else {
            IERC20(token).transfer(owner, IERC20(token).balanceOf(address(this)));
        }
    }
    
    function updateOwner(address newOwner) external onlyOwner validAddress(newOwner) {
        owner = newOwner;
    }
    
    // Clear V3 cache manually if needed
    function clearV3Cache() external onlyOwner {
        // This would require implementing a way to track cache keys
        // For now, cache will auto-expire after 5 minutes
    }
    
    // Get all routers for transparency
    function getAllSupportedRouters() external pure returns (
        address[] memory routerAddresses,
        string[] memory routerNames,
        uint8[] memory routerTypes
    ) {
        routerAddresses = new address[](6);
        routerNames = new string[](6);
        routerTypes = new uint8[](6);
        
        routerAddresses[0] = BASESWAP_ROUTER;       routerNames[0] = "BaseSwap";           routerTypes[0] = 0;
        routerAddresses[1] = UNISWAP_V2_ROUTER;     routerNames[1] = "Uniswap V2";         routerTypes[1] = 0;
        routerAddresses[2] = SUSHISWAP_ROUTER;      routerNames[2] = "SushiSwap";          routerTypes[2] = 0;
        routerAddresses[3] = SWAPBASED_ROUTER;      routerNames[3] = "SwapBased";          routerTypes[3] = 0;
        routerAddresses[4] = HORIZONDEX_ROUTER;     routerNames[4] = "HorizonDEX";         routerTypes[4] = 0;
        routerAddresses[5] = UNISWAP_V3_ROUTER;     routerNames[5] = "Uniswap V3";         routerTypes[5] = 1;
    }
    
    // Gas estimation function
    function estimateGas(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) external view returns (uint256 estimatedGas) {
        RouteInfo memory bestRoute = findBestRoute(tokenA, tokenB, amountIn);
        
        if (!bestRoute.isValid) return 0;
        
        // Rough gas estimates based on route type
        if (bestRoute.routerType == 0) {
            // V2 swaps
            if (bestRoute.path.length == 2) {
                return 150000; // Direct swap
            } else {
                return 200000; // Multi-hop swap
            }
        } else if (bestRoute.routerType == 1) {
            // V3 swaps
            if (bestRoute.v3Path.length > 0) {
                return 180000; // Multi-hop V3
            } else {
                return 130000; // Direct V3 swap
            }
        }
        
        return 200000; // Default estimate
    }
    
    receive() external payable {}
}