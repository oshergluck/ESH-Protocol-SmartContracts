// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

/**
 * LuckESH_FutureBlockhash_Resched (Policy A)
 * - Payment token: USDC (6 decimals)
 * - Fair-ish randomness: blockhash(seedBlock) where seedBlock is chosen in the FUTURE
 * - Owner push-pays winner in spin()
 * - If owner misses the 256-block window, they can reschedule ONLY the seedBlock
 *   (same pot + same tickets; entries stay locked forever after the first close)
 * - No VRF, no commit-reveal, no refunds
 * - Winner selection is O(log N) via checkpoints + binary search (no heavy loops)
 * - Uses per-city rounds (no delete loops)
 */

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IInvoice {
    function verifyOwnershipByBarcode(address owner, string memory productBarcode) external view returns (bool);
}

/* -------------------------- Safe ERC20 Helper -------------------------- */
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SAFE_TRANSFER_FAILED");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SAFE_TRANSFERFROM_FAILED");
    }
}

/* -------------------------- Minimal Reentrancy -------------------------- */
abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

contract LuckSpinnerUltraShop is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ------------------------------ Constants ---------------------------- */
    // USDC 6 decimals
    uint256 public constant MIN_CITY_COST_6 = 1 * 1e6;   // 1 USDC
    uint256 public constant MAX_CITY_COST_6 = 90 * 1e6;  // 90 USDC

    uint256 public constant MIN_BLOCKS_AHEAD = 5;        // minimum future offset for close/reschedule

    // Citizenship gate (same behavior as your old contract)
    string public constant CITIZENSHIP_BARCODE = "LOTERRY";

    /* ------------------------------ Admin/Deps --------------------------- */
    IERC20 public immutable token;      // USDC
    IInvoice public immutable invoices; // citizenship verifier
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    /* ------------------------------ Events ------------------------------ */
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event CityInitialized(string city, uint256 roundId, uint256 registrationCost6);
    event RegistrationCostUpdated(string city, uint256 roundId, uint256 newCost6);

    event Registered(address indexed participant, string city, uint256 roundId, uint256 tickets, uint256 paid);

    // Entries close mechanics
    event EntriesClosingScheduled(string city, uint256 roundId, uint256 entriesCloseBlock);
    event EntriesLocked(string city, uint256 roundId);

    // Randomness seed mechanics (reschedulable if missed)
    event SeedBlockScheduled(string city, uint256 roundId, uint256 seedBlock);
    event SeedBlockRescheduled(string city, uint256 roundId, uint256 oldSeedBlock, uint256 newSeedBlock);

    // Spin / payout
    event LuckSpun(
        string city,
        uint256 roundId,
        address indexed winner,
        uint256 winnerAmount,
        uint256 ownerAmount,
        uint256 totalDeposited,
        uint256 seedBlock,
        bytes32 seedBlockhash
    );

    /* ------------------------------ Data Model --------------------------- */
    struct TicketCheckpoint {
        address participant;
        uint256 cumulativeTickets; // strictly increasing
    }

    struct Round {
        // pricing
        uint256 registrationCost6; // USDC micro

        // totals
        uint256 totalTickets;
        uint256 totalDeposited;

        // checkpoints for binary search winner selection
        TicketCheckpoint[] checkpoints;

        // entry closing
        bool entriesClosingScheduled;
        uint256 entriesCloseBlock; // fixed forever once scheduled
        bool entriesLocked;        // set true once block.number >= entriesCloseBlock

        // randomness seed block (can be rescheduled if missed)
        uint256 seedBlock;

        // payout
        bool paid;
    }

    // city => current roundId (starts at 1)
    mapping(string => uint256) public currentRoundId;

    // city => roundId => round data
    mapping(string => mapping(uint256 => Round)) private _rounds;

    // optional city list
    string[] public cityNames;
    mapping(string => bool) private _citySeen;

    constructor(address usdcToken, address invoiceVerifier) {
        require(usdcToken != address(0), "TOKEN_0");
        require(invoiceVerifier != address(0), "INVOICE_0");
        token = IERC20(usdcToken);
        invoices = IInvoice(invoiceVerifier);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /* ------------------------------ Helpers ----------------------------- */
    function _ensureRound(string memory city) internal returns (Round storage r, uint256 rid) {
        rid = currentRoundId[city];
        if (rid == 0) {
            rid = 1;
            currentRoundId[city] = 1;
        }

        r = _rounds[city][rid];

        // init price once per round
        if (r.registrationCost6 == 0) {
            uint256 cost = _randomCostPseudo(city);
            r.registrationCost6 = cost;

            if (!_citySeen[city]) {
                _citySeen[city] = true;
                cityNames.push(city);
            }

            emit CityInitialized(city, rid, cost);
        }
    }

    // Not used for fairness of winner; only for initial pricing if owner doesn't set manually
    function _randomCostPseudo(string memory city) internal view returns (uint256) {
        uint256 range = MAX_CITY_COST_6 - MIN_CITY_COST_6;
        uint256 x = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, city, address(this))));
        return MIN_CITY_COST_6 + (x % (range + 1));
    }

    function _findWinnerByTicket(Round storage r, uint256 winningIndex) internal view returns (address) {
        uint256 n = r.checkpoints.length;
        require(n > 0, "NO_PARTICIPANTS");

        uint256 lo = 0;
        uint256 hi = n - 1;

        // first checkpoint with cumulativeTickets > winningIndex
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (r.checkpoints[mid].cumulativeTickets > winningIndex) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return r.checkpoints[lo].participant;
    }

    function _syncEntryLock(Round storage r, string memory city, uint256 rid) internal {
        if (r.entriesClosingScheduled && !r.entriesLocked && block.number >= r.entriesCloseBlock) {
            r.entriesLocked = true;
            emit EntriesLocked(city, rid);
        }
    }

    /* ------------------------------ Views ------------------------------ */
    function getCityNames() external view returns (string[] memory) {
        return cityNames;
    }

    function getRoundState(string memory city)
        external
        view
        returns (
            uint256 roundId,
            uint256 registrationCost6,
            uint256 totalTickets,
            uint256 totalDeposited,
            bool entriesClosingScheduled,
            uint256 entriesCloseBlock,
            bool entriesLocked,
            uint256 seedBlock,
            bool paid
        )
    {
        roundId = currentRoundId[city];
        if (roundId == 0) roundId = 1;
        Round storage r = _rounds[city][roundId];
        return (
            roundId,
            r.registrationCost6,
            r.totalTickets,
            r.totalDeposited,
            r.entriesClosingScheduled,
            r.entriesCloseBlock,
            r.entriesLocked,
            r.seedBlock,
            r.paid
        );
    }

    function getParticipantsCount(string memory city) external view returns (uint256) {
        uint256 rid = currentRoundId[city];
        if (rid == 0) rid = 1;
        return _rounds[city][rid].checkpoints.length;
    }

    /* ------------------------------ Admin ------------------------------ */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER_0");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    /**
     * Set price only before anyone buys tickets
     */
    function setRegistrationCost(string memory city, uint256 newCost6) external onlyOwner {
        require(newCost6 >= MIN_CITY_COST_6 && newCost6 <= MAX_CITY_COST_6, "OUT_OF_RANGE");
        (Round storage r, uint256 rid) = _ensureRound(city);
        require(r.totalTickets == 0, "ALREADY_STARTED");
        require(!r.entriesClosingScheduled, "CLOSING_ALREADY_SCHEDULED");
        r.registrationCost6 = newCost6;
        emit RegistrationCostUpdated(city, rid, newCost6);
    }

    /* ------------------------------ Register ------------------------------ */
    function register(uint256 tickets, string memory city) external nonReentrant {
        require(tickets > 0, "TICKETS_0");
        require(invoices.verifyOwnershipByBarcode(msg.sender, CITIZENSHIP_BARCODE), "NO_CITIZENSHIP");

        (Round storage r, uint256 rid) = _ensureRound(city);

        // Lock entries once we passed close block
        _syncEntryLock(r, city, rid);

        // If closing was scheduled, allow entries only strictly before entriesCloseBlock
        if (r.entriesClosingScheduled) {
            require(block.number < r.entriesCloseBlock, "ENTRIES_CLOSED");
        }
        require(!r.entriesLocked, "ENTRIES_LOCKED");

        require(r.registrationCost6 >= MIN_CITY_COST_6 && r.registrationCost6 <= MAX_CITY_COST_6, "BAD_COST");

        uint256 cost = tickets * r.registrationCost6;
        require(cost > 0, "COST_0");

        token.safeTransferFrom(msg.sender, address(this), cost);

        r.totalTickets += tickets;
        r.totalDeposited += cost;

        r.checkpoints.push(TicketCheckpoint({
            participant: msg.sender,
            cumulativeTickets: r.totalTickets
        }));

        emit Registered(msg.sender, city, rid, tickets, cost);
    }

    /* ------------------- Close entries: set a FIXED future close block ------------------- */
    /**
     * Schedules entry closing at a FUTURE block (fixed forever).
     * Also sets initial seedBlock = entriesCloseBlock.
     */
    function closeEntries(string memory city, uint256 blocksAhead) external onlyOwner {
        require(blocksAhead >= MIN_BLOCKS_AHEAD, "AHEAD_TOO_SMALL");

        (Round storage r, uint256 rid) = _ensureRound(city);
        require(!r.entriesClosingScheduled, "ALREADY_SCHEDULED");
        require(r.totalTickets > 0, "NO_TICKETS");

        uint256 closeBlock = block.number + blocksAhead;

        r.entriesClosingScheduled = true;
        r.entriesCloseBlock = closeBlock;

        // initial randomness seed block = the close block
        r.seedBlock = closeBlock;

        emit EntriesClosingScheduled(city, rid, closeBlock);
        emit SeedBlockScheduled(city, rid, closeBlock);
    }

    /* ------------------- Policy A: reschedule ONLY the seed block if missed ------------------- */
    /**
     * If you missed the 256-block window for seedBlock, you can reschedule seedBlock to a new future block.
     *
     * IMPORTANT:
     * - This does NOT reopen entries.
     * - The ticket set + pot stays exactly the same.
     */
    function rescheduleSeedBlock(string memory city, uint256 blocksAhead) external onlyOwner {
        require(blocksAhead >= MIN_BLOCKS_AHEAD, "AHEAD_TOO_SMALL");

        uint256 rid = currentRoundId[city];
        if (rid == 0) rid = 1;
        Round storage r = _rounds[city][rid];

        require(r.totalTickets > 0, "NO_TICKETS");
        require(r.entriesClosingScheduled, "NOT_CLOSED");
        require(!r.paid, "ALREADY_PAID");

        // sync lock if needed
        _syncEntryLock(r, city, rid);

        // must be past entries close so we don't ever reopen entries
        require(block.number >= r.entriesCloseBlock, "WAIT_ENTRIES_CLOSE");
        require(r.entriesLocked, "ENTRIES_NOT_LOCKED_YET");

        uint256 oldSeed = r.seedBlock;

        // Only allow reschedule if the old seed window is truly gone (blockhash unavailable)
        require(block.number > oldSeed + 256, "SEED_STILL_USABLE");

        uint256 newSeed = block.number + blocksAhead;
        r.seedBlock = newSeed;

        emit SeedBlockRescheduled(city, rid, oldSeed, newSeed);
    }

    /* ------------------------------ Spin + Push-Pay ------------------------------ */
    /**
     * Owner triggers payout (push payment).
     * Requirements:
     * - entries close was scheduled
     * - entries are locked (block.number >= entriesCloseBlock)
     * - block.number > seedBlock (so blockhash(seedBlock) exists)
     * - must be within 256 blocks after seedBlock
     */
    function spin(string memory city) external onlyOwner nonReentrant {
        uint256 rid = currentRoundId[city];
        if (rid == 0) rid = 1;
        Round storage r = _rounds[city][rid];

        require(r.totalTickets > 0, "NO_TICKETS");
        require(r.entriesClosingScheduled, "NOT_CLOSED");
        require(!r.paid, "ALREADY_PAID");

        // ensure entries are locked
        _syncEntryLock(r, city, rid);
        require(r.entriesLocked, "ENTRIES_NOT_LOCKED");

        uint256 sb = r.seedBlock;

        require(block.number > sb, "WAIT_FOR_SEED_BLOCK");
        require(block.number <= sb + 256, "TOO_LATE_SPIN");

        bytes32 bh = blockhash(sb);
        require(bh != bytes32(0), "BLOCKHASH_UNAVAILABLE");

        // Mix in city + round + contract so the same blockhash can't be reused across contexts
        bytes32 mix = keccak256(abi.encodePacked(bh, city, rid, address(this)));
        uint256 winningIndex = uint256(mix) % r.totalTickets;

        address winner = _findWinnerByTicket(r, winningIndex);

        uint256 total = r.totalDeposited;
        uint256 ownerAmount = total / 3;
        uint256 winnerAmount = total - ownerAmount;

        token.safeTransfer(owner, ownerAmount);
        token.safeTransfer(winner, winnerAmount);

        r.paid = true;

        emit LuckSpun(city, rid, winner, winnerAmount, ownerAmount, total, sb, bh);

        // Advance to next round (fresh storage, no delete loops)
        currentRoundId[city] = rid + 1;
        // next round initializes on first use
    }
}
