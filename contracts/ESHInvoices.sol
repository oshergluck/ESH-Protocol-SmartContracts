/**
* SPDX-License-Identifier: Apache 2.0
**/
pragma solidity ^0.8.25;

import "@thirdweb-dev/contracts/base/ERC721Base.sol";
import "@thirdweb-dev/contracts/extension/PrimarySale.sol";
import "@thirdweb-dev/contracts/extension/Royalty.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ESHInvoicesMinter is PrimarySale, ERC721Base, ReentrancyGuard {
    address public ERCUltraStore;
    address public contractOwner;
    
    event URISet(uint256 indexed tokenId, string tokenURI);
    event CopyRequested(bytes32 requestId, uint256 tokenId, uint256 amount);
    event CopyApproved(bytes32 requestId, uint256 tokenId, uint256 amount);

    // Optimized Index: walletAddress => productBarcode => list of TokenIDs
    mapping(address => mapping(string => uint256[])) private _ownedTokensByBarcode;
    
    bool public pauser = true;
    mapping(uint256 => uint256) public copyLimits;
    mapping(uint256 => uint256) public copiesMinted;

    mapping(uint256 => uint256[]) private _nftCopies;
    mapping(uint256 => string) private NFTsBarcodes;
    mapping(uint256 => uint256) private _copyToOriginal;
    mapping(uint256 => uint256) private _nftExpirationTimes;

    struct CopyRequest {
        uint256 tokenId;
        uint256 amount;
        string reason;
        bool approved;
    }

    mapping(bytes32 => CopyRequest) private copyRequests;

    modifier onlyStore() {
        require(msg.sender == ERCUltraStore || msg.sender == contractOwner, "Only store contract can call this");
        _;
    }

    modifier whenNotPaused() {
        require(!pauser, "Copying NFTs is currently paused");
        _;
    }

    constructor(
        string memory _StoreName,
        string memory _StoreSymbol
    ) ERC721Base(msg.sender, _StoreName, _StoreSymbol, msg.sender, 500) {
        contractOwner = msg.sender;
    }

    // --- Admin Functions ---

    function setStore(address _ERCUltraStore) public onlyOwner {
        ERCUltraStore = _ERCUltraStore;
    }

    function pauseUnPauseCopies() public onlyOwner {
        pauser = !pauser;
    }

    function setLimitCopies(uint256 tokenId, uint256 limit) public onlyOwner {
        require(_exists(tokenId), "Token does not exist");
        copyLimits[tokenId] = limit;
    }

    // --- Optimized View Functions ---

    /**
     * @dev Gas-optimized balance check. 
     * Iterates only through the tokens owned by this address for this specific barcode.
     */
    function balanceOfByBarcode(address owner, string memory productBarcode) public view returns (uint256) {
        uint256[] storage tokens = _ownedTokensByBarcode[owner][productBarcode];
        uint256 count = 0;
        uint256 len = tokens.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = tokens[i];
            // Check if token still exists and isn't expired
            if (_exists(tokenId)) {
                if (_nftExpirationTimes[tokenId] == 0 || block.timestamp < _nftExpirationTimes[tokenId]) {
                    count++;
                }
            }
        }
        return count;
    }

    /**
     * @dev Returns an array of valid (unexpired/existing) token IDs for a specific barcode.
     */
    function getTokensByBarcode(address owner, string memory productBarcode) public view returns (uint256[] memory) {
        uint256[] storage tokens = _ownedTokensByBarcode[owner][productBarcode];
        uint256 validCount = balanceOfByBarcode(owner, productBarcode);
        
        uint256[] memory validTokens = new uint256[](validCount);
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 tokenId = tokens[i];
            if (_exists(tokenId)) {
                if (_nftExpirationTimes[tokenId] == 0 || block.timestamp < _nftExpirationTimes[tokenId]) {
                    validTokens[currentIndex] = tokenId;
                    currentIndex++;
                }
            }
        }
        return validTokens;
    }

    function getExpirationDate(uint256 tokenId) external view returns (uint256) {
        return _nftExpirationTimes[tokenId];
    }

    function verifyOwnershipByBarcode(address owner, string memory productBarcode) public view returns (bool) {
        return balanceOfByBarcode(owner, productBarcode) > 0;
    }

    function verifyOwnership(address owner, uint256 quantity, string memory productBarcode) public view returns (bool) {
        return balanceOfByBarcode(owner, productBarcode) >= quantity;
    }

    // --- Copy Logic ---

    function askForCopy(uint256 tokenId, uint256 amount, string memory reason) public {
        require(_exists(tokenId), "Token does not exist");
        require(ownerOf(tokenId) == msg.sender, "You don't own this token");
        
        bytes32 requestId = keccak256(abi.encodePacked(tokenId, amount, reason, block.timestamp));
        copyRequests[requestId] = CopyRequest(tokenId, amount, reason, false);
        
        emit CopyRequested(requestId, tokenId, amount);
    }

    function readReason(bytes32 requestId) public view returns (string memory) {
        CopyRequest storage request = copyRequests[requestId];
        require(request.tokenId != 0, "Request does not exist");
        return request.reason;
    }

    function mintCopy(uint256 originalTokenId, address recipient) public whenNotPaused returns (uint256) {
        require(_exists(originalTokenId), "Original token does not exist");
        require(
            ownerOf(originalTokenId) == recipient || 
            msg.sender == contractOwner || 
            msg.sender == address(this),
            "Unauthorized"
        );
        require(_copyToOriginal[originalTokenId] == 0, "Cannot copy a copy");
        require(copiesMinted[originalTokenId] < copyLimits[originalTokenId], "Limit reached");

        uint256 newItemId = nextTokenIdToMint();
        
        NFTsBarcodes[newItemId] = NFTsBarcodes[originalTokenId];
        _copyToOriginal[newItemId] = originalTokenId;
        _nftCopies[originalTokenId].push(newItemId);
        copiesMinted[originalTokenId]++;

        if (_nftExpirationTimes[originalTokenId] != 0) {
            _nftExpirationTimes[newItemId] = _nftExpirationTimes[originalTokenId];
        }

        _safeMint(recipient, 1);
        _setTokenURI(newItemId, tokenURI(originalTokenId));

        return newItemId;
    }

    function approveCopy(bytes32 requestId) public onlyOwner {
        CopyRequest storage request = copyRequests[requestId];
        require(request.tokenId != 0, "Request does not exist");
        require(!request.approved, "Already approved");

        request.approved = true;
        address recipient = ownerOf(request.tokenId);

        for (uint256 i = 0; i < request.amount; i++) {
            mintCopy(request.tokenId, recipient);
        }

        emit CopyApproved(requestId, request.tokenId, request.amount);
    }

    // --- Minting Functions ---

    function mintNFT(address recipient, string memory uri, string memory productBarcode) 
        public onlyStore nonReentrant returns (uint256) 
    {
        uint256 newItemId = nextTokenIdToMint();
        NFTsBarcodes[newItemId] = productBarcode;
        
        _safeMint(recipient, 1);
        _setTokenURI(newItemId, uri);
        
        emit URISet(newItemId, uri);
        return newItemId;
    }

    function mintNFTWithTimer(address recipient, string memory uri, uint256 duration, string memory productBarcode) 
        public onlyStore nonReentrant returns (uint256) 
    {
        require(duration > 0, "Duration must be > 0");
        uint256 newItemId = nextTokenIdToMint();
        
        NFTsBarcodes[newItemId] = productBarcode;
        _nftExpirationTimes[newItemId] = block.timestamp + duration;
        
        _safeMint(recipient, 1);
        _setTokenURI(newItemId, uri);
        
        return newItemId;
    }

    // --- Hooks (Essential for maintaining the Optimized Index) ---

    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal virtual override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = startTokenId + i;

            // Block transfers of expired tokens
            if (from != address(0) && to != address(0)) {
                if (_nftExpirationTimes[tokenId] != 0 && block.timestamp >= _nftExpirationTimes[tokenId]) {
                    revert("NFT has expired");
                }
            }

            // Sync index on transfer/burn
            if (from != address(0)) {
                _removeTokenFromIndex(from, NFTsBarcodes[tokenId], tokenId);
            }
            // Sync index on mint/transfer
            if (to != address(0)) {
                _ownedTokensByBarcode[to][NFTsBarcodes[tokenId]].push(tokenId);
            }
        }
    }

    function _removeTokenFromIndex(address owner, string memory barcode, uint256 tokenId) internal {
        uint256[] storage tokens = _ownedTokensByBarcode[owner][barcode];
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == tokenId) {
                tokens[i] = tokens[len - 1];
                tokens.pop();
                break;
            }
        }
    }

    // --- Burn Logic ---

    function burnNFT(uint256 tokenId) public onlyStore nonReentrant {
        if (_nftCopies[tokenId].length > 0) {
            _burnAllCopies(tokenId);
        }
        delete _nftExpirationTimes[tokenId];
        _burn(tokenId);
    }

    function _burnAllCopies(uint256 originalTokenId) internal {
        uint256[] memory copies = _nftCopies[originalTokenId];
        for (uint i = 0; i < copies.length; i++) {
            uint256 copyId = copies[i];
            if (_exists(copyId)) {
                _burn(copyId);
            }
        }
        delete _nftCopies[originalTokenId];
        copiesMinted[originalTokenId] = 0;
    }

    // --- Boilerplate Overrides ---

    function _canSetRoyaltyInfo() internal view virtual override(ERC721Base) returns (bool) {
        return msg.sender == contractOwner;
    }

    function _canSetPrimarySaleRecipient() internal view virtual override(PrimarySale) returns (bool) {
        return msg.sender == contractOwner;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Base) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}