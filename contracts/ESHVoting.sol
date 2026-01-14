// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/math/Math.sol";

interface IESH {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract ESHVoting {
    IESH public token;
    
    struct Proposal {
        uint256 id;
        string title;
        string description;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endTime;
        bool executed;
        mapping(address => bool) hasVoted;
    }

    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    uint256 public VOTING_PERIOD;
    uint256 public MINIMUM_VOTING_POWER;

    event ProposalCreated(uint256 indexed proposalId, string title, address creator);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 votes);
    event ProposalExecuted(uint256 indexed proposalId);

    constructor(address _token, uint256 _minAmountOfTokens, uint256 _proposalDurationInDays) {
        token = IESH(_token);
        VOTING_PERIOD = _proposalDurationInDays*24*60*60;
        MINIMUM_VOTING_POWER = _minAmountOfTokens*10**18;
    }

    modifier onlyTokenHolder() {
        require(token.balanceOf(msg.sender) > 0, "Must be token holder");
        _;
    }

    function createProposal(string memory title, string memory description) external onlyTokenHolder returns (uint256) {
        require(token.balanceOf(msg.sender) >= MINIMUM_VOTING_POWER, "Insufficient voting power");
        
        proposalCount++;
        Proposal storage proposal = proposals[proposalCount];
        proposal.id = proposalCount;
        proposal.title = title;
        proposal.description = description;
        proposal.endTime = block.timestamp + VOTING_PERIOD;
        
        emit ProposalCreated(proposalCount, title, msg.sender);
        return proposalCount;
    }

    function castVote(uint256 proposalId, bool support) external onlyTokenHolder {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp <= proposal.endTime, "Voting period ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        
        uint256 votes = token.balanceOf(msg.sender);
        require(votes > 0, "No voting power");

        if (support) {
            proposal.votesFor += votes;
        } else {
            proposal.votesAgainst += votes;
        }

        proposal.hasVoted[msg.sender] = true;
        emit VoteCast(proposalId, msg.sender, support, votes);
    }

    function getProposal(uint256 proposalId) external view returns (
        uint256 id,
        string memory title,
        string memory description,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 endTime,
        bool executed
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.title,
            proposal.description,
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.endTime,
            proposal.executed
        );
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return proposals[proposalId].hasVoted[voter];
    }

    function getProposalResult(uint256 proposalId) external view returns (bool passed, uint256 percentage) {
        Proposal storage proposal = proposals[proposalId];
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst;
        
        if (totalVotes == 0) {
            return (false, 0);
        }
        
        percentage = (proposal.votesFor * 100) / token.totalSupply();
        passed = percentage > 50;
        return (passed, percentage);
    }
}