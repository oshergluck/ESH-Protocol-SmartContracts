/**
* SPDX-License-Identifier: MIT                                                                                                                                        
**/



pragma solidity ^0.8.25;
import "@openzeppelin/contracts/utils/Address.sol";
import "contracts/IERC20.sol";
import "contracts/ERCUltra.sol";
import "contracts/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@thirdweb-dev/contracts/extension/PlatformFee.sol";

contract ESH is ERCUltra, ReentrancyGuard, ContractMetadata, PlatformFee {
    address public contractOwner;
    uint256 public MAX_BATCH_SIZE = 500; // Adjust based on gas usage
    uint256 public INIT_BATCH_SIZE = 400; // Adjust based on gas usage
    address public distributor1;
    address public distributor2;
    bool public isReady = true;
    struct TokenBalance {
        uint256 balance;
        string symbol;
    }

    mapping(address => mapping(string => TokenBalance)) private holderTokenBalances;
    mapping(address => string[]) private holderTokenSymbols;

    struct Distribution {
        address[] recipients;
        uint256[] balances;
        address paymentToken;
        uint256 amount;
        uint8 decimals;
        uint256 startIndex;
        uint256 totalBalance;
        bool isCompleted;
    }
    mapping(bytes32 => uint256) public distributionInitIndex;
    mapping(bytes32 => Distribution) public distributions;
    mapping(bytes32 => bool) public distributionInitialized;
    mapping(bytes32 => bool) public distributionInitializationStarted;
    mapping(bytes32 => address[]) public distributionHolders;
    mapping(bytes32 => uint256[]) public distributionBalances;
    mapping(bytes32 => uint256) public distributionTotalBalance;

    // New state variables for voting functionality
    mapping(address => address) private _delegates;
    mapping(address => mapping(uint256 => Checkpoint)) private _checkpoints;
    mapping(address => uint256) private _numCheckpoints;
    
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    event BalanceDistributed(uint256 totalBalance);
    event DistributionCreated(bytes32 id, address indexed creator);
    event DistributionExecuted(bytes32 id, uint256 startIndex, uint256 endIndex);
    event DistributionCompleted(bytes32 id);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    constructor(
        string memory _name,
        string memory _symbol,
        address _contractOwner
    ) ERCUltra(_name, _symbol) {
        _mint(_contractOwner, 1e27);
        contractOwner = _contractOwner;
        _addHolder(_contractOwner);
    }

    modifier onlyOwner() {
        require(msg.sender == contractOwner, "Only owner");
        _;
    }

    modifier OnlyDistributor() {
        require(msg.sender == distributor1 || msg.sender == contractOwner || msg.sender == distributor2, "Only Distributor");
        _;
    }

    function changeOwner(address _newOwner) public onlyOwner nonReentrant returns (bool) {
        contractOwner = _newOwner;
        return true;
    }

    function getHolders() public view returns (address[] memory) {
        return owners;
    }

    function addBalanceToHolder(uint256 amount, address holder, string memory symbol) internal {
        if (holderTokenBalances[holder][symbol].balance == 0) {
            holderTokenSymbols[holder].push(symbol);
        }
        holderTokenBalances[holder][symbol].balance += amount;
        holderTokenBalances[holder][symbol].symbol = symbol;
    }

    function adjustBATCHSize(uint256 _newBATCHSIZE) public onlyOwner returns(uint256) {
        MAX_BATCH_SIZE = _newBATCHSIZE;
        return MAX_BATCH_SIZE;
    }

    function adjustInitBATCHSize(uint256 _newINITBATCHSIZE) public onlyOwner returns(uint256) {
        INIT_BATCH_SIZE = _newINITBATCHSIZE;
        return INIT_BATCH_SIZE;
    }

    function createDistribution(
        address paymentToken,
        uint256 amount
    ) OnlyDistributor public returns (bytes32) {
        IERC20Metadata paymentTokenInterface = IERC20Metadata(paymentToken);
        uint8 tokenDecimals = paymentTokenInterface.decimals();

        bytes32 id = keccak256(abi.encodePacked(msg.sender, paymentToken, amount, block.timestamp));
        distributions[id] = Distribution(
            new address[](0),
            new uint256[](0),
            paymentToken,
            amount,
            tokenDecimals,
            0,
            0,
            false
        );
        distributionInitialized[id] = false;
        distributionInitializationStarted[id] = false;

        emit DistributionCreated(id, msg.sender);
        return id;
    }

    function initializeDistributionStep(
        bytes32 distributionId,
        uint256 maxHolders
    ) public OnlyDistributor {
        Distribution storage dist = distributions[distributionId];

        // Already done?
        require(!distributionInitialized[distributionId], "Distribution already initialized");

        uint256 start = distributionInitIndex[distributionId];
        uint256 totalOwners = owners.length;
        require(start < totalOwners, "Initialization already complete");

        // Limit how many holders we touch in this tx
        uint256 end = start + maxHolders;
        if (end > totalOwners) {
            end = totalOwners;
        }

        for (uint256 i = start; i < end; i++) {
            address holder = owners[i];
            uint256 balance = balanceOf(holder);

            // Only include holders with non-zero balance to save gas
            if (balance > 0) {
                dist.recipients.push(holder);
                dist.balances.push(balance);
                dist.totalBalance += balance;
            }
        }

        distributionInitIndex[distributionId] = end;

        // If we've reached the end, mark as initialized
        if (end == totalOwners) {
            distributionInitialized[distributionId] = true;
            distributionTotalBalance[distributionId] = dist.totalBalance;
            distributionHolders[distributionId] = dist.recipients;
            distributionBalances[distributionId] = dist.balances;
        }
    }

    function distributeBatch(bytes32 distributionId, uint256 batchSize) OnlyDistributor public returns (bool) {
        Distribution storage dist = distributions[distributionId];
        require(!dist.isCompleted, "Distribution already completed");

        IERC20 paymentTokenContract = IERC20(dist.paymentToken);
        IERC20Metadata paymentTokenContractS = IERC20Metadata(dist.paymentToken);
        string memory symbol = paymentTokenContractS.symbol();

        uint256 endIndex = Math.min(dist.startIndex + batchSize, dist.recipients.length);

        for (uint256 i = dist.startIndex; i < endIndex; i++) {
            uint256 share = (dist.amount * dist.balances[i]);
            uint256 adjustedShare = share / dist.totalBalance;

            addBalanceToHolder(adjustedShare, dist.recipients[i], symbol);
            paymentTokenContract.approve(dist.recipients[i], adjustedShare);
            paymentTokenContract.approve(msg.sender, adjustedShare);
            paymentTokenContract.approve(address(this), adjustedShare);
            if (adjustedShare > 0) {
            require(paymentTokenContract.transferFrom(msg.sender, dist.recipients[i], adjustedShare), "Transfer failed");
        }}

        emit DistributionExecuted(distributionId, dist.startIndex, endIndex);

        dist.startIndex = endIndex;

        if (dist.startIndex == dist.recipients.length) {
            dist.isCompleted = true;
            emit DistributionCompleted(distributionId);
        }

        return dist.isCompleted;
    }

    function distributeMulticall(bytes32 distributionId, uint256 maxCalls) OnlyDistributor public returns (bool) {
        Distribution storage dist = distributions[distributionId];
        require(distributionInitialized[distributionId], "Distribution not initialized");
        require(!dist.isCompleted, "Distribution already completed");

        IERC20 paymentTokenContract = IERC20(dist.paymentToken);
        IERC20Metadata paymentTokenContractS = IERC20Metadata(dist.paymentToken);
        string memory symbol = paymentTokenContractS.symbol();
        uint256 remainingRecipients = dist.recipients.length - dist.startIndex;
        uint256 callsToMake = Math.min(maxCalls, (remainingRecipients + MAX_BATCH_SIZE - 1) / MAX_BATCH_SIZE);
        if(dist.amount>0) {
            for (uint256 i = 0; i < callsToMake && !dist.isCompleted; i++) {
                uint256 batchSize = Math.min(MAX_BATCH_SIZE, remainingRecipients);
                uint256 endIndex = dist.startIndex + batchSize;

                for (uint256 j = dist.startIndex; j < endIndex; j++) {
                    uint256 share = (dist.amount * dist.balances[j]);
                    uint256 adjustedShare = share / dist.totalBalance;

                    addBalanceToHolder(adjustedShare, dist.recipients[j], symbol);
                    paymentTokenContract.approve(dist.recipients[j], adjustedShare);
                    paymentTokenContract.approve(address(this), adjustedShare);
                    paymentTokenContract.approve(msg.sender, adjustedShare);
                    if (adjustedShare > 0) {
                    require(paymentTokenContract.transferFrom(msg.sender, dist.recipients[j], adjustedShare), "Transfer failed");
                }}

                emit DistributionExecuted(distributionId, dist.startIndex, endIndex);

                dist.startIndex = endIndex;
                remainingRecipients -= batchSize;

                if (dist.startIndex == dist.recipients.length) {
                    dist.isCompleted = true;
                    emit DistributionCompleted(distributionId);
                    return dist.isCompleted;
                }
            }
        }
        
        if(dist.amount==0) {
            dist.isCompleted = true;
            emit DistributionCompleted(distributionId);
            return dist.isCompleted;
        }

        return dist.isCompleted;
    }

    function getHolderTokenBalance(address holder, string memory symbol) public view returns (uint256) {
        return holderTokenBalances[holder][symbol].balance;
    }

    function getAllHolderTokenBalances(address holder) public view returns (TokenBalance[] memory) {
        string[] memory symbols = holderTokenSymbols[holder];
        TokenBalance[] memory balances = new TokenBalance[](symbols.length);
        
        for (uint i = 0; i < symbols.length; i++) {
            balances[i] = holderTokenBalances[holder][symbols[i]];
        }
        
        return balances;
    }

    function delegates(address account) public view returns (address) {
        return _delegates[account];
    }

    function delegate(address delegatee) public {
        _delegate(msg.sender, delegatee);
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = delegates(delegator);
        uint256 delegatorBalance = balanceOf(delegator);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);
        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint256 srcRepNum = _numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? _checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld - amount;
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint256 dstRepNum = _numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? _checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld + amount;
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(address delegatee, uint256 nCheckpoints, uint256 oldVotes, uint256 newVotes) internal {
        uint32 blockNumber = safe32(block.number, "Block number exceeds 32 bits");

        if (nCheckpoints > 0 && _checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            _checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            _checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            _numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function getVotes(address account) public view returns (uint256) {
        uint256 nCheckpoints = _numCheckpoints[account];
        return nCheckpoints > 0 ? _checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    function getPastVotes(address account, uint256 blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "ERC20Votes: block not yet mined");
        return _checkpointsLookup(account, blockNumber);
    }

    function _checkpointsLookup(address account, uint256 blockNumber) private view returns (uint256) {
        uint256 high = _numCheckpoints[account];
        uint256 low = 0;
        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_checkpoints[account][mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return high == 0 ? 0 : _checkpoints[account][high - 1].votes;
    }

    function safe32(uint256 n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    // Override _afterTokenTransfer to update voting power
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
        _moveDelegates(delegates(from), delegates(to), amount);
    }

    // Override _mint to update voting power
    function _mint(address account, uint256 amount) internal override {
        super._mint(account, amount);
        _moveDelegates(address(0), delegates(account), amount);
    }

    // Override _burn to update voting power
    function _burn(address account, uint256 amount) internal override {
        super._burn(account, amount);
        _moveDelegates(delegates(account), address(0), amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender,amount);
    }

    function burnFrom(address account, uint256 amount) public {
        require(msg.sender==account,"You're not the owner of the tokens");
        _burn(account, amount);
    }

    function setSellerStoreContract(address _ERCUltraStore) onlyOwner public {
        distributor1 = _ERCUltraStore;
    }

    function setRentingStoreContract(address _ERCUltraStore) onlyOwner public {
        distributor2 = _ERCUltraStore;
    }
}