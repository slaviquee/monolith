import { daemon } from '../lib/daemon-client.js';
import { buildSwapIntent, quoteExactInputSingle, getUSDCAddress } from '../lib/intent-builder.js';
import { formatDaemonError } from '../lib/format.js';
import { validateChainId, UNISWAP, V3_FEES } from '../lib/constants.js';

/**
 * Swap ETH for tokens via Uniswap Universal Router.
 * Queries QuoterV2 for a fresh price, encodes full calldata with slippage protection.
 *
 * Usage: node scripts/swap.js <amountETH> [tokenOut] [chainId] [approvalCode]
 *   amountETH: amount of ETH to swap (e.g., "0.1")
 *   tokenOut: "USDC" (default) or a token address
 *   chainId: 1 or 8453 (default: 8453)
 *   approvalCode: 8-digit code from notification (if re-submitting after 202)
 */
async function main() {
  const [, , amountETH, tokenOut = 'USDC', chainIdStr, approvalCode] = process.argv;

  if (!amountETH) {
    console.error('Usage: swap <amountETH> [tokenOut] [chainId] [approvalCode]');
    process.exit(1);
  }

  const chainId = chainIdStr ? parseInt(chainIdStr, 10) : 8453;
  validateChainId(chainId);
  const amountWei = BigInt(Math.round(parseFloat(amountETH) * 1e18));

  // Get a fresh quote first for display
  const weth = UNISWAP.WETH[chainId];
  let tokenOutAddress;
  if (tokenOut.startsWith('0x')) {
    tokenOutAddress = tokenOut;
  } else if (tokenOut.toUpperCase() === 'USDC') {
    tokenOutAddress = getUSDCAddress(chainId);
  } else {
    console.error(`Unsupported output token: ${tokenOut}. Use USDC or a contract address.`);
    process.exit(1);
  }

  console.log(`Quoting ${amountETH} ETH -> ${tokenOut} on chain ${chainId}...`);

  let quotedAmount;
  try {
    quotedAmount = await quoteExactInputSingle(
      chainId, weth, tokenOutAddress, amountWei, V3_FEES.LOW
    );
    const decimals = tokenOut.toUpperCase() === 'USDC' ? 6 : 18;
    const humanAmount = Number(quotedAmount) / 10 ** decimals;
    console.log(`Quote: ~${humanAmount.toFixed(decimals === 6 ? 2 : 6)} ${tokenOut}`);
  } catch (err) {
    console.error(`Failed to get quote: ${err.message}`);
    console.error('The QuoterV2 call failed. Check that the pool exists for this pair/fee.');
    process.exit(1);
  }

  // Build the full swap intent with slippage protection
  // Default 0.5% slippage (50 bps) — daemon will verify this is within profile limits
  const maxSlippageBps = 50;
  let intent;
  try {
    intent = await buildSwapIntent(chainId, amountWei, tokenOut, maxSlippageBps);
  } catch (err) {
    console.error(`Failed to build swap intent: ${err.message}`);
    process.exit(1);
  }

  // Attach approval code if re-submitting after a 202
  if (approvalCode) {
    intent.approvalCode = approvalCode;
  }

  console.log(`Swap intent: ${amountETH} ETH -> ${tokenOut} (max slippage: ${maxSlippageBps / 100}%)`);

  try {
    const response = await daemon.sign(intent);

    if (response.status === 200) {
      console.log(`Transaction submitted: ${response.data.userOpHash}`);
    } else if (response.status === 202) {
      console.log(`Approval required: ${response.data.reason}`);
      console.log(`Summary: ${response.data.summary}`);
      console.log(`Expires in: ${response.data.expiresIn}s`);
      console.log(`\nTo approve, re-run with the 8-digit code from your notification:`);
      console.log(`  swap ${amountETH} ${tokenOut} ${chainId} <approvalCode>`);
    } else {
      console.error(formatDaemonError(response));
      process.exit(1);
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}

main();
