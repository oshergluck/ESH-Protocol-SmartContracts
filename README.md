```markdown
# ESH Protocol: Smart Contract Architecture

## ⛓️ Overview

This repository contains the core **Smart Contracts** powering the **ESH Protocol**, a decentralized ecosystem merging high-level DeFi mechanics with real-world commerce (dCommerce) on the **Base Chain**.

The protocol implements a comprehensive suite of financial tools, enabling:
1.  **Smart Routing (DEX Aggregation):** Best-price execution across multiple Base Chain exchanges.
2.  **Hybrid Launchpad:** Token fundraising utilizing dynamic linear bonding curves.
3.  **Decentralized Storefronts:** On-chain inventory and NFT-based invoicing.
4.  **Yield-Bearing Governance:** Via gas-optimized dividend distribution.

---

## 🏗 Contract Modules

The architecture is composed of five interacting contract systems:

### 1. The Trading Engine (Aggregator)
* **`SwapperOfUltraShop.sol`:** * A sophisticated **DEX Aggregator** enabling best-price execution.
    * **Multi-Protocol Routing:** Scans liquidity across **Uniswap V2/V3, BaseSwap, SushiSwap, HorizonDEX, and SwapBased**.
    * **V3 Optimization:** Implements a caching mechanism for Uniswap V3 quotes to minimize RPC load.
    * **Gas Estimation:** Calculates profitability by execution cost (`estimateGas`), ensuring the true "best route".

### 2. Incubator & Fundraising (Bonding Curve)
* **`ESHFundRaiser.sol`:** * An advanced token launchpad utilizing dynamic pricing.
    * **Linear Bonding Curve:** Implements a pricing model ($P = P_{base} + \Delta P$) where price increases with demand.
    * **Protocol Owned Liquidity (POL):** Automatically converts raised funds + unsold tokens into a liquidity pair on a DEX upon campaign conclusion.
    * **Price Simulation:** Includes `previewInvestment` for accurate frontend price estimation including slippage.

### 3. DeFi & Tokenomics Core
* **`UltraShop.sol` (AMM Launchpad):** * A token launchpad enabling fair launches via automated liquidity locking.
* **`ESH.sol` (Governance & Yield):**
    * An extended ERC-20 token with snapshotting capabilities.
    * **Key Feature:** Implements a `distributeMulticall` function to handle dividend distribution to thousands of holders in batches to bypass block gas limits.

### 4. Commerce Engine (dCommerce)
* **`ESHStoreSalesDB.sol` & `ESHStoreRentalsDB.sol`:**
    * Manages on-chain inventory, pricing, and discounts.
    * Integrates with the Invoice Minter to generate proof-of-purchase.
* **`ESHInvoices.sol` (Dynamic NFTs):**
    * ERC-721 implementation serving as a digital receipt system.
    * Features time-decay logic (`mintNFTWithTimer`) for rental validation and supports encrypted metadata for privacy.

### 5. Registry
* **`StoreManagerOfficial.sol`:** * A decentralized registry for verified stores, connecting governance voting to store reputation.

---

## ⚙️ Key Technical Implementations

### Dynamic Pricing Engine (Bonding Curve)
The fundraising contract calculates token price in real-time based on the sold supply ratio:

```solidity
// From ESHFundRaiser.sol
function _calculatePriceAtSupply(
    uint256 basePrice,
    uint256 maxPrice,
    uint256 soldAmount,
    uint256 totalSupply
) internal pure returns (uint256) {
    // Linear interpolation logic
    uint256 priceRange = maxPrice - basePrice;
    uint256 priceIncrease = (soldAmount * priceRange) / totalSupply;
    return basePrice + priceIncrease;
}

```

### Smart Routing Logic (V2 + V3)

The aggregator dynamically constructs paths to find the optimal output:

```solidity
// From SwapperOfUltraShop.sol
function findBestRoute(address tokenA, address tokenB, uint256 amountIn) 
    public view returns (RouteInfo memory bestRoute) {
    // Queries multiple router interfaces (IUniswapV2, IUniswapV3Quoter)
    // Compares outputs and validates liquidity depth
    // Returns the optimal path for execution
}

```

### Auto-Liquidity Injection

The fundraising contract interacts directly with DEX routers via the Aggregator:

```solidity
// From ESHFundRaiser.sol
Liquidity.addLiquidity(
    tokenAddress,
    raisedAmountPart,
    tokenAmountPart,
    ...
);

```

---

## 🚀 Deployment

This project relies on **Thirdweb** for secure and efficient deployment, eliminating the need to expose private keys in local configuration files.

### Prerequisites

* Node.js
* Thirdweb CLI

### Deploy via CLI

To compile and deploy the contracts interactively:

```bash
npx thirdweb deploy

```

*This command will detect the contracts in the repository and open a dashboard in your browser to connect your wallet (Metamask/Coinbase) and sign the deployment transaction on Base Chain.*

---

## 📄 License

This project is licensed under the MIT License.

---

**Author:** Osher Haim Gluck

**Role:** Lead Blockchain Architect

```

```