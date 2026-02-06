/**
* SPDX-License-Identifier: Apache 2.0
**/
pragma solidity ^0.8.25;

import "contracts/ReentrancyGuard.sol";

interface IInvoice {
    function verifyOwnershipByBarcode(address owner, string memory productBarcode) external view returns (bool);
    function verifyOwnership(address owner, uint256 tokenId, string memory productBarcode) external view returns (bool);
    function getExpirationDate(uint256 tokenId) external view returns (uint256);
}

interface IUltimateDealStore {
    function invoices() external view returns (IInvoice);
    function verifyReceipt(address client, uint256 receiptId) external view returns (bool);
}

contract ListingUltraShop is ReentrancyGuard {
    address public owner;
    address public INVOICES_ADDRESS;
    
    mapping(uint256 => bool) private usedReceipts;
    // Track used promotion NFTs so they can't be used on multiple shops simultaneously
    mapping(uint256 => bool) private usedPromotionReceipts; 

    IUltimateDealStore public LastTryOfReviewestore;
    
    struct Store {
        string urlPath;
        address smartContractAddress;
        string picture;
        bool hidden;
        string name;          
        string description;   
        string category;       
        uint256 creationDate; 
        string contactInfo;
        uint256 expirationDate;
        uint256 promotionExpirationDate; 
    }

    struct StoreVoting {
        address votingSystemAddress;
        address ERCUltra;
        address invoicesOfStore;
        string city;
        address storeOwner;
        bool encrypted;
    }

    struct StoreReview {
        address reviewer;
        uint8 stars;
        string text;
        uint256 receiptId;
    }

    mapping(string => Store) private storeMapping;
    mapping(string => StoreVoting) private votingMapping;
    string[] private storeUrlPaths;
    
    // NEW: A separate list only for promoted stores.
    // This allows getPromotedStores to skip the 9,000 non-promoted shops.
    string[] private promotedStoreUrlPaths; 
    mapping(string => bool) private isUrlInPromotedList;

    Store public officialStore;
    mapping(string => StoreReview[]) public storeReviews;
    mapping(address => mapping(string => bool)) public hasReviewed;
    IUltimateDealStore public instance = IUltimateDealStore(officialStore.smartContractAddress);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    constructor(address _invoices) {
        owner = msg.sender;
        INVOICES_ADDRESS = _invoices;
    }

    function activatePromotion(string memory _urlPath, uint256 _promotionReceiptId) public nonReentrant {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(msg.sender == votingMapping[_urlPath].storeOwner, "Only store owner can promote");
        require(!usedPromotionReceipts[_promotionReceiptId], "This Promotion NFT is already active on a store");

        IInvoice invoiceInstance = IInvoice(INVOICES_ADDRESS);
        
        // 1. Verify this specific NFT is a 'PROS' NFT and owned by user
        bool isOwner = invoiceInstance.verifyOwnership(msg.sender, _promotionReceiptId, 'PROS');
        require(isOwner, "You do not own this Promotion NFT or Barcode is not PROS");

        // 2. Get Expiration
        uint256 nftExpiry = invoiceInstance.getExpirationDate(_promotionReceiptId);
        uint256 finalExpiry = (nftExpiry == 0) ? type(uint256).max : nftExpiry;

        require(finalExpiry > block.timestamp, "Promotion NFT has expired");

        // 3. Apply to Store
        storeMapping[_urlPath].promotionExpirationDate = finalExpiry;
        usedPromotionReceipts[_promotionReceiptId] = true;

        // 4. Add to efficient lookup list if not already there
        if (!isUrlInPromotedList[_urlPath]) {
            promotedStoreUrlPaths.push(_urlPath);
            isUrlInPromotedList[_urlPath] = true;
        }
    }
    // ----------------------------------------

    function registerStore(
        string memory _urlPath,
        address _smartContractAddress,
        string memory _picture,
        string memory _name,
        string memory _description,
        string memory _category,
        string memory _contactInfo,
        uint256 _receiptId,
        string memory _city,
        address _votingSystemAddress,
        address _ERCUltra
    ) public nonReentrant {
        require(storeMapping[_urlPath].smartContractAddress == address(0), "URL path already registered");
        require(_ERCUltra != address(0), "Must Enter ERCUltra");
        require(_votingSystemAddress != address(0), "Must Enter Voting System");
        require(_smartContractAddress != address(0), "Must Enter Store Contract");
        
        // Ownership Check
        require(checkListingOwnerShipWithId(msg.sender, _receiptId), "You don't own this Listing NFT");
        require(!usedReceipts[_receiptId], "Receipt already used");

        // Get Specific Expiration
        IInvoice invoiceInstance = IInvoice(INVOICES_ADDRESS);
        uint256 nftExpiry = invoiceInstance.getExpirationDate(_receiptId);
        uint256 finalExpirationDate = (nftExpiry == 0) ? type(uint256).max : nftExpiry;

        IUltimateDealStore storeInstance = IUltimateDealStore(_smartContractAddress);
        IInvoice invoicesOfTheStore = storeInstance.invoices();
        
        Store memory newStore = Store(
            _urlPath,
            _smartContractAddress,
            _picture,
            false,
            _name,
            _description,
            _category,
            block.timestamp,
            _contactInfo,
            finalExpirationDate,
            0 // Promotion Expiry starts at 0
        );
        
        votingMapping[_urlPath] = StoreVoting({
            votingSystemAddress: _votingSystemAddress,
            ERCUltra: _ERCUltra,
            invoicesOfStore: address(invoicesOfTheStore),
            city: _city,
            storeOwner: msg.sender,
            encrypted: false
        });

        storeMapping[_urlPath] = newStore;
        storeUrlPaths.push(_urlPath);
        usedReceipts[_receiptId] = true;
    }

    function isStoreActive(string memory _urlPath) public view returns (bool) {
        if (storeMapping[_urlPath].hidden) return false;
        return block.timestamp < storeMapping[_urlPath].expirationDate;
    }

    function isStorePromoted(string memory _urlPath) public view returns (bool) {
        if (!isStoreActive(_urlPath)) return false;
        return block.timestamp < storeMapping[_urlPath].promotionExpirationDate;
    }

    function checkListingOwnerShipWithId(address checker, uint256 Id) public view returns (bool) {
        IInvoice invoiceInstance = IInvoice(INVOICES_ADDRESS);
        return invoiceInstance.verifyOwnership(checker, Id, 'LISTESH');
    }

    // --- OPTIMIZED GET PROMOTED STORES ---
    // Now O(PromotedCount) instead of O(TotalShops * TotalNFTs)
    function getPromotedStores() public view returns (Store[] memory) {
        uint validCount = 0;
        
        // First Loop: Count valid promotions
        for (uint i = 0; i < promotedStoreUrlPaths.length; i++) {
            string memory path = promotedStoreUrlPaths[i];
            if (isStorePromoted(path)) {
                validCount++;
            }
        }

        Store[] memory promotedStores = new Store[](validCount);
        uint currentIndex = 0;
        
        // Second Loop: Populate
        for (uint i = 0; i < promotedStoreUrlPaths.length; i++) {
            string memory path = promotedStoreUrlPaths[i];
            if (isStorePromoted(path)) {
                promotedStores[currentIndex] = storeMapping[path];
                currentIndex++;
            }
        }

        return promotedStores;
    }

    // Standard Getters (Same as before)
    function getAllERCUltras() public view returns (address[] memory) {
        uint256 validCount = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (isStoreActive(storeUrlPaths[i])) validCount++;
        }
        address[] memory validERCUltras = new address[](validCount);
        uint256 currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (isStoreActive(storeUrlPaths[i])) {
                validERCUltras[currentIndex] = votingMapping[storeUrlPaths[i]].ERCUltra;
                currentIndex++;
            }
        }
        return validERCUltras;
    }

    // Pagination for scalability
    function getAllERCUltrasPaginated(uint256 offset, uint256 limit) public view returns (address[] memory) {
        uint256 total = storeUrlPaths.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        uint256 validCount = 0;
        for (uint i = offset; i < end; i++) {
             if (isStoreActive(storeUrlPaths[i])) validCount++;
        }

        address[] memory validERCUltras = new address[](validCount);
        uint256 currentIndex = 0;
        for (uint i = offset; i < end; i++) {
             if (isStoreActive(storeUrlPaths[i])) {
                validERCUltras[currentIndex] = votingMapping[storeUrlPaths[i]].ERCUltra;
                currentIndex++;
             }
        }
        return validERCUltras;
    }

    function setUnsetIfEncrypted(string memory _urlPath) public onlyOwner nonReentrant returns (bool) {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");
        votingMapping[_urlPath].encrypted = !votingMapping[_urlPath].encrypted;
        return votingMapping[_urlPath].encrypted;
    }

    function isReceiptUsed(uint256 _receiptId) external view returns (bool) {
        return usedReceipts[_receiptId];
    }

    function editStore(
        string memory _urlPath,
        string memory _picture,
        string memory _name,
        string memory _description,
        string memory _category,
        string memory _contactInfo,
        address _storeOwner,
        string memory _city
    ) public nonReentrant {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        if(msg.sender != owner) {
            require(isStoreActive(_urlPath), "Listing Expired");
        }
        require(msg.sender == votingMapping[_urlPath].storeOwner || msg.sender == owner, "Not the owner");
        
        Store storage storeToEdit = storeMapping[_urlPath];
        storeToEdit.picture = _picture;
        storeToEdit.name = _name;
        storeToEdit.description = _description;
        storeToEdit.category = _category;
        storeToEdit.contactInfo = _contactInfo;
        
        votingMapping[_urlPath].city = _city;
        votingMapping[_urlPath].storeOwner = _storeOwner;
    }

    function editOfficialStore(
        string memory _urlPath,
        address _smartContractAddress,
        string memory _picture,
        string memory _name,
        string memory _description,
        string memory _category,
        string memory _contactInfo,
        string memory _city,
        address _votingSystemAddress,
        address _ERCUltra
    ) public onlyOwner nonReentrant {
        require(officialStore.smartContractAddress != address(0), "Official store does not exist");
        require(keccak256(abi.encodePacked(officialStore.urlPath)) == keccak256(abi.encodePacked(_urlPath)), "URL path does not match official store");
        
        IUltimateDealStore storeInstance = IUltimateDealStore(_smartContractAddress);
        IInvoice invoicesOfTheStore = storeInstance.invoices();
        
        officialStore.smartContractAddress = _smartContractAddress;
        officialStore.picture = _picture;
        officialStore.name = _name;
        officialStore.description = _description;
        officialStore.category = _category;
        officialStore.contactInfo = _contactInfo;
        officialStore.expirationDate = type(uint256).max;
        officialStore.promotionExpirationDate = type(uint256).max;

        votingMapping[_urlPath] = StoreVoting(
            _votingSystemAddress,
            _ERCUltra,
            address(invoicesOfTheStore),
            _city,
            msg.sender,
            true
        );

        storeMapping[_urlPath] = officialStore;
    }

    function hideStore(string memory _urlPath) public onlyOwner nonReentrant {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        storeMapping[_urlPath].hidden = true;
    }

    function unhideStore(string memory _urlPath) public onlyOwner nonReentrant {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        storeMapping[_urlPath].hidden = false;
    }

    function setOfficialStore(
        string memory _urlPath,
        address _smartContractAddress,
        string memory _picture,
        string memory _name,
        string memory _description,
        string memory _category,
        string memory _contactInfo,
        string memory _city,
        address _votingSystemAddress,
        address _ERCUltra
    ) public onlyOwner nonReentrant {
        require(storeMapping[_urlPath].smartContractAddress == address(0), "URL path already registered");
        IUltimateDealStore storeInstance = IUltimateDealStore(_smartContractAddress);
        IInvoice invoicesOfTheStore = storeInstance.invoices();
        
        officialStore = Store(
            _urlPath,
            _smartContractAddress,
            _picture,
            false,
            _name,
            _description,
            _category,
            block.timestamp,
            _contactInfo,
            type(uint256).max,
            type(uint256).max
        );
        
        votingMapping[_urlPath] = StoreVoting(
            _votingSystemAddress,
            _ERCUltra,
            address(invoicesOfTheStore),
            _city,
            msg.sender,
            true
        );

        storeMapping[_urlPath] = officialStore;
        storeUrlPaths.push(_urlPath);
        
        // Add official store to promoted list automatically
        if (!isUrlInPromotedList[_urlPath]) {
            promotedStoreUrlPaths.push(_urlPath);
            isUrlInPromotedList[_urlPath] = true;
        }
    }

    function getStoreVotingSystem(string memory _urlPath) public view returns (StoreVoting memory) {
        require(isStoreActive(_urlPath), "Store inactive or hidden");
        return votingMapping[_urlPath];
    }

    function getStoreAddress(string memory _urlPath) public view returns (address) {
        require(isStoreActive(_urlPath), "Store inactive or hidden");
        return storeMapping[_urlPath].smartContractAddress;
    }

    function getStoreByURLPath(string memory _urlPath) public view returns (Store memory) {
        require(isStoreActive(_urlPath), "Store inactive or hidden");
        return storeMapping[_urlPath];
    }

    function getStoreURLsByOwners(address[] memory _storeOwners) public view returns (string[] memory) {
        string[] memory storeURLs = new string[](_storeOwners.length);
        uint256 foundCount = 0;

        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!isStoreActive(storeUrlPaths[i])) continue;

            StoreVoting memory currentStore = votingMapping[storeUrlPaths[i]];
            Store memory currentStoreInstance = storeMapping[storeUrlPaths[i]];
            for (uint j = 0; j < _storeOwners.length; j++) {
                if (currentStore.storeOwner == _storeOwners[j]) {
                    storeURLs[foundCount] = currentStoreInstance.urlPath;
                    foundCount++;
                    break;
                }
            }
            if (foundCount == _storeOwners.length) break;
        }

        if (foundCount < _storeOwners.length) {
            assembly { mstore(storeURLs, foundCount) }
        }

        return storeURLs;
    }

    function getAllStores() public view returns (Store[] memory, StoreVoting[] memory) {
        uint visibleCount = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (isStoreActive(storeUrlPaths[i])) {
                visibleCount++;
            }
        }

        Store[] memory visibleStores = new Store[](visibleCount);
        StoreVoting[] memory visibleVoting = new StoreVoting[](visibleCount);
        uint currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (isStoreActive(storeUrlPaths[i])) {
                visibleStores[currentIndex] = storeMapping[storeUrlPaths[i]];
                visibleVoting[currentIndex] = votingMapping[storeUrlPaths[i]];
                currentIndex++;
            }
        }
        return (visibleStores, visibleVoting);
    }

    function getRecentStores() public view returns (Store[] memory) {
        uint recentCount = 0;
        uint256 thirtyDaysAgo = block.timestamp - 30 days;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (storeMapping[storeUrlPaths[i]].creationDate >= thirtyDaysAgo && isStoreActive(storeUrlPaths[i])) {
                recentCount++;
            }
        }

        Store[] memory recentStores = new Store[](recentCount);
        uint currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (storeMapping[storeUrlPaths[i]].creationDate >= thirtyDaysAgo && isStoreActive(storeUrlPaths[i])) {
                recentStores[currentIndex] = storeMapping[storeUrlPaths[i]];
                currentIndex++;
            }
        }

        return recentStores;
    }

    function getVisibleStoreOwners() public view returns (address[] memory) {
        uint visibleCount = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (isStoreActive(storeUrlPaths[i])) {
                visibleCount++;
            }
        }

        address[] memory visibleStoreOwners = new address[](visibleCount);
        uint currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (isStoreActive(storeUrlPaths[i])) {
                visibleStoreOwners[currentIndex] = votingMapping[storeUrlPaths[i]].storeOwner;
                currentIndex++;
            }
        }

        return visibleStoreOwners;
    }

    function changeOwner(address _newOwner) onlyOwner public returns (bool) {
        owner = _newOwner;
        return true;
    }

    function addStoreReview(string memory _urlPath, uint8 _stars, string memory _text, uint256 _receiptId) public nonReentrant {
        require(isStoreActive(_urlPath), "Store inactive or hidden");
        require(_stars >= 1 && _stars <= 5, "Stars must be between 1 and 5");
        require(!hasReviewed[msg.sender][_urlPath], "You have already reviewed this store");

        address storeAddress = storeMapping[_urlPath].smartContractAddress;
        LastTryOfReviewestore = IUltimateDealStore(storeAddress);
        require(LastTryOfReviewestore.verifyReceipt(msg.sender, _receiptId), "Invalid receipt");

        StoreReview memory newReview = StoreReview({
            reviewer: msg.sender,
            stars: _stars,
            text: _text,
            receiptId: _receiptId
        });

        storeReviews[_urlPath].push(newReview);
        hasReviewed[msg.sender][_urlPath] = true;
    }

    function getStoreReviews(string memory _urlPath) public view returns (StoreReview[] memory) {
        require(isStoreActive(_urlPath), "Store inactive or hidden");
        return storeReviews[_urlPath];
    }

    function getStoreAverageRating(string memory _urlPath) public view returns (uint8) {
        require(isStoreActive(_urlPath), "Store inactive or hidden");
        StoreReview[] memory reviews = storeReviews[_urlPath];
        if (reviews.length == 0) return 0;
        uint256 totalStars = 0;
        for (uint256 i = 0; i < reviews.length; i++) {
            totalStars += reviews[i].stars;
        }
        return uint8(totalStars / reviews.length);
    }

    function getStoreReviewCount(string memory _urlPath) public view returns (uint256) {
        require(isStoreActive(_urlPath), "Store inactive or hidden");
        return storeReviews[_urlPath].length;
    }

    function hasUserReviewedStore(address _user, string memory _urlPath) public view returns (bool) {
        return hasReviewed[_user][_urlPath];
    }

    function extendPeriodOfStore(string memory _urlPath, uint256 _receiptId) public nonReentrant {
        // 1. וולידציה בסיסית - האם החנות קיימת והאם השולח הוא הבעלים
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(msg.sender == votingMapping[_urlPath].storeOwner, "Only store owner can extend");
        require(!usedReceipts[_receiptId], "Receipt already used");

        IInvoice invoiceInstance = IInvoice(INVOICES_ADDRESS);
        bool isOwner = invoiceInstance.verifyOwnership(msg.sender, _receiptId, 'LISTESH');
        require(isOwner, "You don't own this Listing NFT or Barcode is not LISTESH");

        uint256 nftExpiry = invoiceInstance.getExpirationDate(_receiptId);
        require(nftExpiry > block.timestamp, "Listing NFT itself is expired");
        
        uint256 extensionDuration = nftExpiry - block.timestamp;
        uint256 currentExpiry = storeMapping[_urlPath].expirationDate;

        if (currentExpiry < block.timestamp) {
            storeMapping[_urlPath].expirationDate = block.timestamp + extensionDuration;
        } else {
            storeMapping[_urlPath].expirationDate = currentExpiry + extensionDuration;
        }
        usedReceipts[_receiptId] = true;
    }
}
