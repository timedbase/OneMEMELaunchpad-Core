// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {
    AggregationExecutor,
    Step,
    Reentrancy,
    Paused,
    NotOwner,
    ZeroAddress,
    ZeroAmount,
    EmptyRoute,
    DeadlineExpired,
    RouterNotWhitelisted,
    InsufficientOutput,
    NativeSendFailed
} from "../src/AggregationExecutor.sol";
import {MockERC20}             from "./mocks/MockERC20.sol";
import {MockFOTToken}          from "./mocks/MockFOTToken.sol";
import {MockRouter,
        MockReentrantRouter,
        MockUnwhitelistedRouter} from "./mocks/MockRouter.sol";

contract AggregationExecutorTest is Test {

    // ─── Contracts under test ─────────────────────────────────────────────────
    AggregationExecutor executor;
    MockRouter          router;

    // ─── Tokens ───────────────────────────────────────────────────────────────
    MockERC20    tokenA;
    MockERC20    tokenB;
    MockERC20    tokenC;
    MockERC20    wbnb;       // mock WBNB
    MockFOTToken fotToken;   // 5 % transfer tax

    // ─── Actors ───────────────────────────────────────────────────────────────
    address owner     = address(this);
    address user      = makeAddr("user");
    address recipient = makeAddr("recipient");
    address taxBucket = makeAddr("taxBucket");

    uint256 constant MAX_DEADLINE = type(uint256).max;
    uint256 constant FOT_BPS      = 500; // 5 %

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        wbnb     = new MockERC20("Wrapped BNB", "WBNB", 18);
        executor = new AggregationExecutor(address(wbnb), owner);
        router   = new MockRouter();

        tokenA   = new MockERC20("Token A", "TKA", 18);
        tokenB   = new MockERC20("Token B", "TKB", 18);
        tokenC   = new MockERC20("Token C", "TKC", 18);
        fotToken = new MockFOTToken("FeeToken", "FOT", 18, FOT_BPS, taxBucket);

        // Whitelist the mock router
        executor.addTarget(address(router));

        // Give router liquidity for output tokens
        tokenB.mint(address(router), 1_000 ether);
        tokenC.mint(address(router), 1_000 ether);

        // Give the router BNB for native-out tests
        vm.deal(address(router), 100 ether);

        // Fund user
        tokenA.mint(user, 1_000 ether);
        fotToken.mint(user, 1_000 ether);
        vm.deal(user, 100 ether);

        // User pre-approves executor (unlimited for simplicity)
        vm.startPrank(user);
        tokenA.approve(address(executor), type(uint256).max);
        fotToken.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Build a Step that calls router.swapTokens(tokenIn, amountIn, tokenOut, amountOut).
    function _tokenSwapStep(
        address tkIn,
        uint256 amtIn,
        address tkOut,
        uint256 amtOut,
        uint256 minDelta
    ) internal view returns (Step memory) {
        return Step({
            target:       address(router),
            value:        0,
            callData:     abi.encodeCall(router.swapTokens, (tkIn, amtIn, tkOut, amtOut)),
            approveToken: tkIn,
            approveAmt:   amtIn,
            tokenOut:     tkOut,
            minDelta:     minDelta
        });
    }

    /// @dev Build a Step for native BNB out.
    function _tokenToBNBStep(
        address tkIn,
        uint256 amtIn,
        uint256 bnbOut,
        uint256 minDelta
    ) internal view returns (Step memory) {
        return Step({
            target:       address(router),
            value:        0,
            callData:     abi.encodeCall(router.swapTokensForBNB, (tkIn, amtIn, bnbOut)),
            approveToken: tkIn,
            approveAmt:   amtIn,
            tokenOut:     address(0),   // native BNB output
            minDelta:     minDelta
        });
    }

    /// @dev Build a Step for native BNB in (payable router call).
    function _bnbToTokenStep(
        uint256 bnbIn,
        address tkOut,
        uint256 amtOut,
        uint256 minDelta
    ) internal view returns (Step memory) {
        return Step({
            target:       address(router),
            value:        bnbIn,
            callData:     abi.encodeCall(router.swapBNBForTokens, (tkOut, amtOut)),
            approveToken: address(0),
            approveAmt:   0,
            tokenOut:     tkOut,
            minDelta:     minDelta
        });
    }

    function _encode(Step memory step) internal pure returns (bytes memory) {
        Step[] memory steps = new Step[](1);
        steps[0] = step;
        return abi.encode(steps);
    }

    function _encode(Step[] memory steps) internal pure returns (bytes memory) {
        return abi.encode(steps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Standard ERC-20 single-hop swap
    // ─────────────────────────────────────────────────────────────────────────

    function test_swapStandardERC20() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;

        Step memory step = _tokenSwapStep(
            address(tokenA), amtIn, address(tokenB), amtOut, amtOut
        );

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn,
            address(tokenB), amtOut,
            recipient, MAX_DEADLINE,
            _encode(step)
        );

        assertEq(received, amtOut, "amountOut mismatch");
        assertEq(tokenB.balanceOf(recipient), amtOut, "recipient balance wrong");
        assertEq(tokenA.balanceOf(user), 1_000 ether - amtIn, "user tokenA not pulled");
        // Executor should hold nothing after execution
        assertEq(tokenA.balanceOf(address(executor)), 0, "executor holds tokenA dust");
        assertEq(tokenB.balanceOf(address(executor)), 0, "executor holds tokenB dust");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Fee-on-transfer token
    // ─────────────────────────────────────────────────────────────────────────

    function test_swapFOT_balanceDeltaAccounting() public {
        uint256 nominal  = 100 ether;
        // After 5 % tax on transferFrom: executor receives 95 ether
        uint256 actualIn = (nominal * (10_000 - FOT_BPS)) / 10_000; // 95 ether
        // Router gives back 90 tokenB for 95 FOT received
        uint256 amtOut   = 90 ether;

        // Router must be able to transferFrom the FOT token from executor
        // (no extra tax on executor→router — router gets full amount because
        // the approve amount matches what executor holds)
        Step memory step = _tokenSwapStep(
            address(fotToken), actualIn, address(tokenB), amtOut, amtOut
        );

        vm.prank(user);
        uint256 received = executor.execute(
            address(fotToken), nominal,        // pull 100 nominal; actually receive 95
            address(tokenB),   amtOut,         // expect 90 tokenB
            recipient, MAX_DEADLINE,
            _encode(step)
        );

        assertEq(received, amtOut);
        assertEq(tokenB.balanceOf(recipient), amtOut);
        // Executor's FOT balance should be 0 (gave 95 to router)
        assertEq(fotToken.balanceOf(address(executor)), 0);
    }

    function test_swapFOT_slippage_reverts() public {
        // If the FOT tax reduces actualIn and the offchain step was built
        // with the un-taxed amount, the approve will partially fail (not enough
        // tokens) and the router will revert.  We just verify the revert bubbles.
        uint256 nominal = 100 ether;

        // Deliberately use the nominal amount — router will fail because executor
        // only has 95 tokens after pull, but we're trying to approve 100
        // (the approve itself succeeds, but transferFrom in the router will fail
        //  because executor only holds 95 tokens)
        Step memory step = Step({
            target:       address(router),
            value:        0,
            callData:     abi.encodeCall(
                router.swapTokens, (address(fotToken), nominal, address(tokenB), 90 ether)
            ),
            approveToken: address(fotToken),
            approveAmt:   nominal,            // too large — executor only has 95
            tokenOut:     address(tokenB),
            minDelta:     1
        });

        vm.prank(user);
        // The router's transferFrom will fail (insufficient executor balance)
        vm.expectRevert();
        executor.execute(
            address(fotToken), nominal,
            address(tokenB),   1,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Multi-step: Token A → Token B → Token C
    // ─────────────────────────────────────────────────────────────────────────

    function test_multiStep() public {
        tokenC.mint(address(router), 500 ether);
        // Seed the router with tokenC for the second hop
        uint256 amtIn   = 100 ether;
        uint256 midAmt  = 90 ether;  // A→B
        uint256 finalAmt = 81 ether; // B→C

        Step[] memory steps = new Step[](2);
        // Step 0: A→B
        steps[0] = _tokenSwapStep(address(tokenA), amtIn,  address(tokenB), midAmt,   midAmt);
        // Step 1: B→C (approveAmt = actual received from step 0)
        steps[1] = _tokenSwapStep(address(tokenB), midAmt, address(tokenC), finalAmt, finalAmt);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn,
            address(tokenC), finalAmt,
            recipient, MAX_DEADLINE,
            _encode(steps)
        );

        assertEq(received, finalAmt);
        assertEq(tokenC.balanceOf(recipient), finalAmt);
        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
        assertEq(tokenC.balanceOf(address(executor)), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Native BNB in → Token out
    // ─────────────────────────────────────────────────────────────────────────

    function test_nativeBNBIn() public {
        uint256 bnbIn  = 1 ether;
        uint256 amtOut = 300 ether;
        tokenB.mint(address(router), amtOut);

        Step memory step = _bnbToTokenStep(bnbIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.execute{value: bnbIn}(
            address(0), bnbIn,
            address(tokenB), amtOut,
            recipient, MAX_DEADLINE,
            _encode(step)
        );

        assertEq(received, amtOut);
        assertEq(tokenB.balanceOf(recipient), amtOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Token in → Native BNB out
    // ─────────────────────────────────────────────────────────────────────────

    function test_tokenInNativeBNBOut() public {
        uint256 amtIn  = 100 ether;
        uint256 bnbOut = 1 ether;

        Step memory step = _tokenToBNBStep(address(tokenA), amtIn, bnbOut, bnbOut);

        uint256 recipientBefore = recipient.balance;

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn,
            address(0),     bnbOut,
            recipient, MAX_DEADLINE,
            _encode(step)
        );

        assertEq(received, bnbOut);
        assertEq(recipient.balance - recipientBefore, bnbOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Multi-step: Token → WBNB (via router) → unwrap to BNB (WBNB.withdraw)
    //    Simulated without real WBNB — exercises native-output step formula
    // ─────────────────────────────────────────────────────────────────────────

    function test_multiStep_nativeBNBBridge() public {
        // Simulate: TokenA → tokenB (router), then tokenB → native BNB (router)
        uint256 amtIn   = 100 ether;
        uint256 midAmt  = 90 ether;
        uint256 bnbOut  = 1 ether;

        tokenB.mint(address(router), midAmt);

        Step[] memory steps = new Step[](2);
        steps[0] = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), midAmt, midAmt);
        steps[1] = _tokenToBNBStep(address(tokenB), midAmt, bnbOut, bnbOut);

        uint256 recipBefore = recipient.balance;

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn,
            address(0),     bnbOut,
            recipient, MAX_DEADLINE,
            _encode(steps)
        );

        assertEq(received, bnbOut);
        assertEq(recipient.balance - recipBefore, bnbOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. Slippage protection — final minAmountOut
    // ─────────────────────────────────────────────────────────────────────────

    function test_insufficientFinalOutput_reverts() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 minOut = 95 ether; // higher than what router gives

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, amtOut, minOut));
        executor.execute(
            address(tokenA), amtIn,
            address(tokenB), minOut,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. Per-step minDelta enforcement
    // ─────────────────────────────────────────────────────────────────────────

    function test_stepMinDelta_reverts() public {
        uint256 amtIn     = 100 ether;
        uint256 amtOut    = 90 ether;
        uint256 minDelta  = 95 ether; // step demands more than router gives

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, minDelta);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, amtOut, minDelta));
        executor.execute(
            address(tokenA), amtIn,
            address(tokenB), 1,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Deadline expired
    // ─────────────────────────────────────────────────────────────────────────

    function test_deadlineExpired_reverts() public {
        uint256 past = block.timestamp - 1;
        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);

        vm.prank(user);
        vm.expectRevert(DeadlineExpired.selector);
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 1,
            recipient, past,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. Empty route
    // ─────────────────────────────────────────────────────────────────────────

    function test_emptyRoute_reverts() public {
        Step[] memory steps = new Step[](0);

        vm.prank(user);
        vm.expectRevert(EmptyRoute.selector);
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 1,
            recipient, MAX_DEADLINE,
            _encode(steps)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. Whitelist enforcement — non-whitelisted target
    // ─────────────────────────────────────────────────────────────────────────

    function test_nonWhitelistedTarget_reverts() public {
        MockUnwhitelistedRouter bad = new MockUnwhitelistedRouter();

        Step memory step = Step({
            target:       address(bad),
            value:        0,
            callData:     abi.encodeCall(bad.doSomething, ()),
            approveToken: address(0),
            approveAmt:   0,
            tokenOut:     address(tokenB),
            minDelta:     0
        });

        tokenA.mint(address(executor), 1); // executor has some tokens

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(bad)));
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 0,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. Router revert bubbling
    // ─────────────────────────────────────────────────────────────────────────

    function test_routerRevert_bubbles() public {
        string memory reason = "PancakeSwap: K";

        Step memory step = Step({
            target:       address(router),
            value:        0,
            callData:     abi.encodeCall(router.revertWith, (reason)),
            approveToken: address(0),
            approveAmt:   0,
            tokenOut:     address(tokenB),
            minDelta:     0
        });

        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        vm.prank(user);
        // The string revert from the router should propagate exactly
        vm.expectRevert(bytes(reason));
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 0,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 13. Pause / unpause
    // ─────────────────────────────────────────────────────────────────────────

    function test_pause_blocksExecution() public {
        executor.pause();
        assertTrue(executor.isPaused());

        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);

        vm.prank(user);
        vm.expectRevert(Paused.selector);
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 1,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    function test_unpause_restoressExecution() public {
        executor.pause();
        executor.unpause();
        assertFalse(executor.isPaused());

        uint256 amtIn = 10 ether;
        uint256 amtOut = 9 ether;
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        executor.execute(
            address(tokenA), amtIn,
            address(tokenB), amtOut,
            recipient, MAX_DEADLINE,
            _encode(step)
        );

        assertEq(tokenB.balanceOf(recipient), amtOut);
    }

    function test_onlyOwner_canPause() public {
        vm.prank(user);
        vm.expectRevert(NotOwner.selector);
        executor.pause();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 14. Reentrancy guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_reentrancyGuard() public {
        // Build calldata for the outer execute call (will be used as reentrant call)
        Step[] memory innerSteps = new Step[](0); // will revert EmptyRoute, doesn't matter
        bytes memory innerExecData = abi.encode(innerSteps);
        bytes memory reentrantCalldata = abi.encodeCall(
            executor.execute,
            (address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, innerExecData)
        );

        MockReentrantRouter reentranter = new MockReentrantRouter(
            address(executor),
            reentrantCalldata
        );
        executor.addTarget(address(reentranter));
        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        Step memory step = Step({
            target:       address(reentranter),
            value:        0,
            callData:     hex"",          // fallback is triggered by empty calldata
            approveToken: address(0),
            approveAmt:   0,
            tokenOut:     address(tokenB),
            minDelta:     0
        });

        // The reentrant router's fallback calls executor.execute again;
        // it asserts that the inner call fails (!ok).  The outer execute
        // continues but the step's minDelta = 0 so it doesn't revert.
        // The key test: no reentrancy breach occurs; the guard works.
        vm.prank(user);
        // minAmountOut = 0 so final output check passes even with 0 tokenB
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 0,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 15. Access control on admin functions
    // ─────────────────────────────────────────────────────────────────────────

    function test_addTarget_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(NotOwner.selector);
        executor.addTarget(address(0x1234));
    }

    function test_removeTarget_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(NotOwner.selector);
        executor.removeTarget(address(router));
    }

    function test_addTarget_zeroAddress_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        executor.addTarget(address(0));
    }

    function test_removeTarget_disablesRouter() public {
        executor.removeTarget(address(router));
        assertFalse(executor.allowedTargets(address(router)));

        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);
        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(router)));
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 1,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 16. Emergency rescue
    // ─────────────────────────────────────────────────────────────────────────

    function test_rescueToken() public {
        uint256 stuck = 50 ether;
        tokenA.mint(address(executor), stuck);

        executor.rescueToken(address(tokenA), owner, stuck);
        assertEq(tokenA.balanceOf(owner), stuck);
        assertEq(tokenA.balanceOf(address(executor)), 0);
    }

    function test_rescueNative() public {
        vm.deal(address(executor), 2 ether);

        address payable sink = payable(makeAddr("nativeSink"));
        uint256 before = sink.balance;
        executor.rescueNative(sink, 2 ether);
        assertEq(sink.balance - before, 2 ether);
    }

    function test_rescueToken_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(NotOwner.selector);
        executor.rescueToken(address(tokenA), user, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 17. Ownership transfer (two-step)
    // ─────────────────────────────────────────────────────────────────────────

    function test_transferOwnership_twoStep() public {
        executor.transferOwnership(user);
        assertEq(executor.pendingOwner(), user);
        assertEq(executor.owner(), owner);       // not transferred yet

        vm.prank(user);
        executor.acceptOwnership();

        assertEq(executor.owner(), user);
        assertEq(executor.pendingOwner(), address(0));
    }

    function test_acceptOwnership_wrongCaller_reverts() public {
        executor.transferOwnership(user);

        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("NotPendingOwner()")))
        );
        executor.acceptOwnership();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 18. Zero amount input reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_zeroAmountIn_erc20_reverts() public {
        // transferFrom 0 tokens → balanceDelta = 0 → ZeroAmount
        Step memory step = _tokenSwapStep(address(tokenA), 0, address(tokenB), 0, 0);

        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        executor.execute(
            address(tokenA), 0,
            address(tokenB), 0,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    function test_zeroMsgValue_native_reverts() public {
        Step memory step = _bnbToTokenStep(0, address(tokenB), 0, 0);

        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        executor.execute{value: 0}(
            address(0), 0,
            address(tokenB), 0,
            recipient, MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 19. Zero recipient reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_zeroRecipient_reverts() public {
        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);
        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        vm.prank(user);
        vm.expectRevert(ZeroAddress.selector);
        executor.execute(
            address(tokenA), 1,
            address(tokenB), 1,
            address(0),       // zero recipient
            MAX_DEADLINE,
            _encode(step)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 20. addTargets batch
    // ─────────────────────────────────────────────────────────────────────────

    function test_addTargets_batch() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory targets = new address[](2);
        targets[0] = a;
        targets[1] = b;
        executor.addTargets(targets);
        assertTrue(executor.allowedTargets(a));
        assertTrue(executor.allowedTargets(b));
    }

    function test_addTargets_zeroInBatch_reverts() public {
        address[] memory targets = new address[](2);
        targets[0] = makeAddr("good");
        targets[1] = address(0); // bad

        vm.expectRevert(ZeroAddress.selector);
        executor.addTargets(targets);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 21. Rebasing token edge case
    //     Simulated by manually adjusting balanceOf mid-execution via a mock
    //     that inflates/deflates the reported balance.
    // ─────────────────────────────────────────────────────────────────────────

    function test_rebasingToken_balanceDeltaSafe() public {
        // Use a standard token but verify that if the router gives back MORE
        // than minDelta, the extra is forwarded to recipient (not silently dropped).
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 110 ether; // router gives back MORE (e.g. rebase happened)
        tokenB.mint(address(router), amtOut);

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, 100 ether);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn,
            address(tokenB), 100 ether,
            recipient, MAX_DEADLINE,
            _encode(step)
        );

        // All 110 ether must reach recipient — executor keeps nothing
        assertEq(received, 110 ether);
        assertEq(tokenB.balanceOf(recipient), 110 ether);
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 22. Approval is reset to zero after step
    // ─────────────────────────────────────────────────────────────────────────

    function test_approvalResetAfterStep() public {
        uint256 amtIn = 100 ether;
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), 90 ether, 90 ether);

        vm.prank(user);
        executor.execute(
            address(tokenA), amtIn,
            address(tokenB), 90 ether,
            recipient, MAX_DEADLINE,
            _encode(step)
        );

        // Allowance from executor → router must be zero after execution
        assertEq(tokenA.allowance(address(executor), address(router)), 0, "approval not reset");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 23. Executor constructor guards
    // ─────────────────────────────────────────────────────────────────────────

    function test_constructor_zeroWBNB_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new AggregationExecutor(address(0), owner);
    }

    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new AggregationExecutor(address(wbnb), address(0));
    }
}
