# ClawVault

Secure crypto wallet skill for OpenClaw agents. Hardware-isolated keys (Apple Secure Enclave), on-chain spending caps, ERC-4337 smart wallet.

See docs/SPEC.md for the full technical specification (read it when you need architecture/security details, don't load at startup).

## Tech Stack

- **Daemon:** Swift, macOS only. CryptoKit (Secure Enclave P-256), Foundation (Unix socket server). Runs as launchd background service.
- **Skill:** Node.js scripts + `SKILL.md`. Standard OpenClaw skill structure. Communicates with daemon over Unix socket.
- **Contracts:** Solidity 0.8.x. Coinbase Smart Wallet fork + policy module. Foundry for build/test. Targets ERC-4337 v0.7 EntryPoint.
- **Chains:** Ethereum L1 (chainId 1) and Base (chainId 8453) only.
- **Bundler:** Pimlico public endpoints, no API key. `https://public.pimlico.io/v2/{chainId}/rpc`

## Project Structure

```
daemon/           Swift signing daemon (macOS)
skill/            OpenClaw skill (SKILL.md + Node scripts)
contracts/        Solidity smart wallet + policy + recovery
  src/
  test/
  script/
docs/             Architecture docs
  SPEC.md         Full technical specification
```

## Commands

- `cd contracts && forge build` — compile contracts
- `cd contracts && forge test` — run contract tests
- `cd contracts && forge test -vvv --match-test <name>` — verbose single test
- `cd daemon && swift build` — build daemon
- `cd daemon && swift test` — run daemon unit tests

## Critical Invariants — NEVER violate these

1. **Skill is untrusted.** The skill MUST only emit `{target, calldata, value}`. It MUST NOT set nonce, gas, chainId, fees, or signatures. The daemon owns UserOp construction exclusively.
2. **Default-deny policy.** Unknown calldata → require human approval. Policy is an allowlist, not a blocklist. When in doubt, require approval.
3. **No paymasters.** `paymasterAndData` is always empty. User pays gas. Daemon must preflight every tx (check ETH balance ≥ estimated cost + buffer) and refuse if insufficient.
4. **Two Secure Enclave keys.** Signing key: no `.userPresence` (signs silently for routine ops). Admin key: `.userPresence` required (Touch ID for policy changes). Never mix these up.
5. **On-chain wallet verifies standard `userOpHash` only.** Never the reduced ApprovalHash. See SPEC.md §7.1.
6. **Blocked selectors.** `approve`, `increaseAllowance`, `decreaseAllowance`, `setApprovalForAll`, `permit` (EIP-2612 + DAI), Permit2 — all MUST require explicit user approval regardless of context.
7. **Low-S normalization.** Every P-256 signature must be normalized: if `s > n/2`, replace with `n - s`. Contracts may reject high-S.
8. **Panic asymmetry.** `freeze()` is instant, no Touch ID. Unfreeze requires Touch ID + 10min delay. Key rotation auto-freezes + 48h delay.

## Daemon Socket Protocol

- Socket: `~/.clawvault/daemon.sock` (0600, directory 0700)
- Auth: peer UID check only (same OS user). No HMAC, no shared secrets.
- Admin actions (`/policy/update`, `/allowlist`): daemon shows native macOS confirmation dialog summarizing the change, THEN requires Touch ID. The skill/LLM cannot influence this dialog.

## Daemon API Quick Reference

| Endpoint | Method | Auth | Notes |
|---|---|---|---|
| `/sign` | POST | Socket | Policy-checked, gas-preflighted |
| `/decode` | POST | Socket | Human-readable intent summary, no signing |
| `/capabilities` | GET | Socket | Limits, budgets, gas status (`"ok"/"low"`) |
| `/policy/update` | POST | Socket+TouchID | Shows local confirmation first |
| `/allowlist` | POST | Socket+TouchID | Shows local confirmation first |
| `/panic` | POST | Socket | Instant freeze, no Touch ID |
| `/health` | GET | None | Status check |

## Contract Architecture

- Fork of Coinbase Smart Wallet. P-256 sig verification in `validateUserOp`.
- Use precompile at `0x100` when available (EIP-7951 L1, RIP-7212 Base), fallback to Daimo `p256-verifier`.
- On-chain daily spending cap tracks both native ETH and known stablecoins.
- Recovery: single `recoveryAddress` with `freeze()` (instant) + `initiateKeyRotation()` (48h timelock, auto-freezes).

## Security Profiles

Two built-in profiles configured at setup. Limits are identical across chains.

- **Balanced:** 100 USDC/tx, 500/day, 0.05 ETH/tx, 0.25/day, 10 tx/hr, 1% max slippage. Protocols: Uniswap + Aave.
- **Autonomous:** 250 USDC/tx, 2000/day, 0.15 ETH/tx, 0.75/day, 30 tx/hr, 2% max slippage. Protocols: Uniswap + Aave + Aerodrome (Base) / Lido + Rocket Pool (L1, ETH-in only).

## Code Style

- **Swift:** Swift 5.9+, async/await, structured concurrency. No force unwraps in production code. All Secure Enclave operations wrapped in do/catch.
- **Solidity:** Foundry conventions. NatSpec on all public functions. Custom errors over require strings. Events for all state changes.
- **Node/Skill:** ESM modules, no TypeScript (keep skill minimal). Error handling must surface daemon errors clearly to the agent.

## Gotchas

- Precompile at `0x100` must be probed at runtime with 3 test vectors (valid sig, invalid sig, malformed input) — never assume from docs.
- Pimlico public endpoint is IP-rate-limited. Implement exponential backoff on 429s. No tight polling loops.
- Stablecoins identified by `(chainId, contractAddress)` tuple, never by symbol string.
- ERC-8004 identity registers on the home chain (not forced to L1). Wallet must exist on that chain for ERC-1271 verification.
- Signature format is raw `r||s` (64 bytes). No DER encoding.
- Bundler reimburses itself from wallet balance atomically. If wallet has insufficient ETH, the UserOp will revert on-chain and the user still loses gas. That's why preflight is critical.
