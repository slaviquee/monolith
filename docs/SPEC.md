# ClawVault — Technical Specification

**Version 0.5.0** · February 2026 · DRAFT

Secure Crypto Identity & Wallet Skill for OpenClaw

---

## 1. Scope & Goals

ClawVault enables OpenClaw agents to hold funds, transact on-chain, and maintain a verifiable identity — without ever exposing private keys to the LLM, the network, or any third party.

### 1.1 Security Goals

- **G1 — Key isolation:** Private keys MUST never exist in software memory, on disk, or on any network. Keys are generated and permanently held in the Apple Secure Enclave (P-256).
- **G2 — Prompt-injection resilience:** A fully compromised LLM/skill MUST NOT be able to drain funds, replay transactions, or loosen spending policy.
- **G3 — Autonomous routine spending:** The agent MUST operate without human interaction for transactions within configured policy bounds.
- **G4 — Human presence for policy mutation:** Changes to spending limits, allowlists, or recovery configuration MUST require local user presence (Touch ID / system password).
- **G5 — On-chain backstop:** Smart contract–level caps MUST enforce limits independently, so a compromised local daemon does not equal total loss.
- **G6 — Verifiable on-chain identity:** Each agent MUST have a stable on-chain identifier (ERC-8004) with optional ENS and social linking.

### 1.2 Non-Goals

- Cross-platform support (Linux/Windows) — deferred to a future version.
- Unrestricted DeFi approvals — `approve()` / `permit()` flows remain gated behind explicit user approval. Autopilot covers approval-free swap and lending paths only.
- USD-denominated limits via price oracle — deferred until a low-trust oracle solution is validated.
- Multi-chain beyond Ethereum L1 and Base — additional chains deferred.

---

## 2. Threat Model & Assumptions

### 2.1 Assumptions

- The LLM and any skill code MAY be malicious or prompt-injected at any time.
- The local OS user account is trusted at the process level; same-user malware is a limit case, not a design target.
- Remote attackers cannot access the local Unix domain socket.
- The Apple Secure Enclave is a trusted hardware root (non-extractable keys). Root-level malware may still *request* signatures but cannot *extract* the key; blast radius is limited by policy + on-chain caps.

### 2.2 Trust Boundaries

```
OpenClaw Agent (LLM)
  │
  │  natural language → structured intent
  ▼
┌────────────────────────────┐
│  ClawVault Skill           │  UNTRUSTED
│  Emits: { target,          │  Runs inside OpenClaw
│    calldata, value }       │  NO nonce/gas/fees
└────────────┬───────────────┘
             │  intent via Unix socket (same-user only)
             ▼
┌────────────────────────────┐
│  Signing Daemon            │  TRUSTED (local process)
│  - Peer UID verification   │  Owns UserOp construction
│  - Policy enforcement      │  Secure Enclave signing
│  - Nonce, gas, chainId     │  Gas preflight check
└────────────┬───────────────┘
             │  signed UserOperation (self-funded, no paymaster)
             ▼
┌────────────────────────────┐
│  ERC-4337 Bundler          │  SEMI-TRUSTED (third party)
│  Pimlico public endpoint   │  No API key required
│  (rate-limited by IP)      │
└────────────┬───────────────┘
             ▼
┌────────────────────────────┐
│  Smart Contract Wallet     │  ON-CHAIN (trustless)
│  - P-256 sig verification  │  EIP-7951 / RIP-7212
│  - On-chain spending caps  │  Coinbase Smart Wallet fork
│  - ERC-8004 identity       │
└────────────────────────────┘
```

**Core invariant:** The skill can only submit *intent*. It MUST NOT set nonce, gas, chainId, or EntryPoint. Those are manipulation surfaces and are the daemon's exclusive responsibility.

---

## 3. Distribution, Installation & Interaction

### 3.1 What Ships

ClawVault is distributed as two components:

1. **ClawVault Skill** — a standard OpenClaw skill (`SKILL.md` + Node/shell scripts) published on ClawHub. This is what the LLM interacts with. It parses natural language into structured intents and communicates with the daemon over the Unix socket. It handles ENS resolution and ERC-8004 identity queries (read-only, no signing). The skill is installed via ClawHub like any other skill.

2. **Signing Daemon** — a signed and notarized macOS binary (~1,000 lines of Swift). Distributed as a `.dmg` download, triggered automatically by the skill's setup flow. The daemon is a standalone local process — it is not a browser extension, not a CLI tool the user runs manually, and not a cloud service. It runs in the background and exposes only the Unix socket.

Build-from-source is available for developers but is not the default path. The Secure Enclave and Keychain require proper code-signing entitlements baked into the distributed binary.

### 3.2 Installation Flow (< 5 minutes)

The entire setup is driven from the OpenClaw chat interface. The user never leaves the conversation.

**Step 1 — Install skill:**
The user installs ClawVault from ClawHub, either via the ClawHub UI or by telling the agent:
> "Install ClawVault from github.com/clawvault/skill"

**Step 2 — Setup wizard:**
The user tells the agent:
> "Set up my ClawVault wallet"

This triggers an interactive setup sequence:

1. Skill downloads the signed daemon binary (notarized `.dmg`, ~5 seconds).
2. User approves the macOS install (standard Gatekeeper flow).
3. Daemon launches and generates a P-256 signing key in the Secure Enclave. The key is created **without** a user-presence requirement — it can sign routine UserOps autonomously, without Touch ID prompts. (A separate admin key with `.userPresence` is created for policy-mutating operations — see §5.1.)
4. Daemon creates the Unix socket at `~/.clawvault/daemon.sock` (`0600`, directory `0700`).
5. **User selects home chain:** **Ethereum Mainnet (chainId 1)** or **Base (chainId 8453)**.
6. **User selects security profile:** **Balanced** (recommended) or **Autonomous**. See §6.2 for profile details.
7. Daemon configures the policy engine with the selected profile's limits and protocol pack for the chosen chain.
8. Daemon probes the chosen chain for the P-256 precompile at `0x100` (3 test vectors).
9. Daemon computes and displays the **counterfactual smart wallet address** on the chosen chain (CREATE2 deterministic address).
10. **User must fund the wallet address** with ETH on the chosen chain. The wallet cannot deploy or transact without a native gas balance. The skill displays the address and waits for the user to confirm funding.
11. Daemon deploys the smart wallet on the chosen chain using ERC-4337 `initCode` via bundler.
12. Optionally: register ERC-8004 identity on the home chain.
13. Skill prints: wallet address, active profile + chain summary, recovery address prompt, and audit log path.

After setup, the daemon runs as a background process (launchd service on macOS). It starts automatically on login and is invisible to the user during normal operation.

### 3.3 User Interaction Model

**There is no separate UI.** The user interacts with ClawVault entirely through the OpenClaw chat — the same interface they use for everything else. The LLM is the interface; the skill translates natural language into daemon API calls.

Example commands:

| What the user says | What happens |
|---|---|
| "What's my wallet balance?" | Skill queries chain RPCs (read-only, no daemon needed) |
| "Send 10 USDC to vitalik.eth" | Skill resolves ENS → intent → daemon signs → bundler submits |
| "Swap 0.1 ETH for USDC on Uniswap" | Skill builds swap intent → daemon checks autopilot policy → signs |
| "Show my transaction history" | Skill queries `/audit-log` + chain explorer |
| "What can I do without approval?" | Skill queries `/capabilities` → shows autopilot scope + remaining budget |
| "Decode this transaction before sending" | Skill queries `/decode` → shows human-readable summary |
| "Set my daily limit to 200 USDC" | Skill calls `/policy/update` → daemon triggers Touch ID → updates |
| "Add 0xABC…DEF to my allowlist" | Skill calls `/allowlist` → daemon triggers Touch ID → updates |
| "What's my ENS name?" | Skill queries ENS resolver (read-only) |
| "Register mybot.eth" | Skill builds registration intent → daemon signs (may need approval) |
| "Panic! Freeze everything" | Skill calls `/panic` → immediate freeze (no Touch ID) |

**Approval notifications** arrive via Telegram, Signal, or macOS system notification (configurable). The user replies with the 8-digit code in the notification channel — they do not need to return to the OpenClaw chat to approve.

**Touch ID prompts** appear as native macOS system dialogs when the daemon needs user presence for admin actions. These are triggered by the daemon, not the skill.

### 3.4 Skill Security Invariants

The skill MUST NOT:
- Handle private key material in any form.
- Construct nonces, gas estimates, or fee parameters.
- Bypass the daemon for any on-chain write operation.

The skill MAY:
- Perform read-only chain queries (balances, ENS resolution, tx history) directly.
- Cache non-sensitive data (wallet address, chain config) locally.

---

## 4. Intent Schema (Stable Interface)

The skill-to-daemon interface is the only stable API boundary. All fields not listed here MUST be rejected if sent by the skill.

### 4.1 Intent Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `target` | address | Yes | Destination contract or EOA |
| `calldata` | hex bytes | Yes | Encoded function call (or `0x` for native transfer) |
| `value` | uint256 string | Yes | Native token value in wei |
| `chainHint` | uint256 string | No | Preferred chain; daemon MAY override based on policy |

The daemon MUST ignore and discard any additional fields (nonce, gas, fees, signatures, etc.) present in the intent payload.

---

## 5. Signing Daemon

### 5.1 Access Control

The daemon's local security boundary is the Unix domain socket with OS-level access control. There is no shared secret or HMAC scheme.

- **Transport:** Unix domain socket only. No TCP listener. The daemon MUST NOT expose any network-reachable interface.
- **Socket permissions:** Directory `~/.clawvault/` at `0700`, socket `daemon.sock` at `0600` (owner-only). See [Appendix A](#appendix-a-socket--access-control-details) for startup hygiene.
- **Peer UID verification:** On every incoming connection, the daemon MUST verify the connecting process's UID matches the daemon's own UID (via `SO_PEERCRED`, `getpeereid()`, or equivalent). Connections from other OS users MUST be rejected.
- **No shared secrets:** The skill does not need to read or store any authentication token. If it can connect to the socket, it is the same OS user — that is the only client authentication needed for MVP.

**Threat model honesty:** This protects against other OS users and remote attackers but not against same-user malware. In that scenario, the active defenses are the policy engine + on-chain spending caps. This is consistent with defense-in-depth: no single layer needs to be perfect.

### 5.1.1 Touch ID as Admin Gate

The Secure Enclave signing key is created **without** a user-presence requirement — it can sign routine UserOps autonomously. This is what makes Autonomous mode possible.

A separate admin key (or Keychain item) is created **with** `.userPresence` + `.privateKeyUsage` flags, requiring Touch ID or system password for each use. The daemon checks this admin key before executing any sensitive action.

**Touch ID is required for:**
- `/policy/update` — any policy or profile change
- `/allowlist` — adding or removing addresses or protocols
- Unfreezing after panic
- Recovery configuration changes

**Touch ID is NOT required for:**
- Routine signing within policy (`/sign`)
- Reading state (`/capabilities`, `/policy`, `/address`, `/audit-log`, `/decode`)
- Panic freeze (`/panic` — speed over ceremony)

### 5.1.2 Trusted Local Confirmation for Admin Actions

Before any Touch ID–gated action, the daemon MUST display a **trusted local confirmation dialog** (native macOS alert, not rendered by the skill or LLM) that summarizes exactly what is changing. Examples:

- `"Raise daily stablecoin cap: 500 → 1,000 USDC. Confirm with Touch ID."`
- `"Add address 0xABC…DEF to allowlist. Confirm with Touch ID."`
- `"Switch profile: Balanced → Autonomous. Confirm with Touch ID."`

Touch ID proves user presence but not understanding. The local summary ensures the user knows what they are approving before biometric confirmation. The skill and LLM MUST NOT be able to influence or suppress this dialog.

### 5.2 API Endpoints

All endpoints served over the Unix socket:

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/sign` | POST | Socket | Sign an intent (policy-checked, gas-preflighted) |
| `/decode` | POST | Socket | Decode an intent into a human-readable action summary (no signing) |
| `/capabilities` | GET | Socket | Return current limits, allowlists, autopilot-eligible actions, remaining budgets, gas status |
| `/address` | GET | Socket | Return wallet address and public key |
| `/policy` | GET | Socket | Return current policy configuration and active profile |
| `/policy/update` | POST | Socket + Touch ID | Modify policy (with trusted local confirmation) |
| `/allowlist` | POST | Socket + Touch ID | Modify allowlist (with trusted local confirmation) |
| `/panic` | POST | Socket only | Emergency freeze (no Touch ID — speed over ceremony) |
| `/health` | GET | None | Daemon status (read-only, no secrets) |
| `/audit-log` | GET | Socket | Recent decisions + tx hashes (redacted) |

**Panic asymmetry:** Freezing MUST NOT require Touch ID. Unfreezing MUST require Touch ID. Easy to stop, hard to resume.

### 5.3 Intent Decode Endpoint

The `/decode` endpoint accepts the same intent payload as `/sign` but performs no signing. It MUST return a human-readable action summary, e.g.:

- `"Transfer 25 USDC on Base to 0xABC…DEF"`
- `"Swap 0.02 ETH for ≥58.2 USDC via Uniswap Universal Router"`
- `"Unknown calldata: selector 0x1a2b3c4d on contract 0x…"`

This endpoint is critical for audit UX and approval notifications. The daemon SHOULD use the same calldata decoder that the policy engine uses, ensuring the summary shown to users matches the action the policy actually evaluated.

### 5.4 Capabilities Endpoint

The `/capabilities` endpoint MUST return a structured summary of what the agent can currently do, safe to expose to the LLM. It MUST include:

- Active security profile name and home chain.
- Current spending limits and remaining daily budgets.
- Allowlisted addresses and DeFi contracts (protocol pack).
- Which action types are eligible for autopilot (no approval needed).
- Current freeze status.
- **Gas status** (opaque): `gasStatus: "ok" | "low"`. The daemon checks the wallet's native ETH balance against a threshold and reports a simple status. Exact balances SHOULD NOT be exposed to the LLM.

This endpoint MUST NOT expose Secure Enclave key references or internal daemon state beyond what is listed above. Its purpose is to let the agent runtime make informed decisions about what it can do without trial-and-error against `/sign`.

### 5.5 Audit Log Redaction

The audit log and all local log files MUST NEVER record: approval codes, Secure Enclave key references, or any material that could be used to forge approvals. Logs MUST record: timestamps, intent summaries (target, value, action type), policy decisions (approved/rejected + reason), and on-chain tx hashes.

---

## 6. Policy Engine (Normative Rules)

The policy engine is the core defense against prompt injection. It runs in the daemon and gates every signing request.

### 6.1 Default-Deny Rule

**This is the single most important policy rule.**

If calldata cannot be decoded into a known-safe action, the transaction MUST require human approval regardless of amount. The policy is an **allowlist**, not a blocklist.

### 6.2 Security Profiles

During installation, the user selects one of two built-in profiles. Each profile configures spending limits and a DeFi protocol pack. The profile is stored in the daemon's local configuration for the chosen home chain.

Switching profiles or modifying any limit MUST require Touch ID.

#### Spending Limits

|  | **Balanced** (recommended) | **Autonomous** |
|---|---|---|
| Per-tx stablecoin cap | 100 USDC | 250 USDC |
| Daily stablecoin cap | 500 USDC | 2,000 USDC |
| Per-tx native ETH cap | 0.05 ETH | 0.15 ETH |
| Daily native ETH cap | 0.25 ETH | 0.75 ETH |
| Max tx/hour | 10 | 30 |
| Min cooldown between txs | 5 seconds | 2 seconds |
| Max slippage (swaps) | 1% | 2% |

These limits apply identically whether the home chain is Ethereum L1 or Base. Stablecoins are identified by `(chainId, contractAddress)` — never by symbol or name (see Appendix D).

- Unknown or unpriced tokens MUST require human approval for every transfer.
- Raising any limit MUST require Touch ID.

#### Protocol Packs

Each profile includes a pre-configured set of DeFi protocols eligible for autopilot. These define the `(chainId, contractAddress, allowedSelectors)` allowlist. Adding or removing protocols MUST require Touch ID.

**Balanced Protocol Pack (minimal surface):**

| Chain | Protocols | Allowed Autopilot Actions |
|---|---|---|
| Base (8453) | Uniswap, Aave | Approval-free swaps (ETH→token via `msg.value`); Aave deposit/withdraw ETH via gateway |
| Ethereum L1 (1) | Uniswap, Aave | Approval-free swaps (ETH→token via `msg.value`); Aave deposit/withdraw ETH via gateway |

**Autonomous Protocol Pack (expanded):**

| Chain | Protocols | Allowed Autopilot Actions |
|---|---|---|
| Base (8453) | Uniswap, Aave, Aerodrome | Approval-free swaps; Aave deposit/withdraw; Aerodrome ETH→token swaps |
| Ethereum L1 (1) | Uniswap, Aave, Lido, Rocket Pool | Approval-free swaps; Aave deposit/withdraw; Lido stake ETH (ETH-in only); Rocket Pool stake ETH (ETH-in only) |

**Lido and Rocket Pool constraint:** Only ETH-in staking actions are autopilot-eligible (sending ETH to the staking contract). Unstaking, claiming, or any action requiring token approvals MUST require explicit user approval.

### 6.3 Allowlist & Blocked Selectors

- Transfers to non-allowlisted addresses above trivial amounts SHOULD require approval.
- The following function selectors MUST be blocked by default in both profiles. Any calldata matching these selectors MUST require explicit user approval (Touch ID or approval-code flow), regardless of target or amount:
  - `approve(address,uint256)`
  - `increaseAllowance(address,uint256)`
  - `decreaseAllowance(address,uint256)`
  - `setApprovalForAll(address,bool)`
  - `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` (EIP-2612)
  - DAI-style `permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)`
  - Any Permit2 signature or interaction
- Allowlist modifications MUST require Touch ID.

**Autopilot is approval-free.** If a proposed DeFi action requires token approvals or Permit2 to execute, it is NOT eligible for autopilot and MUST go through the user approval flow, even if the protocol is in the active protocol pack.

### 6.4 DeFi Autopilot

Default-safe autonomous actions (no approval needed within limits):

- ERC-20 stablecoin transfers to allowlisted addresses.
- Native token transfers to allowlisted addresses.
- Swaps on allowlisted routers with daemon-enforced max slippage (per profile).
- Deposits and withdrawals on allowlisted lending/staking protocols (per profile, ETH-in paths only for staking).

**Approval-free route constraint:** Autopilot swaps MUST be restricted to routes that do not require ERC-20 approvals (e.g., native ETH → token swaps where ETH is sent as `msg.value`). Any path that would trigger `approve()`, `setApprovalForAll()`, or `permit()` MUST be blocked by default and require explicit user approval or allowlist expansion. This keeps the common ETH → stablecoin path fully autonomous while preventing approval-based drain attacks.

**Router/protocol allowlist:** The daemon MUST maintain a `(chainId, contractAddress, allowedSelectors)` allowlist of approved DeFi contracts, populated from the active profile's protocol pack. Only interactions matching a known contract + known function selector are eligible for autopilot. Adding a new protocol MUST require Touch ID.

**Slippage enforcement:** The daemon MUST decode swap calldata and verify that the `amountOutMinimum` (or equivalent) parameter enforces a maximum slippage within the active profile's limit. Swaps with no slippage protection or slippage above the configured maximum MUST be rejected.

### 6.5 User-Paid Gas (No Paymasters)

ClawVault does not use paymasters. All UserOperations are **self-funded**.

- The `paymasterAndData` field MUST be empty (unset) on every UserOperation.
- The smart wallet MUST maintain a **native ETH balance** on the home chain sufficient to cover gas.
- Before submitting any UserOperation, the daemon MUST **preflight** the operation:
  1. Run gas estimation via bundler (`eth_estimateUserOperationGas`) and chain RPC.
  2. Compute the estimated maximum cost (gas limit × max fee).
  3. Check that the wallet's ETH balance ≥ (estimated max cost + safety buffer).
  4. If insufficient: refuse to submit and return a clear error to the skill indicating the wallet needs funding.
- The `/capabilities` endpoint MUST expose an opaque `gasStatus: "ok" | "low"` field so the agent can inform the user proactively when the wallet needs more ETH.

---

## 7. Signature Binding & Approval Mechanism

### 7.1 What Is Signed On-Chain (Normative)

**This distinction is critical. Conflating these two hashes introduces replay and fee-griefing risks.**

The on-chain wallet MUST verify the Secure Enclave P-256 signature over the **standard ERC-4337 `userOpHash`** — the exact hash passed into `validateUserOp` by the EntryPoint. This hash binds all UserOperation fields including nonce, gas limits, and initCode. This is non-negotiable: it prevents bundler mutation, nonce replay, and fee-field griefing.

The daemon signs this full `userOpHash` via the Secure Enclave. The skill never sees or influences this hash.

### 7.2 Approval-Flow Hash (Separate, Reduced)

A second, **separate** reduced hash exists solely for the human approval-code flow:

```
ApprovalHash = keccak256(chainId, walletAddress, target, value, calldata, maxSpendCap, expiry)
```

This hash deliberately excludes gas parameters because the daemon may re-estimate gas between the moment the user approves and the moment the transaction is submitted. Including gas fields would cause normal re-estimation to invalidate pending approvals — unacceptable UX friction.

**The ApprovalHash is never used for on-chain signature verification.** It exists only to bind a one-time approval code to a specific user-visible intent. The flow is:

1. User approves ApprovalHash (via code).
2. Daemon constructs the full UserOperation (including gas fields).
3. Daemon signs the resulting `userOpHash` (full ERC-4337 binding) via Secure Enclave.
4. On-chain wallet verifies the `userOpHash` signature — never the ApprovalHash.

Implementers MUST NOT use the reduced ApprovalHash for the Secure Enclave signature or on-chain verification.

### 7.3 Approval Code Flow

When a transaction exceeds policy or involves unknown calldata, the daemon MUST initiate a code-based approval flow.

1. Daemon detects policy exception.
2. Daemon generates a single-use **8-digit** code and computes the ApprovalHash.
3. Daemon sends notification (Telegram/Signal/system alert) with: human-readable action summary (from `/decode`), chain, recipient, asset, amount, ApprovalHash prefix, code, and expiry.
4. User replies with the code.
5. Daemon verifies: code matches, ApprovalHash matches, not expired, not previously used.
6. Daemon constructs the full UserOperation, signs the `userOpHash` via Secure Enclave, and submits.
7. If no valid approval within timeout (default 3 minutes), the transaction is rejected.

### 7.4 Approval Code Security

- Each code MUST be single-use and bound to a specific ApprovalHash.
- Codes MUST be **8 digits** (10^8 = 100M possibilities). 6-digit codes are brute-forceable if the verification channel is programmatically accessible.
- **Rate limiting:** The daemon MUST enforce aggressive rate limits on code verification attempts: maximum **3 failed attempts per pending approval**, after which the approval is permanently revoked and a new code must be requested. Additionally, a global rate limit of **5 failed verification attempts per minute** across all pending approvals MUST be enforced.
- Expired codes MUST be purged.
- The "reply YES" pattern MUST NOT be used (vulnerable to phishing and replay).

---

## 8. Bundler

### 8.1 What a Bundler Does

UserOperations are not mined directly. An ERC-4337 **bundler** is a service that:

1. Accepts signed UserOperations from clients (the daemon).
2. Simulates them to verify they will succeed and pay for themselves.
3. Batches one or more UserOps into a single on-chain `handleOps()` transaction submitted to the EntryPoint contract.

The bundler pays the outer transaction gas upfront and is reimbursed by the EntryPoint from the sender's (wallet's) deposit or balance. In ClawVault's no-paymaster model, **the user ultimately pays all gas costs** — the bundler is an intermediary that fronts the ETH and gets repaid atomically on-chain.

### 8.2 Default Bundler Provider

ClawVault uses **Pimlico public bundler endpoints** as the default. No API key is required.

| Chain | Endpoint |
|---|---|
| Ethereum L1 (chainId 1) | `https://public.pimlico.io/v2/1/rpc` |
| Base (chainId 8453) | `https://public.pimlico.io/v2/8453/rpc` |

**Rate limiting:** The Pimlico public endpoint enforces IP-based rate limits. The daemon MUST implement exponential backoff on 429 responses and MUST NOT poll in tight loops. For high-frequency use cases, users MAY configure a private bundler endpoint via `/policy/update` (requires Touch ID).

### 8.3 Required RPC Methods

The daemon uses the following bundler JSON-RPC methods:

- `eth_sendUserOperation` — submit a signed UserOp for inclusion.
- `eth_estimateUserOperationGas` — simulate and return gas estimates (used for preflight).
- `eth_supportedEntryPoints` — verify the bundler supports EntryPoint v0.7.

The bundler MUST support ERC-4337 v0.7.

---

## 9. On-Chain Wallet Requirements

Each agent gets an ERC-4337 smart contract wallet (Coinbase Smart Wallet fork).

### 9.1 Signature Verification

- The wallet's `validateUserOp` MUST verify the P-256 signature over the **standard `userOpHash` provided by the EntryPoint** — not a reduced or custom hash. See §7.1 for the normative requirement and rationale.
- The wallet MUST verify via the precompile at `0x100` when available (EIP-7951 on L1, RIP-7212 on Base).
- The wallet MUST fall back to Daimo's `p256-verifier` contract on chains without a working precompile.
- Precompile availability MUST be determined by runtime probing (3 test vectors: valid sig, invalid sig, malformed input), not assumed from documentation.

### 9.2 On-Chain Policy

At minimum, the smart contract MUST enforce:

- **Daily spending cap** — limits total outflow per 24-hour period, independent of the local daemon. The cap MUST track both native token transfers and ERC-20 transfers to known stablecoin addresses (using the same `(chainId, contractAddress)` registry as the daemon). Transfers of unknown tokens SHOULD also count against the cap at face value. Implementers MUST be explicit about what the cap covers; if it only covers native ETH, the recovery/freeze mechanism is doing more work than intended.
- **Emergency freeze** — callable by the current signer or the recovery address (see §9.4) to halt all outbound transactions.

Additional on-chain enforcement (allowlisted targets, session keys) MAY be added but is not required for MVP.

### 9.3 Deployment

- Home chain is selected by the user during setup: **Ethereum L1 (chainId 1)** or **Base (chainId 8453)**.
- The wallet is deployed on the home chain. The same address is available on the other chain via CREATE2 if the user later chooses to deploy there.
- The wallet is deployed via ERC-4337 `initCode` through the bundler — the first UserOperation includes the deployment bytecode.
- The user MUST fund the counterfactual address with ETH before deployment (see §6.5).

### 9.4 Recovery (MVP)

The Secure Enclave key is bound to one physical device. Without a recovery mechanism, a lost or compromised Mac means permanent loss of funds. This section defines the minimum viable recovery surface.

**Design principle:** Recovery follows the same asymmetry as panic — stopping is fast, resuming is slow. Key rotation auto-freezes to prevent drain during the delay window.

#### 9.4.1 Recovery Address

The wallet MUST store a `recoveryAddress` (an EOA or hardware wallet controlled by the user). This address is set at wallet deployment and has two powers: immediate freeze and timelocked key rotation.

The `recoveryAddress` SHOULD be immutable (set once in the constructor). If changeability is desired, `setRecoveryAddress(newAddress)` MUST be callable only by the current P-256 signer via a normal UserOperation (requiring the working local setup + Touch ID for policy changes). This aligns with G4: recovery configuration changes require user presence.

#### 9.4.2 Contract State

Minimal additional state:

```
address recoveryAddress;         // set at deployment
bool    frozen;                  // halts all outbound tx
bytes   pendingSignerPubKey;     // new P-256 key awaiting finalization
uint64  recoveryReadyAt;         // timestamp after which rotation can finalize
uint64  unfreezeReadyAt;         // timestamp after which unfreeze can execute
```

#### 9.4.3 Recovery Functions

**`freeze()`**
- Callable by `recoveryAddress` OR the current signer.
- Takes effect immediately. Sets `frozen = true`.
- MUST NOT be timelocked — speed over ceremony, consistent with panic asymmetry.

**`requestUnfreeze()`**
- Callable by `recoveryAddress`.
- Sets `unfreezeReadyAt = block.timestamp + UNFREEZE_DELAY` (default: 10 minutes).
- The delay is a cheap safety win: it gives the user a reaction window if the recovery key is compromised.

**`finalizeUnfreeze()`**
- Callable by `recoveryAddress`.
- Requires `block.timestamp >= unfreezeReadyAt`.
- Sets `frozen = false`, clears `unfreezeReadyAt`.

**`initiateKeyRotation(bytes newP256PubKey)`**
- Callable by `recoveryAddress` only.
- Sets `pendingSignerPubKey = newP256PubKey`.
- Sets `recoveryReadyAt = block.timestamp + RECOVERY_DELAY` (default: 48 hours).
- MUST auto-set `frozen = true`. This prevents ongoing drain during the delay window.

**`finalizeKeyRotation()`**
- Callable by `recoveryAddress` only.
- Requires `block.timestamp >= recoveryReadyAt`.
- Replaces the active P-256 signer public key with `pendingSignerPubKey`.
- Clears `pendingSignerPubKey` and `recoveryReadyAt`.
- MUST NOT auto-unfreeze. Unfreezing is a separate, explicit action.

#### 9.4.4 Operational Scenarios

**Lost Mac:** User gets a new Mac → generates new Secure Enclave P-256 key → calls `initiateKeyRotation(newPubKey)` from recovery wallet → waits 48h → `finalizeKeyRotation()` → `requestUnfreeze()` → waits 10min → `finalizeUnfreeze()`. Daemon on new Mac can now sign.

**Compromised Mac:** User calls `freeze()` from recovery wallet immediately → rotates key via `initiateKeyRotation` → `finalizeKeyRotation` on clean machine → unfreeze when ready.

**Planned migration:** Same flow as lost Mac. If a "current signer can rotate without timelock" shortcut is desired, it MAY be added later but is not required for MVP.

#### 9.4.5 Events

The wallet MUST emit events for monitoring and audit:

- `Frozen(address caller)`
- `UnfreezeRequested(uint64 readyAt)`
- `Unfrozen(address caller)`
- `KeyRotationInitiated(bytes newPubKey, uint64 readyAt)`
- `KeyRotationFinalized(bytes newPubKey)`

#### 9.4.6 Explicitly Deferred

The following are not required for MVP recovery and SHOULD be deferred:

- Multi-guardian threshold recovery.
- Escape-hatch asset sweeping.
- Recovery-triggered policy resets.
- Session keys.
- Cross-chain coordinated recovery.

---

## 10. Identity Layer

### 10.1 ERC-8004 Agent Identity

ClawVault agents SHOULD be registered on the ERC-8004 identity registry on **the home chain** (the chain selected during setup). ERC-8004 registries are deployed as per-chain singletons — there is no requirement to use Ethereum L1 specifically.

- If the user chose **Base**, the agent registers on the Base ERC-8004 registry. The wallet contract exists on Base and can satisfy ERC-1271 signature verification natively.
- If the user chose **Ethereum L1**, the agent registers on the L1 ERC-8004 registry.

Registration provides:

- A unique Agent ID (ERC-721 NFT).
- Linked wallet address(es).
- Service endpoint declarations.
- On-chain reputation accumulation.
- Ownership and transferability.

**Cross-chain identity linking:** If the user later deploys the wallet on the second chain (same address via CREATE2), they MAY register on that chain's ERC-8004 registry as well. This is optional and does not affect the primary identity on the home chain.

### 10.2 ENS Integration

Agents SHOULD be able to register or link an ENS name (e.g., `mybot.eth` or `mybot.clawvault.eth`). The ENS profile includes:

- Primary wallet address (resolver record).
- Avatar / PFP (via avatar record).
- Agent description and capabilities (text records).
- Multi-chain addresses (addr records).

### 10.3 Social Identity (Optional)

Agents MAY link social profiles for broader identity:

- Farcaster account (via signed verification).
- Lens Protocol profile.

### 10.4 Identity Safety Invariant

Identity modules MUST NOT weaken wallet policy or security invariants. Identity registration and linking are read-only from the security model's perspective — they do not grant signing authority or modify spending policy.

---

## 11. UserOperation Flow

The end-to-end transaction flow, for reference:

1. Skill submits minimal intent (`target`, `calldata`, `value`) to daemon via Unix socket.
2. Daemon verifies peer UID (same OS user).
3. Daemon validates intent against policy engine (active profile limits, allowlist, calldata decoding).
4. If policy requires approval → computes ApprovalHash, initiates 8-digit code flow, waits for user.
5. If approved or within policy → daemon queries wallet nonce from EntryPoint.
6. Daemon estimates gas via bundler simulation (`eth_estimateUserOperationGas`) and clamps within safe bounds.
7. Daemon runs gas preflight: checks wallet ETH balance ≥ estimated max cost + buffer. Refuses if insufficient.
8. Daemon constructs complete UserOperation (correct chainId, EntryPoint, nonce, gas, `paymasterAndData` empty).
9. Daemon computes the standard ERC-4337 `userOpHash` and signs it via Secure Enclave (P-256).
10. Daemon extracts raw `r||s`, normalizes to low-S.
11. Daemon submits signed UserOp to Pimlico bundler via `eth_sendUserOperation`.
12. Bundler batches into `handleOps()` transaction on-chain. Bundler fronts gas; EntryPoint reimburses from wallet balance.
13. EntryPoint calls wallet's `validateUserOp` → verifies P-256 signature over the **standard `userOpHash`** via precompile or fallback.
14. If valid and within on-chain policy → transaction executes.

---

## 12. Limitations & Tradeoffs

- **macOS only (initially):** Requires Apple Silicon or T2 for Secure Enclave. Linux/Windows would require TPM 2.0 or YubiKey — a different approach.
- **Two chains only:** Ethereum L1 and Base. Additional chains deferred.
- **User pays gas:** No paymasters or sponsored gas. The wallet must maintain an ETH balance on the home chain. If the wallet runs out of ETH, no transactions can be submitted until funded.
- **Not 100% autonomous:** Transactions above limits and unknown calldata require human approval. Policy changes require Touch ID. This is by design.
- **Same-user malware:** Unix socket + peer UID check protects against other users and remote attackers. Same-user malware can connect to the socket and submit intents. Active defense at that point: policy engine + on-chain caps.
- **Stablecoin-denominated limits:** No USD oracle. Non-stablecoin limits use native denomination.
- **Single-device key:** Secure Enclave key is bound to one physical device. MVP recovery uses a single recovery address with timelocked key rotation (see §9.4). Multi-guardian and cross-chain recovery are deferred.
- **Smart contract risk:** Agent-specific extensions (policy module, session keys) require their own audit before mainnet with significant funds.
- **Bundler rate limits:** Pimlico public endpoint is IP-rate-limited. High-frequency agents may need a private bundler.

---

## Appendix A: Socket & Access Control Details

### Socket Directory Hygiene

On startup, the daemon:

1. Creates `~/.clawvault/` with `0700` permissions (owner-only, no group/other access).
2. Uses `lstat()` to verify `daemon.sock` is not a symlink or unexpected file type.
3. Safely deletes any stale socket.
4. Binds the new socket with `0600` permissions.

### Peer UID Verification

On every incoming connection, the daemon checks the peer's effective UID:

```swift
// macOS / BSD
var cred = xucred()
var len = socklen_t(MemoryLayout<xucred>.size)
getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len)
guard cred.cr_uid == getuid() else { /* reject */ }
```

On Linux (if ported), use `SO_PEERCRED` instead. The principle is the same: only the same OS user can talk to the daemon.

---

## Appendix B: Secure Enclave & Signing Details

### Key Generation (CryptoKit)

```swift
// Signing key — autonomous, NO user-presence requirement.
// This is what makes Autonomous mode possible:
// routine UserOps are signed without any Touch ID prompt.
let signingKey = try SecureEnclave.P256.Signing.PrivateKey(
    accessControl: SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .privateKeyUsage,  // no .userPresence flag
        nil)!
)

// Admin key — requires Touch ID / password for each use.
// Used only for policy-mutating operations (§5.1.1).
let adminKey = try SecureEnclave.P256.Signing.PrivateKey(
    accessControl: SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .userPresence],
        nil)!
)
```

**Two keys, two purposes:** The signing key signs UserOps silently. The admin key gates policy changes behind Touch ID. This separation is what allows the agent to operate autonomously for routine spending while keeping admin actions protected.

### Low-S Normalization

P-256 signatures have malleability: both `(r, s)` and `(r, n-s)` are valid for the same message. Some on-chain verifiers reject high-S. The daemon MUST normalize every signature: if `s > n/2`, replace `s` with `n - s`.

### Signature Format

Raw `r||s` (64 bytes: r 32 bytes, s 32 bytes). No DER encoding.

---

## Appendix C: Precompile Runtime Detection

Three test vectors per chain against `0x0000...0100`:

1. **Valid signature** → expect 32-byte `0x...01`.
2. **Invalid signature** → expect empty bytes (not revert).
3. **Malformed input** (wrong length) → expect empty bytes (not revert).

If all three pass → use precompile. Otherwise → fall back to Daimo's `p256-verifier`.

This runs once per chain at setup time. Results are cached.

### Reference Gas Costs

| Chain | Precompile | Reference Gas |
|-------|-----------|---------------|
| Ethereum L1 | EIP-7951 | ~6,900 |
| Base | RIP-7212 | ~3,450 |
| No precompile | Daimo fallback | ~200,000 |

These are reference values only. The daemon MUST always use bundler simulation (`eth_estimateUserOperationGas`) for actual gas limits.

---

## Appendix D: Stablecoin Address Registry

Stablecoins are identified by `(chainId, contractAddress)`. The daemon ships with a hardcoded allowlist. Users can extend it via `/allowlist` (requires Touch ID).

**Canonical USDC addresses (examples):**

| Chain | chainId | USDC Address |
|-------|---------|-------------|
| Ethereum L1 | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Full address list maintained as a data file in the daemon repository.

---

## Appendix E: Open Source Dependencies

| Component | Source | License | Status |
|-----------|--------|---------|--------|
| Coinbase Smart Wallet | github.com/coinbase/smart-wallet | MIT | Production, audited |
| Daimo p256-verifier | github.com/daimo-eth/p256-verifier | MIT | Deployed, all major chains |
| RIP-7212 / EIP-7951 | Ethereum RIPs/EIPs | CC0 | Live |
| Apple CryptoKit | Apple SDK | Proprietary | Stable, ships with macOS |
| ERC-4337 EntryPoint | eth-infinitism | GPL-3.0 | Production (v0.7) |
| ERC-8004 Registry | Ethereum | CC0 | Live on mainnet |
| Pimlico Bundler | pimlico.io | N/A (public API) | Production |
