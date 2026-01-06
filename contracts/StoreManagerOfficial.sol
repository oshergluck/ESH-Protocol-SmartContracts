/**
* SPDX-License-Identifier: MIT
**/
pragma solidity ^0.8.25;

import "contracts/ReentrancyGuard.sol";


interface IInvoice {
    function verifyOwnershipByBarcode(address owner, string memory productBarcode) external view returns (bool);
    function verifyOwnership(address owner, uint256 tokenId, string memory productBarcode) external view returns (bool);
}

interface IUltimateDealStore {
    function invoices() external view returns (IInvoice);
    function verifyReceipt(address client, uint256 receiptId) external view returns (bool);
}

contract ListingUltimateDeAl is ReentrancyGuard {
    address public owner;
    mapping(uint256 => bool) private usedReceipts;
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
    Store public officialStore;
    mapping(string => StoreReview[]) public storeReviews;
    mapping(address => mapping(string => bool)) public hasReviewed;
    IUltimateDealStore public instance = IUltimateDealStore(officialStore.smartContractAddress);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

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
        require(checkListingOwnerShipWithId(msg.sender,_receiptId), "Your'e not owning Listing NFT");
        require(!usedReceipts[_receiptId], "Receipt already used for store registration");
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
            _contactInfo
        );
        
        votingMapping[_urlPath].votingSystemAddress = _votingSystemAddress;
        votingMapping[_urlPath].ERCUltra = _ERCUltra;
        votingMapping[_urlPath].invoicesOfStore = address(invoicesOfTheStore);
        votingMapping[_urlPath].city = _city;
        votingMapping[_urlPath].storeOwner = msg.sender;
        votingMapping[_urlPath].encrypted = false;

        storeMapping[_urlPath] = newStore;
        storeUrlPaths.push(_urlPath);
        usedReceipts[_receiptId] = true;
    }

    function getAllERCUltras() public view returns (address[] memory) {
        uint256 validCount = 0;
        
        // First, count the number of valid stores
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner)) {
                validCount++;
            }
        }
        
        // Create an array to store the valid ERCUltra addresses
        address[] memory validERCUltras = new address[](validCount);
        uint256 currentIndex = 0;
        
        // Populate the array with valid ERCUltra addresses
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner)) {
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
        if(msg.sender!=owner) {
            require(checkListingOwnerShip(msg.sender),"You're not owning Listing NFT");
        }
        require(msg.sender==votingMapping[_urlPath].storeOwner||msg.sender==owner,"Not the owner");
        Store storage storeToEdit = storeMapping[_urlPath];
        StoreVoting storage votingToEdit = votingMapping[_urlPath];
        storeToEdit.picture = _picture;
        storeToEdit.name = _name;
        storeToEdit.description = _description;
        storeToEdit.category = _category;
        storeToEdit.contactInfo = _contactInfo;
        votingToEdit.city = _city;
        votingToEdit.storeOwner = _storeOwner;
    }

    function checkListingOwnerShip(address checker) public view returns (bool) {
        address invoicesAddress = 0x8f0D68eA5542a09987d96926572259f03d799393;
        IInvoice invoiceInstance = IInvoice(invoicesAddress);
        if(invoiceInstance.verifyOwnershipByBarcode(checker,'LISTESH')) {
            return true;
        }
        else {
            return false;
        }
    }

    function checkListingOwnerShipWithId(address checker,uint256 Id) public view returns (bool) {
        address invoicesAddress = 0x8f0D68eA5542a09987d96926572259f03d799393;
        IInvoice invoiceInstance = IInvoice(invoicesAddress);
        if(invoiceInstance.verifyOwnership(checker,Id,'LISTESH')) {
            return true;
        }
        else {
            return false;
        }
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
        
        StoreVoting memory newVoting = StoreVoting(
            _votingSystemAddress,
            _ERCUltra,
            address(invoicesOfTheStore),
            _city,
            msg.sender,
            true
        );

        votingMapping[_urlPath] = newVoting;

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
            _contactInfo
        );
        StoreVoting memory newVoting = StoreVoting(
            _votingSystemAddress,
            _ERCUltra,
            address(invoicesOfTheStore),
            _city,
            msg.sender,
            true
        );

        votingMapping[_urlPath] = newVoting;

        storeMapping[_urlPath] = officialStore;
        storeUrlPaths.push(_urlPath);
    }

    function getStoreVotingSystem(string memory _urlPath) public view returns (StoreVoting memory) {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");
        StoreVoting storage voting = votingMapping[_urlPath];
        return voting;
    }

    function getStoreAddress(string memory _urlPath) public view returns (address) {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");
        require(checkListingOwnerShip(votingMapping[_urlPath].storeOwner),"Listing Period Is Over");
        return storeMapping[_urlPath].smartContractAddress;
    }

    function getStoreByURLPath(string memory _urlPath) public view returns (Store memory) {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");
        require(checkListingOwnerShip(votingMapping[_urlPath].storeOwner),"Listing Period Is Over");
        return storeMapping[_urlPath];
    }

    function getStoreURLsByOwners(address[] memory _storeOwners) public view returns (string[] memory) {
        // Initialize an array to store the URLs
        string[] memory storeURLs = new string[](_storeOwners.length);
        uint256 foundCount = 0;

        // Iterate through all stores
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            StoreVoting memory currentStore = votingMapping[storeUrlPaths[i]];
            Store memory currentStoreInstance = storeMapping[storeUrlPaths[i]];
            // Check if the current store's owner is in the input array
            for (uint j = 0; j < _storeOwners.length; j++) {
                if (currentStore.storeOwner == _storeOwners[j] && !currentStoreInstance.hidden) {
                    storeURLs[foundCount] = currentStoreInstance.urlPath;
                    foundCount++;
                    break;  // Move to the next store
                }
            }

            // If we've found URLs for all owners, we can stop searching
            if (foundCount == _storeOwners.length) {
                break;
            }
        }

        // If we didn't find URLs for all owners, resize the array
        if (foundCount < _storeOwners.length) {
            assembly {
                mstore(storeURLs, foundCount)
            }
        }

        return storeURLs;
    }

    function getPromotedStores() public view returns (Store[] memory) {
        uint promotedCount = 0;
        address invoicesAddress = 0x8f0D68eA5542a09987d96926572259f03d799393;
        IInvoice invoiceInstance = IInvoice(invoicesAddress);
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner) && invoiceInstance.verifyOwnershipByBarcode(votingMapping[storeUrlPaths[i]].storeOwner,'PROS')) {
                promotedCount++;
            }
        }

        Store[] memory promotedStores = new Store[](promotedCount);
        uint currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner) && invoiceInstance.verifyOwnershipByBarcode(votingMapping[storeUrlPaths[i]].storeOwner,'PROS')) {
                promotedStores[currentIndex] = storeMapping[storeUrlPaths[i]];
                currentIndex++;
            }
        }

        return promotedStores;
    }

    function getAllStores() public view returns (Store[] memory,StoreVoting[] memory) {
        uint visibleCount = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner)) {
                visibleCount++;
            }
        }

        Store[] memory visibleStores = new Store[](visibleCount);
        StoreVoting[] memory visibleVoting = new StoreVoting[](visibleCount);
        uint currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner)) {
                visibleStores[currentIndex] = storeMapping[storeUrlPaths[i]];
                visibleVoting[currentIndex] = votingMapping[storeUrlPaths[i]];
                currentIndex++;
            }
        }
        return (visibleStores,visibleVoting);
    }

    function getRecentStores() public view returns (Store[] memory) {
        uint recentCount = 0;
        uint256 thirtyDaysAgo = block.timestamp - 30 days;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (storeMapping[storeUrlPaths[i]].creationDate >= thirtyDaysAgo && !storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner)) {
                recentCount++;
            }
        }

        Store[] memory recentStores = new Store[](recentCount);
        uint currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (storeMapping[storeUrlPaths[i]].creationDate >= thirtyDaysAgo && !storeMapping[storeUrlPaths[i]].hidden && checkListingOwnerShip(votingMapping[storeUrlPaths[i]].storeOwner)) {
                recentStores[currentIndex] = storeMapping[storeUrlPaths[i]];
                currentIndex++;
            }
        }

        return recentStores;
    }

    function getVisibleStoreOwners() public view returns (address[] memory) {
        uint visibleCount = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden) {
                visibleCount++;
            }
        }

        address[] memory visibleStoreOwners = new address[](visibleCount);
        uint currentIndex = 0;
        for (uint i = 0; i < storeUrlPaths.length; i++) {
            if (!storeMapping[storeUrlPaths[i]].hidden) {
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
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");
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
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");
        return storeReviews[_urlPath];
    }

    function getStoreAverageRating(string memory _urlPath) public view returns (uint8) {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");

        StoreReview[] memory reviews = storeReviews[_urlPath];
        if (reviews.length == 0) {
            return 0;
        }

        uint256 totalStars = 0;
        for (uint256 i = 0; i < reviews.length; i++) {
            totalStars += reviews[i].stars;
        }

        return uint8(totalStars / reviews.length);
    }

    function getStoreReviewCount(string memory _urlPath) public view returns (uint256) {
        require(storeMapping[_urlPath].smartContractAddress != address(0), "Store does not exist");
        require(!storeMapping[_urlPath].hidden, "Store is hidden");
        return storeReviews[_urlPath].length;
    }

    function hasUserReviewedStore(address _user, string memory _urlPath) public view returns (bool) {
        return hasReviewed[_user][_urlPath];
    }

}