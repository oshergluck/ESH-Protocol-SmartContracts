pragma solidity ^0.8.25;
import "contracts/IERC20Flat.sol";
import "contracts/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "contracts/IInvoice.sol";

interface IERC20Extended {
    function decimals() external view returns (uint8);
}

interface IESH {
    function createDistribution(address paymentToken, uint256 amount) external returns (bytes32);
    function distributeMulticall(bytes32 distributionId, uint256 maxCalls) external returns (bool);
}

contract ESHStoreSales is ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    struct DistributionStatus {
        bool exists;
        bool completed;
        bool finalized;
        uint256 amountToDistribute;
        uint256 feeAmount;
    }

    mapping(bytes32 => DistributionStatus) public distributions;
    address public contractOwner;
    address public serverSigner;

    event BalanceDistributed(uint256 totalBalance);
    event WorkerGotPayed(uint256 amount,address workerAddress);
    event ClientRefunded(address client, uint256 receiptId, uint256 refundAmount);
    event DistributionStarted(bytes32 indexed distributionId, uint256 amountToDistribute, uint256 feeAmount);
    event AmountPurchasedMoreInfo(uint256 amount,string info,uint256 invoiceId);
    
    uint8 private rewardTokenDecimals;
    string public typeOfContract;
    IInvoice public invoices;

    event ProductAdded(
        string name,
        string barcode,
        uint256 price,
        uint256 quantity,
        uint256 discountPercentage,
        string description
    );

    event NewReceipt(
        uint256 receiptId,
        uint256 timestamp,
        address clientAddress,
        string productBarcode,
        uint256 amountPaid,
        string ProductDesc            
    );

    struct Product {
        string name;
        string barcode;
        uint256 price;
        uint256 quantity;
        string[] productImages;
        string productDescription;
        uint256 discountPercentage;
        string category;
    }

    struct Receipt {
        uint256 index;
        uint256 timestamp;
        address clientAddress;
        string productBarcode;
        uint256 amountPaid;
        bool isRefunded;
    }

    uint256 public total = 0;
    uint256 public Balance = 0;
    string[] public productBarcodes;
    mapping(string => Product) public products;
    mapping(uint256 => Receipt) public receipts;
    mapping(uint256 => string) public infos;
    uint256 public receiptCounter = 1;
    
    IERC20Flat public tokenContract = IERC20Flat(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20Flat public rewardToken;
    uint256 public rewardsPool;
    mapping(uint256 => uint256[]) receiptNFTs;

    constructor(
        address _ERCUltra,
        address _invoices,
        address _contractOwner
    ) {
        typeOfContract = "Sales";
        invoices = IInvoice(_invoices);
        rewardToken = IERC20Flat(_ERCUltra);
        contractOwner = _contractOwner;
        serverSigner = 0xcb93DAe6611967Ee16D67A3eE0DCfad05d578575;
        rewardsPool = 0;
        rewardTokenDecimals = IERC20Extended(_ERCUltra).decimals();
    }

    modifier onlyOwner() {
        require(msg.sender == contractOwner, "Only owner");
        _;
    }

    function setServerSigner(address _newSigner) external onlyOwner {
        serverSigner = _newSigner;
    }

    function verifyReceipt(address client, uint256 receiptId) public view returns (bool) {
        Receipt storage receipt = receipts[receiptId];
        return (receipt.clientAddress == client && receipt.index == receiptId);
    }

    function verifySpecificReceiptOfSpecificProduct(address client, uint256 receiptId, string memory productBarcode) public view returns (bool) {
        Receipt storage receipt = receipts[receiptId];
        return (receipt.clientAddress == client && receipt.index == receiptId && keccak256(abi.encodePacked(receipt.productBarcode)) == keccak256(abi.encodePacked(productBarcode)));
    }

    function payWorkerAfterFeeFromStoreBalance(address worker, uint256 amount) nonReentrant onlyOwner public returns (bool) {
        require(Balance >= amount,"not enough balance");
        require(tokenContract.transfer(0xfb311Eb413a49389a2078284B57C8BEFeF6aFF67,amount*5/100),"");
        Balance-=amount*5/100;
        require(tokenContract.transfer(worker,amount*95/100),"");
        Balance-=amount*95/100;
        emit WorkerGotPayed(amount,worker);
        return true;
    }

    function depositToRewardPool(uint256 amount) nonReentrant onlyOwner public returns(uint256) {
        require(rewardToken.transferFrom(msg.sender, address(this), amount*10**rewardTokenDecimals), "Transfer failed");
        rewardsPool += amount*10**rewardTokenDecimals;
        return rewardsPool;
    }

    function getProductPics(string memory _barcode) public view returns (string[] memory) {
        return products[_barcode].productImages;
    }

    function deposit(uint256 _amount) nonReentrant public {
        require(_amount > 0, "");
        require(tokenContract.transferFrom(msg.sender, address(this), _amount), "Failed to transfer tokens");
        Balance += _amount;
        total += _amount;
    }

    function changeOwner(address _newOwner) nonReentrant onlyOwner public returns (bool) {
        contractOwner = _newOwner;
        return true;
    }

    function refundClient(address _client, uint256 _receiptId) nonReentrant onlyOwner public {
        require(_receiptId < receiptCounter, "Invalid receipt ID");
        
        Receipt storage receipt = receipts[_receiptId];
        require(receipt.clientAddress == _client, "Client address mismatch");
        require(!receipt.isRefunded, "Receipt Already Refunded");
        
        uint256 amountToRefund = receipt.amountPaid;
        require(tokenContract.transfer(_client, amountToRefund), "Token transfer failed");

        Balance -= amountToRefund;
        receipt.isRefunded = true;
        emit ClientRefunded(_client, _receiptId, amountToRefund);
        
        uint256[] memory nftIds = receiptNFTs[_receiptId];
        for (uint256 i = 0; i < nftIds.length; i++) {
            invoices.burnNFT(nftIds[i]);
        }
        delete receiptNFTs[_receiptId];
    }

    function withdrawRewardsPool() nonReentrant onlyOwner public {
        if(rewardsPool!=0) {
            require(rewardToken.transfer(msg.sender, rewardsPool), "Reward transfer failed");
            rewardsPool=0;
        }
    }

    function getNFTsForReceipt(uint256 _receiptId) public view returns (uint256[] memory) {
        return receiptNFTs[_receiptId];
    }
 
    function distributeQuarterlyBalance(uint256 percentageToDistribute, uint256 maxCalls) nonReentrant onlyOwner public returns(bool) {
        require(percentageToDistribute <= 100, "Cannot distribute more than 100%");
        
        uint256 totalBalance = Balance;
        uint256 amountToDistribute = ((totalBalance * percentageToDistribute) / 100);
        uint256 feeAmount = amountToDistribute * 5 / 100;
        require(tokenContract.approve(address(rewardToken),amountToDistribute),"Failed To Approve");

        IESH tokenContractInstance = IESH(address(rewardToken));
        bytes32 distributionId = tokenContractInstance.createDistribution(address(tokenContract), amountToDistribute);

        distributions[distributionId] = DistributionStatus({
            exists: true,
            completed: false,
            finalized: false,
            amountToDistribute: amountToDistribute,
            feeAmount: feeAmount
        });

        emit DistributionStarted(distributionId, amountToDistribute, feeAmount);

        bool completed = tokenContractInstance.distributeMulticall(distributionId, maxCalls);

        if (completed) {
            distributions[distributionId].completed = true;
        }

        return completed;
    }

    function finalizeDistribution(bytes32 distributionId) nonReentrant onlyOwner public returns(bool) {
        require(distributions[distributionId].exists, "Distribution does not exist");
        require(distributions[distributionId].completed, "Distribution not completed");
        require(!distributions[distributionId].finalized, "Distribution already finalized");

        DistributionStatus storage dist = distributions[distributionId];

        require(tokenContract.transfer(0xfb311Eb413a49389a2078284B57C8BEFeF6aFF67, dist.feeAmount), "Failed to transfer fee");

        uint256 totalDistributed = dist.amountToDistribute + dist.feeAmount;
        Balance -= totalDistributed;

        emit BalanceDistributed(totalDistributed);

        dist.finalized = true;

        return true;
    }

    function continueDistribution(bytes32 distributionId, uint256 maxCalls) nonReentrant onlyOwner public returns(bool) {
        require(distributions[distributionId].exists, "Distribution does not exist");
        require(!distributions[distributionId].completed, "Distribution already completed");

        IESH tokenContractInstance = IESH(address(rewardToken));
        bool completed = tokenContractInstance.distributeMulticall(distributionId, maxCalls);

        if (completed) {
            distributions[distributionId].completed = true;
        }

        return completed;
    }

    function addProduct(
        string memory _name,
        string memory _barcode,
        uint256 _priceInNormalNumber,
        uint256 _quantity,
        string[] memory _productImages,
        string memory _productDescription,
        uint256 _discountPercentage,
        string memory _category
    ) nonReentrant onlyOwner public {
        require(bytes(products[_barcode].barcode).length == 0, "Product already exists");
        require(_discountPercentage<=100,"discount greater than 100%!");
        Product storage newProduct = products[_barcode];
        newProduct.name = _name;
        newProduct.barcode = _barcode;
        newProduct.price = _priceInNormalNumber;
        newProduct.quantity = _quantity;
        newProduct.productImages = _productImages;
        newProduct.productDescription = _productDescription;
        newProduct.discountPercentage = _discountPercentage;
        newProduct.category = _category;
        productBarcodes.push(_barcode);
        
        emit ProductAdded(
            _name,
            _barcode,
            _priceInNormalNumber,
            _quantity,
            _discountPercentage,
            _productDescription
        );
    }

    function getAllCategories() public view returns (string[] memory) {
        string[] memory allCategories = new string[](productBarcodes.length);
        uint256 categoryCount = 0;

        for (uint256 i = 0; i < productBarcodes.length; i++) {
            string memory category = products[productBarcodes[i]].category;
            bool isUnique = true;
            
            for (uint256 j = 0; j < categoryCount; j++) {
                if (keccak256(abi.encodePacked(allCategories[j])) == keccak256(abi.encodePacked(category))) {
                    isUnique = false;
                    break;
                }
            }
            
            if (isUnique) {
                allCategories[categoryCount] = category;
                categoryCount++;
            }
        }

        string[] memory uniqueCategories = new string[](categoryCount);
        for (uint256 i = 0; i < categoryCount; i++) {
            uniqueCategories[i] = allCategories[i];
        }

        return uniqueCategories;
    }

    function updateProductQuantity(string memory _barcode, uint256 _newQuantity) nonReentrant onlyOwner public {
        for (uint256 i = 0; i < productBarcodes.length; i++) {
            if (keccak256(abi.encodePacked(productBarcodes[i])) == keccak256(abi.encodePacked(_barcode))) {
                products[productBarcodes[i]].quantity = _newQuantity;
                break;
            }
        }
    }

    function purchaseProduct(
        string memory _productBarcode,
        uint256 _amount, 
        string memory _info, 
        string memory metadata,
        bytes calldata _signature, 
        uint256 _deadline 
    ) nonReentrant public {
        
        require(block.timestamp <= _deadline, "Signature expired");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, _productBarcode, _amount, _deadline));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(_signature);

        require(signer == serverSigner, "Not authorized: Client not registered in DB");

        Product storage product = products[_productBarcode];
        require(product.quantity >= _amount, "Out of stock");

        uint256 amountToPay = product.price*_amount;

        if (product.discountPercentage > 0) {
            amountToPay = amountToPay * (100 - product.discountPercentage) / 100;
        }

        require(tokenContract.transferFrom(msg.sender, address(this), amountToPay), "Token transfer failed");

        product.quantity-=_amount;
        uint256 newReceiptId = receiptCounter;
        receiptCounter++;
        Balance += amountToPay;
        total += amountToPay;

        Receipt memory receipt = Receipt({
            index: newReceiptId,
            timestamp: block.timestamp,
            clientAddress: msg.sender,
            productBarcode: _productBarcode,
            amountPaid: amountToPay,
            isRefunded: false
        });

        infos[newReceiptId] = string(abi.encodePacked("Amount of the product: ", Strings.toString(_amount), "\n More info: ", _info));
        receipts[newReceiptId] = receipt;

        emit NewReceipt(
            newReceiptId,
            receipt.timestamp,
            msg.sender,
            receipt.productBarcode,
            receipt.amountPaid,
            product.productDescription
        );

        emit AmountPurchasedMoreInfo(_amount,_info,newReceiptId);

        uint256 totalReward = 0;
        uint256 rewardsPoolCalc = rewardsPool;
        for (uint256 i = 0; i < _amount; i++) {
            if(rewardsPool>=500) {
                uint256 rewardToBuyer = (rewardsPool * 2) / 1000;
                totalReward += rewardToBuyer;
                rewardsPoolCalc -= rewardToBuyer;
            }
        }
        if(rewardsPool>=totalReward&&totalReward!=0) {
            require(rewardToken.transfer(msg.sender, totalReward), "Reward transfer failed");
            rewardsPool-=totalReward;
        }

        uint256[] memory nftIds = new uint256[](_amount);
        for (uint256 i = 0; i < _amount; i++) {
            uint256 nftId = invoices.mintNFT(msg.sender, metadata, _productBarcode);
            nftIds[i] = nftId;
        }
        if(rewardsPool>=totalReward&&totalReward!=0) {
            rewardToken.burnFrom(address(this),totalReward);
            rewardsPool -= totalReward;
        }
        receiptNFTs[newReceiptId] = nftIds;
    }

    function changeProductDiscount(string memory _barcode, uint256 _newDiscountPercentage) nonReentrant onlyOwner public {
        require(bytes(products[_barcode].barcode).length != 0, "not found");
        require(_newDiscountPercentage<=100,"discount greater than 100%!");
        products[_barcode].discountPercentage = _newDiscountPercentage;
    }

    function editProduct(
        string memory _barcode,
        string memory _name,
        uint256 _priceInNormalNumber,
        string[] memory _productImages,
        string memory _productDescription,
        string memory _category
    ) nonReentrant onlyOwner public {
        require(bytes(products[_barcode].name).length != 0, "");
        products[_barcode].name = _name;
        products[_barcode].price = _priceInNormalNumber;
        products[_barcode].productImages = _productImages;
        products[_barcode].productDescription = _productDescription;
        products[_barcode].category = _category;
    }

    function getAllProductsBarcodes() public view returns (string[] memory) {
        return productBarcodes;
    }

    function getAllReceipts() public view returns (Receipt[] memory) {
        Receipt[] memory allReceipts = new Receipt[](receiptCounter);
        for (uint256 i = 0; i < receiptCounter; i++) {
            allReceipts[i] = receipts[i];
        }
        return allReceipts;
    }

    function getAllReceiptsByWalletAddress(address _walletAddress) public view returns (Receipt[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < receiptCounter; i++) {
            if (receipts[i].clientAddress == _walletAddress) {
                count++;
            }
        }

        Receipt[] memory clientReceipts = new Receipt[](count);
        count = 0;

        for (uint256 i = 0; i < receiptCounter; i++) {
            if (receipts[i].clientAddress == _walletAddress) {
                clientReceipts[count] = receipts[i];
                count++;
            }
        }

        return clientReceipts;
    }
}