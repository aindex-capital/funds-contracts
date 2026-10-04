// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FundController} from "../src/core/FundController.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {Side} from "../src/interfaces/IPriceRouter.sol";
import {MarketParams, IMorpho} from "../src/interfaces/external/morpho/IMorpho.sol";
import {IUniswapV3Pool} from "../src/interfaces/external/uniswap/IUniswapV3.sol";
import {IFablesPoolRegistry} from "../src/interfaces/external/fables/IFablesPoolRegistry.sol";

/**
 * @title  RehearseFund
 * @notice The manager's half of the Funds rehearsal: real actions through every adapter kind of a Fund made by
 *         CreateFund, checking after each that the book is complete and printing NAV. Run by
 *         `script/rehearse-funds.sh` on an anvil fork of Robinhood Chain; it works the same on mainnet with the
 *         manager's key, which is how an agent's first trades would look. The positions it leaves (liquidity in
 *         three venues, a Morpho loan with collateral and a borrow, an ERC-4626 deposit) are what `RehearseTeller`'s
 *         exits in kind then split (in one transaction and in parts).
 *
 * @dev    `run()`, order and amounts (USDG, raw 6 decimals), sized for a 500 USDG opening stake:
 *         1. swap 100 USDG to NVDA through KyberSwap (KYBER_NVDA_* from script/rehearsal/kyber-route.mjs), or the
 *            Universal Router's v3 NVDA/USDG pool when no route is given;
 *         2. swap 80 USDG to WETH through the Universal Router (v3 USDG/WETH 0.05%, Permit2 approval);
 *         3. buy 30 USDG of AIXSTR at backing through the index adapter and AINDEX's IndexZap, only when ZAP_DATA
 *            is given (the rehearsal leaves it out: every deposit would then have to buy AIXSTR, and KyberSwap only
 *            finds its thin v4 pool, which charged 76% over backing on 2026-10-01);
 *         4. deposit 50 USDG into steakUSDG (ERC-4626);
 *         5. lend 50 USDG on Morpho, NVDA/USDG 62.5% (a reviewed oracle);
 *         6. post a fifth of the NVDA as collateral in the same market and borrow 10 USDG against it;
 *         7. Uniswap v3 liquidity, WETH/USDG 0.05%, half the WETH and 40 USDG;
 *         8. Uniswap v4 liquidity, hookless WETH/USDG 0.05%, the rest of the WETH and 40 USDG;
 *         9. Fables liquidity, NVDA/USDG on Fables' NVDA hook, half the remaining NVDA and 50 USDG.
 *         `invest(keepUsdg)`: the manager invests the Fund's new cash (deposits enter as cash), every USDG above
 *         `keepUsdg` into NVDA through the Universal Router.
 *         `tsla()`: buy 2 USDG of TSLA through the Universal Router, a holding the rehearsal then downgrades to no
 *         market and sets aside in a holders' pocket.
 */
contract RehearseFund is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AIXSTR = 0xe7c9209D3C35d7cf1895e46a2d62b9A30841bB98;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant STEAK_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant KYBER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant V3_USDG_WETH_500 = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a;
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    /// NVDA/USDG 62.5%, oracle 0xC5b8 (Chainlink NVDA and USDG, reviewed), little borrowed.
    bytes32 constant MORPHO_NVDA_LIQUID = 0x66306c087add8907752320b309934abcc354d21626de8115c79df49d9c214edc;
    /// Fables NVDA/USDG on the gen-1 NVDA hook.
    bytes32 constant FABLES_NVDA_POOL = 0x7990aad9e8fb048f49a155a7df5603db0366f0657035b78eb4196395cccb3dcd;
    IFablesPoolRegistry constant FABLES = IFablesPoolRegistry(0x159A113E012593D9B3cC63ad45E30F0467e13Ef3);

    FundController internal controller;
    address internal vault;
    string internal rec;
    uint256 internal lastNav;
    uint256 internal step;

    function run() external {
        _load();
        lastNav = _nav("start");

        vm.startBroadcast();
        _swapNvda();
        _swapWeth();
        _index();
        _act("erc4626", abi.encode(uint8(0), STEAK_USDG, uint256(50e6), uint256(1)), "steakUSDG deposit 50 USDG");
        (address loan, address coll, address oracle, address irm, uint256 lltv) = MORPHO.idToMarketParams(MORPHO_NVDA_LIQUID);
        MarketParams memory mp = MarketParams(loan, coll, oracle, irm, lltv);
        _act("morpho", abi.encode(uint8(0), mp, uint256(50e6)), "Morpho supply 50 USDG, NVDA/USDG");
        uint256 collateral = IERC20(NVDA).balanceOf(vault) / 5;
        _act("morpho", abi.encode(uint8(2), mp, collateral), "Morpho collateral: a fifth of the NVDA, NVDA/USDG");
        _act("morpho", abi.encode(uint8(4), mp, uint256(10e6)), "Morpho borrow 10 USDG against it");
        _uniswapV3();
        _uniswapV4();
        _fables();
        vm.stopBroadcast();

        (uint256 bid, bool ok) = controller.nav(uint8(Side.Bid));
        console.log("final NAV fair / bid (USD 1e18):", lastNav, bid);
        require(ok, "book incomplete at the end");
    }

    /// @notice The manager invests the Fund's cash above `keepUsdg` (raw) into NVDA.
    function invest(uint256 keepUsdg) external {
        _load();
        lastNav = _nav("start");
        uint256 bal = IERC20(USDG).balanceOf(vault);
        require(bal > keepUsdg, "no new cash to invest");
        uint256 amount = bal - keepUsdg;
        vm.startBroadcast();
        _ur(amount, NVDA, 500, _minOut(NVDA, amount), "invest the Fund's new cash into NVDA (Universal Router)");
        vm.stopBroadcast();
    }

    /// @notice A small TSLA holding the rehearsal later downgrades to no market: 2 USDG through the Universal Router.
    function tsla() external {
        _load();
        lastNav = _nav("start");
        vm.startBroadcast();
        _ur(2e6, TSLA, 3000, _minOut(TSLA, 2e6), "Universal Router 2 USDG -> TSLA");
        vm.stopBroadcast();
    }

    function _load() internal {
        rec = vm.readFile(vm.envOr("FUND_RECORD", string("deployments/rehearsal-fund.json")));
        controller = FundController(vm.parseJsonAddress(rec, ".controller"));
        vault = controller.vault();
    }

    // ---------------------------------------------------------------- actions

    function _swapNvda() internal {
        if (vm.envOr("KYBER_NVDA_SENDER", address(0)) == _inst("swap")) {
            _kyber("KYBER_NVDA_", NVDA, "KyberSwap 100 USDG -> NVDA");
        } else {
            console.log("no KyberSwap NVDA route for this clone: Universal Router instead");
            _ur(100e6, NVDA, 500, _minOut(NVDA, 100e6), "Universal Router 100 USDG -> NVDA");
        }
    }

    function _swapWeth() internal {
        _ur(80e6, WETH, 500, _minOut(WETH, 80e6), "Universal Router 80 USDG -> WETH");
    }

    function _index() internal {
        bytes memory zap = vm.envOr("ZAP_DATA", bytes(""));
        if (zap.length < 4) {
            console.log("SKIPPED index: no IndexZap plan (ZAP_DATA from AINDEX's trade API)");
            return;
        }
        _act("index", _zapBuy(zap), "IndexZap buy of AIXSTR with 30 USDG, at backing");
        uint256 shares = IERC20(AIXSTR).balanceOf(vault) / 2;
        _act("index", abi.encode(uint8(1), AIXSTR, shares, new uint256[](0)), "index redeem half the AIXSTR into its basket");
    }

    function _uniswapV3() internal {
        (, int24 tick,,,,,) = IUniswapV3Pool(V3_USDG_WETH_500).slot0();
        (int24 lo, int24 hi) = _range(tick, 10, 1000);
        uint256 weth = IERC20(WETH).balanceOf(vault) / 2;
        _act(
            "uniswapV3",
            abi.encode(uint8(0), WETH, USDG, uint24(500), lo, hi, weth, uint256(40e6), uint256(0), uint256(0)),
            "Uniswap v3 WETH/USDG 0.05% mint"
        );
    }

    function _uniswapV4() internal {
        PoolKey memory key = PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), 500, 10, IHooks(address(0)));
        (, int24 tick,,) = PM.getSlot0(key.toId());
        (int24 lo, int24 hi) = _range(tick, 10, 1000);
        uint256 weth = IERC20(WETH).balanceOf(vault);
        _act(
            "uniswapV4",
            abi.encode(uint8(0), key, lo, hi, weth, uint256(40e6), uint256(0), uint256(0)),
            "Uniswap v4 WETH/USDG 0.05% mint"
        );
    }

    function _fables() internal {
        PoolKey memory key = FABLES.poolById(PoolId.wrap(FABLES_NVDA_POOL)).key;
        (, int24 tick,,) = PM.getSlot0(key.toId());
        (int24 lo, int24 hi) = _range(tick, key.tickSpacing, 20 * key.tickSpacing);
        uint256 nvda = IERC20(NVDA).balanceOf(vault) / 2;
        (uint256 a0, uint256 a1) = Currency.unwrap(key.currency0) == USDG ? (uint256(50e6), nvda) : (nvda, uint256(50e6));
        _act(
            "fables",
            abi.encode(uint8(0), FABLES_NVDA_POOL, lo, hi, uint128(a0), uint128(a1), uint128(0)),
            "Fables NVDA/USDG deposit"
        );
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The API's `IndexZap.buy` calldata, as the adapter's ZAP_BUY action: the same eight arguments after
    ///      the action id. Done on the raw words (decoding all eight at once is too deep for the stack): the two
    ///      dynamic offsets move by one word for the prepended id, and the deadline moves later because the
    ///      rehearsal's clock runs a day ahead of the API's (the plan itself carries none).
    function _zapBuy(bytes memory data) internal view returns (bytes memory action) {
        action = abi.encodePacked(uint256(2), _slice(data, 4));
        uint256 deadline = block.timestamp + 1 hours;
        assembly ("memory-safe") {
            let head := add(action, 0x40) // skip the length word and the action id
            mstore(add(head, mul(5, 0x20)), add(mload(add(head, mul(5, 0x20))), 0x20)) // commands offset
            mstore(add(head, mul(6, 0x20)), add(mload(add(head, mul(6, 0x20))), 0x20)) // inputs offset
            mstore(add(head, mul(7, 0x20)), deadline)
        }
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) out[i] = b[i + from];
    }

    function _kyber(string memory p, address tokenOut, string memory what) internal {
        require(vm.envAddress(string.concat(p, "SENDER")) == _inst("swap"), "route is for another clone");
        address target = vm.envAddress(string.concat(p, "TARGET"));
        require(target == KYBER, "route is not for KyberSwap's router");
        _act(
            "swap",
            abi.encode(
                uint8(0),
                USDG,
                vm.envUint(string.concat(p, "AMOUNT_IN")),
                tokenOut,
                vm.envUint(string.concat(p, "MIN_OUT")),
                target,
                vm.envBytes(string.concat(p, "DATA"))
            ),
            what
        );
    }

    /// @dev Universal Router V3_SWAP_EXACT_IN (command 0x00) from USDG, paid through Permit2 by the adapter
    ///      (payerIsUser), paid out to the adapter (MSG_SENDER = address(1)). The router on this chain is newer
    ///      than the classic five-argument layout: it also reads a per-hop slippage array, and a five-argument
    ///      input reverts SliceOutOfBounds (same finding as aindex's basketbuy.ts).
    function _ur(uint256 amountIn, address tokenOut, uint24 fee, uint256 minOut, string memory what) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), amountIn, minOut, abi.encodePacked(USDG, fee, tokenOut), true, new uint256[](0));
        bytes memory data = abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)", hex"00", inputs, block.timestamp + 30 minutes
        );
        _act("swap", abi.encode(uint8(0), USDG, amountIn, tokenOut, minOut, UNIVERSAL_ROUTER, data), what);
    }

    /// @dev 97% of what `amountIn` USDG buys at the router's fair price: the swap must not be worse than that.
    function _minOut(address token, uint256 amountIn) internal view returns (uint256) {
        PriceRouter r = PriceRouter(address(controller.router()));
        uint256 px = r.quote(token).fair;
        uint8 d = r.config(token).decimals;
        return amountIn * 1e12 * (10 ** d) / px * 97 / 100;
    }

    function _act(string memory adapter, bytes memory action, string memory what) internal {
        controller.act(_inst(adapter), action);
        lastNav = _nav(what);
    }

    function _nav(string memory what) internal returns (uint256 fair) {
        bool ok;
        (fair, ok) = controller.nav(uint8(Side.Fair));
        (uint256 bid,) = controller.nav(uint8(Side.Bid));
        require(ok, string.concat("book incomplete after: ", what));
        console.log(string.concat(vm.toString(step), ". ", what));
        console.log("   NAV fair, bid (USD, 1e18):", fair, bid);
        if (step != 0) {
            if (fair >= lastNav) console.log("   change vs before: +", fair - lastNav);
            else console.log("   change vs before: -", lastNav - fair);
        }
        ++step;
    }

    function _inst(string memory label) internal view returns (address) {
        return vm.parseJsonAddress(rec, string.concat(".adapters.", label));
    }

    function _range(int24 tick, int24 spacing, int24 half) internal pure returns (int24 lo, int24 hi) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        lo = c * spacing - (half / spacing) * spacing;
        hi = c * spacing + (half / spacing + 1) * spacing;
    }
}
