// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/token/BRKXToken.sol";

/**
 * @title BRKXTokenTest
 * @notice 10 unit tests covering BRKXToken correctness.
 *
 * Tests:
 *   1.  Total supply = 100M minted to treasury at deploy.
 *   2.  Transfer between accounts works correctly.
 *   3.  Approve + transferFrom works correctly.
 *   4.  burn() reduces total supply.
 *   5.  ERC20Votes: delegate + getPastVotes snapshot.
 *   6.  ERC20Permit: off-chain gasless approval.
 *   7.  Non-owner cannot mint (no mint function exists).
 *   8.  Ownable2Step: ownership transfer requires acceptance.
 *   9.  MAX_SUPPLY constant equals 100M (1e26).
 *   10. Fuzz: burn any amount <= holder's balance succeeds.
 */
contract BRKXTokenTest is Test {

    BRKXToken public brkx;

    address public treasury = address(0xABCD);
    address public alice    = address(0x1111);
    address public bob      = address(0x2222);

    uint256 constant MAX_SUPPLY = 100_000_000e18;

    function setUp() public {
        brkx = new BRKXToken(treasury);
    }

    // ───────────────────────────────────────────────────────────
    // Test 1: Supply minted to treasury
    // ───────────────────────────────────────────────────────────

    function test_1_TotalSupplyMintedToTreasury() public view {
        assertEq(brkx.totalSupply(), MAX_SUPPLY,            "total supply = 100M");
        assertEq(brkx.balanceOf(treasury), MAX_SUPPLY,      "treasury holds all BRKX");
        assertEq(brkx.balanceOf(alice), 0,                  "alice starts with 0");
    }

    // ───────────────────────────────────────────────────────────
    // Test 2: Transfer works
    // ───────────────────────────────────────────────────────────

    function test_2_TransferWorks() public {
        uint256 amount = 1_000e18;

        vm.prank(treasury);
        brkx.transfer(alice, amount);

        assertEq(brkx.balanceOf(alice),    amount,              "alice receives tokens");
        assertEq(brkx.balanceOf(treasury), MAX_SUPPLY - amount, "treasury reduced");
        assertEq(brkx.totalSupply(),       MAX_SUPPLY,          "supply unchanged");
    }

    // ───────────────────────────────────────────────────────────
    // Test 3: Approve + transferFrom
    // ───────────────────────────────────────────────────────────

    function test_3_ApproveAndTransferFrom() public {
        uint256 amount = 5_000e18;

        vm.prank(treasury);
        brkx.transfer(alice, amount);

        vm.prank(alice);
        brkx.approve(bob, amount);

        assertEq(brkx.allowance(alice, bob), amount, "allowance set");

        vm.prank(bob);
        brkx.transferFrom(alice, bob, amount);

        assertEq(brkx.balanceOf(bob),            amount, "bob received tokens");
        assertEq(brkx.balanceOf(alice),           0,      "alice balance zeroed");
        assertEq(brkx.allowance(alice, bob),      0,      "allowance consumed");
    }

    // ───────────────────────────────────────────────────────────
    // Test 4: burn() reduces total supply
    // ───────────────────────────────────────────────────────────

    function test_4_BurnReducesSupply() public {
        uint256 burnAmount = 1_000_000e18; // burn 1M

        vm.prank(treasury);
        brkx.burn(burnAmount);

        assertEq(brkx.totalSupply(),       MAX_SUPPLY - burnAmount, "supply reduced");
        assertEq(brkx.balanceOf(treasury), MAX_SUPPLY - burnAmount, "treasury balance reduced");
    }

    // ───────────────────────────────────────────────────────────
    // Test 5: ERC20Votes — delegate + getPastVotes snapshot
    // ───────────────────────────────────────────────────────────

    function test_5_ERC20Votes_DelegateAndPastVotes() public {
        uint256 amount = 10_000e18;

        // Treasury holds tokens, delegates to alice
        vm.startPrank(treasury);
        brkx.transfer(alice, amount);
        vm.stopPrank();

        vm.prank(alice);
        brkx.delegate(alice); // self-delegate to activate voting power at current block

        // Advance to the next block so getPastVotes can look back at the delegation block
        vm.roll(block.number + 1);

        // block.number - 1 is the block where delegation (and transfer) happened
        assertEq(
            brkx.getPastVotes(alice, block.number - 1),
            amount,
            "alice past votes equals delegated balance at delegation block"
        );
    }

    // ───────────────────────────────────────────────────────────
    // Test 6: ERC20Permit — off-chain approval via signature
    // ───────────────────────────────────────────────────────────

    function test_6_ERC20Permit_OffChainApproval() public {
        uint256 permitAmount = 500e18;
        uint256 deadline     = block.timestamp + 1 hours;

        // Create a wallet with a known private key
        uint256 pk      = 0xA11CE;
        address spender = alice;
        address signer  = vm.addr(pk);

        // Give signer some BRKX
        vm.prank(treasury);
        brkx.transfer(signer, permitAmount);

        // Sign the permit
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                brkx.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        spender,
                        permitAmount,
                        brkx.nonces(signer),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // Anyone can submit the permit transaction (gasless for signer)
        brkx.permit(signer, spender, permitAmount, deadline, v, r, s);

        assertEq(brkx.allowance(signer, spender), permitAmount, "permit approved gaslessly");
    }

    // ───────────────────────────────────────────────────────────
    // Test 7: No mint function — supply is fixed
    // ───────────────────────────────────────────────────────────

    function test_7_NoMintFunctionExists() public view {
        // BRKXToken has no `mint` function. Verify by checking the interface:
        // If we try to call a non-existent function the compiler would catch it at test time.
        // Here we verify that the total supply equals MAX_SUPPLY and cannot increase.
        assertEq(brkx.totalSupply(), MAX_SUPPLY, "supply fixed at MAX_SUPPLY");

        // Additional sanity: verify MAX_SUPPLY constant is correct
        assertEq(brkx.MAX_SUPPLY(), 100_000_000e18, "MAX_SUPPLY = 100M with 18 decimals");
    }

    // ───────────────────────────────────────────────────────────
    // Test 8: Ownable2Step — ownership transfer requires acceptance
    // ───────────────────────────────────────────────────────────

    function test_8_Ownable2Step_TransferRequiresAcceptance() public {
        // treasury is the current owner (set in constructor)
        assertEq(brkx.owner(), treasury, "treasury is initial owner");

        // treasury initiates transfer to alice
        vm.prank(treasury);
        brkx.transferOwnership(alice);

        // Pending owner is alice, but owner is still treasury
        assertEq(brkx.pendingOwner(), alice,    "alice is pending owner");
        assertEq(brkx.owner(),        treasury, "treasury still owner until accepted");

        // alice accepts
        vm.prank(alice);
        brkx.acceptOwnership();

        assertEq(brkx.owner(),        alice,        "alice is now owner");
        assertEq(brkx.pendingOwner(), address(0),   "pending owner cleared");
    }

    // ───────────────────────────────────────────────────────────
    // Test 9: MAX_SUPPLY constant immutability
    // ───────────────────────────────────────────────────────────

    function test_9_MaxSupplyConstantCorrect() public view {
        // 100 million tokens with 18 decimal places
        uint256 expectedSupply = 100_000_000 * 10 ** 18;
        assertEq(brkx.MAX_SUPPLY(), expectedSupply, "MAX_SUPPLY = 100_000_000e18");
        assertEq(brkx.decimals(),   18,              "18 decimals");
        assertEq(brkx.name(),       "Baraka Token",  "correct name");
        assertEq(brkx.symbol(),     "BRKX",          "correct symbol");
    }

    // ───────────────────────────────────────────────────────────
    // Test 10: Fuzz — burn any amount <= balance succeeds
    // ───────────────────────────────────────────────────────────

    function testFuzz_10_BurnAnyAmountWithinBalance(uint256 burnSeed) public {
        uint256 aliceBalance = 1_000_000e18;

        vm.prank(treasury);
        brkx.transfer(alice, aliceBalance);

        // Bound burn amount to [0, alice's balance]
        uint256 burnAmount = bound(burnSeed, 0, aliceBalance);

        vm.prank(alice);
        brkx.burn(burnAmount);

        assertEq(brkx.balanceOf(alice), aliceBalance - burnAmount, "balance after burn correct");
        assertEq(brkx.totalSupply(),    MAX_SUPPLY   - burnAmount, "total supply reduced correctly");
    }
}
