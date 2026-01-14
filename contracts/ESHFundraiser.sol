// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.25;

import "contracts/IERC20.sol";
import "contracts/extensions/IERC20Metadata.sol";
import "contracts/ReentrancyGuard.sol";
import "contracts/INFT.sol";

interface IESHLiquid {
    function addLiquidity(
        address tokenB,
        uint256 tokenAAmount,
        uint256 tokenBAmount,
        uint256 minTokenAAmount,
        uint256 minTokenBAmount,
        uint256 deadline
    ) external returns (uint256);
}

interface IESHSHOP {
    function isClient(address _address) external view returns (bool);
}


/**
 * @title ESHFundRaising with Bonding Curve
 * @dev Complete implementation with dynamic pricing mechanism
 * @author ESH Platform
 */
contract ESHFundRaisingBondingCurve is ReentrancyGuard {

    // ========== STRUCTS ==========

    struct Campaign {
        string phoneNumber;
        address owner;
        string title;
        string description;
        uint256 target;
        uint256 endDate;
        string profilePic;
        string videoLinkFromPinata;
        string typeOfCampaign;
        bool cashedOut;
        bool isCheckedByWebsite;
        string websiteComment;
        uint256 minimum;
    }

    struct Investments {
        string[] profilePics;
        string[] names;
        address[] donators;
        uint256[] donations;
        string[] comments;
        uint256 totalAmount;
    }

    struct CampaignReward {
        IERC20 token;
        uint256 balance;              // כמה טוקנים נשארו
        uint256 initialSupply;        // סך הכל טוקנים שהופקדו בהתחלה
        uint256 soldTokens;           // כמה טוקנים כבר נמכרו
        uint256 basePricePerReward;   // מחיר בסיס (למשל 1 USDC = 1e6)
        uint256 maxPricePerReward;    // מחיר מקסימלי (למשל 3 USDC = 3e6)
        uint256 extra;                // רזרבה (7.62%)
        uint256 investsToLiquidity;   // טוקנים שהולכים לנזילות
        bool useBondingCurve;         // האם להשתמש ב-bonding curve?
    }

    // ========== EVENTS ==========

    event CampaignCreated(uint256 indexed campaignId, address indexed owner, uint256 profit);
    event DonationReceived(
        uint256 indexed campaignId, 
        address indexed donor, 
        uint256 amount, 
        uint256 tokensReceived, 
        uint256 pricePerToken
    );
    event CampaignWithdrawn(uint256 indexed campaignId, address indexed owner, uint256 amount);
    event CampaignClosed(uint256 indexed campaignId, address indexed byModerator);
    event CampaignStopped(uint256 indexed campaignId);
    event CampaignVerified(uint256 indexed campaignId);
    event ProfitWithdrawn(uint256 amountWithdrawnInNormalNumber, address indexed withdrawer);
    event CampaignRewardSetup(uint256 indexed campaignId, address tokenAddress, bool useBondingCurve);
    event CampaignRewardDeposited(uint256 indexed campaignId, uint256 amount);
    event NFTMinted(address indexed recipient, uint256 tokenId, string nftType);
    event PriceUpdate(uint256 indexed campaignId, uint256 newPrice, uint256 soldPercentage);

    // ========== STATE VARIABLES ==========

    IERC20 public tokenContract;
    uint256 public total;
    address public contractOwner;
    uint256 public discountRate = 85;
    IESHSHOP public Shop;
    uint256 public Profit = 0;
    uint256 public openCampaignCost = 0;
    
    mapping(uint256 => Campaign) public campaigns;
    uint256[] public activeCampaignIDs;
    uint256 public numberOfCampaigns = 0;
    mapping(address => bool) public moderators;
    uint256 public MIN_DONATION = 0;
    address[] public modAddresses;
    mapping(uint256 => Investments) public investments;
    mapping(uint256 => CampaignReward) public campaignRewards;
    
    IESH public campaignCreatorNFT;
    IESH public donatorNFT;
    IESHLiquid public Liquidity;

    uint256 constant DECIMAL_FACTOR = 1000;

    // ========== CONSTRUCTOR ==========

    constructor(
        address _tokenAddress,
        address _campaignCreatorNFTAddress,
        address _donatorNFTAddress,
        address _liquidityMaker,
        address _ESHShop
    ) {
        contractOwner = msg.sender;
        tokenContract = IERC20(_tokenAddress);
        MIN_DONATION = 500000; // 0.5 USDC (6 decimals)
        openCampaignCost = 199900000; // ~199.9 USDC
        modAddresses.push(msg.sender);
        moderators[msg.sender] = true;
        total = 0;
        campaignCreatorNFT = IESH(_campaignCreatorNFTAddress);
        donatorNFT = IESH(_donatorNFTAddress);
        Liquidity = IESHLiquid(_liquidityMaker);
        Shop = IESHSHOP(_ESHShop);
    }

    // ========== MODIFIERS ==========

    modifier onlyOwner() {
        require(msg.sender == contractOwner, "Only owner can call this");
        _;
    }

    modifier onlyMod() {
        require(moderators[msg.sender], "Only moderators can call this");
        _;
    }

    modifier onlyCampaignOwner(uint256 _campaignId) {
        require(msg.sender == campaigns[_campaignId].owner, "Only campaign owner");
        _;
    }

    // ========== MAIN FUNCTIONS ==========

    /**
     * @dev יצירת קמפיין חדש עם bonding curve
     * @param _useBondingCurve true למחיר דינמי, false למחיר קבוע
     * @param _basePrice מחיר התחלתי (למשל 1000000 = 1 USDC)
     * @param _maxPrice מחיר מקסימלי (למשל 3000000 = 3 USDC)
     */
    function createCampaign(
        string memory _profilePic,
        string memory _phoneNumber,
        string memory _title,
        string memory _description,
        uint256 _target,
        uint256 _endDate,
        string memory _videoLinkFromPinata,
        string memory _type,
        address _rewardTokenAddress,
        uint256 _initialRewardDeposit,
        uint256 _basePrice,
        uint256 _maxPrice,
        bool _useBondingCurve,
        string memory tokenURI,
       uint256 _minimum
    ) public nonReentrant returns (uint256) {
        uint256 effectiveCost = Shop.isClient(msg.sender) 
            ? openCampaignCost * (100 - discountRate) / 100 
            : openCampaignCost;
        
        require(tokenContract.transferFrom(msg.sender, address(this), effectiveCost), "Payment failed");
        require(_endDate > block.timestamp, "End date must be in future");
        require(_rewardTokenAddress != address(0), "Invalid reward token address");
        require(_initialRewardDeposit > 0, "Initial deposit must be > 0");
        require(_basePrice > 0, "Base price must be > 0");
        
        if (_useBondingCurve) {
            require(_maxPrice >= _basePrice, "Max price must be >= base price");
        }

        numberOfCampaigns++;
        Campaign storage campaign = campaigns[numberOfCampaigns];
        campaign.owner = msg.sender;
        campaign.profilePic = _profilePic;
        campaign.typeOfCampaign = _type;
        campaign.phoneNumber = _phoneNumber;
        campaign.title = _title;
        campaign.description = _description;
        campaign.target = _target;
        campaign.endDate = _endDate;
        campaign.videoLinkFromPinata = _videoLinkFromPinata;
        campaign.cashedOut = false;
        campaign.isCheckedByWebsite = false;
        campaign.websiteComment = "Hasn't been verified yet";
        campaign.minimum = _minimum;

        Investments storage inv = investments[numberOfCampaigns];
        inv.totalAmount = 0;

        uint256 campaignId = numberOfCampaigns;
        
        // Setup reward with bonding curve parameters
        setupCampaignReward(
            campaignId,
            _rewardTokenAddress,
            _basePrice,
            _maxPrice,
            _useBondingCurve
        );
        
        // Deposit initial rewards (108.25% of planned amount)
        depositCampaignRewards(campaignId, _initialRewardDeposit * 10825 / 10000);

        uint256 commission = effectiveCost;
        Profit += commission;
        
        emit CampaignCreated(campaignId, msg.sender, commission);
        
        uint256 tokenId = campaignCreatorNFT.mintNFT(msg.sender, tokenURI, "CAMPAIGNCREATION");
        emit NFTMinted(msg.sender, tokenId, "CampaignCreator");
        
        return campaignId;
    }

    /**
     * @dev הגדרת פרמטרי reward token
     */
    function setupCampaignReward(
        uint256 _campaignId,
        address _tokenAddress,
        uint256 _basePrice,
        uint256 _maxPrice,
        bool _useBondingCurve
    ) internal {
        require(_tokenAddress != address(0), "Invalid token address");

        CampaignReward storage reward = campaignRewards[_campaignId];
        reward.token = IERC20(_tokenAddress);
        reward.balance = 0;
        reward.initialSupply = 0; // יתעדכן ב-deposit
        reward.soldTokens = 0;
        reward.basePricePerReward = _basePrice;
        reward.maxPricePerReward = _useBondingCurve ? _maxPrice : _basePrice;
        reward.extra = 0;
        reward.investsToLiquidity = 0;
        reward.useBondingCurve = _useBondingCurve;

        emit CampaignRewardSetup(_campaignId, _tokenAddress, _useBondingCurve);
    }

    /**
     * @dev הפקדת טוקנים לקמפיין
     */
    function depositCampaignRewards(uint256 _campaignId, uint256 _amount) internal {
        CampaignReward storage reward = campaignRewards[_campaignId];
        require(address(reward.token) != address(0), "Reward token not set up");
        require(reward.token.transferFrom(msg.sender, address(this), _amount), "Failed to transfer rewards");
        
        reward.balance += _amount;
        reward.initialSupply += _amount;
        reward.extra = _amount * 762 / 10000; // 7.62%

        emit CampaignRewardDeposited(_campaignId, _amount);
    }

    /**
     * @dev עריכת פרטי קמפיין
     */
    function editCampaign(
        uint256 _campaignId,
        string memory _title,
        string memory _description,
        string memory _videoLinkFromPinata,
        string memory _profilePic
    ) public nonReentrant returns (uint256) {
        Campaign storage campaign = campaigns[_campaignId];
        require(msg.sender == campaign.owner && campaign.isCheckedByWebsite, "Not authorized or not verified");
        campaign.title = _title;
        campaign.description = _description;
        campaign.videoLinkFromPinata = _videoLinkFromPinata;
        campaign.profilePic = _profilePic;
        return _campaignId;
    }

    /**
     * @dev אימות קמפיין על ידי מנהל
     */
    function verifyCampaign(uint256 _id, string memory _websiteComment) public onlyOwner nonReentrant {
        Campaign storage campaign = campaigns[_id];
        require(
            keccak256(abi.encodePacked(campaign.videoLinkFromPinata)) != keccak256(abi.encodePacked("X")),
            "Campaign is disqualified"
        );
        campaign.isCheckedByWebsite = true;
        campaign.websiteComment = _websiteComment;
        activeCampaignIDs.push(_id);
        emit CampaignVerified(_id);
    }

    /**
     * @dev תרומה לקמפיין
     */
    function donateToCampaign(
        uint256 _id,
        string memory _comment,
        uint256 amount,
        string memory _profilePic,
        string memory _name,
        string memory tokenURI
    ) nonReentrant public {
        require(!campaigns[_id].cashedOut, "Campaign already cashed out");
        require(_id <= numberOfCampaigns && campaigns[_id].isCheckedByWebsite == true, "Campaign not verified");
        Campaign storage campaign = campaigns[_id];
        require(amount >= campaign.minimum, "Amount below minimum donation");
        require(block.timestamp < campaigns[_id].endDate, "Campaign has ended");

        require(tokenContract.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");

        // שמירת פרטי התרומה
        investments[_id].comments.push(_comment);
        investments[_id].donators.push(msg.sender);
        investments[_id].donations.push(amount);
        investments[_id].names.push(_name);
        investments[_id].profilePics.push(_profilePic);
        investments[_id].totalAmount += amount;

        // חלוקת rewards
        CampaignReward storage reward = campaignRewards[_id];
        uint256 tokensReceived = 0;
        uint256 avgPrice = 0;
        
        if (address(reward.token) != address(0) && reward.balance > reward.investsToLiquidity) {
            if (reward.useBondingCurve) {
                // Bonding curve mode
                (tokensReceived, avgPrice) = _distributeRewardsWithBondingCurve(_id, amount, msg.sender);
            } else {
                // Fixed price mode
                (tokensReceived, avgPrice) = _distributeRewardsFixedPrice(_id, amount, msg.sender);
            }
        }

        // Mint NFT
        string memory campaignBarcode = string(abi.encodePacked(uintToString(_id), "INVESTMENT"));
        uint256 tokenId = donatorNFT.mintNFT(msg.sender, tokenURI, campaignBarcode);
        
        emit DonationReceived(_id, msg.sender, amount, tokensReceived, avgPrice);
        emit NFTMinted(msg.sender, tokenId, "Donator");
        
        total += amount;
    }

    /**
     * @dev חלוקת rewards עם bonding curve
     */
    function _distributeRewardsWithBondingCurve(
        uint256 _campaignId,
        uint256 usdcAmount,
        address recipient
    ) internal returns (uint256 tokensGiven, uint256 avgPrice) {
        CampaignReward storage reward = campaignRewards[_campaignId];
        
        uint256 remainingUSDC = usdcAmount;
        uint256 currentSold = reward.soldTokens;
        uint256 totalSupply = reward.initialSupply;
        uint256 tokensAccumulated = 0;
        
        uint256 stepSize = totalSupply / 1000;
        if (stepSize == 0) stepSize = 1;
        
        uint256 maxIterations = 100;
        uint256 iterations = 0;
        
        while (remainingUSDC > 0 && 
               currentSold < totalSupply && 
               reward.balance > reward.investsToLiquidity &&
               iterations < maxIterations) {
            
            uint256 currentPrice = _calculatePriceAtSupply(
                reward.basePricePerReward,
                reward.maxPricePerReward,
                currentSold,
                totalSupply
            );
            
            uint256 tokensAtPrice = (remainingUSDC * 1e18) / currentPrice;
            
            if (tokensAtPrice > stepSize) {
                tokensAtPrice = stepSize;
            }
            
            uint256 available = reward.balance - reward.investsToLiquidity;
            if (tokensAtPrice > available) {
                tokensAtPrice = available;
            }
            
            uint256 cost = (tokensAtPrice * currentPrice) / 1e18;
            
            if (cost > remainingUSDC) {
                tokensAtPrice = (remainingUSDC * 1e18) / currentPrice;
                cost = remainingUSDC;
            }
            
            if (tokensAtPrice > 0) {
                tokensAccumulated += tokensAtPrice;
                remainingUSDC -= cost;
                currentSold += tokensAtPrice;
                
                // עדכון liquidity (7.62%)
                uint256 liquidityAmount = (tokensAtPrice * 762) / 10000;
                reward.investsToLiquidity += liquidityAmount;
            }
            
            iterations++;
            if (tokensAtPrice == 0) break;
        }
        
        if (tokensAccumulated > 0) {
            require(reward.token.transfer(recipient, tokensAccumulated), "Reward transfer failed");
            reward.balance -= tokensAccumulated;
            reward.soldTokens = currentSold;
            
            avgPrice = (usdcAmount * 1e18) / tokensAccumulated;
            
            // Emit price update event
            uint256 soldPercentage = (currentSold * 100) / totalSupply;
            emit PriceUpdate(_campaignId, getCurrentPrice(_campaignId), soldPercentage);
        }
        
        return (tokensAccumulated, avgPrice);
    }

    /**
     * @dev חלוקת rewards במחיר קבוע
     */
    function _distributeRewardsFixedPrice(
        uint256 _campaignId,
        uint256 usdcAmount,
        address recipient
    ) internal returns (uint256 tokensGiven, uint256 price) {
        CampaignReward storage reward = campaignRewards[_campaignId];
        
        uint256 actualReward = (usdcAmount * 1e18) / reward.basePricePerReward;
        uint256 available = reward.balance - reward.investsToLiquidity;
        
        if (actualReward > 0 && available > 0) {
            if (available >= actualReward) {
                require(reward.token.transfer(recipient, actualReward), "Reward transfer failed");
                reward.balance -= actualReward;
                reward.soldTokens += actualReward;
                uint256 liquidityAmount = (actualReward * 762) / 10000;
                reward.investsToLiquidity += liquidityAmount;
                return (actualReward, reward.basePricePerReward);
            } else if (available > reward.extra) {
                uint256 toGive = available - reward.extra;
                require(reward.token.transfer(recipient, toGive), "Reward transfer failed");
                reward.balance = reward.extra;
                reward.soldTokens += toGive;
                return (toGive, reward.basePricePerReward);
            }
        }
        
        return (0, reward.basePricePerReward);
    }

    /**
     * @dev משיכת כספים מקמפיין מוצלח
     */
    function withdrawCampaign(uint256 _id) public nonReentrant onlyCampaignOwner(_id) {
        Campaign storage campaign = campaigns[_id];
        require(
            campaign.target <= investments[_id].totalAmount || block.timestamp > campaign.endDate,
            "Campaign target not reached and not ended"
        );
        require(!campaign.cashedOut, "Already withdrawn");
        require(campaign.isCheckedByWebsite, "Campaign not verified");

        uint256 fee = investments[_id].totalAmount * 35 / 1000; // 3.5%
        Profit += fee * 50 / 100; // 1.75% לפלטפורמה
        uint256 market = investments[_id].totalAmount * 65 / 1000; // 6.5%
        uint256 amountToWithdraw = investments[_id].totalAmount - fee - market; // 90%
        
        if (amountToWithdraw > 0) {
            require(tokenContract.approve(address(this), amountToWithdraw), "Approval failed");
            require(tokenContract.approve(campaign.owner, amountToWithdraw), "Approval failed");
            require(tokenContract.transfer(campaign.owner, amountToWithdraw), "Transfer to owner failed");
        }

        // הסרה מרשימת קמפיינים פעילים
        for (uint256 i = 0; i < activeCampaignIDs.length; i++) {
            if (activeCampaignIDs[i] == _id) {
                activeCampaignIDs[i] = activeCampaignIDs[activeCampaignIDs.length - 1];
                activeCampaignIDs.pop();
                break;
            }
        }

        investments[_id].totalAmount = 0;
        campaign.cashedOut = true;
        campaign.websiteComment = concatenate(
            "This campaign raised ",
            uintToDecimalString(div(amountToWithdraw, 1e6)),
            " USD successfully!"
        );

        // יצירת liquidity pool והחזרת יתרת טוקנים
        CampaignReward storage reward = campaignRewards[_id];
        if (address(reward.token) != address(0) && reward.balance > 0) {
            uint256 liquidityUSDC = fee * 50 / 100 + market; // 1.75% + 6.5% = 8.25%
            
            if (liquidityUSDC > 0 && reward.investsToLiquidity > 0) {
                require(reward.token.approve(address(Liquidity), reward.investsToLiquidity), "Token approval failed");
                require(tokenContract.approve(address(Liquidity), liquidityUSDC), "USDC approval failed");
                
                uint256 minTokenAAmount = (liquidityUSDC * 95) / 100; // 5% slippage
                uint256 minTokenBAmount = (reward.investsToLiquidity * 95) / 100;
                
                Liquidity.addLiquidity(
                    address(reward.token),
                    liquidityUSDC,
                    reward.investsToLiquidity,
                    minTokenAAmount,
                    minTokenBAmount,
                    block.timestamp + 800
                );
                
                // החזרת יתרת טוקנים לבעל הקמפיין
                if (reward.balance > reward.investsToLiquidity) {
                    require(
                        reward.token.transfer(campaign.owner, reward.balance - reward.investsToLiquidity),
                        "Return tokens to owner failed"
                    );
                }
            } else {
                // אם אין liquidity, להחזיר הכל לבעל הקמפיין
                require(reward.token.transfer(campaign.owner, reward.balance), "Return all tokens failed");
            }
            reward.balance = 0;
        }

        emit CampaignWithdrawn(_id, campaign.owner, amountToWithdraw);
    }

    /**
     * @dev סגירת קמפיין על ידי מנהל (החזר כספים למשקיעים)
     */
    function closeCampaign(uint256 _id) public onlyOwner nonReentrant {
        Campaign storage campaign = campaigns[_id];
        Investments storage invest = investments[_id];
        
        if (invest.donations.length > 0) {
            returnFundsToDonators(_id);
        }

        // הסרה מרשימת קמפיינים פעילים
        for (uint256 i = 0; i < activeCampaignIDs.length; i++) {
            if (activeCampaignIDs[i] == _id) {
                activeCampaignIDs[i] = activeCampaignIDs[activeCampaignIDs.length - 1];
                activeCampaignIDs.pop();
                break;
            }
        }

        // החזרת טוקנים לבעל הקמפיין
        CampaignReward storage reward = campaignRewards[_id];
        if (address(reward.token) != address(0) && reward.balance > 0) {
            require(reward.token.transfer(campaign.owner, reward.balance), "Failed to return rewards");
            reward.balance = 0;
        }

        campaign.isCheckedByWebsite = false;
        campaign.videoLinkFromPinata = "X";
        campaign.websiteComment = "Refunded due to policy violation";
        emit CampaignClosed(_id, msg.sender);
    }

    /**
     * @dev החזר כספים לתורמים
     */
    function returnFundsToDonators(uint256 _campaignId) internal {
        Investments storage invest = investments[_campaignId];
        uint256 totalDonations = investments[_campaignId].totalAmount;

        require(tokenContract.approve(address(this), totalDonations), "Approval failed");

        for (uint256 i = 0; i < invest.donators.length; i++) {
            require(tokenContract.transfer(invest.donators[i], invest.donations[i]), "Refund transfer failed");
            totalDonations -= invest.donations[i];
        }

        investments[_campaignId].totalAmount = 0;
    }

    // ========== BONDING CURVE HELPER FUNCTIONS ==========

    /**
     * @dev חישוב מחיר נוכחי
     */
    function getCurrentPrice(uint256 _campaignId) public view returns (uint256) {
        CampaignReward storage reward = campaignRewards[_campaignId];
        
        if (!reward.useBondingCurve) {
            return reward.basePricePerReward;
        }
        
        uint256 totalSupply = reward.initialSupply;
        if (totalSupply == 0) return reward.basePricePerReward;
        
        uint256 soldTokens = reward.soldTokens;
        if (soldTokens >= totalSupply) return reward.maxPricePerReward;
        
        return _calculatePriceAtSupply(
            reward.basePricePerReward,
            reward.maxPricePerReward,
            soldTokens,
            totalSupply
        );
    }

    /**
     * @dev חישוב מחיר בנקודת supply מסוימת
     */
    function _calculatePriceAtSupply(
        uint256 basePrice,
        uint256 maxPrice,
        uint256 soldAmount,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        if (totalSupply == 0) return basePrice;
        if (soldAmount >= totalSupply) return maxPrice;
        
        uint256 priceRange = maxPrice - basePrice;
        uint256 priceIncrease = (soldAmount * priceRange) / totalSupply;
        
        return basePrice + priceIncrease;
    }

    /**
     * @dev חישוב כמה טוקנים מקבלים עבור X USDC
     */
    function calculateTokensForUSDC(
        uint256 _campaignId,
        uint256 usdcAmount
    ) public view returns (uint256 tokensToReceive, uint256 averagePrice) {
        CampaignReward storage reward = campaignRewards[_campaignId];
        
        if (!reward.useBondingCurve) {
            tokensToReceive = (usdcAmount * 1e18) / reward.basePricePerReward;
            averagePrice = reward.basePricePerReward;
            return (tokensToReceive, averagePrice);
        }
        
        uint256 remainingUSDC = usdcAmount;
        uint256 currentSold = reward.soldTokens;
        uint256 totalSupply = reward.initialSupply;
        uint256 tokensAccumulated = 0;
        
        uint256 stepSize = totalSupply / 1000;
        if (stepSize == 0) stepSize = 1;
        
        uint256 maxIterations = 1000;
        uint256 iterations = 0;
        
        while (remainingUSDC > 0 && currentSold < totalSupply && iterations < maxIterations) {
            uint256 currentPrice = _calculatePriceAtSupply(
                reward.basePricePerReward,
                reward.maxPricePerReward,
                currentSold,
                totalSupply
            );
            
            uint256 tokensAtPrice = (remainingUSDC * 1e18) / currentPrice;
            
            if (tokensAtPrice > stepSize) {
                tokensAtPrice = stepSize;
            }
            
            uint256 remainingSupply = totalSupply - currentSold;
            if (tokensAtPrice > remainingSupply) {
                tokensAtPrice = remainingSupply;
            }
            
            uint256 cost = (tokensAtPrice * currentPrice) / 1e18;
            
            if (cost > remainingUSDC) {
                tokensAtPrice = (remainingUSDC * 1e18) / currentPrice;
                cost = remainingUSDC;
            }
            
            tokensAccumulated += tokensAtPrice;
            remainingUSDC -= cost;
            currentSold += tokensAtPrice;
            iterations++;
            
            if (tokensAtPrice == 0) break;
        }
        
        tokensToReceive = tokensAccumulated;
        averagePrice = tokensAccumulated > 0 
            ? (usdcAmount * 1e18) / tokensAccumulated 
            : reward.basePricePerReward;
            
        return (tokensToReceive, averagePrice);
    }

    /**
     * @dev קבלת מידע מלא על המחיר והסטטיסטיקה של הקמפיין
     */
    function getCampaignPriceInfo(uint256 _campaignId) 
        public 
        view 
        returns (
            uint256 currentPrice,
            uint256 basePrice,
            uint256 maxPrice,
            uint256 soldTokens,
            uint256 totalSupply,
            uint256 percentageSold,
            bool useBondingCurve
        ) 
    {
        CampaignReward storage reward = campaignRewards[_campaignId];
        
        currentPrice = getCurrentPrice(_campaignId);
        basePrice = reward.basePricePerReward;
        maxPrice = reward.maxPricePerReward;
        soldTokens = reward.soldTokens;
        totalSupply = reward.initialSupply;
        percentageSold = totalSupply > 0 ? (soldTokens * 100) / totalSupply : 0;
        useBondingCurve = reward.useBondingCurve;
        
        return (
            currentPrice,
            basePrice,
            maxPrice,
            soldTokens,
            totalSupply,
            percentageSold,
            useBondingCurve
        );
    }

    /**
     * @dev סימולציה: כמה טוקנים אקבל אם אשקיע X USDC?
     */
    function previewInvestment(uint256 _campaignId, uint256 usdcAmount) 
        public 
        view 
        returns (
            uint256 tokensYouWillGet,
            uint256 averagePricePerToken,
            uint256 priceAfterPurchase
        ) 
    {
        (tokensYouWillGet, averagePricePerToken) = calculateTokensForUSDC(_campaignId, usdcAmount);
        
        CampaignReward storage reward = campaignRewards[_campaignId];
        
        if (reward.useBondingCurve) {
            uint256 newSoldAmount = reward.soldTokens + tokensYouWillGet;
            priceAfterPurchase = _calculatePriceAtSupply(
                reward.basePricePerReward,
                reward.maxPricePerReward,
                newSoldAmount,
                reward.initialSupply
            );
        } else {
            priceAfterPurchase = reward.basePricePerReward;
        }
        
        return (tokensYouWillGet, averagePricePerToken, priceAfterPurchase);
    }

    /**
     * @dev קבלת היסטוריית מחירים (תמונת מצב)
     */
    function getPriceHistory(uint256 _campaignId) 
        public 
        view 
        returns (
            uint256[] memory milestones,
            uint256[] memory prices
        ) 
    {
        CampaignReward storage reward = campaignRewards[_campaignId];
        
        if (!reward.useBondingCurve) {
            milestones = new uint256[](1);
            prices = new uint256[](1);
            milestones[0] = 0;
            prices[0] = reward.basePricePerReward;
            return (milestones, prices);
        }
        
        // יצירת 11 נקודות (0%, 10%, 20%, ..., 100%)
        milestones = new uint256[](11);
        prices = new uint256[](11);
        
        for (uint256 i = 0; i <= 10; i++) {
            uint256 percentage = i * 10;
            uint256 soldAmount = (reward.initialSupply * percentage) / 100;
            
            milestones[i] = percentage;
            prices[i] = _calculatePriceAtSupply(
                reward.basePricePerReward,
                reward.maxPricePerReward,
                soldAmount,
                reward.initialSupply
            );
        }
        
        return (milestones, prices);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @dev קבלת מחיר reward של קמפיין
     */
    function priceRewardOfCampaign(uint256 _campaignId) public view returns (uint256) {
        return getCurrentPrice(_campaignId);
    }

    /**
     * @dev קבלת שם הטוקן
     */
    function rewardName(uint256 _campaignId) public view returns (string memory) {
        CampaignReward storage reward = campaignRewards[_campaignId];
        require(address(reward.token) != address(0), "No reward token");
        IERC20Metadata tokenMeta = IERC20Metadata(address(reward.token));
        return tokenMeta.symbol();
    }

    /**
     * @dev קבלת רשימת תורמים לקמפיין
     */
    function getDonators(uint256 _id) public view returns (
        address[] memory donators,
        uint256[] memory donations,
        string[] memory comments,
        uint256 totalAmount,
        string[] memory names,
        string[] memory profilePics
    ) {
        return (
            investments[_id].donators,
            investments[_id].donations,
            investments[_id].comments,
            investments[_id].totalAmount,
            investments[_id].names,
            investments[_id].profilePics
        );
    }

    /**
     * @dev קבלת כל הקמפיינים
     */
    function getCampaigns() public view returns (Campaign[] memory) {
        Campaign[] memory allCampaigns = new Campaign[](numberOfCampaigns + 1);
        for (uint256 i = 1; i <= numberOfCampaigns; i++) {
            Campaign storage item = campaigns[i];
            allCampaigns[i] = item;
        }
        return allCampaigns;
    }

    /**
     * @dev קבלת קמפיין ספציפי
     */
    function getCampaign(uint256 _index) public view returns (Campaign memory) {
        return campaigns[_index];
    }

    /**
     * @dev קבלת עלות פתיחת קמפיין
     */
    function getPrice() public view returns (uint256) {
        return openCampaignCost;
    }

    /**
     * @dev בדיקה אם כתובת היא לקוח
     */
    function isCustomer(address customerAddress) public view returns (bool) {
        return Shop.isClient(customerAddress);
    }

    /**
     * @dev קבלת סך כל התרומות בפלטפורמה
     */
    function returnTotal() public view returns (uint256) {
        return total;
    }

    /**
     * @dev קבלת רשימת כתובות מנהלים
     */
    function getModsAddresses() public view onlyMod returns (address[] memory) {
        return modAddresses;
    }

    /**
     * @dev קבלת רשימת קמפיינים פעילים
     */
    function getActiveCampaigns() public view returns (uint256[] memory) {
        return activeCampaignIDs;
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @dev הוספת מנהל
     */
    function addModerator(address _moderator) public onlyOwner nonReentrant {
        require(_moderator != address(0), "Invalid moderator address");
        require(!moderators[_moderator], "Already a moderator");
        moderators[_moderator] = true;
        modAddresses.push(_moderator);
    }

    /**
     * @dev הסרת מנהל
     */
    function removeModerator(address _moderator) public onlyOwner nonReentrant {
        require(moderators[_moderator], "Not a moderator");
        moderators[_moderator] = false;
        for (uint256 i = 0; i < modAddresses.length; i++) {
            if (modAddresses[i] == _moderator) {
                modAddresses[i] = modAddresses[modAddresses.length - 1];
                modAddresses.pop();
                break;
            }
        }
    }

    /**
     * @dev עצירת קמפיין על ידי מנהל
     */
    function stopCampaignByMod(uint256 _campaignId) public onlyMod {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.isCheckedByWebsite, "Campaign not verified");
        campaign.isCheckedByWebsite = false;
        campaign.websiteComment = "Stopped for review by moderator";
        emit CampaignStopped(_campaignId);
    }

    /**
     * @dev הגדרת אחוז הנחה
     */
    function setDiscountRate(uint256 _percentage) public onlyOwner {
        require(_percentage <= 100, "Invalid percentage");
        discountRate = _percentage;
    }

    /**
     * @dev הגדרת עלות פתיחת קמפיין
     */
    function setCost(uint256 _cost) public onlyOwner {
        require(_cost > 0, "Cost must be > 0");
        openCampaignCost = _cost;
    }

    /**
     * @dev שינוי תרומה מינימלית
     */
    function changeMinInvestment(uint256 _min) public onlyOwner nonReentrant returns (bool) {
        require(_min > 0, "Minimum must be > 0");
        MIN_DONATION = _min;
        return true;
    }

    /**
     * @dev משיכת רווחים
     */
    function withdrawProfit() public onlyOwner nonReentrant returns (bool) {
        require(Profit > 0, "No profit to withdraw");
        uint256 amountToWithdraw = Profit;
        Profit = 0;
        require(tokenContract.transfer(msg.sender, amountToWithdraw), "Profit transfer failed");
        emit ProfitWithdrawn(amountToWithdraw / 1e6, msg.sender);
        return true;
    }

    /**
     * @dev שינוי בעלות על החוזה
     */
    function changeOwner(address _newOwner) public onlyOwner returns (bool, address) {
        require(_newOwner != address(0), "Invalid new owner address");
        require(_newOwner != contractOwner, "Already the owner");
        
        // הסרת הבעלים הנוכחי מרשימת המנהלים
        moderators[contractOwner] = false;
        for (uint256 i = 0; i < modAddresses.length; i++) {
            if (modAddresses[i] == contractOwner) {
                modAddresses[i] = modAddresses[modAddresses.length - 1];
                modAddresses.pop();
                break;
            }
        }

        // הגדרת הבעלים החדש
        contractOwner = _newOwner;
        moderators[_newOwner] = true;
        modAddresses.push(_newOwner);

        return (true, contractOwner);
    }

    /**
     * @dev עדכון כתובות NFT
     */
    function setNFTAddresses(address _investorNFT, address _campaignCreatorNFTAddress) public onlyOwner {
        require(_investorNFT != address(0) && _campaignCreatorNFTAddress != address(0), "Invalid NFT addresses");
        campaignCreatorNFT = IESH(_campaignCreatorNFTAddress);
        donatorNFT = IESH(_investorNFT);
    }

    /**
     * @dev עדכון כתובת חוזה Liquidity
     */
    function setLiquidityAddress(address _liquidityAddress) public onlyOwner {
        require(_liquidityAddress != address(0), "Invalid liquidity address");
        Liquidity = IESHLiquid(_liquidityAddress);
    }

    /**
     * @dev עדכון כתובת חוזה Shop
     */
    function setShopAddress(address _shopAddress) public onlyOwner {
        require(_shopAddress != address(0), "Invalid shop address");
        Shop = IESHSHOP(_shopAddress);
    }

    // ========== EMERGENCY FUNCTIONS ==========

    /**
     * @dev משיכת טוקנים תקועים (חירום בלבד)
     */
    function emergencyTokenWithdraw(address _token, uint256 _amount) public onlyOwner nonReentrant {
        require(_token != address(0), "Invalid token address");
        require(_amount > 0, "Amount must be > 0");
        IERC20 token = IERC20(_token);
        require(token.transfer(msg.sender, _amount), "Emergency withdrawal failed");
    }

    /**
     * @dev משיכת ETH תקוע (חירום בלבד)
     */
    function emergencyETHWithdraw() public onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = msg.sender.call{value: balance}("");
        require(success, "ETH withdrawal failed");
    }

    // ========== UTILITY FUNCTIONS ==========

    /**
     * @dev שרשור מחרוזות
     */
    function concatenate(string memory a, string memory b, string memory c) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c));
    }

    /**
     * @dev המרת uint למחרוזת
     */
    function uintToString(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    /**
     * @dev המרת uint למחרוזת עם נקודה עשרונית
     */
    function uintToDecimalString(uint256 value) internal pure returns (string memory) {
        uint256 integerPart = value / DECIMAL_FACTOR;
        uint256 fractionalPart = value % DECIMAL_FACTOR;

        string memory fractionalPartStr = uintToString(fractionalPart);
        
        // הוספת אפסים מובילים אם צריך
        while (bytes(fractionalPartStr).length < 3) {
            fractionalPartStr = string(abi.encodePacked("0", fractionalPartStr));
        }

        return string(abi.encodePacked(uintToString(integerPart), ".", fractionalPartStr));
    }

    /**
     * @dev כפל עם דיוק עשרוני
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / DECIMAL_FACTOR;
    }

    /**
     * @dev חילוק עם דיוק עשרוני
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "Division by zero");
        return (a * DECIMAL_FACTOR) / b;
    }

    // ========== FALLBACK & RECEIVE ==========

    /**
     * @dev קבלת ETH (אם נדרש)
     */
    receive() external payable {
        // Contract can receive ETH
    }

    /**
     * @dev Fallback function
     */
    fallback() external payable {
        revert("Function does not exist");
    }
}

// ========== END OF CONTRACT ==========
