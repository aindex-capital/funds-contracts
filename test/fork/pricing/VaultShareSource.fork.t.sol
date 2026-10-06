// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {VaultShareSource} from "../../../src/pricing/sources/VaultShareSource.sol";
import {IPriceRouter, PriceClass, Side} from "../../../src/interfaces/IPriceRouter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {PriceRouter} from "../../../src/pricing/PriceRouter.sol";

/**
 * @notice VaultShareSource against the live PriceRouter and Arcus pTokens on Robinhood Chain (4663). Skipped when
 *         ROBINHOOD_RPC is unset. Each pToken must price at what Arcus' own `convertToAssets` says, in USD through the
 *         router's USDG price.
 */
contract VaultShareSourceForkTest is Test {
    address constant ROUTER = 0x7ca511aeA087381C8a1981A4F9850aE154e624BB;
    address[5] internal tokens = [
        0xe24CABDf76DD1c2576049167eB1755C84b985C36, // pHOOD3x
        0x0053333fCafF9486fA55877044F09137c1A52530, // sHOOD3x
        0xC25c966168a8e933b0aBa0DC8A25Cac4A2b2B91D, // sBTC
        0xB2Cb7371BC45A460F856712a3088c23aCD385DF8, // sGLD5x
        0x4472C69d299382F8847ebCE4FC6Ed8e295510E3e // pBTC3x
    ];

    function test_PricesLivePTokens() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        VaultShareSource source = new VaultShareSource(IPriceRouter(ROUTER));
        for (uint256 i; i < tokens.length; ++i) {
            (uint256 usd,, bool ok) = source.price(tokens[i]);
            (bool s, bytes memory r) = tokens[i].staticcall(abi.encodeWithSignature("convertToAssets(uint256)", 1e18));
            require(s, "convertToAssets");
            uint256 assets = abi.decode(r, (uint256));
            console.log(tokens[i], usd / 1e14, assets);
            assertTrue(ok, "priced");
            // USDG has 6 decimals and trades at its $1 peg within a cent.
            assertApproxEqRel(usd, assets * 1e12, 0.01e18);
        }
    }

    /// @notice The listing as `ListVaultShares` makes it, applied a day later by anyone; then the clock goes back so
    ///         the live feeds are fresh, and the router quotes each pToken with its class and haircut.
    function test_ListedThroughTheLiveRouter() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        PriceRouter router = PriceRouter(ROUTER);
        VaultShareSource source = new VaultShareSource(IPriceRouter(ROUTER));
        uint256 t0 = block.timestamp;
        vm.startPrank(router.owner());
        for (uint256 i; i < tokens.length; ++i) {
            router.propose(tokens[i], PriceRouter.Config({ primary: IPriceSource(address(source)), check: IPriceSource(address(0)),
                class_: PriceClass.Thin, haircutBps: 150, maxDeviationBps: 0, decimals: 0, chained: 0 }));
        }
        vm.stopPrank();
        vm.warp(t0 + router.CONFIG_DELAY());
        for (uint256 i; i < tokens.length; ++i) router.applyPending(tokens[i]);
        vm.warp(t0);
        for (uint256 i; i < tokens.length; ++i) {
            (uint256 fair,,) = source.price(tokens[i]);
            (uint256 bid, PriceClass c, bool ok) = router.value(tokens[i], 1e18, Side.Bid);
            assertTrue(ok, "quoted");
            assertEq(uint8(c), uint8(PriceClass.Thin));
            assertApproxEqRel(bid, fair * 9850 / 10_000, 0.0001e18, "bid 1.5% under fair");
        }
    }
}
