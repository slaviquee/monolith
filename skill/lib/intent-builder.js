import {
  encodeFunctionData,
  encodeAbiParameters,
  encodePacked,
  createPublicClient,
  http,
} from 'viem';
import { mainnet, base } from 'viem/chains';
import {
  STABLECOINS,
  ERC20_TRANSFER_ABI,
  CHAINS,
  UNISWAP,
  V3_FEES,
  QUOTER_V2_ABI,
} from './constants.js';

/**
 * Build intents ({target, calldata, value}) for common actions.
 * The skill is UNTRUSTED — it MUST NOT set nonce, gas, chainId, fees, or signatures.
 * Only target, calldata, value, and optionally chainHint.
 */

/**
 * Build a native ETH transfer intent.
 */
export function buildETHTransfer(to, amountWei, chainId) {
  const intent = {
    target: to,
    calldata: '0x',
    value: amountWei.toString(),
  };
  if (chainId) intent.chainHint = chainId.toString();
  return intent;
}

/**
 * Build an ERC-20 transfer intent.
 * @param {string} tokenAddress - The ERC-20 contract address.
 * @param {string} to - Recipient address.
 * @param {bigint} amount - Amount in token's smallest unit.
 */
export function buildERC20Transfer(tokenAddress, to, amount) {
  const calldata = encodeFunctionData({
    abi: ERC20_TRANSFER_ABI,
    functionName: 'transfer',
    args: [to, amount],
  });

  return {
    target: tokenAddress,
    calldata,
    value: '0',
  };
}

/**
 * Build a USDC transfer intent for a specific chain.
 * @param {number} chainId - Chain ID (1 or 8453).
 * @param {string} to - Recipient address.
 * @param {number} amountUSDC - Amount in human-readable USDC (e.g., 100 for 100 USDC).
 */
export function buildUSDCTransfer(chainId, to, amountUSDC) {
  const stables = STABLECOINS[chainId];
  if (!stables) throw new Error(`No stablecoins configured for chain ${chainId}`);

  const [usdcAddress, info] = Object.entries(stables)[0];
  const amount = BigInt(Math.round(amountUSDC * 10 ** info.decimals));

  return {
    ...buildERC20Transfer(usdcAddress, to, amount),
    chainHint: chainId.toString(),
  };
}

/**
 * Get the USDC contract address for a chain.
 * Lookup is by (chainId, address) tuple — never by symbol string.
 * @param {number} chainId - Chain ID (1 or 8453).
 * @returns {string|null} USDC contract address or null if not configured.
 */
export function getUSDCAddress(chainId) {
  const stables = STABLECOINS[chainId];
  if (!stables) return null;

  // USDC addresses are the first (and currently only) entry per chain
  // Identified by (chainId, contractAddress), not by symbol
  const usdcAddresses = {
    1: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    8453: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  };

  return usdcAddresses[chainId] || null;
}

/**
 * Query Uniswap V3 QuoterV2 for expected output amount.
 * Read-only RPC call — no daemon needed.
 * @param {number} chainId
 * @param {string} tokenIn - Input token address.
 * @param {string} tokenOut - Output token address.
 * @param {bigint} amountIn - Input amount in smallest unit.
 * @param {number} fee - Pool fee tier (e.g., 500, 3000).
 * @returns {Promise<bigint>} Expected output amount.
 */
export async function quoteExactInputSingle(chainId, tokenIn, tokenOut, amountIn, fee) {
  const chain = chainId === 1 ? mainnet : base;
  const client = createPublicClient({
    chain,
    transport: http(CHAINS[chainId].rpcUrl),
  });

  const quoterAddress = UNISWAP.QUOTER_V2[chainId];
  if (!quoterAddress) throw new Error(`No QuoterV2 for chain ${chainId}`);

  const [amountOut] = await client.readContract({
    address: quoterAddress,
    abi: QUOTER_V2_ABI,
    functionName: 'quoteExactInputSingle',
    args: [
      {
        tokenIn,
        tokenOut,
        amountIn,
        fee,
        sqrtPriceLimitX96: 0n,
      },
    ],
  });

  return amountOut;
}

/**
 * Build a V3 swap path (packed encoding: tokenIn + fee + tokenOut).
 */
function buildV3Path(tokenIn, fee, tokenOut) {
  return encodePacked(
    ['address', 'uint24', 'address'],
    [tokenIn, fee, tokenOut]
  );
}

/**
 * Build a full Uniswap Universal Router swap intent (ETH → token).
 * Queries the QuoterV2 for a fresh price quote and applies slippage.
 *
 * @param {number} chainId - Chain ID (1 or 8453).
 * @param {bigint} amountInWei - ETH amount in wei.
 * @param {string} tokenOut - Output token symbol ('USDC') or address.
 * @param {number} [maxSlippageBps=50] - Max slippage in basis points (default 0.5%).
 * @returns {Promise<{target: string, calldata: string, value: string, chainHint: string}>}
 */
export async function buildSwapIntent(chainId, amountInWei, tokenOut = 'USDC', maxSlippageBps = 50) {
  const weth = UNISWAP.WETH[chainId];
  if (!weth) throw new Error(`No WETH address for chain ${chainId}`);

  // Resolve token out address
  let tokenOutAddress;
  if (tokenOut.startsWith('0x')) {
    tokenOutAddress = tokenOut;
  } else if (tokenOut.toUpperCase() === 'USDC') {
    tokenOutAddress = getUSDCAddress(chainId);
    if (!tokenOutAddress) throw new Error(`No USDC address for chain ${chainId}`);
  } else {
    throw new Error(`Unsupported output token: ${tokenOut}`);
  }

  // ETH→USDC typically uses the 500 (0.05%) fee tier on mainnet/Base
  const fee = V3_FEES.LOW;

  // 1. Get fresh quote from QuoterV2
  const quotedAmountOut = await quoteExactInputSingle(
    chainId, weth, tokenOutAddress, amountInWei, fee
  );

  // 2. Apply slippage to get amountOutMin
  const amountOutMin = quotedAmountOut * BigInt(10000 - maxSlippageBps) / 10000n;

  // 3. Build Universal Router calldata
  // Commands: WRAP_ETH (0x0b) + V3_SWAP_EXACT_IN (0x00)
  const commands = '0x0b00';

  // WRAP_ETH input: abi.encode(address recipient, uint256 amount)
  // Recipient = ADDRESS_THIS (router holds WETH temporarily)
  const wrapInput = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    [UNISWAP.ADDRESS_THIS, amountInWei]
  );

  // V3_SWAP_EXACT_IN input: abi.encode(address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool payerIsUser)
  // Recipient = MSG_SENDER (output tokens go to the wallet)
  // payerIsUser = false (router already has WETH from WRAP_ETH step)
  const path = buildV3Path(weth, fee, tokenOutAddress);
  const swapInput = encodeAbiParameters(
    [
      { type: 'address' },
      { type: 'uint256' },
      { type: 'uint256' },
      { type: 'bytes' },
      { type: 'bool' },
    ],
    [UNISWAP.MSG_SENDER, amountInWei, amountOutMin, path, false]
  );

  // 4. Encode the full execute(bytes,bytes[],uint256) call
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800); // 30 minutes
  const calldata = encodeFunctionData({
    abi: [
      {
        type: 'function',
        name: 'execute',
        inputs: [
          { name: 'commands', type: 'bytes' },
          { name: 'inputs', type: 'bytes[]' },
          { name: 'deadline', type: 'uint256' },
        ],
        outputs: [],
        stateMutability: 'payable',
      },
    ],
    functionName: 'execute',
    args: [commands, [wrapInput, swapInput], deadline],
  });

  return {
    target: UNISWAP.UNIVERSAL_ROUTER,
    calldata,
    value: amountInWei.toString(),
    chainHint: chainId.toString(),
  };
}
