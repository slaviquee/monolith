import { daemon } from './daemon-client.js';

/**
 * Setup flow for ClawVault (per spec §3.2).
 * The skill presents status; the actual interactive flow (chain selection,
 * profile selection, etc.) happens through the daemon's setup/config endpoints.
 */

/**
 * Check if the daemon is running and healthy.
 */
export async function checkDaemonHealth() {
  try {
    const response = await daemon.health();
    return {
      running: response.status === 200,
      version: response.data?.version,
    };
  } catch {
    return { running: false, version: null };
  }
}

/**
 * Get the wallet address and setup status.
 */
export async function getSetupStatus() {
  try {
    const health = await checkDaemonHealth();
    if (!health.running) {
      return {
        step: 'daemon_not_running',
        message: 'The ClawVault daemon is not running. Please start it first.',
      };
    }

    const addr = await daemon.address();
    if (addr.status !== 200) {
      return {
        step: 'error',
        message: 'Could not get wallet address from daemon.',
      };
    }

    const caps = await daemon.capabilities();

    return {
      step: addr.data.walletAddress === 'not deployed' ? 'needs_deploy' : 'ready',
      walletAddress: addr.data.walletAddress,
      signerPublicKey: addr.data.signerPublicKey,
      homeChainId: addr.data.homeChainId,
      profile: caps.data?.profile,
      frozen: caps.data?.frozen,
      gasStatus: caps.data?.gasStatus,
    };
  } catch (err) {
    return {
      step: 'error',
      message: err.message,
    };
  }
}

/**
 * Run the setup wizard — gathers full status per spec §3.2.
 * Checks daemon health, wallet address, capabilities, and policy,
 * then returns structured data for each step so the agent can present it.
 *
 * @returns {Promise<object>} Structured setup status including:
 *   - daemon: { running, version }
 *   - wallet: { address, signerPublicKey, homeChainId, deployed }
 *   - capabilities: { profile, frozen, gasStatus, limits, remaining, allowedProtocols }
 *   - policy: current policy configuration (if available)
 *   - error: error message if something went wrong
 */
export async function runSetupWizard() {
  const result = {
    daemon: null,
    wallet: null,
    capabilities: null,
    policy: null,
    error: null,
  };

  // Step 1: Check daemon health
  try {
    const health = await checkDaemonHealth();
    result.daemon = health;
    if (!health.running) {
      result.error = 'The ClawVault daemon is not running. Please start it first.';
      return result;
    }
  } catch (err) {
    result.error = `Daemon health check failed: ${err.message}`;
    return result;
  }

  // Step 2: Get wallet address and key info
  try {
    const addr = await daemon.address();
    if (addr.status === 200) {
      result.wallet = {
        address: addr.data.walletAddress,
        signerPublicKey: addr.data.signerPublicKey,
        homeChainId: addr.data.homeChainId,
        deployed: addr.data.walletAddress !== 'not deployed',
      };
    } else {
      result.error = 'Could not get wallet address from daemon.';
      return result;
    }
  } catch (err) {
    result.error = `Failed to get wallet address: ${err.message}`;
    return result;
  }

  // Step 3: Get capabilities (profile, limits, budgets, gas)
  try {
    const caps = await daemon.capabilities();
    if (caps.status === 200) {
      result.capabilities = {
        profile: caps.data.profile,
        frozen: caps.data.frozen,
        gasStatus: caps.data.gasStatus,
        limits: caps.data.limits,
        remaining: caps.data.remaining,
        allowedProtocols: caps.data.allowedProtocols,
      };
    }
  } catch {
    // Non-fatal — capabilities may not be available before full setup
  }

  // Step 4: Get current policy configuration
  try {
    const pol = await daemon.policy();
    if (pol.status === 200) {
      result.policy = pol.data;
    }
  } catch {
    // Non-fatal — policy may not be configured yet
  }

  return result;
}

/**
 * Initialize the wallet with chain and profile configuration.
 * Calls POST /setup on the daemon.
 *
 * @param {object} params - { chainId: number, profile: string, recoveryAddress?: string }
 * @returns {Promise<object>} Setup result with walletAddress, precompileAvailable, etc.
 */
export async function initializeWallet(params) {
  const { chainId, profile, recoveryAddress } = params;
  if (!chainId || !profile) {
    throw new Error('chainId and profile are required');
  }

  const body = { chainId, profile };
  if (recoveryAddress) {
    body.recoveryAddress = recoveryAddress;
  }

  const response = await daemon.setup(body);
  if (response.status !== 200) {
    throw new Error(
      response.data?.error || `Setup failed with status ${response.status}`
    );
  }
  return response.data;
}

/**
 * Deploy the wallet on-chain.
 * Requires the wallet to be funded first.
 * Calls POST /setup/deploy on the daemon.
 *
 * @returns {Promise<object>} Deploy result with walletAddress, userOpHash, etc.
 */
export async function deployWallet() {
  const response = await daemon.setupDeploy();
  if (response.status !== 200) {
    throw new Error(
      response.data?.error || `Deploy failed with status ${response.status}`
    );
  }
  return response.data;
}
