#!/usr/bin/env node
// A KyberSwap route on Robinhood Chain for a Fund's swap adapter clone, printed as shell exports with a prefix.
// Forge scripts may not call out, so the route is fetched first and passed in through the environment.
//
//   eval "$(node script/rehearsal/kyber-route.mjs <swapClone> <tokenOut> <amountInUsdgRaw> <PREFIX> [deadline] [slippageBps])"
//
// The clone is both sender and recipient: it holds the USDG during the action and must receive the output.
// deadline (unix seconds) defaults to now + 20 minutes; the rehearsal passes a later one because it warps the
// fork's clock a day ahead. Prints PREFIX_SENDER, PREFIX_TARGET, PREFIX_AMOUNT_IN, PREFIX_MIN_OUT, PREFIX_DATA.

const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const API = "https://aggregator-api.kyberswap.com/robinhood/api/v1";
const HEADERS = { accept: "application/json", "content-type": "application/json", "user-agent": "Mozilla/5.0" };

const [clone, tokenOut, amountIn, prefix, deadlineArg, slippageBps = "150"] = process.argv.slice(2);
if (!/^0x[0-9a-fA-F]{40}$/.test(clone ?? "") || !/^0x[0-9a-fA-F]{40}$/.test(tokenOut ?? "") || !amountIn || !prefix) {
  console.error("usage: kyber-route.mjs <swapClone> <tokenOut> <amountInUsdgRaw> <PREFIX> [deadline] [slippageBps]");
  process.exit(1);
}
const deadline = Number(deadlineArg ?? Math.floor(Date.now() / 1000) + 1200);

// Kyber's Robinhood endpoint answers 503 now and then, so each call gets a few tries.
async function call(url, body) {
  for (let i = 0; i < 6; i++) {
    const r = await fetch(url, body ? { method: "POST", headers: HEADERS, body: JSON.stringify(body) } : { headers: HEADERS });
    if (r.ok) return r.json();
    if (r.status !== 429 && r.status < 500) throw new Error(`${r.status} ${await r.text()}`);
    await new Promise((s) => setTimeout(s, 700 * (i + 1)));
  }
  throw new Error("KyberSwap unreachable");
}

// RFQ and Ekubo v3 sources are left out on the fork: the fork's clock runs ahead of the real one, so RFQ quotes
// (real-time expiry) cannot settle, and Ekubo v3 needs an Osaka opcode forge's and anvil's EVM lack.
const q = await call(
  `${API}/routes?tokenIn=${USDG}&tokenOut=${tokenOut}&amountIn=${amountIn}&excludeRFQSources=true&excludedSources=ekubo-v3,ekubo`,
);
const summary = q?.data?.routeSummary;
if (!summary?.amountOut) throw new Error("no route: " + JSON.stringify(q).slice(0, 300));
const b = await call(`${API}/route/build`, {
  routeSummary: summary,
  sender: clone,
  recipient: clone,
  slippageTolerance: Number(slippageBps),
  deadline,
});
const d = b?.data;
if (!d?.data) throw new Error("build failed: " + JSON.stringify(b).slice(0, 300));
const minOut = (BigInt(d.amountOut) * BigInt(10_000 - Number(slippageBps))) / 10_000n;

console.log(`export ${prefix}_SENDER=${clone}`);
console.log(`export ${prefix}_TARGET=${d.routerAddress}`);
console.log(`export ${prefix}_AMOUNT_IN=${amountIn}`);
console.log(`export ${prefix}_MIN_OUT=${minOut}`);
console.log(`export ${prefix}_DATA=${d.data}`);
console.error(`kyber: ${amountIn} USDG raw -> ${d.amountOut} raw of ${tokenOut} (min ${minOut}) via ${d.routerAddress}`);
