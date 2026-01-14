//SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract ESH is ERC20, Ownable, ReentrancyGuard {
    using Address for address;
    // ==========================================
    // State Variables - Holders List (ERCUltra)
    // ==========================================
    address[] public owners;
    mapping(address => uint256) private ownerIndex;

    // ==========================================
    // State Variables - ESH Logic (Dist & Votes)
    // ==========================================
    uint256 public MAX_BATCH_SIZE;
    uint256 public INIT_BATCH_SIZE;
    address public distributor1;
    address public distributor2;
    bool public isReady;

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

    // Voting State
    mapping(address => address) private _delegates;
    mapping(address => mapping(uint256 => Checkpoint)) private _checkpoints;
    mapping(address => uint256) private _numCheckpoints;
    
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    // ==========================================
    // Events
    // ==========================================
    event DistributionCreated(bytes32 id, address indexed creator);
    event DistributionExecuted(bytes32 id, uint256 startIndex, uint256 endIndex);
    event DistributionCompleted(bytes32 id);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    // ==========================================
    // Constructor (Replaces Initialize)
    // ==========================================

    constructor(string memory _name, string memory _symbol) 
        ERC20(_name, _symbol) 
        Ownable(msg.sender) 
    {
        // ESH Init Defaults
        MAX_BATCH_SIZE = 500;
        INIT_BATCH_SIZE = 400;
        isReady = true;

        // Mint Initial Supply to Deployer
        _mint(msg.sender, 1000000000 * 10 ** decimals()); 
    }

    // ==========================================
    // Core Logic: _update (Handles EVERYTHING)
    // ==========================================

    /**
     * @dev Combined hook for ERCUltra (Holders) and ESH (Voting)
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        // 1. Perform Transfer
        super._update(from, to, value);

        // 2. Voting Logic (Move Delegates)
        _moveDelegates(delegates(from), delegates(to), value);

        // 3. Holders List Logic
        if (to != address(0) && balanceOf(to) > 0) {
            _addHolder(to);
        }
        if (from != address(0) && balanceOf(from) == 0) {
            _removeHolder(from);
        }
    }

    // ==========================================
    // Holders List Logic (Internal)
    // ==========================================

    function _addHolder(address account) internal {
        if (ownerIndex[account] > 0) return;
        owners.push(account);
        ownerIndex[account] = owners.length;
    }

    function _removeHolder(address account) internal {
        uint256 indexPlusOne = ownerIndex[account];
        if (indexPlusOne == 0) return;

        uint256 toDeleteIndex = indexPlusOne - 1;
        uint256 lastIndex = owners.length;

        if (toDeleteIndex != lastIndex - 1) {
            address lastHolder = owners[lastIndex - 1];
            owners[toDeleteIndex] = lastHolder;
            ownerIndex[lastHolder] = indexPlusOne; 
        }

        owners.pop();
        delete ownerIndex[account];
    }

    function getHolders() public view returns (address[] memory) {
        return owners;
    }

    // ==========================================
    // ESH Distribution Logic
    // ==========================================

    modifier OnlyDistributor() {
        require(msg.sender == distributor1 || msg.sender == owner() || msg.sender == distributor2, "Only Distributor");
        _;
    }

    function setDistributors(address _dist1, address _dist2) external onlyOwner {
        distributor1 = _dist1;
        distributor2 = _dist2;
    }

    function adjustBatchSizes(uint256 _maxBatch, uint256 _initBatch) external onlyOwner {
        MAX_BATCH_SIZE = _maxBatch;
        INIT_BATCH_SIZE = _initBatch;
    }

    function createDistribution(address paymentToken, uint256 amount) public OnlyDistributor returns (bytes32) {
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
        // Reset state
        distributionInitialized[id] = false;
        distributionInitializationStarted[id] = false;
        distributionInitIndex[id] = 0;

        emit DistributionCreated(id, msg.sender);
        return id;
    }

    function initializeDistributionStep(bytes32 distributionId, uint256 maxHolders) public OnlyDistributor {
        Distribution storage dist = distributions[distributionId];
        require(!distributionInitialized[distributionId], "Already initialized");

        uint256 start = distributionInitIndex[distributionId];
        uint256 totalHolders = owners.length;
        require(start < totalHolders, "Init complete");

        uint256 end = start + maxHolders;
        if (end > totalHolders) {
            end = totalHolders;
        }

        for (uint256 i = start; i < end; i++) {
            address holder = owners[i];
            uint256 balance = balanceOf(holder);
            if (balance > 0) {
                dist.recipients.push(holder);
                dist.balances.push(balance);
                dist.totalBalance += balance;
            }
        }

        distributionInitIndex[distributionId] = end;

        if (end == totalHolders) {
            distributionInitialized[distributionId] = true;
            distributionTotalBalance[distributionId] = dist.totalBalance;
        }
    }

    function distributeBatch(bytes32 distributionId, uint256 batchSize) public OnlyDistributor nonReentrant returns (bool) {
        Distribution storage dist = distributions[distributionId];
        require(distributionInitialized[distributionId], "Not initialized");
        require(!dist.isCompleted, "Completed");

        IERC20 paymentTokenContract = IERC20(dist.paymentToken);
        // Assuming string symbol retrieval is needed for internal tracking logic
        string memory symbol = IERC20Metadata(dist.paymentToken).symbol(); 

        uint256 endIndex = Math.min(dist.startIndex + batchSize, dist.recipients.length);

        for (uint256 i = dist.startIndex; i < endIndex; i++) {
            address recipient = dist.recipients[i];
            // ✅ skip contracts
            if (recipient.code.length != 0) {
                continue;
            }
            uint256 share = (dist.amount * dist.balances[i]) / dist.totalBalance;

            if (share > 0) {
                // Internal tracking
                _addBalanceToHolder(share, recipient, symbol);
                
                // Transfer Logic:
                // Needs approval from msg.sender to this contract beforehand
                bool success = paymentTokenContract.transferFrom(msg.sender, recipient, share);
                require(success, "Transfer failed");
            }
        }

        emit DistributionExecuted(distributionId, dist.startIndex, endIndex);
        dist.startIndex = endIndex;

        if (dist.startIndex >= dist.recipients.length) {
            dist.isCompleted = true;
            emit DistributionCompleted(distributionId);
        }

        return dist.isCompleted;
    }

    function _addBalanceToHolder(uint256 amount, address holder, string memory symbol) internal {
        if (holderTokenBalances[holder][symbol].balance == 0) {
            holderTokenSymbols[holder].push(symbol);
        }
        holderTokenBalances[holder][symbol].balance += amount;
        holderTokenBalances[holder][symbol].symbol = symbol;
    }

    // ==========================================
    // Voting Logic (Delegation)
    // ==========================================

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
                    address recipient = dist.recipients[j];

                    // ✅ skip contracts
                    if (recipient.code.length != 0) {
                        continue;
                    }
                    uint256 share = (dist.amount * dist.balances[j]);
                    uint256 adjustedShare = share / dist.totalBalance;

                    _addBalanceToHolder(adjustedShare, dist.recipients[j], symbol);
                    paymentTokenContract.approve(dist.recipients[j], adjustedShare);
                    paymentTokenContract.approve(address(this), adjustedShare);
                    paymentTokenContract.approve(msg.sender, adjustedShare);
                    if (adjustedShare > 0) {
                    paymentTokenContract.transferFrom(msg.sender, dist.recipients[j], adjustedShare);
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
    }
}