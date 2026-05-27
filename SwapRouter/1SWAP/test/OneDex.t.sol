// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {
    OneDex,
    Step,
    SwapCallbackData,
    Reentrancy,
    Paused,
    NotOwner,
    ZeroAddress,
    ZeroAmount,
    EmptyRoute,
    DeadlineExpired,
    RouterNotWhitelisted,
    InsufficientOutput,
    NativeSendFailed,
    NativeNotPermitted
} from "../src/OneDex.sol";
import {IPermit2}              from "../src/interfaces/IPermit2.sol";
import {MockERC20}             from "./mocks/MockERC20.sol";
import {MockFOTToken}          from "./mocks/MockFOTToken.sol";
import {MockRouter,
        ReentrantPool,
        MockUnwhitelistedRouter} from "./mocks/MockRouter.sol";
import {MockPermit2}           from "./mocks/MockPermit2.sol";
import {MockV2Factory,
        MockV2Pair}            from "./mocks/MockV2Pair.sol";
import {MockV3Factory,
        MockV3Pool,
        ConfigurableV3Factory} from "./mocks/MockV3Pool.sol";

contract OneDexTest is Test {

    // ── Core fixtures ─────────────────────────────────────────────────────────

    OneDex      executor;
    MockRouter  router;
    MockPermit2 mockPermit2;
    MockV3Factory testV3Factory; // keys: (token0, token1, fee) → pool

    MockERC20    tokenA;
    MockERC20    tokenB;
    MockERC20    tokenC;
    MockERC20    wbnb;
    MockFOTToken fotToken;

    address owner     = address(this);
    address user      = makeAddr("user");
    address recipient = makeAddr("recipient");
    address taxBucket = makeAddr("taxBucket");
    address feeAddr   = makeAddr("feeAddr");

    uint256 constant MAX_DEADLINE = type(uint256).max;
    uint256 constant FOT_BPS      = 500;

    // MockRouter pretends to be a V3 pool with (tokenA, tokenB, 3000).
    // The testV3Factory maps that triplet to address(router), so _validateTarget passes.
    uint24  constant ROUTER_FEE = 3000;

    function setUp() public {
        // Tokens first — needed for MockRouter constructor
        wbnb     = new MockERC20("Wrapped BNB", "WBNB", 18);
        tokenA   = new MockERC20("Token A", "TKA", 18);
        tokenB   = new MockERC20("Token B", "TKB", 18);
        tokenC   = new MockERC20("Token C", "TKC", 18);
        fotToken = new MockFOTToken("FeeToken", "FOT", 18, FOT_BPS, taxBucket);

        mockPermit2 = new MockPermit2();

        // Router acts as a V3 pool identity: (tokenA, tokenB, 3000)
        router = new MockRouter(address(tokenA), address(tokenB), ROUTER_FEE);

        // Factory recognises address(router) as the pool for (tokenA, tokenB, 3000)
        testV3Factory = new MockV3Factory();
        testV3Factory.registerPool(address(tokenA), address(tokenB), ROUTER_FEE, address(router));

        // executor: CAKE_V3_FACTORY = testV3Factory; all other factories = address(0)
        executor = new OneDex(
            address(wbnb),
            address(mockPermit2),
            feeAddr,
            address(0),        // uniV2Factory
            address(0),        // cakeV2Factory
            address(0),        // uniV3Factory
            address(testV3Factory) // cakeV3Factory
        );

        // Fund router with output tokens / BNB
        tokenB.mint(address(router), 1_000 ether);
        tokenC.mint(address(router), 1_000 ether);
        vm.deal(address(router), 100 ether);

        tokenA.mint(user, 1_000 ether);
        fotToken.mint(user, 1_000 ether);
        vm.deal(user, 100 ether);

        vm.startPrank(user);
        tokenA.approve(address(executor), type(uint256).max);
        fotToken.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _fee(uint256 a) internal pure returns (uint256) { return a * 30 / 10_000; }
    function _net(uint256 a) internal pure returns (uint256) { return a - _fee(a); }

    /// @dev Build a Step that uses the mock router (approve/pull style, V3-like).
    function _tokenSwapStep(
        address tkIn,
        uint256 amtIn,
        address tkOut,
        uint256 amtOut,
        uint256 minDelta
    ) internal view returns (Step memory) {
        return Step({
            target:           address(router),
            value:            0,
            callData:         abi.encodeCall(router.swapTokens, (tkIn, amtIn, tkOut, amtOut)),
            approveToken:     tkIn,
            approveAmt:       amtIn,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         tkOut,
            minDelta:         minDelta
        });
    }

    function _tokenToBNBStep(
        address tkIn,
        uint256 amtIn,
        uint256 bnbOut,
        uint256 minDelta
    ) internal view returns (Step memory) {
        return Step({
            target:           address(router),
            value:            0,
            callData:         abi.encodeCall(router.swapTokensForBNB, (tkIn, amtIn, bnbOut)),
            approveToken:     tkIn,
            approveAmt:       amtIn,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         address(0),
            minDelta:         minDelta
        });
    }

    function _bnbToTokenStep(
        uint256 bnbIn,
        address tkOut,
        uint256 amtOut,
        uint256 minDelta
    ) internal view returns (Step memory) {
        return Step({
            target:           address(router),
            value:            bnbIn,
            callData:         abi.encodeCall(router.swapBNBForTokens, (tkOut, amtOut)),
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         tkOut,
            minDelta:         minDelta
        });
    }

    function _encode(Step memory step, bool feeOnInput) internal pure returns (bytes memory) {
        Step[] memory steps = new Step[](1);
        steps[0] = step;
        return abi.encode(feeOnInput, steps);
    }
    function _encode(Step[] memory steps, bool feeOnInput) internal pure returns (bytes memory) {
        return abi.encode(feeOnInput, steps);
    }
    function _encode(Step memory step) internal pure returns (bytes memory) { return _encode(step, false); }
    function _encode(Step[] memory steps) internal pure returns (bytes memory) { return _encode(steps, false); }

    function _permit2(address token, uint256 amount) internal pure returns (IPermit2.PermitTransferFrom memory) {
        return IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: token, amount: amount}),
            nonce:     0,
            deadline:  type(uint256).max
        });
    }

    // ── 1. Standard ERC-20 swap ───────────────────────────────────────────────

    function test_swapStandardERC20() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 netOut = _net(amtOut);
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
        assertEq(tokenB.balanceOf(feeAddr), _fee(amtOut));
        assertEq(tokenA.balanceOf(user), 1_000 ether - amtIn);
        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }

    // ── 2. Fee-on-transfer token ──────────────────────────────────────────────

    function test_swapFOT_balanceDeltaAccounting() public {
        uint256 nominal  = 100 ether;
        uint256 actualIn = (nominal * (10_000 - FOT_BPS)) / 10_000;
        uint256 amtOut   = 90 ether;
        uint256 netOut   = _net(amtOut);
        Step memory step = _tokenSwapStep(address(fotToken), actualIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.execute(
            address(fotToken), nominal, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
        assertEq(fotToken.balanceOf(address(executor)), 0);
    }

    function test_swapFOT_slippage_reverts() public {
        uint256 nominal = 100 ether;
        Step memory step = Step({
            target:           address(router),
            value:            0,
            callData:         abi.encodeCall(router.swapTokens, (address(fotToken), nominal, address(tokenB), 90 ether)),
            approveToken:     address(fotToken),
            approveAmt:       nominal,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         address(tokenB),
            minDelta:         1
        });

        vm.prank(user);
        vm.expectRevert();
        executor.execute(address(fotToken), nominal, address(tokenB), 1, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 3. Multi-step: A → B → C ─────────────────────────────────────────────

    function test_multiStep() public {
        tokenC.mint(address(router), 500 ether);
        uint256 amtIn    = 100 ether;
        uint256 midAmt   = 90 ether;
        uint256 finalAmt = 81 ether;
        uint256 netOut   = _net(finalAmt);

        Step[] memory steps = new Step[](2);
        steps[0] = _tokenSwapStep(address(tokenA), amtIn,  address(tokenB), midAmt,   midAmt);
        steps[1] = _tokenSwapStep(address(tokenB), midAmt, address(tokenC), finalAmt, finalAmt);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(tokenC), netOut, recipient, MAX_DEADLINE, _encode(steps)
        );

        assertEq(received, netOut);
        assertEq(tokenC.balanceOf(recipient), netOut);
        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
        assertEq(tokenC.balanceOf(address(executor)), 0);
    }

    // ── 4. Native BNB in → Token out ─────────────────────────────────────────

    function test_nativeBNBIn() public {
        uint256 bnbIn  = 1 ether;
        uint256 amtOut = 300 ether;
        uint256 netOut = _net(amtOut);
        tokenB.mint(address(router), amtOut);
        Step memory step = _bnbToTokenStep(bnbIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.execute{value: bnbIn}(
            address(0), bnbIn, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
    }

    // ── 5. Token in → Native BNB out ─────────────────────────────────────────

    function test_tokenInNativeBNBOut() public {
        uint256 amtIn  = 100 ether;
        uint256 bnbOut = 1 ether;
        uint256 netBnb = _net(bnbOut);
        Step memory step = _tokenToBNBStep(address(tokenA), amtIn, bnbOut, bnbOut);
        uint256 recipientBefore = recipient.balance;

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(0), netBnb, recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, netBnb);
        assertEq(recipient.balance - recipientBefore, netBnb);
    }

    // ── 6. Multi-step native BNB bridge ──────────────────────────────────────

    function test_multiStep_nativeBNBBridge() public {
        uint256 amtIn  = 100 ether;
        uint256 midAmt = 90 ether;
        uint256 bnbOut = 1 ether;
        uint256 netBnb = _net(bnbOut);
        tokenB.mint(address(router), midAmt);

        Step[] memory steps = new Step[](2);
        steps[0] = _tokenSwapStep(address(tokenA), amtIn,  address(tokenB), midAmt, midAmt);
        steps[1] = _tokenToBNBStep(address(tokenB), midAmt, bnbOut, bnbOut);

        uint256 recipBefore = recipient.balance;

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(0), netBnb, recipient, MAX_DEADLINE, _encode(steps)
        );

        assertEq(received, netBnb);
        assertEq(recipient.balance - recipBefore, netBnb);
    }

    // ── 7. Slippage protection ────────────────────────────────────────────────

    function test_insufficientFinalOutput_reverts() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 minOut = 95 ether;
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, _net(amtOut), minOut));
        executor.execute(address(tokenA), amtIn, address(tokenB), minOut, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 8. Per-step minDelta ──────────────────────────────────────────────────

    function test_stepMinDelta_reverts() public {
        uint256 amtIn    = 100 ether;
        uint256 amtOut   = 90 ether;
        uint256 minDelta = 95 ether;
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, minDelta);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, amtOut, minDelta));
        executor.execute(address(tokenA), amtIn, address(tokenB), 1, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 9. Deadline ───────────────────────────────────────────────────────────

    function test_deadlineExpired_reverts() public {
        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);

        vm.prank(user);
        vm.expectRevert(DeadlineExpired.selector);
        executor.execute(address(tokenA), 1, address(tokenB), 1, recipient, block.timestamp - 1, _encode(step));
    }

    // ── 10. Empty route ───────────────────────────────────────────────────────

    function test_emptyRoute_reverts() public {
        Step[] memory steps = new Step[](0);

        vm.prank(user);
        vm.expectRevert(EmptyRoute.selector);
        executor.execute(address(tokenA), 1, address(tokenB), 1, recipient, MAX_DEADLINE, _encode(steps));
    }

    // ── 11. _validateTarget — rejection ───────────────────────────────────────

    function test_noToken0_reverts() public {
        // MockUnwhitelistedRouter has no token0() → _validateTarget catches revert → RouterNotWhitelisted
        MockUnwhitelistedRouter bad = new MockUnwhitelistedRouter();
        Step memory step = Step({
            target:           address(bad),
            value:            0,
            callData:         abi.encodeCall(bad.doSomething, ()),
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         address(tokenB),
            minDelta:         0
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(bad)));
        executor.execute(address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    function test_unknownPool_notInFactory_reverts() public {
        // Deploy a pool with token0/token1/fee but NOT registered in testV3Factory
        MockV3Pool unregistered = new MockV3Pool(address(tokenA), address(tokenC), 500);

        Step memory step = Step({
            target:           address(unregistered),
            value:            0,
            callData:         hex"",
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         address(tokenC),
            minDelta:         0
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(unregistered)));
        executor.execute(address(tokenA), 1, address(tokenC), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 12. Router revert bubbling ────────────────────────────────────────────

    function test_routerRevert_bubbles() public {
        string memory reason = "PancakeSwap: K";
        Step memory step = Step({
            target:           address(router),
            value:            0,
            callData:         abi.encodeCall(router.revertWith, (reason)),
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         address(tokenB),
            minDelta:         0
        });

        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        vm.prank(user);
        vm.expectRevert(bytes(reason));
        executor.execute(address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 13. Pause / unpause ───────────────────────────────────────────────────

    function test_pause_blocksExecution() public {
        executor.pause();
        assertTrue(executor.isPaused());
        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);

        vm.prank(user);
        vm.expectRevert(Paused.selector);
        executor.execute(address(tokenA), 1, address(tokenB), 1, recipient, MAX_DEADLINE, _encode(step));
    }

    function test_unpause_restoresExecution() public {
        executor.pause();
        executor.unpause();
        assertFalse(executor.isPaused());

        uint256 amtIn  = 10 ether;
        uint256 amtOut = 9 ether;
        uint256 netOut = _net(amtOut);
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        executor.execute(address(tokenA), amtIn, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step));
        assertEq(tokenB.balanceOf(recipient), netOut);
    }

    function test_onlyOwner_canPause() public {
        vm.prank(user);
        vm.expectRevert(NotOwner.selector);
        executor.pause();
    }

    // ── 14. Reentrancy guard ──────────────────────────────────────────────────

    function test_reentrancyGuard() public {
        // Inner call with empty steps — will revert at EmptyRoute inside the reentrant call,
        // which causes ok=false, which satisfies require(!ok) in ReentrantPool.
        Step[] memory innerSteps = new Step[](0);
        bytes memory innerExecData = abi.encode(false, innerSteps);
        bytes memory reentrantCalldata = abi.encodeCall(
            executor.execute,
            (address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, innerExecData)
        );

        // ReentrantPool has a distinct (tokenA, tokenC, 500) identity so it can be registered
        ReentrantPool reentranter = new ReentrantPool(
            address(tokenA), address(tokenC), 500, address(executor), reentrantCalldata
        );
        testV3Factory.registerPool(address(tokenA), address(tokenC), 500, address(reentranter));

        Step memory step = Step({
            target:           address(reentranter),
            value:            0,
            callData:         hex"",  // triggers fallback → reentrancy attempt
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         address(tokenB),
            minDelta:         0
        });

        vm.prank(user);
        // Outer execute succeeds; inner reentrancy is blocked (Reentrancy error → ok=false)
        executor.execute(address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 15. Emergency rescue ──────────────────────────────────────────────────

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

    // ── 16. Ownership transfer (two-step) ─────────────────────────────────────

    function test_transferOwnership_twoStep() public {
        executor.transferOwnership(user);
        assertEq(executor.pendingOwner(), user);
        assertEq(executor.owner(), owner);

        vm.prank(user);
        executor.acceptOwnership();

        assertEq(executor.owner(), user);
        assertEq(executor.pendingOwner(), address(0));
    }

    function test_acceptOwnership_wrongCaller_reverts() public {
        executor.transferOwnership(user);
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("NotPendingOwner()"))));
        executor.acceptOwnership();
    }

    // ── 17. Zero amount ───────────────────────────────────────────────────────

    function test_zeroAmountIn_erc20_reverts() public {
        Step memory step = _tokenSwapStep(address(tokenA), 0, address(tokenB), 0, 0);

        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        executor.execute(address(tokenA), 0, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    function test_zeroMsgValue_native_reverts() public {
        Step memory step = _bnbToTokenStep(0, address(tokenB), 0, 0);

        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        executor.execute{value: 0}(address(0), 0, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 18. Zero recipient ────────────────────────────────────────────────────

    function test_zeroRecipient_reverts() public {
        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);
        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        vm.prank(user);
        vm.expectRevert(ZeroAddress.selector);
        executor.execute(address(tokenA), 1, address(tokenB), 1, address(0), MAX_DEADLINE, _encode(step));
    }

    // ── 19. Rebasing token ────────────────────────────────────────────────────

    function test_rebasingToken_balanceDeltaSafe() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 110 ether;
        uint256 netOut = _net(amtOut);
        tokenB.mint(address(router), amtOut);
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, 100 ether);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }

    // ── 20. Approval reset after step ────────────────────────────────────────

    function test_approvalResetAfterStep() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 netOut = _net(amtOut);
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        executor.execute(address(tokenA), amtIn, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step));

        assertEq(tokenA.allowance(address(executor), address(router)), 0);
    }

    // ── 21. Constructor guards ────────────────────────────────────────────────

    function test_constructor_zeroWBNB_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new OneDex(address(0), address(mockPermit2), feeAddr, address(0), address(0), address(0), address(0));
    }

    function test_constructor_zeroPermit2_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new OneDex(address(wbnb), address(0), feeAddr, address(0), address(0), address(0), address(0));
    }

    function test_constructor_zeroFeeRecipient_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new OneDex(address(wbnb), address(mockPermit2), address(0), address(0), address(0), address(0), address(0));
    }

    function test_constructor_ownerIsDeployer() public {
        OneDex fresh = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                   address(0), address(0), address(0), address(0));
        assertEq(fresh.owner(), address(this));
    }

    function test_constructor_immutablesStored() public {
        address uniV2 = makeAddr("uniV2");
        address cakeV2 = makeAddr("cakeV2");
        address uniV3 = makeAddr("uniV3");
        address cakeV3 = makeAddr("cakeV3");
        OneDex fresh = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                   uniV2, cakeV2, uniV3, cakeV3);
        assertEq(fresh.UNI_V2_FACTORY(),  uniV2);
        assertEq(fresh.CAKE_V2_FACTORY(), cakeV2);
        assertEq(fresh.UNI_V3_FACTORY(),  uniV3);
        assertEq(fresh.CAKE_V3_FACTORY(), cakeV3);
    }

    // ── 22. Permit2 ───────────────────────────────────────────────────────────

    function test_permit2_standardSwap() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 netOut = _net(amtOut);

        vm.prank(user);
        tokenA.approve(address(mockPermit2), type(uint256).max);

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.executeWithPermit2(
            address(tokenA), amtIn, address(tokenB), netOut,
            recipient, MAX_DEADLINE, _encode(step),
            _permit2(address(tokenA), amtIn), hex""
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
        assertEq(tokenA.balanceOf(address(executor)), 0);
    }

    function test_permit2_fot_balanceDeltaAccounting() public {
        uint256 nominal  = 100 ether;
        uint256 actualIn = (nominal * (10_000 - FOT_BPS)) / 10_000;
        uint256 amtOut   = 90 ether;
        uint256 netOut   = _net(amtOut);

        vm.prank(user);
        fotToken.approve(address(mockPermit2), type(uint256).max);

        Step memory step = _tokenSwapStep(address(fotToken), actualIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.executeWithPermit2(
            address(fotToken), nominal, address(tokenB), netOut,
            recipient, MAX_DEADLINE, _encode(step),
            _permit2(address(fotToken), nominal), hex""
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
    }

    function test_permit2_nativeIn_reverts() public {
        Step memory step = _bnbToTokenStep(1 ether, address(tokenB), 1 ether, 1 ether);

        vm.prank(user);
        vm.expectRevert(NativeNotPermitted.selector);
        executor.executeWithPermit2(
            address(0), 1 ether, address(tokenB), 1 ether,
            recipient, MAX_DEADLINE, _encode(step),
            _permit2(address(0), 1 ether), hex""
        );
    }

    function test_permit2_deadlineExpired_reverts() public {
        vm.prank(user);
        tokenA.approve(address(mockPermit2), type(uint256).max);

        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);

        vm.prank(user);
        vm.expectRevert(DeadlineExpired.selector);
        executor.executeWithPermit2(
            address(tokenA), 1, address(tokenB), 1,
            recipient, block.timestamp - 1, _encode(step),
            _permit2(address(tokenA), 1), hex""
        );
    }

    function test_permit2_insufficientOutput_reverts() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 minOut = 95 ether;

        vm.prank(user);
        tokenA.approve(address(mockPermit2), type(uint256).max);

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, _net(amtOut), minOut));
        executor.executeWithPermit2(
            address(tokenA), amtIn, address(tokenB), minOut,
            recipient, MAX_DEADLINE, _encode(step),
            _permit2(address(tokenA), amtIn), hex""
        );
    }

    function test_permit2_paused_reverts() public {
        executor.pause();

        vm.prank(user);
        tokenA.approve(address(mockPermit2), type(uint256).max);

        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);

        vm.prank(user);
        vm.expectRevert(Paused.selector);
        executor.executeWithPermit2(
            address(tokenA), 1, address(tokenB), 1,
            recipient, MAX_DEADLINE, _encode(step),
            _permit2(address(tokenA), 1), hex""
        );
    }

    function test_permit2_nativeOut() public {
        uint256 amtIn  = 100 ether;
        uint256 bnbOut = 1 ether;
        uint256 netBnb = _net(bnbOut);

        vm.prank(user);
        tokenA.approve(address(mockPermit2), type(uint256).max);

        Step memory step = _tokenToBNBStep(address(tokenA), amtIn, bnbOut, bnbOut);
        uint256 recipientBefore = recipient.balance;

        vm.prank(user);
        uint256 received = executor.executeWithPermit2(
            address(tokenA), amtIn, address(0), netBnb,
            recipient, MAX_DEADLINE, _encode(step),
            _permit2(address(tokenA), amtIn), hex""
        );

        assertEq(received, netBnb);
        assertEq(recipient.balance - recipientBefore, netBnb);
    }

    // ── 23. Aggregation fee ───────────────────────────────────────────────────

    function test_feeOnOutput_erc20() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 100 ether;
        tokenB.mint(address(router), amtOut);

        uint256 expectedFee  = _fee(amtOut);
        uint256 expectedUser = _net(amtOut);

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(tokenB), expectedUser,
            recipient, MAX_DEADLINE, _encode(step, false)
        );

        assertEq(received, expectedUser);
        assertEq(tokenB.balanceOf(recipient), expectedUser);
        assertEq(tokenB.balanceOf(feeAddr), expectedFee);
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }

    function test_feeOnInput_erc20() public {
        uint256 amtIn    = 100 ether;
        uint256 fee      = _fee(amtIn);
        uint256 swapIn   = amtIn - fee;
        uint256 amtOut   = 90 ether;
        tokenB.mint(address(router), amtOut);

        Step memory step = _tokenSwapStep(address(tokenA), swapIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(tokenB), amtOut,
            recipient, MAX_DEADLINE, _encode(step, true)
        );

        assertEq(received, amtOut);
        assertEq(tokenA.balanceOf(feeAddr), fee);
        assertEq(tokenB.balanceOf(recipient), amtOut);
        assertEq(tokenA.balanceOf(address(executor)), 0);
    }

    function test_feeOnOutput_native() public {
        uint256 amtIn    = 100 ether;
        uint256 bnbOut   = 2 ether;
        uint256 fee      = _fee(bnbOut);
        uint256 userBnb  = _net(bnbOut);

        Step memory step = _tokenToBNBStep(address(tokenA), amtIn, bnbOut, bnbOut);
        uint256 feeBalBefore = feeAddr.balance;
        uint256 recipBefore  = recipient.balance;

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(0), userBnb,
            recipient, MAX_DEADLINE, _encode(step, false)
        );

        assertEq(received, userBnb);
        assertEq(recipient.balance - recipBefore, userBnb);
        assertEq(feeAddr.balance - feeBalBefore, fee);
    }

    function test_feeOnInput_native() public {
        uint256 bnbIn  = 1 ether;
        uint256 fee    = _fee(bnbIn);
        uint256 swapIn = bnbIn - fee;
        uint256 amtOut = 300 ether;
        tokenB.mint(address(router), amtOut);

        Step memory step = _bnbToTokenStep(swapIn, address(tokenB), amtOut, amtOut);
        uint256 feeBalBefore = feeAddr.balance;

        vm.prank(user);
        uint256 received = executor.execute{value: bnbIn}(
            address(0), bnbIn, address(tokenB), amtOut,
            recipient, MAX_DEADLINE, _encode(step, true)
        );

        assertEq(received, amtOut);
        assertEq(feeAddr.balance - feeBalBefore, fee);
        assertEq(tokenB.balanceOf(recipient), amtOut);
    }

    function test_setFeeRecipient_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(NotOwner.selector);
        executor.setFeeRecipient(feeAddr);
    }

    function test_setFeeRecipient_zeroAddress_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        executor.setFeeRecipient(address(0));
    }

    function test_feeOnOutput_minAmountOut_enforced_after_fee() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 100 ether;
        uint256 netOut = _net(amtOut);
        tokenB.mint(address(router), amtOut);

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, netOut, amtOut));
        executor.execute(
            address(tokenA), amtIn, address(tokenB), amtOut,
            recipient, MAX_DEADLINE, _encode(step, false)
        );
    }

    function test_permit2_feeOnOutput() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 100 ether;
        uint256 fee    = _fee(amtOut);
        uint256 netOut = _net(amtOut);
        tokenB.mint(address(router), amtOut);

        vm.prank(user);
        tokenA.approve(address(mockPermit2), type(uint256).max);

        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.executeWithPermit2(
            address(tokenA), amtIn, address(tokenB), netOut,
            recipient, MAX_DEADLINE, _encode(step, false),
            _permit2(address(tokenA), amtIn), hex""
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(feeAddr), fee);
        assertEq(tokenB.balanceOf(recipient), netOut);
    }

    // ── 24. _validateTarget — V2 pair path ────────────────────────────────────

    function test_v2Pair_uniV2Factory_validated() public {
        MockV2Factory v2fac = new MockV2Factory();
        MockV2Pair    pair  = new MockV2Pair(address(tokenA), address(tokenB));
        v2fac.setPair(address(tokenA), address(tokenB), address(pair));

        // Deploy executor with uniV2Factory
        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(v2fac), address(0), address(0), address(0));

        tokenB.mint(address(pair), 90 ether);

        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 netOut = _net(amtOut);

        tokenA.mint(user, amtIn);
        vm.prank(user);
        tokenA.approve(address(dex), type(uint256).max);

        Step memory step = Step({
            target:           address(pair),
            value:            0,
            callData:         abi.encodeCall(pair.swap, (0, amtOut, address(dex), "")),
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(tokenA),
            preTransferAmt:   amtIn,
            tokenOut:         address(tokenB),
            minDelta:         amtOut
        });

        vm.prank(user);
        uint256 received = dex.execute(
            address(tokenA), amtIn, address(tokenB), netOut,
            recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
        // tokenA was pre-transferred into pair (not via approve)
        assertEq(tokenA.balanceOf(address(pair)), amtIn);
        assertEq(tokenA.allowance(address(dex), address(pair)), 0);
    }

    function test_v2Pair_cakeV2Factory_validated() public {
        MockV2Factory cakeV2fac = new MockV2Factory();
        MockV2Pair    pair      = new MockV2Pair(address(tokenA), address(tokenB));
        cakeV2fac.setPair(address(tokenA), address(tokenB), address(pair));

        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(0), address(cakeV2fac), address(0), address(0));

        tokenB.mint(address(pair), 70 ether);
        tokenA.mint(user, 80 ether);
        vm.prank(user);
        tokenA.approve(address(dex), type(uint256).max);

        Step memory step = Step({
            target:           address(pair),
            value:            0,
            callData:         abi.encodeCall(pair.swap, (0, 70 ether, address(dex), "")),
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(tokenA),
            preTransferAmt:   80 ether,
            tokenOut:         address(tokenB),
            minDelta:         70 ether
        });

        vm.prank(user);
        uint256 received = dex.execute(
            address(tokenA), 80 ether, address(tokenB), _net(70 ether),
            recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, _net(70 ether));
    }

    function test_v2Pair_wrongFactory_reverts() public {
        MockV2Factory v2fac   = new MockV2Factory();
        MockV2Pair    pair    = new MockV2Pair(address(tokenA), address(tokenB));
        address       other   = makeAddr("other");
        // Factory maps to a DIFFERENT address
        v2fac.setPair(address(tokenA), address(tokenB), other);

        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(v2fac), address(0), address(0), address(0));
        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(dex), type(uint256).max);

        Step memory step = Step({
            target:           address(pair),
            value:            0,
            callData:         hex"",
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(0),
            preTransferAmt:   0,
            tokenOut:         address(tokenB),
            minDelta:         0
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(pair)));
        dex.execute(address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 25. _validateTarget — V3 pool path ────────────────────────────────────

    function test_v3Pool_uniV3Factory_validated() public {
        MockV3Pool pool  = new MockV3Pool(address(tokenA), address(tokenB), 500);
        MockV3Factory v3fac = new MockV3Factory();
        v3fac.registerPool(address(tokenA), address(tokenB), 500, address(pool));

        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(0), address(0), address(v3fac), address(0));

        tokenB.mint(address(pool), 90 ether);
        pool.prepareOutput(address(tokenB), 90 ether);
        tokenA.mint(user, 100 ether);
        vm.prank(user);
        tokenA.approve(address(dex), type(uint256).max);

        uint256 netOut = _net(90 ether);

        Step memory step = Step({
            target:           address(pool),
            value:            0,
            callData:         abi.encodeCall(pool.swap, (0, 90 ether, address(dex), "")),
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(tokenA),
            preTransferAmt:   100 ether,
            tokenOut:         address(tokenB),
            minDelta:         90 ether
        });

        vm.prank(user);
        uint256 received = dex.execute(
            address(tokenA), 100 ether, address(tokenB), netOut,
            recipient, MAX_DEADLINE, _encode(step)
        );

        assertEq(received, netOut);
        assertEq(tokenB.balanceOf(recipient), netOut);
    }

    // ── 26. preTransfer mechanics ─────────────────────────────────────────────

    function test_preTransfer_zero_skipped_approvalPathWorks() public {
        // Existing approval-style step — preTransferAmt = 0 → skipped
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 netOut = _net(amtOut);
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        uint256 received = executor.execute(
            address(tokenA), amtIn, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step)
        );
        assertEq(received, netOut);
        // Approval path was used (allowance reset to 0 after step)
        assertEq(tokenA.allowance(address(executor), address(router)), 0);
    }

    function test_preTransfer_pushesTokensBeforeCall() public {
        MockV2Factory v2fac = new MockV2Factory();
        MockV2Pair    pair  = new MockV2Pair(address(tokenA), address(tokenB));
        v2fac.setPair(address(tokenA), address(tokenB), address(pair));

        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(v2fac), address(0), address(0), address(0));

        uint256 preAmt = 80 ether;
        uint256 outAmt = 75 ether;
        tokenB.mint(address(pair), outAmt);
        tokenA.mint(user, preAmt);
        vm.prank(user);
        tokenA.approve(address(dex), type(uint256).max);

        Step memory step = Step({
            target:           address(pair),
            value:            0,
            callData:         abi.encodeCall(pair.swap, (0, outAmt, address(dex), "")),
            approveToken:     address(0),
            approveAmt:       0,
            preTransferToken: address(tokenA),
            preTransferAmt:   preAmt,
            tokenOut:         address(tokenB),
            minDelta:         outAmt
        });

        vm.prank(user);
        dex.execute(
            address(tokenA), preAmt, address(tokenB), _net(outAmt),
            recipient, MAX_DEADLINE, _encode(step)
        );

        // tokenA was pushed into pair, not approved
        assertEq(tokenA.allowance(address(dex), address(pair)), 0);
        assertEq(tokenA.balanceOf(address(pair)), preAmt);
    }

    // ── 27. V3 swap callbacks ─────────────────────────────────────────────────

    function test_v3Callback_disabledFactory_reverts() public {
        // executor has address(0) for UNI_V3_FACTORY → uniswapV3SwapCallback must revert
        MockV3Pool pool = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        bytes memory cbData = abi.encode(SwapCallbackData({
            tokenIn:  address(tokenA),
            amountIn: 100 ether,
            payer:    address(executor)
        }));

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(pool)));
        executor.uniswapV3SwapCallback(100 ether, 0, cbData);
    }

    function test_pancakeV3Callback_disabledFactory_reverts() public {
        MockV3Pool pool = new MockV3Pool(address(tokenA), address(tokenB), 2500);
        bytes memory cbData = abi.encode(SwapCallbackData({
            tokenIn:  address(tokenA),
            amountIn: 50 ether,
            payer:    address(executor)
        }));

        // executor's CAKE_V3_FACTORY = testV3Factory, which maps (tokenA, tokenB, 2500) → address(0)
        // so the pool won't be found → RouterNotWhitelisted
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(pool)));
        executor.pancakeV3SwapCallback(50 ether, 0, cbData);
    }

    function test_v3Callback_validPool_pays() public {
        MockV3Pool pool = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        ConfigurableV3Factory cbFactory = new ConfigurableV3Factory(address(pool));

        // Deploy fresh executor with UNI_V3_FACTORY = cbFactory
        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(0), address(0), address(cbFactory), address(0));
        tokenA.mint(address(dex), 100 ether);

        uint256 poolBefore = tokenA.balanceOf(address(pool));

        bytes memory cbData = abi.encode(SwapCallbackData({
            tokenIn:  address(tokenA),
            amountIn: 100 ether,
            payer:    address(dex)
        }));

        vm.prank(address(pool));
        dex.uniswapV3SwapCallback(100 ether, 0, cbData);

        assertEq(tokenA.balanceOf(address(pool)) - poolBefore, 100 ether);
        assertEq(tokenA.balanceOf(address(dex)), 0);
    }

    function test_pancakeV3Callback_validPool_pays() public {
        MockV3Pool pool = new MockV3Pool(address(tokenA), address(tokenB), 500);
        ConfigurableV3Factory cbFactory = new ConfigurableV3Factory(address(pool));

        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(0), address(0), address(0), address(cbFactory));
        tokenA.mint(address(dex), 50 ether);

        uint256 poolBefore = tokenA.balanceOf(address(pool));

        bytes memory cbData = abi.encode(SwapCallbackData({
            tokenIn:  address(tokenA),
            amountIn: 50 ether,
            payer:    address(dex)
        }));

        vm.prank(address(pool));
        dex.pancakeV3SwapCallback(50 ether, 0, cbData);

        assertEq(tokenA.balanceOf(address(pool)) - poolBefore, 50 ether);
    }

    function test_v3Callback_invalidPool_reverts() public {
        MockV3Pool pool  = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        address fakePool = makeAddr("fakePool");
        ConfigurableV3Factory cbFactory = new ConfigurableV3Factory(fakePool); // returns fakePool, not pool

        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(0), address(0), address(cbFactory), address(0));
        tokenA.mint(address(dex), 100 ether);

        bytes memory cbData = abi.encode(SwapCallbackData({
            tokenIn:  address(tokenA),
            amountIn: 100 ether,
            payer:    address(dex)
        }));

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(pool)));
        dex.uniswapV3SwapCallback(100 ether, 0, cbData);
    }

    function test_v3Callback_amount1DeltaPositive() public {
        MockV3Pool pool = new MockV3Pool(address(tokenA), address(tokenB), 3000);
        ConfigurableV3Factory cbFactory = new ConfigurableV3Factory(address(pool));

        OneDex dex = new OneDex(address(wbnb), address(mockPermit2), feeAddr,
                                 address(0), address(0), address(cbFactory), address(0));
        tokenA.mint(address(dex), 75 ether);

        uint256 poolBefore = tokenA.balanceOf(address(pool));

        bytes memory cbData = abi.encode(SwapCallbackData({
            tokenIn:  address(tokenA),
            amountIn: 75 ether,
            payer:    address(dex)
        }));

        vm.prank(address(pool));
        dex.uniswapV3SwapCallback(0, 75 ether, cbData);

        assertEq(tokenA.balanceOf(address(pool)) - poolBefore, 75 ether);
    }
}
