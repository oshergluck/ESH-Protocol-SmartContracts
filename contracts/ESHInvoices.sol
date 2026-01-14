/**
* SPDX-License-Identifier: Apache 2.0
**/
pragma solidity ^0.8.25;

import "@thirdweb-dev/contracts/base/ERC721Base.sol";
import "@thirdweb-dev/contracts/extension/PrimarySale.sol";
import "@thirdweb-dev/contracts/extension/Royalty.sol";

contract ESHInvoicesMinter is PrimarySale, Royalty, ERC721Base {
    address public ERCUltraStore;
    address public contractOwner;
    event URISet(uint256 indexed tokenId, string tokenURI);

    bool public pauser = true;  // Pauser variable
    mapping(uint256 => uint256) public copyLimits;  // Mapping from original NFT ID to its copy limit
    mapping(uint256 => uint256) public copiesMinted;  // Mapping from original NFT ID to the number of copies minted

    // Mapping from original NFT ID to an array of its copy NFT IDs
    mapping(uint256 => uint256[]) private _nftCopies;
    mapping(uint256 => string) private NFTsBarcodes;
    // Mapping from NFT ID to its original NFT ID (if it's a copy)
    mapping(uint256 => uint256) private _copyToOriginal;
    mapping(uint256 => address) private _owners;
    // Mapping for NFT expiration times
    mapping(uint256 => uint256) private _nftExpirationTimes;

    struct CopyRequest {
        uint256 tokenId;
        uint256 amount;
        string reason;
        bool approved;
    }

    // Mapping to store copy requests
    mapping(bytes32 => CopyRequest) private copyRequests;

    // New events
    event CopyRequested(bytes32 requestId, uint256 tokenId, uint256 amount);
    event CopyApproved(bytes32 requestId, uint256 tokenId, uint256 amount);

    modifier onlyStore() {
        require(msg.sender == ERCUltraStore || msg.sender == contractOwner , "Only store contract can call this");
        _;
    }

    modifier pauseCopy() {
        require(!pauser, "Copying NFTs is currently paused");
        _;
    }

    function pauseUnPauseCopies() public onlyOwner {
        pauser = !pauser;
    }

    function setLimitCopies(uint256 tokenId, uint256 limit) public onlyOwner {
        require(_exists(tokenId), "Token does not exist");
        copyLimits[tokenId] = limit;
    }

    function _canSetRoyaltyInfo()
        internal
        view
        virtual
        override(ERC721Base, Royalty)
        returns (bool)
    {
        return msg.sender == contractOwner;
    }

    function _canSetPrimarySaleRecipient()
        internal
        view
        virtual
        override
        returns (bool)
    {
        return msg.sender == contractOwner;
    }

    function verifyOwnership(address owner, uint256 tokenId, string memory productBarcode) public view returns (bool) {
        // Check if the NFT has expired
        if (_nftExpirationTimes[tokenId] != 0 && block.timestamp >= _nftExpirationTimes[tokenId]) {
            return false;
        }

        // Check if the owner holds the original NFT or one of its copies
        if (_owners[tokenId] == owner && keccak256(abi.encodePacked(NFTsBarcodes[tokenId])) == keccak256(abi.encodePacked(productBarcode))) {
            return true;
        }

        // Check if the provided tokenId is a copy and if the owner holds the original
        uint256 originalId = _copyToOriginal[tokenId];
        if (originalId != 0) {
            // Check if the original has expired
            if (_nftExpirationTimes[originalId] != 0 && block.timestamp >= _nftExpirationTimes[originalId]) {
                return false;
            }
            if (_owners[originalId] == owner && keccak256(abi.encodePacked(NFTsBarcodes[tokenId])) == keccak256(abi.encodePacked(productBarcode))) {
                return true;
            }
        }

        return false;
    }

    function getAllNFTsForToken(uint256 tokenId) public view returns (uint256[] memory) {
        uint256[] memory allNFTs = new uint256[](_nftCopies[tokenId].length + 1);
        allNFTs[0] = tokenId;
        for (uint256 i = 0; i < _nftCopies[tokenId].length; i++) {
            allNFTs[i + 1] = _nftCopies[tokenId][i];
        }
        return allNFTs;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, ERC721Base)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || 
               type(IERC2981).interfaceId == interfaceId;
    }

    constructor(
        string memory _StoreName,
        string memory _StoreSymbol
    ) ERC721Base(msg.sender, _StoreName, _StoreSymbol, msg.sender, 5) {
        contractOwner = msg.sender;
    }

    function setStore(address _ERCUltraStore) public onlyOwner {
        ERCUltraStore = _ERCUltraStore;
    }

    function mintNFT(address recipient, string memory tokenURI, string memory productBarcode) public onlyStore returns (uint256) {
        uint256 newItemId = nextTokenIdToMint();
        _safeMint(recipient, 1, "");
        NFTsBarcodes[newItemId] = productBarcode;
        _setTokenURI(newItemId, tokenURI);
        emit URISet(newItemId, tokenURI);
        _owners[newItemId] = recipient;
        return newItemId;
    }

    function mintNFTWithTimer(address recipient, string memory tokenURI, uint256 duration, string memory productBarcode) public onlyStore returns (uint256) {
        require(duration > 0, "Duration must be greater than zero");
        uint256 newItemId = nextTokenIdToMint();
        _safeMint(recipient, 1, "");
        NFTsBarcodes[newItemId] = productBarcode;
        _setTokenURI(newItemId, tokenURI);
        _owners[newItemId] = recipient;
        _nftExpirationTimes[newItemId] = block.timestamp + duration;
        return newItemId;
    }

    function askForCopy(uint256 tokenId, uint256 amount, string memory reason) public {
        require(_exists(tokenId), "Token does not exist");
        require(ownerOf(tokenId) == msg.sender, "You don't own this token");
        
        bytes32 requestId = keccak256(abi.encodePacked(tokenId, amount, reason, block.timestamp));
        copyRequests[requestId] = CopyRequest(tokenId, amount, reason, false);
        
        emit CopyRequested(requestId, tokenId, amount);
    }

    function readReason(bytes32 requestId) public onlyOwner view returns (string memory) {
        CopyRequest storage request = copyRequests[requestId];
        require(request.tokenId != 0, "Request does not exist");
        string memory a = request.reason;
        return a;
    }

    function mintCopy(uint256 originalTokenId, address recipient) public pauseCopy returns (uint256) {
        require(_exists(originalTokenId), "Original token does not exist");
        require(
            ownerOf(originalTokenId) == recipient || 
            msg.sender == contractOwner || 
            msg.sender == address(this),
            "Unauthorized minting attempt"
        );
        require(_copyToOriginal[originalTokenId] == 0, "Cannot copy a copy NFT");
        require(copiesMinted[originalTokenId] < copyLimits[originalTokenId], "Copy limit reached");

        uint256 newItemId = nextTokenIdToMint();
        NFTsBarcodes[newItemId] = NFTsBarcodes[originalTokenId];
        _safeMint(recipient, 1, "");
        _setTokenURI(newItemId, tokenURI(originalTokenId));

        _nftCopies[originalTokenId].push(newItemId);
        _copyToOriginal[newItemId] = originalTokenId;
        _owners[newItemId] = recipient;
        copiesMinted[originalTokenId]++;

        // If original has expiration, set the same for copy
        if (_nftExpirationTimes[originalTokenId] != 0) {
            _nftExpirationTimes[newItemId] = _nftExpirationTimes[originalTokenId];
        }

        return newItemId;
    }

    function approveCopy(bytes32 requestId) public onlyOwner {
        CopyRequest storage request = copyRequests[requestId];
        require(request.tokenId != 0, "Request does not exist");
        require(!request.approved, "Request already approved");

        request.approved = true;

        for (uint256 i = 0; i < request.amount; i++) {
            mintCopy(request.tokenId, ownerOf(request.tokenId));
        }

        emit CopyApproved(requestId, request.tokenId, request.amount);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public virtual override(ERC721A, IERC721) {
        _beforeTokenTransfer(from, to, tokenId);
        super.safeTransferFrom(from, to, tokenId, data);
        _owners[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual override(ERC721A, IERC721) {
        _beforeTokenTransfer(from, to, tokenId);
        super.safeTransferFrom(from, to, tokenId);
        _owners[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual override(ERC721A, IERC721) {
        _beforeTokenTransfer(from, to, tokenId);
        super.transferFrom(from, to, tokenId);
        _owners[tokenId] = to;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual {
        // Check if the NFT has expired
        if (_nftExpirationTimes[tokenId] != 0 && block.timestamp >= _nftExpirationTimes[tokenId]) {
            revert("NFT has expired");
        }
        
        // If this is an original NFT being transferred, burn all copies
        if (_nftCopies[tokenId].length > 0) {
            _burnAllCopies(tokenId);
        }
    }

    function burnNFT(uint256 tokenId) public onlyStore {
        if (_nftCopies[tokenId].length > 0) {
            _burnAllCopies(tokenId);
        } else if (_copyToOriginal[tokenId] != 0) {
            // If it's a copy, remove it from the original's copy list
            uint256 originalId = _copyToOriginal[tokenId];
            _removeFromCopies(originalId, tokenId);
        }
        delete _nftExpirationTimes[tokenId];
        delete _owners[tokenId];
        _burn(tokenId);
    }

    function _burnAllCopies(uint256 originalTokenId) internal {
        for (uint i = 0; i < _nftCopies[originalTokenId].length; i++) {
            uint256 copyId = _nftCopies[originalTokenId][i];
            if(copyId != 0) {
                _burn(copyId);
                delete _copyToOriginal[copyId];
                delete _nftExpirationTimes[copyId];
                delete _owners[copyId];
            }
        }
        delete _nftCopies[originalTokenId];
        copiesMinted[originalTokenId] = 0;
    }

    function _removeFromCopies(uint256 originalTokenId, uint256 copyTokenId) internal {
        uint256[] storage copiesArray = _nftCopies[originalTokenId];
        for (uint256 i = 0; i < copiesArray.length; i++) {
            if (copiesArray[i] == copyTokenId) {
                copiesArray[i] = copiesArray[copiesArray.length - 1];
                copiesArray.pop();
                break;
            }
        }
    }

    function verifyOwnershipByBarcode(address owner, string memory productBarcode) public view returns (bool) {
        uint256 totalSupply = nextTokenIdToMint();
        bytes32 barcodeHash = keccak256(abi.encodePacked(productBarcode));

        for (uint256 tokenId = 0; tokenId < totalSupply; tokenId++) {
            // Check if the NFT exists
            if (_exists(tokenId)) {
                // Check if the barcode matches
                if (keccak256(abi.encodePacked(NFTsBarcodes[tokenId])) == barcodeHash) {
                    // Check if the NFT has expired
                    if (_nftExpirationTimes[tokenId] != 0 && block.timestamp >= _nftExpirationTimes[tokenId]) {
                        continue; // Skip expired NFTs
                    }

                    // Check if the owner holds the NFT
                    if (_owners[tokenId] == owner) {
                        return true;
                    }

                    // Check copies of the original NFT
                    uint256[] memory copies = _nftCopies[tokenId];
                    for (uint256 i = 0; i < copies.length; i++) {
                        uint256 copyId = copies[i];
                        // Skip expired copies
                        if (_nftExpirationTimes[copyId] != 0 && block.timestamp >= _nftExpirationTimes[copyId]) {
                            continue;
                        }
                        if (_owners[copyId] == owner) {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    function burnAllExpiredNFTs() public onlyOwner {
        uint256 totalSupply = nextTokenIdToMint();
        
        for (uint256 tokenId = 0; tokenId < totalSupply; tokenId++) {
            if (_exists(tokenId)) {
                // Check if the NFT has expired
                if (_nftExpirationTimes[tokenId] != 0 && block.timestamp >= _nftExpirationTimes[tokenId]) {
                    // Burn the expired NFT
                    burnNFT(tokenId);
                }
            }
        }
    }
}
