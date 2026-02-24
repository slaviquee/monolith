import { describe, it, mock, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

// We need to mock fetch and viem before importing the module under test.
// Use dynamic imports after setting up mocks.

describe('swap routing', async () => {

  // --- Constants test (no mocking needed) ---

  describe('RPC constants', () => {
    it('chain 1 rpcUrl is publicnode', async () => {
      const { CHAINS } = await import('../lib/constants.js');
      assert.equal(CHAINS[1].rpcUrl, 'https://ethereum-rpc.publicnode.com');
    });

    it('chain 8453 rpcUrl is base mainnet', async () => {
      const { CHAINS } = await import('../lib/constants.js');
      assert.equal(CHAINS[8453].rpcUrl, 'https://mainnet.base.org');
    });
  });

  // --- Routing API tests ---

  describe('tryRoutingAPI', () => {
    let originalFetch;

    beforeEach(() => {
      originalFetch = globalThis.fetch;
    });

    afterEach(() => {
      globalThis.fetch = originalFetch;
    });

    const WETH_MAINNET = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
    const USDC_MAINNET = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
    const UNIVERSAL_ROUTER = '0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD';
    const AMOUNT_IN = 100000000000000000n; // 0.1 ETH

    function makeMockAPIResponse(overrides = {}) {
      return {
        chainId: 1,
        quote: { amount: '250000000', amountDecimals: '250.0' },
        methodParameters: {
          to: UNIVERSAL_ROUTER,
          calldata: '0x3593564c000000000000000000000000000000000000000000000000000000000000abcd',
          value: '100000000000000000',
        },
        ...overrides,
      };
    }

    it('returns intent on valid API response', async () => {
      const mockResponse = makeMockAPIResponse();
      globalThis.fetch = mock.fn(async () => ({
        ok: true,
        json: async () => mockResponse,
      }));

      const { tryRoutingAPI } = await import('../lib/intent-builder.js');
      const result = await tryRoutingAPI(1, WETH_MAINNET, USDC_MAINNET, AMOUNT_IN, 50);

      assert.notEqual(result, null);
      assert.equal(result.target, UNIVERSAL_ROUTER);
      assert.equal(result.calldata, mockResponse.methodParameters.calldata);
      assert.equal(result.value, '100000000000000000');
      assert.equal(result.amountOut, 250000000n);
    });

    it('returns null on non-2xx response', async () => {
      globalThis.fetch = mock.fn(async () => ({
        ok: false,
        status: 500,
      }));

      const { tryRoutingAPI } = await import('../lib/intent-builder.js');
      const result = await tryRoutingAPI(1, WETH_MAINNET, USDC_MAINNET, AMOUNT_IN, 50);
      assert.equal(result, null);
    });

    it('returns null on network error', async () => {
      globalThis.fetch = mock.fn(async () => {
        throw new Error('network down');
      });

      const { tryRoutingAPI } = await import('../lib/intent-builder.js');
      const result = await tryRoutingAPI(1, WETH_MAINNET, USDC_MAINNET, AMOUNT_IN, 50);
      assert.equal(result, null);
    });

    it('returns null when target is unexpected router', async () => {
      const mockResponse = makeMockAPIResponse();
      mockResponse.methodParameters.to = '0x0000000000000000000000000000000000000BAD';

      globalThis.fetch = mock.fn(async () => ({
        ok: true,
        json: async () => mockResponse,
      }));

      const { tryRoutingAPI } = await import('../lib/intent-builder.js');
      const result = await tryRoutingAPI(1, WETH_MAINNET, USDC_MAINNET, AMOUNT_IN, 50);
      assert.equal(result, null);
    });

    it('returns null when response has empty calldata', async () => {
      const mockResponse = makeMockAPIResponse();
      mockResponse.methodParameters.calldata = '0x';

      globalThis.fetch = mock.fn(async () => ({
        ok: true,
        json: async () => mockResponse,
      }));

      const { tryRoutingAPI } = await import('../lib/intent-builder.js');
      const result = await tryRoutingAPI(1, WETH_MAINNET, USDC_MAINNET, AMOUNT_IN, 50);
      assert.equal(result, null);
    });

    it('returns null when chainId in response mismatches', async () => {
      const mockResponse = makeMockAPIResponse({ chainId: 8453 });

      globalThis.fetch = mock.fn(async () => ({
        ok: true,
        json: async () => mockResponse,
      }));

      const { tryRoutingAPI } = await import('../lib/intent-builder.js');
      const result = await tryRoutingAPI(1, WETH_MAINNET, USDC_MAINNET, AMOUNT_IN, 50);
      assert.equal(result, null);
    });
  });

  // --- Fallback quote tests ---

  describe('fallbackQuote', () => {
    it('throws with tier details when all tiers fail (bogus token)', async () => {
      const { fallbackQuote } = await import('../lib/intent-builder.js');

      // Use a bogus token address with no Uniswap pools to force all tiers to fail
      const BOGUS_TOKEN = '0x0000000000000000000000000000000000000001';

      await assert.rejects(
        () => fallbackQuote(
          1,
          '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
          BOGUS_TOKEN,
          100000000000000000n,
          50
        ),
        (err) => {
          assert.match(err.message, /All fee tier quotes failed/);
          assert.match(err.message, /3000/);
          assert.match(err.message, /500/);
          assert.match(err.message, /10000/);
          return true;
        }
      );
    });

    it('returns best quote when multiple tiers succeed (live RPC)', async () => {
      // This test hits real mainnet RPC with a real pair (ETH/USDC).
      // Multiple fee tiers may have pools; verify we get the best one.
      const { fallbackQuote } = await import('../lib/intent-builder.js');

      const result = await fallbackQuote(
        1,
        '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
        '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
        100000000000000000n, // 0.1 ETH
        50
      );

      assert.ok(result.fee > 0, 'fee should be positive');
      assert.ok(result.amountOut > 0n, 'amountOut should be positive');
      assert.ok(result.amountOutMin > 0n, 'amountOutMin should be positive');
      assert.ok(result.amountOutMin < result.amountOut, 'amountOutMin should be less than amountOut (slippage applied)');
    });
  });

  // --- buildSwapIntent integration (API path) ---

  describe('buildSwapIntent', () => {
    let originalFetch;

    beforeEach(() => {
      originalFetch = globalThis.fetch;
    });

    afterEach(() => {
      globalThis.fetch = originalFetch;
    });

    it('uses routing API when available and returns valid intent', async () => {
      const mockResponse = {
        chainId: 1,
        quote: { amount: '250000000' },
        methodParameters: {
          to: '0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD',
          calldata: '0x3593564c000000000000000000000000000000000000000000000000000000000000abcd',
          value: '100000000000000000',
        },
      };

      globalThis.fetch = mock.fn(async () => ({
        ok: true,
        json: async () => mockResponse,
      }));

      const { buildSwapIntent } = await import('../lib/intent-builder.js');
      const intent = await buildSwapIntent(1, 100000000000000000n, 'USDC', 50);

      assert.equal(intent.target, '0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD');
      assert.equal(intent.chainHint, '1');
      assert.equal(intent.source, 'routing-api');
      assert.equal(intent.quotedAmountOut, 250000000n);
      // Verify standard intent shape
      assert.ok(intent.calldata);
      assert.ok(intent.value);
    });

    it('falls back to on-chain quoter when API fails', async () => {
      globalThis.fetch = mock.fn(async () => ({
        ok: false,
        status: 503,
      }));

      const { buildSwapIntent } = await import('../lib/intent-builder.js');

      // Use a bogus token address so the fallback fails fast (no real pools)
      // This verifies the fallback path is reached (error comes from tier probing, not API)
      try {
        await buildSwapIntent(1, 100000000000000000n, '0x0000000000000000000000000000000000000001', 50);
        assert.fail('Should have thrown');
      } catch (err) {
        assert.match(err.message, /All fee tier quotes failed/);
      }
    });

    it('returns correct intent shape with chainHint', async () => {
      const mockResponse = {
        chainId: 8453,
        quote: { amount: '250000000' },
        methodParameters: {
          to: '0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD',
          calldata: '0x3593564c0000000000000000000000000000000000000000000000000000000000001234',
          value: '50000000000000000',
        },
      };

      globalThis.fetch = mock.fn(async () => ({
        ok: true,
        json: async () => mockResponse,
      }));

      const { buildSwapIntent } = await import('../lib/intent-builder.js');
      const intent = await buildSwapIntent(8453, 50000000000000000n, 'USDC', 50);

      assert.equal(intent.chainHint, '8453');
      assert.equal(typeof intent.target, 'string');
      assert.equal(typeof intent.calldata, 'string');
      assert.equal(typeof intent.value, 'string');
    });
  });

  // --- resolveTokenOutAddress ---

  describe('resolveTokenOutAddress', () => {
    it('resolves USDC to correct address on chain 1', async () => {
      const { resolveTokenOutAddress } = await import('../lib/intent-builder.js');
      assert.equal(
        resolveTokenOutAddress('USDC', 1),
        '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'
      );
    });

    it('resolves USDC to correct address on chain 8453', async () => {
      const { resolveTokenOutAddress } = await import('../lib/intent-builder.js');
      assert.equal(
        resolveTokenOutAddress('USDC', 8453),
        '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
      );
    });

    it('passes through hex addresses', async () => {
      const { resolveTokenOutAddress } = await import('../lib/intent-builder.js');
      const addr = '0x1234567890abcdef1234567890abcdef12345678';
      assert.equal(resolveTokenOutAddress(addr, 1), addr);
    });

    it('throws for unsupported token symbol', async () => {
      const { resolveTokenOutAddress } = await import('../lib/intent-builder.js');
      assert.throws(() => resolveTokenOutAddress('DAI', 1), /Unsupported output token/);
    });
  });
});
