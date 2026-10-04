// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../../utils/Mocks.sol";

/// @notice A Folio in miniature: shares backed pro rata by a basket it holds; mint takes the Ceil amounts and
///         keeps a fee in shares, redeem pays the Floor amounts.
contract MockFolio is ERC20 {
    address[] public basket;
    uint256 public mintFee; // 1e18 = 100%
    uint256 public pendingFeeShares;
    bool public midFill;

    constructor(address[] memory basket_) ERC20("Mock index", "MIDX") {
        basket = basket_;
    }

    /// Seed backing: `shares` to `to` against `amounts` already sent here.
    function seed(address to, uint256 shares) external {
        _mint(to, shares);
    }

    function setMintFee(uint256 f) external {
        mintFee = f;
    }

    function setPendingFeeShares(uint256 s) external {
        pendingFeeShares = s;
    }

    function setMidFill(bool b) external {
        midFill = b;
    }

    function totalSupply() public view override returns (uint256) {
        return super.totalSupply() + pendingFeeShares;
    }

    function totalAssets() public view returns (address[] memory a, uint256[] memory m) {
        a = basket;
        m = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) {
            m[i] = IERC20(a[i]).balanceOf(address(this));
        }
    }

    function toAssets(uint256 shares, uint8 rounding) public view returns (address[] memory a, uint256[] memory m) {
        (a, m) = totalAssets();
        uint256 s = totalSupply();
        for (uint256 i; i < a.length; ++i) {
            m[i] = Math.mulDiv(shares, m[i], s, rounding == 1 ? Math.Rounding.Ceil : Math.Rounding.Floor);
        }
    }

    function mint(uint256 shares, address receiver, uint256 minSharesOut)
        external
        returns (address[] memory a, uint256[] memory m)
    {
        (a, m) = toAssets(shares, 1);
        for (uint256 i; i < a.length; ++i) {
            IERC20(a[i]).transferFrom(msg.sender, address(this), m[i]);
        }
        uint256 out = shares - shares * mintFee / 1e18;
        require(out >= minSharesOut, "slippage");
        _mint(receiver, out);
        pendingFeeShares += shares - out;
    }

    function redeem(uint256 shares, address receiver, address[] calldata assets, uint256[] calldata mins)
        external
        returns (uint256[] memory m)
    {
        address[] memory a;
        (a, m) = toAssets(shares, 0);
        _burn(msg.sender, shares);
        require(a.length == assets.length && a.length == mins.length, "lengths");
        for (uint256 i; i < a.length; ++i) {
            require(a[i] == assets[i], "asset");
            require(m[i] >= mins[i], "min");
            IERC20(a[i]).transfer(receiver, m[i]);
        }
    }

    function stateChangeActive() external view returns (bool, bool) {
        return (midFill, false);
    }

    function isDeprecated() external pure returns (bool) {
        return false;
    }
}

contract MockIndexFactory {
    mapping(address => bool) public isIndex;

    function set(address index, bool b) external {
        isIndex[index] = b;
    }
}

/// @notice IndexZap with the Universal Router plan replaced by a fixed-rate mint and burn: `commands` carries
///         abi.encode(uint256 refund) on a buy (pay token handed back unspent) and abi.encode(uint256 out) on a
///         sell (what the plan delivers).
contract MockZap {
    address public immutable factory;
    address public immutable weth;
    address public immutable usdg;
    address public router = address(0xBEEF);

    constructor(address factory_, address weth_, address usdg_) {
        factory = factory_;
        weth = weth_;
        usdg = usdg_;
    }

    function buy(
        address index,
        uint256 shares,
        uint256 minSharesOut,
        address payToken,
        uint256 payAmount,
        bytes calldata commands,
        bytes[] calldata,
        uint256
    ) external payable returns (uint256 sharesOut) {
        require(MockIndexFactory(factory).isIndex(index), "not an index");
        IERC20(payToken).transferFrom(msg.sender, address(this), payAmount);
        uint256 refund = abi.decode(commands, (uint256));
        MockERC20(payToken).burn(address(this), payAmount - refund);
        sharesOut = _mintFor(index, shares, minSharesOut);
        IERC20(payToken).transfer(msg.sender, refund);
        // Like the real zap after an API plan: leftover WETH, unwrapped by the router, refunded as ETH.
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "ETH refund failed");
        }
    }

    receive() external payable {}

    function _mintFor(address index, uint256 shares, uint256 minSharesOut) private returns (uint256 sharesOut) {
        (address[] memory a, uint256[] memory m) = MockFolio(index).toAssets(shares, 1);
        for (uint256 i; i < a.length; ++i) {
            MockERC20(a[i]).mint(address(this), m[i] + 1); // one unit over, returned as a leftover
            IERC20(a[i]).approve(index, m[i]);
        }
        uint256 before = IERC20(index).balanceOf(msg.sender);
        MockFolio(index).mint(shares, msg.sender, minSharesOut);
        sharesOut = IERC20(index).balanceOf(msg.sender) - before;
        for (uint256 i; i < a.length; ++i) {
            IERC20(a[i]).transfer(msg.sender, IERC20(a[i]).balanceOf(address(this)));
        }
    }

    function sell(
        address index,
        uint256 shares,
        address outToken,
        uint256 minOut,
        bytes calldata commands,
        bytes[] calldata,
        uint256
    ) external returns (uint256 received) {
        require(MockIndexFactory(factory).isIndex(index), "not an index");
        IERC20(index).transferFrom(msg.sender, address(this), shares);
        (address[] memory a, uint256[] memory m) = MockFolio(index).toAssets(shares, 0);
        MockFolio(index).redeem(shares, address(this), a, m);
        for (uint256 i; i < a.length; ++i) {
            MockERC20(a[i]).burn(address(this), m[i]);
        }
        received = abi.decode(commands, (uint256));
        require(received >= minOut, "too little");
        MockERC20(outToken).mint(msg.sender, received);
    }
}

/// @notice WETH that wraps: `deposit` mints one token per wei.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}
