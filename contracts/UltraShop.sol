// SPDX-License-Identifier: apache 2.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2Router02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IESH {
    function burn(uint256 amount) external;
    function getHolders() external view returns (address[] memory);
    function balanceOf(address account) external view returns (uint256);
    function isReady() external view returns(bool);
}

contract UltraShop is ReentrancyGuard, Ownable(msg.sender) {
    // Base chain addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    IUniswapV2Router02 public constant ROUTER = IUniswapV2Router02(0x327Df1E6de05895d2ab08513aaDD9313Fe505d86); // BaseSwap Router
    IUniswapV2Factory public constant FACTORY = IUniswapV2Factory(0xFDa619b6d20975be80A10332cD39b9a4b0FAa8BB); // BaseSwap Factory
    mapping(address => uint256) public lastActivityAt;
    uint256 public constant REQUIRED_TOKEN_A_AMOUNT = 1_000_000_000 * 10**18; // 1 billion tokenA (18 decimals)
    uint256 public constant INITIAL_PRICE = 6; // 0.0000006 USDC (6 decimals for USDC)
    uint256 public constant MIN_PURCHASE = 1000000; // Minimum 1.0 USDC
    uint256 public constant LP_TRIGGER = 30; // Create LP at 50% purchased
    
    // Fee configuration (basis points: 100 = 1%)
    uint256 public constant PLATFORM_FEE_BPS = 200; // 2% platform fee
    uint256 public constant CREATOR_FEE_BPS = 100; // 1% creator fee
    mapping(address => address[]) private coinsByCreator;
    struct Coin {
        address tokenA;
        uint256 tokenAReserve;
        uint256 usdcReserve;
        uint256 totalPurchased;
        bool lpCreated;
        address creator;
        uint256 createdAt;
        uint256 totalVolume;
        string URI;
        uint256 creatorFeesUSDC; // Accumulated fees for creator in USDC
        uint256 creatorFeesTokenA; // Accumulated fees for creator in tokenA
        uint256 virtualTokenReserve; // Virtual reserve for price calculation
        
        uint256 virtualUSDCReserve; // Virtual reserve for price calculation 
    }

    struct Transaction {
        address user;
        uint256 tokenAAmount;
        uint256 usdcAmount;
        uint256 price;
        uint256 timestamp;
        bool isBuy; // true for buy, false for sell/withdraw
    }

    struct HolderInfo {
        address holder;
        uint256 balance;
    }

    mapping(address => Coin) public coins; // tokenA address => Coin data
    mapping(address => Transaction[]) public coinTransactions; // tokenA => transactions

    // Platform fee accumulators
    uint256 public platformFeesUSDC;
    mapping(address => uint256) public platformFeesToken; // token address => accumulated fees

    address[] public allCoins;

    event CoinDeposited(
        address indexed creator,
        address indexed tokenA,
        uint256 initialUSDC,
        uint256 initialPrice
    );

    event TokensPurchased(
        address indexed user,
        address indexed tokenA,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 pricePerToken,
        uint256 platformFee,
        uint256 creatorFee
    );

    event TokensSold(
        address indexed user,
        address indexed tokenA,
        uint256 tokenAmount,
        uint256 usdcAmount,
        uint256 pricePerToken,
        uint256 platformFee,
        uint256 creatorFee
    );

    event LiquidityPoolCreated(
        address indexed tokenA,
        address pair,
        uint256 usdcAmount,
        uint256 tokenAAmount
    );

    event FeesWithdrawn(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        bool isPlatformFee
    );

    event PlatformFeesWithdrawn(
        address indexed owner,
        address indexed token,
        uint256 amount
    );

    event CreatorFeesWithdrawn(
        address indexed creator,
        address indexed tokenA,
        address feeToken,
        uint256 amount
    );

    /**
     * @notice Deposit an existing token to create a bonding curve market
     * @param tokenA Address of the ERC20 token to deposit
     * @param initialUSDC Initial USDC to start the bonding curve (must be >= 1.0 USDC)
     * @param tokenInfo URI or description of the token
     */
    function depositCoin(
        address tokenA,
        uint256 initialUSDC,
        string memory tokenInfo
    ) external nonReentrant {
        require(tokenA != address(0), "Invalid token address");
        require(coins[tokenA].tokenA == address(0), "Coin already exists");
        require(initialUSDC >= MIN_PURCHASE, "Minimum purchase: 1 USDC");

        // Validate ERC20
        require(IERC20(tokenA).totalSupply() > 0, "Invalid ERC20 token");

        // Validate ESH compatibility
        try IESH(tokenA).getHolders() returns (address[] memory holders) {
            require(holders.length > 0, "getHolders() must return at least one holder");
            require(IESH(tokenA).isReady(), "Creator must be a token holder");
            require(IERC20Metadata(tokenA).totalSupply()==1e27,"Total supply doesnt configured right");
        } catch {
            revert("Token must be an ESH-compatible token with getHolders() function");
        }

        // Pull the full supply chunk into the contract
        require(
            IERC20(tokenA).transferFrom(msg.sender, address(this), REQUIRED_TOKEN_A_AMOUNT),
            "TokenA transfer failed"
        );

        // Pull USDC from creator
        require(
            IERC20(USDC).transferFrom(msg.sender, address(this), initialUSDC),
            "USDC transfer failed"
        );

        // OPTIONAL: apply same fee model as buyTokens() for deposit
        uint256 platformFee = (initialUSDC * PLATFORM_FEE_BPS) / 10000;
        uint256 creatorFee  = (initialUSDC * CREATOR_FEE_BPS) / 10000;
        uint256 netUsdcAmount = initialUSDC - platformFee - creatorFee;

        // Seed curve as if it already has 6k USDC virtual
        uint256 vUSDC  = 6000*1e6;
        uint256 vToken = REQUIRED_TOKEN_A_AMOUNT;

        // Simulate a buy on the curve (same formula as buyTokens)
        uint256 tokenAmount = calculateBuyReturn(vToken, vUSDC, netUsdcAmount);
        require(tokenAmount > 0 && tokenAmount < REQUIRED_TOKEN_A_AMOUNT, "Invalid token amount");

        // Update virtual reserves after the buy
        uint256 newVUSDC  = vUSDC + netUsdcAmount;
        uint256 newVToken = vToken - tokenAmount;

        // Now initialize coin state
        coins[tokenA] = Coin({
            tokenA: tokenA,
            tokenAReserve: REQUIRED_TOKEN_A_AMOUNT - tokenAmount,
            usdcReserve: netUsdcAmount,
            totalPurchased: tokenAmount,
            lpCreated: false,
            creator: msg.sender,
            createdAt: block.timestamp,
            totalVolume: initialUSDC,
            URI: tokenInfo,
            creatorFeesUSDC: creatorFee,
            creatorFeesTokenA: 0,
            virtualTokenReserve: newVToken,
            virtualUSDCReserve: newVUSDC
        });


        // platform fee accrues (optional)
        platformFeesUSDC += platformFee;

        lastActivityAt[tokenA] = block.timestamp;
        coinsByCreator[msg.sender].push(tokenA);
        allCoins.push(tokenA);

        // Transfer bought tokens to creator
        require(IERC20(tokenA).transfer(msg.sender, tokenAmount), "Token transfer to creator failed");

        // Record transaction (gross in UI terms)
        uint256 price = getCurrentPrice(tokenA);
        recordTransaction(tokenA, msg.sender, initialUSDC, tokenAmount, price, true);

        emit CoinDeposited(msg.sender, tokenA, initialUSDC, price);
    }

    /**
     * @notice Buy tokens with USDC using bonding curve pricing
     * @param tokenA Address of the token to buy
     * @param usdcAmount Amount of USDC to spend
     */
    function buyTokens(
        address tokenA,
        uint256 usdcAmount,
        uint256 minTokenAReceived   // <— NEW
    ) public nonReentrant {
        require(coins[tokenA].tokenA != address(0), "Coin does not exist");
        require(!coins[tokenA].lpCreated, "LP already created, trade on Uniswap");
        require(usdcAmount >= MIN_PURCHASE, "Minimum purchase: 1.0 USDC");

        Coin storage coin = coins[tokenA];

        uint256 platformFee = (usdcAmount * PLATFORM_FEE_BPS) / 10000;
        uint256 creatorFee  = (usdcAmount * CREATOR_FEE_BPS) / 10000;
        uint256 netUsdcAmount = usdcAmount - platformFee - creatorFee;
        
        // Transfer full USDC amount from user
        require(IERC20(USDC).transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        
        // Calculate tokens based on NET USDC (after fees)
        uint256 tokenAmount = calculateBuyReturn(
            coin.virtualTokenReserve,
            coin.virtualUSDCReserve,
            netUsdcAmount
        );
        require(tokenAmount > 0, "Insufficient output");
        require(tokenAmount <= coin.tokenAReserve, "Insufficient liquidity");

        // --- slippage guard ---
        require(tokenAmount >= minTokenAReceived, "Slippage: tokenA out too low");
        
        // Update reserves: virtual reserves track the bonding curve state (NET amounts)
        coin.virtualUSDCReserve  += netUsdcAmount;
        coin.virtualTokenReserve -= tokenAmount;

        // Actual reserves also use NET (what's available for trading)
        coin.tokenAReserve -= tokenAmount;
        coin.usdcReserve   += netUsdcAmount;
        coin.totalPurchased += tokenAmount;
        coin.totalVolume    += usdcAmount;

        // Track fees separately - these are NOT part of the bonding curve
        platformFeesUSDC     += platformFee;
        coin.creatorFeesUSDC += creatorFee;

        require(IERC20(tokenA).transfer(msg.sender, tokenAmount), "Token transfer failed");

        uint256 pricePerToken = (usdcAmount * 1e18) / tokenAmount;
        recordTransaction(tokenA, msg.sender, usdcAmount, tokenAmount, pricePerToken, true);

        uint256 percentagePurchased = (coin.totalPurchased * 100) / REQUIRED_TOKEN_A_AMOUNT;
        if (percentagePurchased >= LP_TRIGGER && !coin.lpCreated) {
            createLiquidityPool(tokenA);
        }
    }

    using Strings for address;

    function _toLower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 65 && c <= 90) { // 'A'..'Z'
                b[i] = bytes1(c + 32);
            }
        }
        return string(b);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }

    function _addrHexLower(address a) internal pure returns (string memory) {
        // 0x-prefixed hex, lowercased (length fixed for address)
        bytes memory s = bytes(Strings.toHexString(uint160(a), 20));
        for (uint256 i = 2; i < s.length; i++) { // skip "0x"
            uint8 c = uint8(s[i]);
            if (c >= 65 && c <= 90) s[i] = bytes1(c + 32);
        }
        return string(s);
    }

    function _coinMatches(address tokenA, string memory qLower) internal view returns (bool) {
        // address contains
        if (_contains(_addrHexLower(tokenA), qLower)) return true;

        // name / symbol (best-effort; some tokens revert)
        string memory n;
        string memory sy;
        try IERC20Metadata(tokenA).name() returns (string memory _n) { n = _n; } catch {}
        try IERC20Metadata(tokenA).symbol() returns (string memory _s) { sy = _s; } catch {}

        if (bytes(n).length > 0 && _contains(_toLower(n), qLower)) return true;
        if (bytes(sy).length > 0 && _contains(_toLower(sy), qLower)) return true;

        return false;
    }

    /**
     * @notice Sell tokens back for USDC using bonding curve pricing
     * @param tokenA Address of the token to sell
     * @param tokenAmount Amount of tokens to sell
     */
    function sellTokens(
        address tokenA,
        uint256 tokenAmount,
        uint256 minUSDCReceived     // <— NEW
    ) public nonReentrant {
        require(coins[tokenA].tokenA != address(0), "Coin does not exist");
        require(!coins[tokenA].lpCreated, "LP already created, trade on Uniswap");
        require(tokenAmount > 0, "Amount must be > 0");
        require(IERC20(tokenA).balanceOf(msg.sender) >= tokenAmount, "Insufficient token balance");

        Coin storage coin = coins[tokenA];

        uint256 balBefore = IERC20(tokenA).balanceOf(address(this));
        require(IERC20(tokenA).transferFrom(msg.sender, address(this), tokenAmount), "Token transfer failed");
        uint256 balAfter = IERC20(tokenA).balanceOf(address(this));
        uint256 actualReceived = balAfter - balBefore;
        require(actualReceived > 0, "No tokens received");

        // Calculate USDC output from bonding curve based on current virtual reserves
        uint256 usdcFromCurve = calculateSellReturn(
            coin.virtualTokenReserve,
            coin.virtualUSDCReserve,
            actualReceived
        );
        require(usdcFromCurve > 0, "Invalid output");

        // Take fees from the curve output  
        uint256 platformFee = (usdcFromCurve * PLATFORM_FEE_BPS) / 10000;
        uint256 creatorFee  = (usdcFromCurve * CREATOR_FEE_BPS) / 10000;
        uint256 usdcNet     = usdcFromCurve - platformFee - creatorFee;
        
        require(usdcFromCurve <= coin.usdcReserve, "Insufficient USDC in reserve");

        // --- slippage guard (protects user payout) ---
        require(usdcNet >= minUSDCReceived, "Slippage: USDC out too low");
        
        // Update virtual reserves: these track the bonding curve state (curve values, not user values)
        coin.virtualTokenReserve += actualReceived;
        coin.virtualUSDCReserve  -= usdcFromCurve;  // Subtract exactly what the curve calculated

        // Update actual reserves: these track what's physically in the contract
        coin.tokenAReserve += actualReceived;
        coin.usdcReserve   -= usdcFromCurve;  // Remove the full curve amount from reserve

        coin.totalPurchased = (coin.totalPurchased >= actualReceived)
            ? (coin.totalPurchased - actualReceived)
            : 0;

        coin.totalVolume += usdcFromCurve;

        // Track fees separately - these are NOT part of the bonding curve
        platformFeesUSDC     += platformFee;
        coin.creatorFeesUSDC += creatorFee;

        uint256 pricePerToken = (usdcFromCurve * 1e18) / actualReceived;
        recordTransaction(tokenA, msg.sender, usdcFromCurve, actualReceived, pricePerToken, false);

        require(IERC20(USDC).transfer(msg.sender, usdcNet), "USDC transfer failed");

        emit TokensSold(
            msg.sender,
            tokenA,
            actualReceived,
            usdcNet,
            pricePerToken,
            platformFee,
            creatorFee
        );
    }

    function searchCoinsAll(string memory query)
        public
        view
        returns (
            address[] memory tokenAs,
            Coin[] memory coinInfos,
            uint256 totalMatches
        )
    {
        string memory qLower = _toLower(query);

        // Count matches (empty query => all)
        if (bytes(query).length == 0) {
            totalMatches = allCoins.length;
        } else {
            for (uint256 i = 0; i < allCoins.length; i++) {
                if (_coinMatches(allCoins[i], qLower)) {
                    unchecked { totalMatches++; }
                }
            }
        }

        if (totalMatches == 0) {
            return (new address[](0), new Coin[](0), 0);
        }

        // Collect matches
        tokenAs = new address[](totalMatches);
        coinInfos = new Coin[](totalMatches);

        uint256 k = 0;
        if (bytes(query).length == 0) {
            for (uint256 i = 0; i < allCoins.length; i++) {
                address t = allCoins[i];
                tokenAs[k] = t;
                coinInfos[k] = coins[t];
                unchecked { k++; }
            }
        } else {
            for (uint256 i = 0; i < allCoins.length; i++) {
                address t = allCoins[i];
                if (_coinMatches(t, qLower)) {
                    tokenAs[k] = t;
                    coinInfos[k] = coins[t];
                    unchecked { k++; }
                }
            }
        }
    }


    /**
     * @notice Create Uniswap V2 liquidity pool when 30% purchased
     */
    function createLiquidityPool(address tokenA) internal {
        Coin storage coin = coins[tokenA];
        require(!coin.lpCreated, "LP already created");

        coin.lpCreated = true;

        uint256 usdcForLP   = coin.usdcReserve;
        uint256 tokenAForLP = coin.tokenAReserve;
        require(usdcForLP > 0 && tokenAForLP > 0, "No reserves for LP");

        // Virtual reserves (for curve spot price)
        uint256 virtUSDC  = coin.virtualUSDCReserve; 
        uint256 virtToken = coin.virtualTokenReserve;
        require(virtUSDC > 0 && virtToken > 0, "Invalid virtual reserves");

        // --- +35% premium ---
        uint256 baseBps      = 10_000;
        uint256 premiumBps   = 3_500;     // 35%
        uint256 multiplierBps = baseBps + premiumBps; // = 13_500

        // denom = virtUSDC * 1.35
        uint256 denom = (virtUSDC * multiplierBps) / baseBps;
        require(denom > 0, "Bad denom");

        // tokenAmount = (realUSDC * virtualToken) / (virtualUSDC * 1.35)
        uint256 amountTokenADesired =
            (usdcForLP * virtToken) / denom;

        if (amountTokenADesired > tokenAForLP) {
            amountTokenADesired = tokenAForLP;
        }
        require(amountTokenADesired > 0, "TokenA LP amount zero");

        // Approve for router
        IERC20(USDC).approve(address(ROUTER), usdcForLP);
        IERC20(tokenA).approve(address(ROUTER), tokenAForLP);

        // Add liquidity
        (uint amountUSDC, uint amountTokenA, uint liquidity) = ROUTER.addLiquidity(
            USDC,
            tokenA,
            usdcForLP,
            amountTokenADesired,
            0,
            0,
            address(this),
            block.timestamp + 300
        );

        // Uniswap LP TOKEN (cannot burn)
        address pair = FACTORY.getPair(USDC, tokenA);
        require(pair != address(0), "pair");

        // LP TOKENS: must be sent to dead (cannot burn via totalSupply)
        uint256 lpBal = IERC20(pair).balanceOf(address(this));
        if (lpBal > 0) {
            // Lock LP forever
            IERC20(pair).transfer(
                0x000000000000000000000000000000000000dEaD,
                lpBal
            );
        }

        // Update reserves to actual used values
        coin.usdcReserve   -= amountUSDC;
        coin.tokenAReserve -= amountTokenA;

        emit LiquidityPoolCreated(tokenA, pair, amountUSDC, amountTokenA);

        // ================================
        // 🔥 BURN REMAINING TOKENA
        // ================================
        uint256 remainingTokenA = IERC20(tokenA).balanceOf(address(this));
        if (remainingTokenA > 0) {
            // Burn to reduce totalSupply
            IESH(tokenA).burn(remainingTokenA);
        }
    }


    // ============ CORRECTED BONDING CURVE CALCULATIONS ============

    /**
     * @notice Calculate token return for buy (constant product formula)
     */
    function calculateBuyReturn(
        uint256 tokenReserve, 
        uint256 usdcReserve, 
        uint256 usdcAmount
    ) 
        public 
        pure 
        returns (uint256) 
    {
        if (tokenReserve == 0 || usdcReserve == 0) return 0;
        
        // Constant product formula: tokenAmount = (tokenReserve * usdcAmount) / (usdcReserve + usdcAmount)
        uint256 numerator = tokenReserve * usdcAmount;
        uint256 denominator = usdcReserve + usdcAmount;
        
        return numerator / denominator;
    }

    /**
     * @notice Calculate USDC return for sell (constant product formula)
     */
    function calculateSellReturn(
        uint256 tokenReserve, 
        uint256 usdcReserve, 
        uint256 tokenAmount
    ) 
        public 
        pure 
        returns (uint256) 
    {
        if (tokenReserve == 0 || usdcReserve == 0) return 0;
        
        // Constant product formula: usdcAmount = (usdcReserve * tokenAmount) / (tokenReserve + tokenAmount)
        uint256 numerator = usdcReserve * tokenAmount;
        uint256 denominator = tokenReserve + tokenAmount;
        
        return numerator / denominator;
    }

    /**
     * @notice Calculate token output using bonding curve
     */
    function calculateTokenOutput(address tokenA, uint256 usdcAmount) 
        public 
        view 
        returns (uint256) 
    {
        if (coins[tokenA].tokenA == address(0)) {
            // For new coin, use initial price calculation
            return (usdcAmount * 10**18) / INITIAL_PRICE;
        }

        Coin memory coin = coins[tokenA];
        return calculateBuyReturn(coin.virtualTokenReserve, coin.virtualUSDCReserve, usdcAmount);
    }

    /**
     * @notice Calculate USDC output when selling tokens
     */
    function calculateUSDCOutput(address tokenA, uint256 tokenAmount) 
        public 
        view 
        returns (uint256) 
    {
        Coin memory coin = coins[tokenA];
        return calculateSellReturn(coin.virtualTokenReserve, coin.virtualUSDCReserve, tokenAmount);
    }

    /**
     * @notice Get current price of token in USDC (per token)
     */
    function getCurrentPrice(address tokenA) public view returns (uint256) {
        Coin memory coin = coins[tokenA];
        if (coin.virtualTokenReserve == 0 || coin.virtualUSDCReserve == 0) return 0;
        // 24-decimals price (USDC6 * 1e18 / token1e18)
        return (coin.virtualUSDCReserve * 1e24) / coin.virtualTokenReserve;
    }


    /**
     * @notice Get price for a specific amount of tokens
     */
    function getPriceForAmount(address tokenA, uint256 tokenAmount) 
        public 
        view 
        returns (uint256 totalPrice, uint256 pricePerToken) 
    {
        Coin memory coin = coins[tokenA];
        if (coin.virtualTokenReserve == 0 || coin.virtualUSDCReserve == 0) return (0, 0);
        
        // Calculate how much USDC needed for tokenAmount
        totalPrice = calculateSellReturn(coin.virtualTokenReserve, coin.virtualUSDCReserve, tokenAmount);
        pricePerToken = (totalPrice * 10**18) / tokenAmount;
        
        return (totalPrice, pricePerToken);
    }

    // ============ FEE WITHDRAWAL FUNCTIONS ============

    /**
     * @notice Withdraw platform fees in USDC (contract owner only)
     */
    function withdrawPlatformFeesUSDC(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= platformFeesUSDC, "Insufficient platform fees");
        
        platformFeesUSDC -= amount;
        
        require(IERC20(USDC).transfer(owner(), amount), "USDC transfer failed");
        
        emit PlatformFeesWithdrawn(owner(), USDC, amount);
        emit FeesWithdrawn(owner(), USDC, amount, true);
    }

    function withdrawAllPlatformFeesUSDC() external onlyOwner nonReentrant {
        uint256 accrued = platformFeesUSDC;
        require(accrued > 0, "No platform fees to withdraw");

        uint256 bal = IERC20(USDC).balanceOf(address(this));
        require(bal > 0, "USDC balance is zero");

        // Withdraw the minimum that is actually available
        uint256 amount = accrued <= bal ? accrued : bal;

        // Effects first
        platformFeesUSDC -= amount;

        // Interaction
        require(IERC20(USDC).transfer(owner(), amount), "USDC transfer failed");

        emit PlatformFeesWithdrawn(owner(), USDC, amount);
        emit FeesWithdrawn(owner(), USDC, amount, true);
    }


    function withdrawPlatformFeesToken(address token, uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= platformFeesToken[token], "Insufficient platform token fees");
        
        platformFeesToken[token] -= amount;
        require(IERC20(token).transfer(owner(), amount), "Token transfer failed");
        
        emit PlatformFeesWithdrawn(owner(), token, amount);
        emit FeesWithdrawn(owner(), token, amount, true);
    }

    function withdrawAllPlatformFeesToken(address token) external onlyOwner nonReentrant {
        uint256 amount = platformFeesToken[token];
        require(amount > 0, "No platform token fees to withdraw");
        
        platformFeesToken[token] = 0;
        require(IERC20(token).transfer(owner(), amount), "Token transfer failed");
        
        emit PlatformFeesWithdrawn(owner(), token, amount);
        emit FeesWithdrawn(owner(), token, amount, true);
    }

    function withdrawCreatorFeesUSDC(address tokenA, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        Coin storage coin = coins[tokenA];
        require(coin.creator == msg.sender, "Only creator can withdraw fees");
        require(amount <= coin.creatorFeesUSDC, "Insufficient creator fees");
        
        coin.creatorFeesUSDC -= amount;
        require(IERC20(USDC).transfer(msg.sender, amount), "USDC transfer failed");
        
        emit CreatorFeesWithdrawn(msg.sender, tokenA, USDC, amount);
        emit FeesWithdrawn(msg.sender, USDC, amount, false);
    }

    function withdrawAllCreatorFeesUSDC(address tokenA) external nonReentrant {
        Coin storage coin = coins[tokenA];
        require(coin.creator == msg.sender, "Only creator can withdraw fees");
        
        uint256 amount = coin.creatorFeesUSDC;
        require(amount > 0, "No creator fees to withdraw");
        
        coin.creatorFeesUSDC = 0;
        require(IERC20(USDC).transfer(msg.sender, amount), "USDC transfer failed");
        
        emit CreatorFeesWithdrawn(msg.sender, tokenA, USDC, amount);
        emit FeesWithdrawn(msg.sender, USDC, amount, false);
    }

    function withdrawCreatorFeesToken(address tokenA, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        Coin storage coin = coins[tokenA];
        require(coin.creator == msg.sender, "Only creator can withdraw fees");
        require(amount <= coin.creatorFeesTokenA, "Insufficient creator token fees");
        
        coin.creatorFeesTokenA -= amount;
        require(IERC20(tokenA).transfer(msg.sender, amount), "Token transfer failed");
        
        emit CreatorFeesWithdrawn(msg.sender, tokenA, tokenA, amount);
        emit FeesWithdrawn(msg.sender, tokenA, amount, false);
    }

    function withdrawAllCreatorFeesToken(address tokenA) external nonReentrant {
        Coin storage coin = coins[tokenA];
        require(coin.creator == msg.sender, "Only creator can withdraw fees");
        
        uint256 amount = coin.creatorFeesTokenA;
        require(amount > 0, "No creator token fees to withdraw");
        
        coin.creatorFeesTokenA = 0;
        require(IERC20(tokenA).transfer(msg.sender, amount), "Token transfer failed");
        
        emit CreatorFeesWithdrawn(msg.sender, tokenA, tokenA, amount);
        emit FeesWithdrawn(msg.sender, tokenA, amount, false);
    }

    // ============ VIEW FUNCTIONS ============

    function getTokenHoldersWithBalances(address tokenA) 
        external 
        view 
        returns (address[] memory holders, uint256[] memory balances) 
    {
        require(coins[tokenA].tokenA != address(0), "Coin does not exist");
        
        IESH ieshToken = IESH(tokenA);
        address[] memory allHolders = ieshToken.getHolders();
        
        holders = allHolders;
        balances = new uint256[](allHolders.length);
        
        for (uint256 i = 0; i < allHolders.length; i++) {
            balances[i] = ieshToken.balanceOf(allHolders[i]);
        }
        
        return (holders, balances);
    }

    function getTokenHoldersInfo(address tokenA) 
        external 
        view 
        returns (HolderInfo[] memory) 
    {
        require(coins[tokenA].tokenA != address(0), "Coin does not exist");
        
        IESH ieshToken = IESH(tokenA);
        address[] memory allHolders = ieshToken.getHolders();
        
        HolderInfo[] memory holderInfo = new HolderInfo[](allHolders.length);
        
        for (uint256 i = 0; i < allHolders.length; i++) {
            holderInfo[i] = HolderInfo({
                holder: allHolders[i],
                balance: ieshToken.balanceOf(allHolders[i])
            });
        }
        
        return holderInfo;
    }

    function getTokenHolderCount(address tokenA) external view returns (uint256) {
        require(coins[tokenA].tokenA != address(0), "Coin does not exist");
        return IESH(tokenA).getHolders().length;
    }

    function getUserBalance(address user, address tokenA) external view returns (uint256) {
        return IERC20(tokenA).balanceOf(user);
    }

    function getCoinInfo(address tokenA) 
        external 
        view 
        returns (
            uint256 tokenAReserve,
            uint256 usdcReserve,
            uint256 totalPurchased,
            bool lpCreated,
            uint256 percentagePurchased,
            uint256 currentPrice,
            string memory URI,
            uint256 creatorFeesUSDC,
            uint256 creatorFeesTokenA,
            uint256 virtualTokenReserve,
            uint256 virtualUSDCReserve,
            address creator
        ) 
    {
        Coin memory coin = coins[tokenA];
        percentagePurchased = (coin.totalPurchased * 100) / REQUIRED_TOKEN_A_AMOUNT;
        currentPrice = getCurrentPrice(tokenA);

        return (
            coin.tokenAReserve,
            coin.usdcReserve,
            coin.totalPurchased,
            coin.lpCreated,
            percentagePurchased,
            currentPrice,
            coin.URI,
            coin.creatorFeesUSDC,
            coin.creatorFeesTokenA,
            coin.virtualTokenReserve,
            coin.virtualUSDCReserve,
            coin.creator
        );
    }

    function getPlatformFees() external view returns (uint256 usdcFees, address[] memory tokens, uint256[] memory tokenFees) {
        uint256 count = 0;
        for (uint256 i = 0; i < allCoins.length; i++) {
            if (platformFeesToken[allCoins[i]] > 0) {
                count++;
            }
        }

        tokens = new address[](count);
        tokenFees = new uint256[](count);
        
        uint256 index = 0;
        for (uint256 i = 0; i < allCoins.length; i++) {
            if (platformFeesToken[allCoins[i]] > 0) {
                tokens[index] = allCoins[i];
                tokenFees[index] = platformFeesToken[allCoins[i]];
                index++;
            }
        }

        return (platformFeesUSDC, tokens, tokenFees);
    }

    function getCreatorFees(address tokenA) external view returns (uint256 usdcFees, uint256 tokenFees) {
        Coin memory coin = coins[tokenA];
        return (coin.creatorFeesUSDC, coin.creatorFeesTokenA);
    }

    function getTransactionHistory(address tokenA, uint256 limit) 
        external 
        view 
        returns (Transaction[] memory) 
    {
        uint256 length = coinTransactions[tokenA].length;
        uint256 start = length > limit ? length - limit : 0;
        
        Transaction[] memory result = new Transaction[](length - start);
        for (uint256 i = start; i < length; i++) {
            result[i - start] = coinTransactions[tokenA][i];
        }
        return result;
    }

    function recordTransaction(
        address tokenA,
        address user,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 price,
        bool isBuy
    ) internal {
        coinTransactions[tokenA].push(Transaction({
            user: user,
            tokenAAmount: tokenAmount,
            usdcAmount: usdcAmount,
            price: price,
            timestamp: block.timestamp,
            isBuy: isBuy
        }));
        lastActivityAt[tokenA] = block.timestamp;
    }

    function getAllCoins() external view returns (address[] memory) {
        return allCoins;
    }

    function getCoinsCount() external view returns (uint256) {
        return allCoins.length;
    }

    function getMostRecentTXedCoinsByBatches(uint256 from, uint256 to)
        public
        view
        returns (address[] memory tokenAs, Coin[] memory coinInfos, uint256 totalActive)
    {
        uint256 n = allCoins.length;

        // First pass: count active coins (have activity timestamp > 0).
        // We treat a coin as active if lastActivityAt > 0. (deposit sets it; recordTransaction updates it.)
        for (uint256 i = 0; i < n; i++) {
            address t = allCoins[i];
            if (lastActivityAt[t] > 0) {
                unchecked { totalActive++; }
            }
        }

        // Early out: no active coins
        if (totalActive == 0 || from >= to) {
            return (new address[](0), new Coin[](0), 0);
        }

        // Clamp pagination bounds
        if (to > totalActive) to = totalActive;
        if (from > to) from = to; // empty page if out of range

        // Collect active tokens and their activity times
        address[] memory tokens = new address[](totalActive);
        uint256[] memory times = new uint256[](totalActive);

        uint256 idx = 0;
        for (uint256 i = 0; i < n; i++) {
            address t = allCoins[i];
            uint256 act = lastActivityAt[t];
            if (act > 0) {
                tokens[idx] = t;
                times[idx] = act;
                unchecked { idx++; }
            }
        }

        // Partial selection sort by times desc up to 'to' (we only need correct order up to 'to - 1')
        // This avoids full O(n log n) sort and keeps gas cheaper for typical front-end reads (view).
        uint256 upto = to; // number of leading items to order
        for (uint256 i = 0; i < upto; i++) {
            uint256 maxJ = i;
            uint256 maxT = times[i];
            for (uint256 j = i + 1; j < totalActive; j++) {
                if (times[j] > maxT) {
                    maxJ = j;
                    maxT = times[j];
                }
            }
            if (maxJ != i) {
                // swap tokens
                address tmpA = tokens[i];
                tokens[i] = tokens[maxJ];
                tokens[maxJ] = tmpA;
                // swap times
                uint256 tmpT = times[i];
                times[i] = times[maxJ];
                times[maxJ] = tmpT;
            }
        }

        // Build the requested page
        uint256 pageLen = to - from;
        tokenAs = new address[](pageLen);
        coinInfos = new Coin[](pageLen);

        for (uint256 k = 0; k < pageLen; k++) {
            address t = tokens[from + k];
            tokenAs[k] = t;
            coinInfos[k] = coins[t];
        }

        return (tokenAs, coinInfos, totalActive);
    }

    function getContractTokenBalance(address tokenA) external view returns (uint256) {
        return IERC20(tokenA).balanceOf(address(this));
    }

    function getContractUSDCBalance() external view returns (uint256) {
        return IERC20(USDC).balanceOf(address(this));
    }

    /**
     * @notice Get detailed price information for display
     */
    function getPriceInfo(address tokenA) 
        external 
        view 
        returns (
            uint256 currentPrice,
            uint256 priceForMinPurchase,
            uint256 tokensForMinPurchase,
            uint256 priceForOneToken,
            uint256 oneTokenPrice
        ) 
    {
        currentPrice = getCurrentPrice(tokenA);
        tokensForMinPurchase = calculateTokenOutput(tokenA, MIN_PURCHASE);
        priceForMinPurchase = tokensForMinPurchase > 0 ? (MIN_PURCHASE * 10**18) / tokensForMinPurchase : 0;
        oneTokenPrice = getCurrentPrice(tokenA);
        priceForOneToken = oneTokenPrice;
        
        return (
            currentPrice,
            priceForMinPurchase,
            tokensForMinPurchase,
            priceForOneToken,
            oneTokenPrice
        );
    }
    /**
    * @notice Get detailed info of all coins created by a specific user
    * @param user Address of the creator
    * @return userCoins Array of Coin structs created by the user
    */
    function getAllCoinsCreated(address user) 
        public 
        view 
        returns (Coin[] memory userCoins) 
    {
        address[] memory created = coinsByCreator[user];
        uint256 length = created.length;
        userCoins = new Coin[](length);
        for (uint256 i = 0; i < length; i++) {
            userCoins[i] = coins[created[i]];
        }
        return userCoins;
    }

    /**
    * @notice Convenience: get all coins (with full info) created by msg.sender
    */
    function getMyCoinsCreated() 
        public 
        view 
        returns (Coin[] memory userCoins) 
    {
        return getAllCoinsCreated(msg.sender);
    }

        /**
    * @notice Quote a buy with gross USDC input (before fees).
    * @dev Price impact uses NET USDC (after fees), matching buyTokens().
    * @return tokenOut           Tokens the buyer would receive
    * @return platformFee        USDC fee to platform (taken from gross)
    * @return creatorFee         USDC fee to creator (taken from gross)
    * @return usdcNet            USDC actually added to reserves (gross - fees)
    * @return pricePerTokenGross Gross price per token in USDC scaled by 1e18 (usdcIn * 1e18 / tokenOut)
    * @return enoughTokenLiquidity Whether current tokenAReserve can cover tokenOut
    */
    function getBuyQuote(address tokenA, uint256 usdcIn)
        external
        view
        returns (
            uint256 tokenOut,
            uint256 platformFee,
            uint256 creatorFee,
            uint256 usdcNet,
            uint256 pricePerTokenGross,
            bool    enoughTokenLiquidity
        )
    {
        Coin memory coin = coins[tokenA];
        if (coin.tokenA == address(0) || usdcIn == 0) {
            return (0, 0, 0, 0, 0, false);
        }

        // fees from gross
        platformFee = (usdcIn * PLATFORM_FEE_BPS) / 10000;
        creatorFee  = (usdcIn * CREATOR_FEE_BPS) / 10000;
        usdcNet     = usdcIn - platformFee - creatorFee;

        // curve output uses NET (mirrors buyTokens)
        tokenOut = calculateBuyReturn(
            coin.virtualTokenReserve,
            coin.virtualUSDCReserve,
            usdcNet
        );

        // liquidity check vs actual reserve
        enoughTokenLiquidity = (tokenOut <= coin.tokenAReserve && tokenOut > 0);

        // gross price per token for display
        pricePerTokenGross = (tokenOut > 0) ? (usdcIn * 1e18) / tokenOut : 0;
    }

    /**
    * @notice Quote a sell with token input (assumes no fee-on-transfer).
    * @dev If token charges transfer fees, actual received by the contract may be lower than tokenIn,
    *      and the real payout will be smaller. For exactness with fee-on-transfer tokens, call sellTokens
    *      (which measures actualReceived) or expose a UI warning.
    * @return usdcGross          USDC from curve before fees
    * @return platformFee        USDC fee to platform (taken from gross)
    * @return creatorFee         USDC fee to creator (taken from gross)
    * @return usdcNet            USDC paid to the seller (gross - fees)
    * @return pricePerTokenGross Gross USDC per token scaled by 1e18 (usdcGross * 1e18 / tokenIn)
    * @return enoughUSDCReserve  Whether current usdcReserve can pay usdcNet
    */
    function getSellQuote(address tokenA, uint256 tokenIn)
        external
        view
        returns (
            uint256 usdcGross,
            uint256 platformFee,
            uint256 creatorFee,
            uint256 usdcNet,
            uint256 pricePerTokenGross,
            bool    enoughUSDCReserve
        )
    {
        Coin memory coin = coins[tokenA];
        if (coin.tokenA == address(0) || tokenIn == 0) {
            return (0, 0, 0, 0, 0, false);
        }

        // curve output uses tokenIn (sellTokens adjusts for actualReceived at runtime)
        usdcGross = calculateSellReturn(
            coin.virtualTokenReserve,
            coin.virtualUSDCReserve,
            tokenIn
        );

        if (usdcGross == 0) {
            return (0, 0, 0, 0, 0, false);
        }

        // fees from gross
        platformFee = (usdcGross * PLATFORM_FEE_BPS) / 10000;
        creatorFee  = (usdcGross * CREATOR_FEE_BPS) / 10000;
        usdcNet     = usdcGross - platformFee - creatorFee;

        // reserve check vs actual reserve (sellTokens also checks this)
        enoughUSDCReserve = (usdcNet <= coin.usdcReserve);

        // gross price per token for display
        pricePerTokenGross = (tokenIn > 0) ? (usdcGross * 1e18) / tokenIn : 0;
    }

    function getUSDCAccounting()
        external
        view
        returns (
            uint256 contractUSDCBalance,
            uint256 sumReserves,
            uint256 sumCreatorFees,
            uint256 platformFees,
            int256  delta // contractUSDCBalance - (sumReserves + sumCreatorFees + platformFees)
        )
    {
        uint256 reserves = 0;
        uint256 creators = 0;

        for (uint256 i = 0; i < allCoins.length; i++) {
            Coin memory c = coins[allCoins[i]];
            reserves += c.usdcReserve;
            creators += c.creatorFeesUSDC;
        }

        uint256 bal = IERC20(USDC).balanceOf(address(this));
        uint256 totalClaimable = reserves + creators + platformFeesUSDC;

        // cast to signed for negative inspection in UIs
        int256 diff = int256(bal) - int256(totalClaimable);

        return (bal, reserves, creators, platformFeesUSDC, diff);
    }

    
}
