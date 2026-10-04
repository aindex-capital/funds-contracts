#!/usr/bin/env node
// Fetches a KyberSwap route on Robinhood Chain for the AggregatorSwapAdapter fork test and prints it as
// shell exports. Forge tests may not call out (vm.ffi is off), so the route is fetched first and passed in.
//
//   eval "$(node test/fork/adapters/spot/kyber-route.mjs <adapterClone> [amountInRaw] [slippageBps])"
//   ROBINHOOD_RPC=... forge test --match-path 'test/fork/adapters/spot/*' -vv
//
// <adapterClone> is the swap adapter clone address the fork test deploys; `test_PrintSwapAdapter` prints it
// and it is deterministic (same deployer, same nonces). It is both the sender and the recipient of the route,
// because the adapter is what holds the USDG and must receive the NVDA. Defaults: 10 USDG in, 100 bps slippage.
// Run the test within a few minutes: the route is priced against current pools and carries a deadline.

const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const NVDA = "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC"; // Robinhood's NVDA stock token
const API = "https://aggregator-api.kyberswap.com/robinhood/api/v1";
const HEADERS = { accept: "application/json", "content-type": "application/json", "user-agent": "Mozilla/5.0" };

const [adapter, amountIn = "10000000", slippageBps = "100"] = process.argv.slice(2);
if (!/^0x[0-9a-fA-F]{40}$/.test(adapter ?? "")) {
  console.error("usage: kyber-route.mjs <adapterClone> [amountInRaw] [slippageBps]");
  process.exit(1);
}

// Kyber's Robinhood endpoint answers 503 intermittently, so each call gets a few tries.
async function call(url, body) {
  for (let i = 0; i < 6; i++) {
    const r = await fetch(url, body ? { method: "POST", headers: HEADERS, body: JSON.stringify(body) } : { headers: HEADERS });
    if (r.ok) return r.json();
    if (r.status !== 429 && r.status < 500) throw new Error(`${r.status} ${await r.text()}`);
    await new Promise((s) => setTimeout(s, 700 * (i + 1)));
  }
  throw new Error("KyberSwap unreachable");
}

const q = await call(`${API}/routes?tokenIn=${USDG}&tokenOut=${NVDA}&amountIn=${amountIn}`);
const summary = q?.data?.routeSummary;
if (!summary?.amountOut) throw new Error("no route: " + JSON.stringify(q).slice(0, 300));
const b = await call(`${API}/route/build`, {
  routeSummary: summary,
  sender: adapter,
  recipient: adapter,
  slippageTolerance: Number(slippageBps),
});
const d = b?.data;
if (!d?.data) throw new Error("build failed: " + JSON.stringify(b).slice(0, 300));
const minOut = (BigInt(d.amountOut) * BigInt(10_000 - Number(slippageBps))) / 10_000n;

console.log(`export KYBER_SENDER=${adapter}`);
console.log(`export KYBER_TARGET=${d.routerAddress}`);
console.log(`export KYBER_AMOUNT_IN=${amountIn}`);
console.log(`export KYBER_MIN_OUT=${minOut}`);
console.log(`export KYBER_DATA=${d.data}`);
console.error(`kyber: ${amountIn} USDG raw -> ${d.amountOut} NVDA raw (min ${minOut}) via ${d.routerAddress}`);
