# Monolith

Secure crypto wallet for AI agents. Hardware-isolated keys, on-chain spending caps, default-deny policy engine.

Monolith lets OpenClaw agents hold funds, transact on-chain, and maintain a verifiable identity -- without ever exposing private keys to the LLM, the network, or any third party.

## Architecture

```
OpenClaw Agent (LLM)
  │
  │  natural language → structured intent
  ▼
┌────────────────────────────┐
│  Skill (Node.js)           │  UNTRUSTED
│  Emits: { target,          │  Runs inside OpenClaw
│    calldata, value }       │  NO nonce/gas/fees
└────────────┬───────────────┘
             │  Unix socket (same-user only)
             ▼
┌────────────────────────────┐       XPC (Mach service)       ┌──────────────────────────┐
│  Signing Daemon (Swift)    │◄──────────────────────────────►│  Companion App (SwiftUI) │
│  - Policy enforcement      │  Owns UserOp construction      │  - Touch ID prompts      │
│  - Secure Enclave signing  │  Gas preflight check           │  - Approval UI           │
│  - Freeze integrity sync   │  On-chain freeze sync          │  - Menu bar status       │
└────────────┬───────────────┘                                 └──────────────────────────┘
             │  signed UserOperation
             ▼
┌────────────────────────────┐
│  ERC-4337 Bundler          │  Pimlico public endpoint
└────────────┬───────────────┘
             ▼
┌────────────────────────────┐
│  Smart Contract Wallet     │  ON-CHAIN (trustless)
│  - P-256 sig verification  │  EIP-7951 / RIP-7212
│  - On-chain spending caps  │  Coinbase Smart Wallet fork
│  - Recovery with timelocks │  48h key rotation, 10m unfreeze
└────────────────────────────┘
```

The key security insight: **the skill is untrusted**. A fully compromised LLM or skill cannot drain funds, replay transactions, or loosen spending policy. Defense is layered across the daemon (local policy), the contract (on-chain caps), and hardware (Secure Enclave).

## Components

### `contracts/` -- Solidity Smart Wallet

ERC-4337 smart wallet with P-256 signature verification, on-chain spending caps, and recovery.

- **MonolithWallet** -- Single-owner P-256 wallet. `validateUserOp` verifies signatures using the precompile at `0x100` (EIP-7951/RIP-7212) with Daimo P256Verifier fallback. Raw `r||s` signature format with low-S enforcement.
- **MonolithFactory** -- CREATE2 deterministic deployment. Compatible with ERC-4337 `initCode` pattern.
- **Spending Policy** -- Daily cap tracking both native ETH and ERC-20 transfers (`transfer` + `transferFrom`). Known stablecoin registry per-chain.
- **Recovery** -- `freeze()` (instant, callable by signer or recovery address), `unfreeze` (10min timelock), `initiateKeyRotation` (auto-freezes, 48h timelock).

48 passing tests.

### `daemon/` -- Swift Signing Daemon

macOS background service. Zero external dependencies -- CryptoKit + Foundation only.

- **Secure Enclave** -- Two P-256 keys: signing key (no user presence, for routine ops) and admin key (Touch ID required, for policy changes).
- **Policy Engine** -- Default-deny. Evaluates every signing request against spending limits, selector blocklists, protocol allowlists, and slippage limits.
- **Slippage Verification** -- Decodes Uniswap V3 Universal Router calldata, queries QuoterV2 for fresh market prices, rejects swaps exceeding profile slippage limits.
- **Approval Manager** -- 8-digit codes shared with companion app over XPC. Rate-limited (3 failures per approval, 5/min global). 3-minute expiry.
- **UserOp Builder** -- Constructs complete ERC-4337 UserOperations with gas estimation via Pimlico bundler.
- **Audit Logger** -- Append-only log with redaction (no approval codes or key material).
- **Unix Socket API** -- `~/.monolith/daemon.sock` with peer UID verification. HTTP-style request/response over the socket.

Runs as a `launchd` LaunchAgent (`com.monolith.daemon`).

### `companion/` -- Menu Bar App

SwiftUI menu bar app (`LSUIElement`). Handles all human-facing interactions.

- **Touch ID Prompts** -- `LAContext` biometric authentication for admin operations (policy changes, allowlist edits, unfreeze).
- **Approval UI** -- SwiftUI sheet displaying trusted admin-action summaries; approval codes are delivered through system notifications and hidden in the menu list.
- **Freeze Status** -- Menu bar icon shows wallet freeze state.
- **XPC Connection** -- Bidirectional Mach service communication with the daemon. Code-signing verified in release builds.

Required for admin operations. Routine signing within policy works without the companion.

### `skill/` -- OpenClaw Skill

Node.js scripts that translate agent intents into daemon API calls. Minimal dependency: `viem` for ABI encoding.

| Command | Description |
|---------|-------------|
| `send <to> <amount> [token] [chainId]` | Send ETH or USDC |
| `swap <amountETH> [tokenOut] [chainId]` | Swap via Uniswap with slippage protection |
| `balance <address> [chainId]` | Check balances (read-only, no daemon) |
| `panic` | Emergency freeze -- instant, no Touch ID |
| `capabilities` | Show current limits, budgets, gas status |
| `status` | Daemon health and wallet info |
| `policy` | View/update spending policy |
| `allowlist <add\|remove> <address>` | Manage allowlist (Touch ID) |
| `setup` | Initial configuration wizard |

## Security Model

### What works on autopilot

- ETH and USDC transfers within limits to allowlisted addresses
- Swaps on allowlisted DEXes within slippage limits
- DeFi deposits/withdrawals on allowlisted protocols

### What always requires approval

- Transfers over spending caps or to unknown addresses
- Token approvals (`approve`, `permit`, `setApprovalForAll`)
- Unknown calldata (default-deny)
- Swaps exceeding slippage limits
- Multi-hop swaps

### Security Profiles

| | Balanced | Autonomous |
|---|---|---|
| Per-tx | 100 USDC / 0.05 ETH | 250 USDC / 0.15 ETH |
| Daily | 500 USDC / 0.25 ETH | 2000 USDC / 0.75 ETH |
| Tx rate | 10/hr | 30/hr |
| Max slippage | 1% | 2% |
| Protocols | Uniswap, Aave | + Aerodrome (Base), Lido, Rocket Pool (L1) |

### Panic Asymmetry

Freezing is fast and easy. Unfreezing is slow and deliberate.

- `freeze()` -- instant, no Touch ID, callable by signer or recovery address
- `unfreeze` -- requires Touch ID + 10-minute delay
- Key rotation -- auto-freezes + 48-hour delay

## Supported Chains

- Ethereum Mainnet (chainId 1)
- Base (chainId 8453)

## Prerequisites

- macOS 14+ with Apple Silicon or T2 chip (Secure Enclave required)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) for contract development
- Swift 5.9+ (included with Xcode 15+)
- Node.js 18+

## Quick Start

### Production Install (Recommended)

Install signed and notarized artifacts from the latest release:

- Daemon installer package (`MonolithDaemon.pkg`)
- Companion app archive (`MonolithCompanion.app.zip`)

Release page: <https://github.com/slaviquee/monolith/releases/latest>

After installing both components, run `monolith setup`. The setup flow prints actionable diagnostics and manual startup commands if a local component is missing or not running.

### Build From Source (Developer)

```bash
# Contracts
cd contracts && forge build

# Daemon
cd daemon && swift build

# Companion app
cd companion && swift build

# Skill
cd skill && npm install
```

### Test

```bash
# Contract tests (48 tests)
cd contracts && forge test

# Daemon unit tests
cd daemon && swift test
```

### Manual Daemon Install (Developer)

```bash
# Configure your Apple Developer Team ID (required for release builds)
scripts/configure-team-id.sh YOUR_TEAM_ID

# Build release
cd daemon && swift build -c release

# Copy binary
cp .build/release/MonolithDaemon /usr/local/bin/

# Install launchd agent
cp com.monolith.daemon.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.monolith.daemon.plist
launchctl enable gui/$(id -u)/com.monolith.daemon
launchctl kickstart -k gui/$(id -u)/com.monolith.daemon
```

### First Run

```bash
cd skill && node scripts/setup.js
```

On first run, this creates Secure Enclave keys, creates the config at `~/.monolith/config.json`, and displays your wallet address. If daemon/companion is not installed or not running, setup prints concrete remediation steps.

## Daemon API

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/health` | GET | None | Status check |
| `/address` | GET | Socket | Wallet address and public key |
| `/capabilities` | GET | Socket | Limits, budgets, gas status |
| `/decode` | POST | Socket | Human-readable intent summary |
| `/sign` | POST | Socket | Policy-checked signing and submission |
| `/policy` | GET | Socket | Current policy config |
| `/policy/update` | POST | Socket + Companion | Update policy (companion shows confirmation + Touch ID) |
| `/allowlist` | POST | Socket + Companion | Manage address allowlist |
| `/unfreeze` | POST | Socket + Companion | Unfreeze wallet (verifies on-chain state first) |
| `/panic` | POST | Socket | Emergency freeze |
| `/audit-log` | GET | Socket | Append-only audit log |

## Specification

Full technical specification: [`docs/SPEC.md`](docs/SPEC.md)

## License

MIT
