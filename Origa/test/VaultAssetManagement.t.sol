// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {OrigaVaultLite} from "../src/OrigaVaultLite.sol";
import {OrigaVault} from "../src/OrigaVault.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    function mint(address to, uint256 tokenId) external { ownerOf[tokenId] = to; }
    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        if (to.code.length > 0) {
            bytes4 ret = IERC721ReceiverMin(to).onERC721Received(msg.sender, from, tokenId, "");
            require(ret == 0x150b7a02, "receiver rejected");
        }
    }
}

contract MockERC1155 {
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    function mint(address to, uint256 id, uint256 amount) external { balanceOf[id][to] += amount; }
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;
        if (to.code.length > 0) {
            bytes4 ret = IERC1155ReceiverMin(to).onERC1155Received(msg.sender, from, id, amount, data);
            require(ret == 0xf23a6e61, "receiver rejected");
        }
    }
}

interface IERC721ReceiverMin {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}
interface IERC1155ReceiverMin {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
}

contract VaultAssetManagementTest is Test {
    function _clone(address impl) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        require(instance != address(0), "clone failed");
    }

    MockERC20   erc20;
    MockERC721  erc721;
    MockERC1155 erc1155;
    address recipient = makeAddr("recipient");

    function setUp() public {
        erc20   = new MockERC20();
        erc721  = new MockERC721();
        erc1155 = new MockERC1155();
    }

    function testLite_ReceivesAndSendsAllAssetTypes() public {
        OrigaVaultLite vault = OrigaVaultLite(payable(_clone(address(new OrigaVaultLite()))));
        address owner = makeAddr("owner");
        vault.init(owner);

        // Receive native.
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 1 ether);

        // Receive ERC20.
        erc20.mint(address(vault), 1000e18);
        assertEq(erc20.balanceOf(address(vault)), 1000e18);

        // Receive ERC721 via safeTransferFrom (this is the gap that needed onERC721Received).
        erc721.mint(address(this), 42);
        erc721.safeTransferFrom(address(this), address(vault), 42);
        assertEq(erc721.ownerOf(42), address(vault));

        // Receive ERC1155 via safeTransferFrom.
        erc1155.mint(address(vault), 7, 50);
        assertEq(erc1155.balanceOf(7, address(vault)), 50);

        // Owner sends each asset type out.
        vm.startPrank(owner);
        vault.sendNative(recipient, 0.4 ether);
        vault.sendERC20(address(erc20), recipient, 300e18);
        vault.sendERC721(address(erc721), recipient, 42);
        vault.sendERC1155(address(erc1155), recipient, 7, 20, "");
        vm.stopPrank();

        assertEq(recipient.balance, 0.4 ether);
        assertEq(erc20.balanceOf(recipient), 300e18);
        assertEq(erc721.ownerOf(42), recipient);
        assertEq(erc1155.balanceOf(7, recipient), 20);

        // Non-owner blocked from every asset function.
        address rando = makeAddr("rando");
        vm.startPrank(rando);
        vm.expectRevert(OrigaVaultLite.NotOwner.selector);
        vault.sendNative(rando, 1);
        vm.expectRevert(OrigaVaultLite.NotOwner.selector);
        vault.sendERC20(address(erc20), rando, 1);
        vm.stopPrank();

        // Generic arbitrary-calldata execute() still works (e.g. an ERC20 transfer encoded by hand).
        vm.prank(owner);
        vault.execute(address(erc20), 0, abi.encodeWithSelector(MockERC20.transfer.selector, recipient, 100e18));
        assertEq(erc20.balanceOf(recipient), 400e18);
    }

    function testVault_2of3_ReceivesAndSendsViaMultisig() public {
        OrigaVault vault = OrigaVault(payable(_clone(address(new OrigaVault()))));
        address s1 = makeAddr("s1"); address s2 = makeAddr("s2"); address s3 = makeAddr("s3");
        vault.init([s1, s2, s3]);

        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        erc20.mint(address(vault), 1000e18);
        erc721.mint(address(this), 99);
        erc721.safeTransferFrom(address(this), address(vault), 99);
        assertEq(erc721.ownerOf(99), address(vault));
        erc1155.mint(address(vault), 3, 80);

        // Sending native requires 2-of-3 approval, via self-call to sendNative.
        bytes memory sendNativeData = abi.encodeWithSelector(vault.sendNative.selector, recipient, 0.5 ether);
        vm.prank(s1);
        uint256 pid1 = vault.propose(address(vault), 0, sendNativeData);
        vm.expectRevert(); // ThresholdNotMet, 1/2
        vault.execute(pid1);
        vm.prank(s2);
        vault.approve(pid1);
        vault.execute(pid1);
        assertEq(recipient.balance, 0.5 ether);

        // Sending ERC721 via self-call to sendERC721.
        bytes memory sendNftData = abi.encodeWithSelector(vault.sendERC721.selector, address(erc721), recipient, 99);
        vm.prank(s1);
        uint256 pid2 = vault.propose(address(vault), 0, sendNftData);
        vm.prank(s3);
        vault.approve(pid2);
        vault.execute(pid2);
        assertEq(erc721.ownerOf(99), recipient);

        // Direct (non-self) call to sendERC20 must fail -- only reachable via execute().
        vm.expectRevert(); // NotSelf
        vault.sendERC20(address(erc20), recipient, 1e18);

        // Generic arbitrary calldata still works too: propose a raw ERC1155 transfer.
        bytes memory rawData = abi.encodeWithSelector(MockERC1155.safeTransferFrom.selector, address(vault), recipient, 3, 30, "");
        vm.prank(s1);
        uint256 pid3 = vault.propose(address(erc1155), 0, rawData);
        vm.prank(s2);
        vault.approve(pid3);
        vault.execute(pid3);
        assertEq(erc1155.balanceOf(3, recipient), 30);
    }
}
