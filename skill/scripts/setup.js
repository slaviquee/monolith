import { runSetupWizard } from '../lib/setup-wizard.js';

/**
 * Run the ClawVault setup wizard and print status.
 * Usage: node scripts/setup.js
 */
async function main() {
  try {
    const status = await runSetupWizard();

    if (status.error) {
      console.error(`Setup error: ${status.error}`);
      process.exit(1);
    }

    // Daemon info
    console.log(`Daemon: running (v${status.daemon.version})`);

    // Wallet info
    if (status.wallet) {
      console.log(`Wallet address: ${status.wallet.address}`);
      console.log(`Signer public key: ${status.wallet.signerPublicKey}`);
      console.log(`Home chain: ${status.wallet.homeChainId}`);
      console.log(`Deployed: ${status.wallet.deployed ? 'Yes' : 'No'}`);
    }

    // Capabilities
    if (status.capabilities) {
      console.log(`Profile: ${status.capabilities.profile}`);
      console.log(`Frozen: ${status.capabilities.frozen}`);
      console.log(`Gas status: ${status.capabilities.gasStatus}`);

      if (status.capabilities.limits) {
        const l = status.capabilities.limits;
        console.log('Limits:');
        if (l.perTxEthCap) console.log(`  Per-tx ETH cap: ${l.perTxEthCap}`);
        if (l.perTxStablecoinCap) console.log(`  Per-tx stablecoin cap: ${l.perTxStablecoinCap}`);
        if (l.maxTxPerHour) console.log(`  Max tx/hour: ${l.maxTxPerHour}`);
        if (l.maxSlippageBps) console.log(`  Max slippage: ${l.maxSlippageBps / 100}%`);
      }

      if (status.capabilities.remaining) {
        const r = status.capabilities.remaining;
        console.log('Daily remaining:');
        if (r.ethDaily) console.log(`  ETH: ${r.ethDaily}`);
        if (r.stablecoinDaily) console.log(`  Stablecoin: ${r.stablecoinDaily}`);
      }

      if (status.capabilities.allowedProtocols) {
        console.log(`Allowed protocols: ${status.capabilities.allowedProtocols.join(', ')}`);
      }
    }

    // Policy
    if (status.policy) {
      console.log('Policy: configured');
    } else {
      console.log('Policy: not yet configured');
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}

main();
