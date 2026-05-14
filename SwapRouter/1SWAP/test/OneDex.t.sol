// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {
    OneDex,
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
    NativeSendFailed,
    NativeNotPermitted
} from "../src/OneDex.sol";
import {IPermit2}              from "../src/interfaces/IPermit2.sol";
import {MockERC20}             from "./mocks/MockERC20.sol";
import {MockFOTToken}          from "./mocks/MockFOTToken.sol";
import {MockRouter,
        MockReentrantRouter,
        MockUnwhitelistedRouter} from "./mocks/MockRouter.sol";
import {MockPermit2}           from "./mocks/MockPermit2.sol";

contract OneDexTest is Test {

    OneDex      executor;
    MockRouter  router;
    MockPermit2 mockPermit2;

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

    function setUp() public {
        wbnb        = new MockERC20("Wrapped BNB", "WBNB", 18);
        mockPermit2 = new MockPermit2();
        executor    = new OneDex(address(wbnb), address(mockPermit2), feeAddr);
        router      = new MockRouter();

        tokenA   = new MockERC20("Token A", "TKA", 18);
        tokenB   = new MockERC20("Token B", "TKB", 18);
        tokenC   = new MockERC20("Token C", "TKC", 18);
        fotToken = new MockFOTToken("FeeToken", "FOT", 18, FOT_BPS, taxBucket);

        executor.addTarget(address(router));

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

    function _fee(uint256 a) internal pure returns (uint256) { return a * 30 / 10_000; }
    function _net(uint256 a) internal pure returns (uint256) { return a - _fee(a); }

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
            tokenOut:     address(0),
            minDelta:     minDelta
        });
    }

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

    function _encode(Step memory step, bool feeOnInput) internal pure returns (bytes memory) {
        Step[] memory steps = new Step[](1);
        steps[0] = step;
        return abi.encode(feeOnInput, steps);
    }

    function _encode(Step[] memory steps, bool feeOnInput) internal pure returns (bytes memory) {
        return abi.encode(feeOnInput, steps);
    }

    // Convenience wrappers — fee on output by default
    function _encode(Step memory step) internal pure returns (bytes memory) {
        return _encode(step, false);
    }

    function _encode(Step[] memory steps) internal pure returns (bytes memory) {
        return _encode(steps, false);
    }

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
            target:       address(router),
            value:        0,
            callData:     abi.encodeCall(router.swapTokens, (address(fotToken), nominal, address(tokenB), 90 ether)),
            approveToken: address(fotToken),
            approveAmt:   nominal,
            tokenOut:     address(tokenB),
            minDelta:     1
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

    // ── 11. Whitelist enforcement ─────────────────────────────────────────────

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
        tokenA.mint(address(executor), 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RouterNotWhitelisted.selector, address(bad)));
        executor.execute(address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 12. Router revert bubbling ────────────────────────────────────────────

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

    function test_unpause_restoressExecution() public {
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
        Step[] memory innerSteps = new Step[](0);
        bytes memory innerExecData = abi.encode(innerSteps);
        bytes memory reentrantCalldata = abi.encodeCall(
            executor.execute,
            (address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, innerExecData)
        );

        MockReentrantRouter reentranter = new MockReentrantRouter(address(executor), reentrantCalldata);
        executor.addTarget(address(reentranter));
        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        Step memory step = Step({
            target:       address(reentranter),
            value:        0,
            callData:     hex"",
            approveToken: address(0),
            approveAmt:   0,
            tokenOut:     address(tokenB),
            minDelta:     0
        });

        vm.prank(user);
        executor.execute(address(tokenA), 1, address(tokenB), 0, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 15. Admin access control ──────────────────────────────────────────────

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
        executor.execute(address(tokenA), 1, address(tokenB), 1, recipient, MAX_DEADLINE, _encode(step));
    }

    // ── 16. Emergency rescue ──────────────────────────────────────────────────

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

    // ── 17. Ownership transfer (two-step) ─────────────────────────────────────

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

    // ── 18. Zero amount ───────────────────────────────────────────────────────

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

    // ── 19. Zero recipient ────────────────────────────────────────────────────

    function test_zeroRecipient_reverts() public {
        Step memory step = _tokenSwapStep(address(tokenA), 1, address(tokenB), 1, 1);
        tokenA.mint(user, 1);
        vm.prank(user);
        tokenA.approve(address(executor), 1);

        vm.prank(user);
        vm.expectRevert(ZeroAddress.selector);
        executor.execute(address(tokenA), 1, address(tokenB), 1, address(0), MAX_DEADLINE, _encode(step));
    }

    // ── 20. addTargets batch ──────────────────────────────────────────────────

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
        targets[1] = address(0);

        vm.expectRevert(ZeroAddress.selector);
        executor.addTargets(targets);
    }

    // ── 21. Rebasing token ────────────────────────────────────────────────────

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

    // ── 22. Approval reset after step ────────────────────────────────────────

    function test_approvalResetAfterStep() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 90 ether;
        uint256 netOut = _net(amtOut);
        Step memory step = _tokenSwapStep(address(tokenA), amtIn, address(tokenB), amtOut, amtOut);

        vm.prank(user);
        executor.execute(address(tokenA), amtIn, address(tokenB), netOut, recipient, MAX_DEADLINE, _encode(step));

        assertEq(tokenA.allowance(address(executor), address(router)), 0);
    }

    // ── 23. Constructor guards ────────────────────────────────────────────────

    function test_constructor_zeroWBNB_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new OneDex(address(0), address(mockPermit2), feeAddr);
    }

    function test_constructor_zeroPermit2_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new OneDex(address(wbnb), address(0), feeAddr);
    }

    function test_constructor_zeroFeeRecipient_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new OneDex(address(wbnb), address(mockPermit2), address(0));
    }

    function test_constructor_ownerIsDeployer() public {
        OneDex fresh = new OneDex(address(wbnb), address(mockPermit2), feeAddr);
        assertEq(fresh.owner(), address(this));
    }

    // ── 24. Permit2 ───────────────────────────────────────────────────────────

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

    // ── 25. Aggregation fee ───────────────────────────────────────────────────

    function test_feeOnOutput_erc20() public {
        uint256 amtIn  = 100 ether;
        uint256 amtOut = 100 ether; // router gives 100 tokenB
        tokenB.mint(address(router), amtOut);

        // 0.5 % of 100 = 0.5 tokenB fee; user gets 99.5
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
        uint256 fee      = _fee(amtIn);    // 0.3 tokenA
        uint256 swapIn   = amtIn - fee;    // 99.5 tokenA → steps
        uint256 amtOut   = 90 ether;       // router gives 90 tokenB for 99.5 tokenA
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

        // Demand more than the net output — should revert
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, netOut, amtOut));
        executor.execute(
            address(tokenA), amtIn, address(tokenB), amtOut, // minAmountOut == gross, too high
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
}
