// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Dynamic v2 — AI-gated, challengeable milestone launchpad
/// @dev UNAUDITED. Compile with optimizer enabled (and viaIR if you hit "stack too deep").
///      Funds stay in escrow; a tranche is released only when the launch's own oracle set attests the milestone
///      and nobody successfully challenges it. The admin can never move escrowed funds, and cannot change the
///      oracle set or fees of a launch that already exists (everything is snapshotted at creation).
contract Dynamic is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant CHALLENGE_WINDOW = 48 hours;
    uint256 public constant VOTE_PERIOD = 72 hours;
    uint16 public constant STAKE_BPS = 500;     // challenge stake = 5% of the tranche
    uint16 public constant QUORUM_BPS = 1000;   // 10% of raised funds must vote for a vote to count
    uint16 public constant MAX_FEE_BPS = 500;   // protocol fee never exceeds 5%
    uint8 public constant MIN_SCORE = 70;
    uint8 public constant MAX_ORACLES = 15;

    enum LS { Funding, Active, Halted, Completed, Failed }
    enum MS { Pending, Claimed, Challenged, Released }

    struct M {
        uint16 bps; uint40 deadline; MS st; uint40 claimEnd; uint40 voteEnd;
        uint8 attests; uint8 round; uint256 yes; uint256 no;
        address challenger; uint256 stake; bytes32 spec;   // spec = keccak256 of the milestone definition
    }
    struct Launch {
        address team; IERC20 pay; IERC20 sale;
        uint256 goal; uint256 raised; uint256 bond; uint256 rate;
        uint40 fundEnd; LS st; uint256 paid; uint256 refundable;
        uint8 next; uint256 saleReclaimed; uint16 feeBps; uint8 threshold;
    }
    struct Params {
        IERC20 pay; IERC20 sale; uint256 goal; uint256 rate; uint40 fundEnd;
        uint16[] bps; uint40[] durations; bytes32[] specs; string metaURI;
    }

    // ---- admin-managed config (applies to NEW launches only, except insurance policy) ----
    address public treasury;
    uint16 public releaseFeeBps;
    uint256 public createFee;          // flat, payment-token units
    uint16 public insuranceShareBps = 2500; // share of each fee kept in the insurance pool
    uint16 public coverBps = 2500;     // pool tops up refunds by at most this % of the unpaid escrow
    uint256 public starterCap;         // launches with goal <= this pay no create fee ("starter" launches)
    uint256 public repMinGoal;         // only launches with goal >= this build a team's track record
    uint8 public threshold;
    bool public paused = true;         // starts PAUSED: admin must set maxGoal and unpause. Pause blocks new launches/contributions only, never refunds or claims.
    uint256 public maxGoal;            // cap per launch (payment-token units) to limit exposure while the system is young
    address[] public oracleList;
    mapping(address => bool) public isOracle;

    // ---- state ----
    uint256 public count;
    mapping(uint256 => Launch) internal L;
    mapping(uint256 => M[]) internal ms;
    mapping(uint256 => string) public metaURI;
    mapping(uint256 => mapping(address => bool)) public launchOracle;      // oracle set snapshot per launch
    mapping(uint256 => mapping(address => uint256)) public contributed;
    mapping(uint256 => mapping(address => uint256)) public tokensTaken;   // sale tokens already claimed
    mapping(uint256 => mapping(address => bool)) public refunded;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public voted;
    mapping(uint256 => mapping(uint256 => mapping(uint8 => mapping(address => bool)))) internal att;
    mapping(address => uint256) public insurance;   // per payment token
    mapping(address => uint8) public rep;           // completed launches per team

    event Created(uint256 indexed id, address indexed team);
    event Contributed(uint256 indexed id, address indexed user, uint256 amount);
    event Claimed(uint256 indexed id, uint256 indexed i, string evidenceURI);
    event Attested(uint256 indexed id, uint256 indexed i, address indexed oracle, uint8 score, bytes32 reportHash);
    event Challenged(uint256 indexed id, uint256 indexed i, address indexed challenger);
    event Released(uint256 indexed id, uint256 indexed i, uint256 amount);
    event Halted(uint256 indexed id, uint256 refundable);

    constructor(address owner_, address[] memory oracles, uint8 threshold_, address treasury_, uint16 feeBps_, uint256 createFee_)
        Ownable(owner_)
    {
        require(oracles.length <= MAX_ORACLES && threshold_ > 0 && threshold_ <= oracles.length, "oracles");
        require(treasury_ != address(0) && feeBps_ <= MAX_FEE_BPS, "fees");
        for (uint256 i; i < oracles.length; i++) { isOracle[oracles[i]] = true; oracleList.push(oracles[i]); }
        threshold = threshold_; treasury = treasury_; releaseFeeBps = feeBps_; createFee = createFee_;
    }

    // ------------------------------------------------------------------ admin
    // Changes below never touch launches that already exist (oracle set / threshold / fee are snapshotted).
    function addOracle(address o) external onlyOwner {
        require(!isOracle[o] && oracleList.length < MAX_ORACLES, "oracle");
        isOracle[o] = true; oracleList.push(o);
    }
    function removeOracle(address o) external onlyOwner {
        require(isOracle[o], "not oracle");
        isOracle[o] = false;
        for (uint256 i; i < oracleList.length; i++) {
            if (oracleList[i] == o) { oracleList[i] = oracleList[oracleList.length - 1]; oracleList.pop(); break; }
        }
        if (threshold > oracleList.length) threshold = uint8(oracleList.length);
    }
    function setThreshold(uint8 t) external onlyOwner { require(t > 0 && t <= oracleList.length, "threshold"); threshold = t; }
    function setTreasury(address t) external onlyOwner { require(t != address(0), "zero"); treasury = t; }
    function setPaused(bool p) external onlyOwner { paused = p; }
    function setMaxGoal(uint256 g) external onlyOwner { maxGoal = g; }
    function setFees(uint16 bps, uint256 flat) external onlyOwner { require(bps <= MAX_FEE_BPS, "max 5%"); releaseFeeBps = bps; createFee = flat; }
    function setPolicy(uint16 insShare, uint16 cover, uint256 starter, uint256 repGoal) external onlyOwner {
        require(insShare <= 10000 && cover <= 10000, "bps");
        insuranceShareBps = insShare; coverBps = cover; starterCap = starter; repMinGoal = repGoal;
    }
    function oracleCount() external view returns (uint256) { return oracleList.length; }

    /// @notice Teams with a track record post a smaller bond. Track record only counts for launches >= repMinGoal.
    function bondBpsFor(address team) public view returns (uint16) {
        uint8 r = rep[team];
        return r >= 3 ? 500 : (r >= 1 ? 700 : 1000);
    }

    // ----------------------------------------------------------------- launch
    /// @param p.durations seconds allowed for each milestone, counted cumulatively from funding completion
    /// @param p.specs     keccak256 of each milestone's definition; the oracle only attests milestones whose spec matches
    function create(Params calldata p) external nonReentrant returns (uint256 id) {
        uint256 n = p.bps.length;
        require(p.goal > 0 && p.rate > 0 && p.fundEnd > block.timestamp, "params");
        require(!paused, "paused");
        require(maxGoal > 0 && p.goal <= maxGoal, "goal cap");
        require(n > 0 && n <= 20 && n == p.durations.length && n == p.specs.length, "milestones");
        require(threshold > 0 && oracleList.length >= threshold, "no oracles");
        uint256 sum;
        for (uint256 i; i < n; i++) sum += p.bps[i];
        require(sum == 10000, "bps != 100%");

        id = ++count;
        Launch storage l = L[id];
        l.team = msg.sender; l.pay = p.pay; l.sale = p.sale; l.goal = p.goal; l.rate = p.rate;
        l.fundEnd = p.fundEnd; l.feeBps = releaseFeeBps; l.threshold = threshold;
        l.bond = (p.goal * bondBpsFor(msg.sender)) / 10000;
        metaURI[id] = p.metaURI;
        for (uint256 i; i < n; i++) {
            M storage m = ms[id].push();
            m.bps = p.bps[i]; m.deadline = p.durations[i]; m.spec = p.specs[i];
        }
        for (uint256 i; i < oracleList.length; i++) launchOracle[id][oracleList[i]] = true;

        p.pay.safeTransferFrom(msg.sender, address(this), l.bond);
        if (createFee > 0 && p.goal > starterCap) p.pay.safeTransferFrom(msg.sender, treasury, createFee);
        p.sale.safeTransferFrom(msg.sender, address(this), p.goal * p.rate);
        emit Created(id, msg.sender);
    }

    function contribute(uint256 id, uint256 amount) external nonReentrant {
        Launch storage l = L[id];
        require(l.st == LS.Funding && block.timestamp <= l.fundEnd, "closed");
        require(!paused, "paused");
        uint256 a = Math.min(amount, l.goal - l.raised);
        require(a > 0, "zero");
        l.pay.safeTransferFrom(msg.sender, address(this), a);
        l.raised += a;
        contributed[id][msg.sender] += a;
        emit Contributed(id, msg.sender, a);
        if (l.raised == l.goal) {
            l.st = LS.Active;
            uint256 t = block.timestamp;
            for (uint256 i; i < ms[id].length; i++) { t += ms[id][i].deadline; ms[id][i].deadline = uint40(t); }
        }
    }

    function closeFunding(uint256 id) external nonReentrant {
        Launch storage l = L[id];
        require(l.st == LS.Funding && block.timestamp > l.fundEnd, "not ended");
        l.st = LS.Failed; l.refundable = l.raised;
        uint256 b = l.bond; l.bond = 0;
        l.pay.safeTransfer(l.team, b);
    }

    // ------------------------------------------------------------- milestones
    /// @notice Team claims the current milestone. If oracles failed to approve in time, the team may claim again (new round).
    function claimMilestone(uint256 id, string calldata evidenceURI) external {
        Launch storage l = L[id];
        require(msg.sender == l.team && l.st == LS.Active, "auth");
        M storage m = ms[id][l.next];
        require(block.timestamp <= m.deadline, "late");
        if (m.st == MS.Claimed) {
            require(block.timestamp > m.claimEnd && m.attests < l.threshold, "in progress");
            m.round++; m.attests = 0;
        } else {
            require(m.st == MS.Pending, "state");
        }
        m.st = MS.Claimed; m.claimEnd = uint40(block.timestamp + CHALLENGE_WINDOW);
        emit Claimed(id, l.next, evidenceURI);
    }

    /// @notice Oracles from this launch's own snapshot publish a score and the hash of their full report.
    function attest(uint256 id, uint8 score, bytes32 reportHash) external {
        require(launchOracle[id][msg.sender], "not oracle");
        Launch storage l = L[id];
        M storage m = ms[id][l.next];
        require(l.st == LS.Active && m.st == MS.Claimed, "state");
        require(!att[id][l.next][m.round][msg.sender], "done");
        att[id][l.next][m.round][msg.sender] = true;
        if (score >= MIN_SCORE) m.attests++;
        emit Attested(id, l.next, msg.sender, score, reportHash);
    }

    function challenge(uint256 id) external nonReentrant {
        Launch storage l = L[id];
        M storage m = ms[id][l.next];
        require(l.st == LS.Active && m.st == MS.Claimed && block.timestamp <= m.claimEnd, "state");
        uint256 stake = (((l.raised * m.bps) / 10000) * STAKE_BPS) / 10000;
        l.pay.safeTransferFrom(msg.sender, address(this), stake);
        m.st = MS.Challenged; m.challenger = msg.sender; m.stake = stake;
        m.voteEnd = uint40(block.timestamp + VOTE_PERIOD);
        emit Challenged(id, l.next, msg.sender);
    }

    /// @param valid true = the milestone is genuinely complete. Weight is linear in contribution (splitting wallets gains nothing).
    function vote(uint256 id, bool valid) external {
        Launch storage l = L[id];
        M storage m = ms[id][l.next];
        require(m.st == MS.Challenged && block.timestamp <= m.voteEnd, "state");
        uint256 c = contributed[id][msg.sender];
        require(c > 0 && !voted[id][l.next][msg.sender], "ineligible");
        voted[id][l.next][msg.sender] = true;
        if (valid) m.yes += c; else m.no += c;
    }

    function resolve(uint256 id) external nonReentrant {
        Launch storage l = L[id];
        require(l.st == LS.Active, "inactive");
        M storage m = ms[id][l.next];
        if (m.st == MS.Claimed) {
            require(block.timestamp > m.claimEnd && m.attests >= l.threshold, "not approved");
            _pay(id, l, m);
        } else if (m.st == MS.Challenged) {
            require(block.timestamp > m.voteEnd, "voting");
            bool quorum = (m.yes + m.no) * 10000 >= l.raised * QUORUM_BPS;
            bool approved = m.attests >= l.threshold;
            if (quorum ? m.yes > m.no : approved) {
                l.pay.safeTransfer(l.team, m.stake);            // failed challenge: stake goes to the team
                _pay(id, l, m);
            } else if (quorum) {
                _halt(id, l, m.challenger, m.stake);            // community rejected the milestone
            } else {
                // inconclusive: nobody voted and the oracles had not approved. Refund the stake, let the team retry.
                l.pay.safeTransfer(m.challenger, m.stake);
                m.st = MS.Pending; m.challenger = address(0); m.stake = 0; m.yes = 0; m.no = 0; m.attests = 0; m.round++;
            }
        } else revert("state");
    }

    /// @notice Anyone can halt a launch whose current milestone deadline passed without approval.
    function failByDeadline(uint256 id) external nonReentrant {
        Launch storage l = L[id];
        require(l.st == LS.Active, "inactive");
        M storage m = ms[id][l.next];
        require(block.timestamp > m.deadline, "not late");
        bool stuck = m.st == MS.Pending ||
            (m.st == MS.Claimed && block.timestamp > m.claimEnd && m.attests < l.threshold);
        require(stuck, "in progress");
        _halt(id, l, address(0), 0);
    }

    function _pay(uint256 id, Launch storage l, M storage m) internal {
        uint256 amt = (l.raised * m.bps) / 10000;
        m.st = MS.Released; l.paid += amt;
        emit Released(id, l.next, amt);
        l.next++;
        uint256 fee = (amt * l.feeBps) / 10000;   // fee is only earned when a milestone is actually released
        if (fee > 0) {
            uint256 ins = (fee * insuranceShareBps) / 10000;
            insurance[address(l.pay)] += ins;
            l.pay.safeTransfer(treasury, fee - ins);
        }
        l.pay.safeTransfer(l.team, amt - fee);
        if (l.next == ms[id].length) {
            l.st = LS.Completed;
            if (l.goal >= repMinGoal && rep[l.team] < type(uint8).max) rep[l.team]++;
            uint256 b = l.bond; l.bond = 0;
            l.pay.safeTransfer(l.team, b);
        }
    }

    function _halt(uint256 id, Launch storage l, address challenger, uint256 stake) internal {
        l.st = LS.Halted;
        address pt = address(l.pay);
        uint256 unpaid = l.raised - l.paid;
        uint256 bondForPool = l.bond;
        if (challenger != address(0)) {
            uint256 bounty = l.bond / 2;
            bondForPool = l.bond - bounty;
            uint256 extra = Math.min(insurance[pt], stake);   // watcher reward from the insurance pool
            insurance[pt] -= extra;
            l.pay.safeTransfer(challenger, bounty + stake + extra);
        }
        uint256 cover = Math.min(insurance[pt], (unpaid * coverBps) / 10000);   // partial compensation
        insurance[pt] -= cover;
        l.bond = 0;
        l.refundable = unpaid + bondForPool + cover;
        emit Halted(id, l.refundable);
    }

    // ---------------------------------------------------------- exits & tokens
    /// @notice Refund covers the UNPAID part of the escrow (plus bond share / insurance). Tokens for the paid part stay claimable.
    function refund(uint256 id) external nonReentrant {
        Launch storage l = L[id];
        require(l.st == LS.Halted || l.st == LS.Failed, "no refund");
        uint256 c = contributed[id][msg.sender];
        require(c > 0 && !refunded[id][msg.sender], "none");
        refunded[id][msg.sender] = true;
        l.pay.safeTransfer(msg.sender, (c * l.refundable) / l.raised);
    }

    /// @notice Sale tokens vest in step with released funds: you can claim your share of whatever has been paid out so far.
    function claimTokens(uint256 id) external nonReentrant {
        Launch storage l = L[id];
        require(l.st == LS.Active || l.st == LS.Completed || l.st == LS.Halted, "locked");
        uint256 vested = (contributed[id][msg.sender] * l.rate * l.paid) / l.raised;
        uint256 amt = vested - tokensTaken[id][msg.sender];
        require(amt > 0, "nothing to claim");
        tokensTaken[id][msg.sender] += amt;
        l.sale.safeTransfer(msg.sender, amt);
    }

    /// @notice After a halt or failed funding the team can take back the sale tokens that never vested.
    function reclaimSale(uint256 id) external nonReentrant {
        Launch storage l = L[id];
        require(msg.sender == l.team && (l.st == LS.Halted || l.st == LS.Failed), "auth");
        uint256 amt = l.goal * l.rate - l.paid * l.rate - l.saleReclaimed;
        require(amt > 0, "none");
        l.saleReclaimed += amt;
        l.sale.safeTransfer(l.team, amt);
    }

    // ------------------------------------------------------------------ views
    function launch(uint256 id) external view returns (Launch memory) { return L[id]; }
    function milestones(uint256 id) external view returns (M[] memory) { return ms[id]; }
    function hasAttested(uint256 id, uint256 i, address o) external view returns (bool) { return att[id][i][ms[id][i].round][o]; }
}
