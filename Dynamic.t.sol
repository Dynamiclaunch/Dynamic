// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dynamic} from "../src/Dynamic.sol";

contract Tok is ERC20 {
    uint8 private d;
    constructor(string memory n, uint8 d_) ERC20(n, n) { d = d_; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract DynamicTest is Test {
    Dynamic dyn; Tok usdc; Tok sale;
    address admin = address(0xAD); address treasury = address(0xBE); address team = address(0xCA);
    address o1 = address(0x101); address o2 = address(0x102); address o3 = address(0x103);
    address alice = address(0xA1); address bob = address(0xB1); address carol = address(0xC1);
    uint256 constant GOAL = 1000e6;
    uint256 constant RATE = 2e13; // 20 SALE (18 dec) per 1 USDC (6 dec)

    function setUp() public {
        usdc = new Tok("USDC", 6); sale = new Tok("SALE", 18);
        address[] memory os = new address[](3); os[0] = o1; os[1] = o2; os[2] = o3;
        dyn = new Dynamic(admin, os, 2, treasury, 200, 0);
        vm.startPrank(admin); dyn.setMaxGoal(10_000e6); dyn.setPaused(false); vm.stopPrank();
        usdc.mint(team, 1_000e6); sale.mint(team, 100_000e18);
        usdc.mint(alice, 700e6); usdc.mint(bob, 400e6); usdc.mint(carol, 100e6);
    }

    // ------------------------------------------------------------ helpers
    function _params() internal view returns (Dynamic.Params memory p) {
        p.pay = IERC20(address(usdc)); p.sale = IERC20(address(sale)); p.goal = GOAL; p.rate = RATE;
        p.fundEnd = uint40(block.timestamp + 7 days);
        p.bps = new uint16[](2); p.bps[0] = 5000; p.bps[1] = 5000;
        p.durations = new uint40[](2); p.durations[0] = 10 days; p.durations[1] = 20 days;
        p.specs = new bytes32[](2); p.specs[0] = keccak256("m1"); p.specs[1] = keccak256("m2");
        p.metaURI = "data:application/json,{}";
    }
    function _create() internal returns (uint256 id) {
        Dynamic.Params memory p = _params();
        vm.startPrank(team);
        usdc.approve(address(dyn), type(uint256).max); sale.approve(address(dyn), type(uint256).max);
        id = dyn.create(p);
        vm.stopPrank();
    }
    function _contribute(uint256 id, address who, uint256 amt) internal {
        vm.startPrank(who); usdc.approve(address(dyn), amt); dyn.contribute(id, amt); vm.stopPrank();
    }
    function _fund(uint256 id) internal returns (uint256 t0) {
        _contribute(id, alice, 600e6); _contribute(id, bob, 400e6); t0 = block.timestamp;
    }
    function _claim(uint256 id, bool approved) internal {
        vm.prank(team); dyn.claimMilestone(id, "ipfs://evidence");
        if (approved) {
            vm.prank(o1); dyn.attest(id, 80, bytes32(0));
            vm.prank(o2); dyn.attest(id, 90, bytes32(0));
        }
    }
    function _pastWindow() internal { vm.warp(block.timestamp + 48 hours + 1); }
    function _release(uint256 id) internal { _claim(id, true); _pastWindow(); dyn.resolve(id); }

    // -------------------------------------------------------------- tests
    function test_startsPaused() public {
        address[] memory os = new address[](1); os[0] = o1;
        Dynamic fresh = new Dynamic(admin, os, 1, treasury, 200, 0);
        assertTrue(fresh.paused());
    }

    function test_pausedBlocksNewLaunches() public {
        vm.prank(admin); dyn.setPaused(true);
        Dynamic.Params memory p = _params();
        vm.prank(team); vm.expectRevert(bytes("paused"));
        dyn.create(p);
    }

    function test_goalCapEnforced() public {
        vm.prank(admin); dyn.setMaxGoal(500e6);
        Dynamic.Params memory p = _params();
        vm.prank(team); vm.expectRevert(bytes("goal cap"));
        dyn.create(p);
    }

    function test_createTakesBondAndSnapshots() public {
        uint256 before = usdc.balanceOf(team);
        uint256 id = _create();
        Dynamic.Launch memory l = dyn.launch(id);
        assertEq(l.bond, 100e6);
        assertEq(l.threshold, 2);
        assertEq(l.feeBps, 200);
        assertEq(before - usdc.balanceOf(team), 100e6);
        assertTrue(dyn.launchOracle(id, o1));
    }

    function test_happyPathFeesBondAndReputation() public {
        uint256 id = _create(); _fund(id);
        _release(id);
        assertEq(usdc.balanceOf(team), 900e6 + 490e6);       // 500 tranche - 2% fee
        assertEq(usdc.balanceOf(treasury), 7_500_000);        // 75% of the 10 USDC fee
        assertEq(dyn.insurance(address(usdc)), 2_500_000);    // 25% kept as insurance
        _release(id);
        assertEq(usdc.balanceOf(team), 900e6 + 490e6 + 490e6 + 100e6); // bond returned at completion
        assertEq(uint256(dyn.launch(id).st), 3);              // Completed
        assertEq(dyn.rep(team), 1);
    }

    function test_communityRejectsChallengedMilestone() public {
        uint256 id = _create(); _fund(id); _claim(id, true);
        vm.startPrank(alice); usdc.approve(address(dyn), 25e6); dyn.challenge(id); dyn.vote(id, false); vm.stopPrank();
        vm.prank(bob); dyn.vote(id, true);
        vm.warp(block.timestamp + 72 hours + 1);
        uint256 aliceBefore = usdc.balanceOf(alice);
        dyn.resolve(id);
        assertEq(uint256(dyn.launch(id).st), 2);                         // Halted
        assertEq(usdc.balanceOf(alice) - aliceBefore, 75e6);              // stake 25 + half the bond 50
        assertEq(dyn.launch(id).refundable, 1050e6);
        vm.prank(alice); dyn.refund(id);
        vm.prank(bob); dyn.refund(id);
        assertEq(usdc.balanceOf(bob), 420e6);
    }

    function test_noVotesNoOracleApproval_isInconclusive() public {
        uint256 id = _create(); _fund(id); _claim(id, false);
        vm.startPrank(alice); usdc.approve(address(dyn), 25e6); dyn.challenge(id); vm.stopPrank();
        uint256 b = usdc.balanceOf(alice);
        vm.warp(block.timestamp + 72 hours + 1);
        dyn.resolve(id);
        assertEq(usdc.balanceOf(alice) - b, 25e6);                       // stake refunded
        assertEq(uint256(dyn.milestones(id)[0].st), 0);                  // Pending again
        assertEq(uint256(dyn.launch(id).st), 1);                         // still Active
    }

    function test_noVotesButOracleApproved_passesAndTeamKeepsStake() public {
        uint256 id = _create(); _fund(id); _claim(id, true);
        vm.startPrank(carol); usdc.approve(address(dyn), 25e6); dyn.challenge(id); vm.stopPrank();
        vm.warp(block.timestamp + 72 hours + 1);
        dyn.resolve(id);
        assertEq(usdc.balanceOf(team), 900e6 + 490e6 + 25e6);
    }

    function test_teamCanRetryAfterOracleTimeout() public {
        uint256 id = _create(); _fund(id);
        vm.prank(team); dyn.claimMilestone(id, "e");
        vm.prank(o1); dyn.attest(id, 80, bytes32(0));
        _pastWindow();
        vm.prank(team); dyn.claimMilestone(id, "e2");
        assertEq(dyn.milestones(id)[0].round, 1);
        assertFalse(dyn.hasAttested(id, 0, o1));
    }

    function test_deadlineHaltRefundsEscrowAndBond() public {
        uint256 id = _create(); uint256 t0 = _fund(id);
        vm.warp(t0 + 10 days + 1);
        dyn.failByDeadline(id);
        assertEq(dyn.launch(id).refundable, 1100e6);
        vm.prank(alice); dyn.refund(id);
        assertEq(usdc.balanceOf(alice), 100e6 + 660e6);
        vm.prank(alice); vm.expectRevert(bytes("none"));
        dyn.refund(id);
    }

    function test_insuranceTopsUpRefundAndTeamReclaimsUnvestedTokens() public {
        uint256 id = _create(); uint256 t0 = _fund(id);
        _release(id);
        vm.warp(t0 + 30 days + 1);
        dyn.failByDeadline(id);
        assertEq(dyn.launch(id).refundable, 500e6 + 100e6 + 2_500_000);
        assertEq(dyn.insurance(address(usdc)), 0);
        vm.prank(team); dyn.reclaimSale(id);
        assertEq(sale.balanceOf(team), 90_000e18);                       // 80,000 left + 10,000 unvested
    }

    function test_tokensVestWithReleasedFunds() public {
        uint256 id = _create(); _fund(id);
        vm.prank(alice); vm.expectRevert(bytes("nothing to claim"));
        dyn.claimTokens(id);
        _release(id);
        vm.prank(alice); dyn.claimTokens(id);
        assertEq(sale.balanceOf(alice), 6_000e18);
        vm.prank(alice); vm.expectRevert(bytes("nothing to claim"));
        dyn.claimTokens(id);
    }

    function test_adminCannotChangeOraclesOfExistingLaunch() public {
        uint256 id = _create(); _fund(id);
        address o4 = address(0x104);
        vm.startPrank(admin); dyn.addOracle(o4); dyn.removeOracle(o1); vm.stopPrank();
        vm.prank(team); dyn.claimMilestone(id, "e");
        vm.prank(o4); vm.expectRevert(bytes("not oracle"));
        dyn.attest(id, 99, bytes32(0));
        vm.prank(o1); dyn.attest(id, 80, bytes32(0));                    // snapshot still valid for this launch
    }

    function test_failedFundingReturnsBondAndRefunds() public {
        uint256 id = _create();
        _contribute(id, alice, 300e6);
        vm.warp(block.timestamp + 7 days + 1);
        dyn.closeFunding(id);
        assertEq(usdc.balanceOf(team), 1_000e6);                         // bond back
        vm.prank(alice); dyn.refund(id);
        assertEq(usdc.balanceOf(alice), 700e6);
    }

    /// Fuzz: whatever the contribution split, refunds after a halt never exceed the refundable pool.
    function testFuzz_haltRefundsStaySolvent(uint256 a) public {
        a = bound(a, 1e6, GOAL - 1e6);
        address x = address(0x501); address y = address(0x502);
        usdc.mint(x, a); usdc.mint(y, GOAL - a);
        uint256 id = _create();
        _contribute(id, x, a); _contribute(id, y, GOAL - a);
        vm.warp(block.timestamp + 10 days + 1);
        dyn.failByDeadline(id);
        vm.prank(x); dyn.refund(id);
        vm.prank(y); dyn.refund(id);
        uint256 total = usdc.balanceOf(x) + usdc.balanceOf(y);
        assertLe(total, 1100e6);
        assertGe(total, 1100e6 - 2);                                     // only rounding dust remains
    }
}
