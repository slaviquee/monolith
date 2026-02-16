import { daemon } from '../lib/daemon-client.js';
import { formatDaemonError } from '../lib/format.js';

/**
 * ERC-8004 identity operations.
 * Usage: node scripts/identity.js [query|register]
 */
async function main() {
  const [, , action = 'query'] = process.argv;

  if (action === 'query') {
    // Read-only — get wallet address for identity lookup
    try {
      const addr = await daemon.address();
      if (addr.status === 200) {
        console.log(`Wallet: ${addr.data.walletAddress}`);
        console.log(`Chain: ${addr.data.homeChainId}`);
        console.log(
          'ERC-8004 identity query: check the registry on the home chain'
        );
      } else {
        console.error(formatDaemonError(addr));
      }
    } catch (err) {
      console.error(err.message);
    }
  } else if (action === 'register') {
    console.log('ERC-8004 registration requires building an intent.');
    console.log('Use the daemon /sign endpoint with the registration calldata.');
  } else {
    console.error('Usage: identity [query|register]');
    process.exit(1);
  }
}

main();
