/**
* SPDX-License-Identifier: Apache 2.0
*
**/

pragma solidity ^0.8.25;

import "contracts/IERC20.sol";
import "contracts/ReentrancyGuard.sol";

interface IInvoice {
    function verifyOwnershipByBarcode(address owner, string memory productBarcode) external view returns (bool);
}

contract LuckESH is ReentrancyGuard {
    struct CityData {
        uint256 totalTickets;
        uint256 totalDeposited;
        uint256 registrationCost;
        address[] participants;
        mapping(address => uint256) ticketsOwned;
        mapping(address => uint256) amountDeposited;
    }
    IInvoice public invoices;
    mapping(string => CityData) public cities;
    string[] public cityNames;
    IERC20 public token;
    address public owner;

    uint256 public constant MIN_CITY_COST = 1 * 1e6;
    uint256 public constant MAX_CITY_COST = 90 * 1e6;

    event Registered(address indexed participant, uint256 tickets, string city);
    event LuckSpinned(address indexed winner, uint256 amount, string city);
    event RegistrationCostUpdated(uint256 newCost, string city);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenChanged(address indexed oldToken, address indexed newToken);
    event Refunded(address indexed participant, uint256 amount, string city);
    event CityInitialized(string city, uint256 initialCost);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    constructor(IERC20 _token,address _invoices) {
        token = _token;
        owner = msg.sender;
        invoices = IInvoice(_invoices);
    }

    function initializeCity(string memory _city) internal {
        if (cities[_city].registrationCost == 0) {
            uint256 initialCost = getRandomCost();
            cities[_city].registrationCost = initialCost;
            cityNames.push(_city);
            emit CityInitialized(_city, initialCost);
        }
    }

    function getRandomCost() internal view returns (uint256) {
        uint256 range = MAX_CITY_COST - MIN_CITY_COST;
        uint256 randomness = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender)));
        return MIN_CITY_COST + (randomness % (range + 1));
    }

    function calculatePrice(uint256 _tickets, string memory _city) public view returns (uint256) {
        return _tickets * cities[_city].registrationCost;
    }

    function getTicketsOwned(string memory _city, address _participant) public view returns (uint256) {
        return cities[_city].ticketsOwned[_participant];
    }

    function register(uint256 _tickets, string memory _city) public nonReentrant {
        require(invoices.verifyOwnershipByBarcode(msg.sender,"LOTERRY"),"You Don't Have CitizenShip");
        require(_tickets > 0, "Must buy at least one ticket");
        
        initializeCity(_city);

        uint256 cost = calculatePrice(_tickets, _city);
        require(token.transferFrom(msg.sender, address(this), cost), "Transfer failed");

        CityData storage cityData = cities[_city];
        if (cityData.ticketsOwned[msg.sender] == 0) {
            cityData.participants.push(msg.sender);
        }
        cityData.ticketsOwned[msg.sender] += _tickets;
        cityData.amountDeposited[msg.sender] += cost;
        cityData.totalTickets += _tickets;
        cityData.totalDeposited += cost;

        emit Registered(msg.sender, _tickets, _city);
    }

    function spinTheLuck(bytes32 randomSeed, string memory _city) public onlyOwner nonReentrant {
        CityData storage cityData = cities[_city];
        require(cityData.totalTickets > 0, "No tickets sold for this city");

        uint256 winningTicket = getRandomNumber(randomSeed) % cityData.totalTickets;
        address winner;
        uint256 ticketCount = 0;

        for (uint256 i = 0; i < cityData.participants.length; i++) {
            address participant = cityData.participants[i];
            ticketCount += cityData.ticketsOwned[participant];
            if (ticketCount > winningTicket) {
                winner = participant;
                break;
            }
        }

        uint256 totalDeposited = cityData.totalDeposited;
        require(token.approve(address(this), totalDeposited), "Approval failed");
        require(token.transfer(owner, totalDeposited / 3), "Transfer to owner failed");
        require(token.transfer(winner, totalDeposited * 2 / 3), "Transfer to winner failed");

        emit LuckSpinned(winner, totalDeposited, _city);

        // Reset the city state
        for (uint256 i = 0; i < cityData.participants.length; i++) {
            delete cityData.ticketsOwned[cityData.participants[i]];
            delete cityData.amountDeposited[cityData.participants[i]];
        }
        delete cityData.participants;
        cityData.totalTickets = 0;
        cityData.totalDeposited = 0;
    }

    function getRandomNumber(bytes32 randomSeed) internal view returns (uint256) {
        uint256 randomNumber;
        assembly {
            let fp := mload(0x40)
            mstore(fp, randomSeed)
            mstore(add(fp, 32), timestamp())
            mstore(add(fp, 64), prevrandao())
            mstore(add(fp, 96), blockhash(sub(number(), 1)))
            randomNumber := keccak256(fp, 128)
        }
        return randomNumber;
    }

    function setRegistrationCost(uint256 _newCost, string memory _city) public onlyOwner {
        initializeCity(_city);
        cities[_city].registrationCost = _newCost;
        emit RegistrationCostUpdated(_newCost, _city);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function getParticipantsCount(string memory _city) public view returns (uint256) {
        return cities[_city].participants.length;
    }

    function getCityTotalDeposited(string memory _city) public view returns (uint256) {
        return cities[_city].totalDeposited;
    }

    function getCityPrice(string memory _city) public view returns (uint256) {
        return cities[_city].registrationCost;
    }

    function changeToken(address _newToken) public onlyOwner nonReentrant {
        require(_newToken != address(0), "New token is the zero address");
        IERC20 oldToken = token;
        token = IERC20(_newToken);

        // Refund all participants with the old token for all cities
        for (uint256 j = 0; j < cityNames.length; j++) {
            string memory city = cityNames[j];
            CityData storage cityData = cities[city];
            for (uint256 i = 0; i < cityData.participants.length; i++) {
                address participant = cityData.participants[i];
                uint256 amount = cityData.amountDeposited[participant];
                if (amount > 0) {
                    require(oldToken.transfer(participant, amount), "Refund transfer failed");
                    emit Refunded(participant, amount, city);
                    delete cityData.amountDeposited[participant];
                    delete cityData.ticketsOwned[participant];
                }
            }
            delete cityData.participants;
            cityData.totalTickets = 0;
            cityData.totalDeposited = 0;
        }

        emit TokenChanged(address(oldToken), address(_newToken));
    }

    function getCityNames() public view returns (string[] memory) {
        return cityNames;
    }
}