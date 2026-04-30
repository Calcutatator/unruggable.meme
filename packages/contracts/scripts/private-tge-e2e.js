// scripts/private-tge-e2e.js
//
// End-to-end devnet walkthrough for the privacy machinery added by this PR.
//
// What this does:
//   1. Connects to a local starknet-devnet (default http://127.0.0.1:5050)
//   2. Declares & deploys: MockShieldedPool, ERC20Token (a generic ERC20 standing in
//      for the launched token — the pool is token-agnostic, so this exercises the same
//      machinery that runs against UnruggableMemecoin in production)
//   3. Registers the token in the pool
//   4. Approves the pool to pull tokens from the deployer (who holds the supply)
//   5. Calls pool.deposit(token, amount, commitments, amounts, encrypted_outputs) —
//      the same call that `launch_private_on_ekubo` makes internally during a private TGE
//   6. Verifies on-chain state (pool balance, commitments)
//   7. Withdraws a note to a recipient and verifies the recipient received the token
//
// Why this scope:
//   The production launch path is `Factory.launch_private_on_ekubo`, which seeds AMM
//   liquidity on the real Ekubo deployment AND deposits the team allocation into the
//   shielded pool. Ekubo isn't available on a fresh devnet (no in-repo mock), so this
//   script exercises the privacy machinery directly — the same `pool.deposit` /
//   `pool.withdraw` calls the launch function makes, on a real Starknet VM.
//
//   We use the generic ERC20Token mock instead of UnruggableMemecoin because UDC-based
//   deploys can't easily inject a deployer-owned supply into the memecoin (its
//   constructor mints to `get_caller_address()`, which is the UDC, not the account).
//   The pool's deposit/withdraw flow is token-agnostic, so the integration is verified
//   regardless of which ERC20 is at the other end. UnruggableMemecoin-specific
//   interactions (transfer restrictions post-launch) are covered by the snforge unit
//   tests (`test_private_lifecycle.cairo::test_post_withdraw_recipient_can_publicly_transfer`).
//
//   Validation pre-checks for `launch_private_on_ekubo` are covered by the snforge unit
//   tests (`test_private_launch.cairo`). The full Ekubo happy path requires a mainnet
//   fork test, same as the existing `launch_on_ekubo`.
//
// Usage:
//   1) In one terminal:   starknet-devnet --seed 42 --accounts 3 --port 5050
//   2) In another:        cd packages/contracts && scarb build
//   3) Then:              cd packages/contracts/scripts && node private-tge-e2e.js
//
// Optional env vars:
//   DEVNET_URL            (default: http://127.0.0.1:5050)

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import colors from "colors";
import {
  Account,
  RpcProvider,
  json,
  shortString,
  num,
  logger,
} from "starknet";

// Silence the "Insufficient transaction data" warnings devnet emits during fee estimation
// (it doesn't have enough block history for tip-based pricing — harmless on a fresh devnet).
try {
  logger.setLogLevel("OFF");
} catch {
  /* older starknet.js — fine */
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TARGET_PATH = path.join(__dirname, "..", "target", "dev");
const DEVNET_URL = process.env.DEVNET_URL || "http://127.0.0.1:5050";

// --------------------------------------------------------------------------- helpers

function loadArtifacts(name) {
  const sierraPath = path.join(TARGET_PATH, `unruggable_${name}.contract_class.json`);
  const casmPath = path.join(
    TARGET_PATH,
    `unruggable_${name}.compiled_contract_class.json`,
  );
  return {
    sierra: json.parse(fs.readFileSync(sierraPath, "ascii")),
    casm: json.parse(fs.readFileSync(casmPath, "ascii")),
  };
}

async function declareClass(account, name) {
  const { sierra, casm } = loadArtifacts(name);
  process.stdout.write(`  declare ${name.padEnd(22)} `.cyan);
  const decl = await account.declareIfNot({ contract: sierra, casm });
  if (decl.transaction_hash) {
    await account.waitForTransaction(decl.transaction_hash);
  }
  console.log(`class_hash=${shortHex(decl.class_hash)}`.gray);
  return decl.class_hash;
}

async function deployContract(account, name, classHash, constructorCalldata) {
  process.stdout.write(`  deploy  ${name.padEnd(22)} `.cyan);
  const dep = await account.deployContract({
    classHash,
    constructorCalldata,
  });
  await account.waitForTransaction(dep.transaction_hash);
  console.log(`address=${shortHex(dep.contract_address)}`.gray);
  return dep.contract_address;
}

async function declareAndDeploy(account, name, constructorCalldata = []) {
  const classHash = await declareClass(account, name);
  const address = await deployContract(account, name, classHash, constructorCalldata);
  return { classHash, address };
}

function u256(x) {
  const big = BigInt(x);
  const low = big & ((1n << 128n) - 1n);
  const high = big >> 128n;
  return [num.toHex(low), num.toHex(high)];
}

function shortHex(h) {
  if (!h) return h;
  const s = num.toHex(h);
  return s.length > 14 ? `${s.slice(0, 8)}…${s.slice(-4)}` : s;
}

async function getDevnetAccount(provider) {
  const res = await fetch(DEVNET_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "devnet_getPredeployedAccounts",
      id: 1,
    }),
  });
  const body = await res.json();
  const acc = body.result[0];
  return new Account({
    provider,
    address: acc.address,
    signer: acc.private_key,
    cairoVersion: "1",
  });
}

function step(n, title) {
  console.log(`\n[${n}] ${title}`.bold);
}

function eq(a, b, label) {
  const aStr = num.toHex(a);
  const bStr = num.toHex(b);
  if (aStr !== bStr) {
    throw new Error(
      `assertion failed (${label}): expected ${bStr}, got ${aStr}`,
    );
  }
  console.log(`    ✓ ${label}`.green);
}

// --------------------------------------------------------------------------- constants

const MEMECOIN_INITIAL_SUPPLY = 21_000_000n * 10n ** 18n;
const HALF_NOTE = 105_000n * 10n ** 18n; // 0.5% of supply per note
const TEAM_ALLOCATION = HALF_NOTE * 2n; // 1% of supply

// --------------------------------------------------------------------------- main

async function main() {
  console.log("\n  ── Private TGE — devnet E2E ──\n".bold);
  console.log(`  devnet at ${DEVNET_URL}`.gray);

  const provider = new RpcProvider({ nodeUrl: DEVNET_URL, specVersion: "0.8.1" });
  const owner = await getDevnetAccount(provider);
  console.log(`  owner    ${shortHex(owner.address)}`.gray);

  step(1, "Declare & deploy contracts");

  // 1a. The shielded pool we're integrating.
  const pool = await declareAndDeploy(owner, "MockShieldedPool", []);

  // 1b. Generic ERC20 standing in for the launched token. Mints the supply to the
  //     deployer account so we can drive approve/deposit from outside.
  const token = await declareAndDeploy(owner, "ERC20Token", [
    ...u256(MEMECOIN_INITIAL_SUPPLY),
    owner.address,
  ]);

  step(2, "Register token in shielded pool");

  await owner.execute({
    contractAddress: pool.address,
    entrypoint: "register_token",
    calldata: [token.address],
  });
  console.log(`    ✓ registered`.green);

  step(3, "Approve pool to pull team allocation from supply holder");

  await owner.execute({
    contractAddress: token.address,
    entrypoint: "approve",
    calldata: [pool.address, ...u256(TEAM_ALLOCATION)],
  });
  console.log(`    ✓ approved ${TEAM_ALLOCATION} of token to pool`.green);

  step(4, "Deposit team allocation as shielded notes");
  console.log(
    "    same call Factory.launch_private_on_ekubo would make internally\n".gray,
  );

  const COMMIT_A = "0xAAA";
  const COMMIT_B = "0xBBB";
  const depositCalldata = [
    token.address, // token
    ...u256(TEAM_ALLOCATION), // amount
    "2", // note_commitments.len()
    COMMIT_A,
    COMMIT_B,
    "2", // note_amounts.len()
    ...u256(HALF_NOTE),
    ...u256(HALF_NOTE),
    "2", // encrypted_outputs.len()
    "1", // payload A length
    "0x42",
    "1", // payload B length
    "0x42",
  ];

  const depositTx = await owner.execute({
    contractAddress: pool.address,
    entrypoint: "deposit",
    calldata: depositCalldata,
  });
  await owner.waitForTransaction(depositTx.transaction_hash);
  console.log(`    ✓ deposited (tx ${shortHex(depositTx.transaction_hash)})`.green);

  step(5, "Verify on-chain state");

  // pool now holds the team allocation
  const poolBal = await provider.callContract({
    contractAddress: token.address,
    entrypoint: "balance_of",
    calldata: [pool.address],
  });
  const poolBalU256 = (BigInt(poolBal[1]) << 128n) | BigInt(poolBal[0]);
  eq(
    "0x" + poolBalU256.toString(16),
    "0x" + TEAM_ALLOCATION.toString(16),
    `pool holds team_allocation (${TEAM_ALLOCATION})`,
  );

  // commitments stored
  const commitABal = await provider.callContract({
    contractAddress: pool.address,
    entrypoint: "balance_of_commitment",
    calldata: [COMMIT_A],
  });
  const commitABalU256 = (BigInt(commitABal[1]) << 128n) | BigInt(commitABal[0]);
  eq(
    "0x" + commitABalU256.toString(16),
    "0x" + HALF_NOTE.toString(16),
    "pool stores commitment A with HALF_NOTE",
  );

  const commitAToken = await provider.callContract({
    contractAddress: pool.address,
    entrypoint: "token_of_commitment",
    calldata: [COMMIT_A],
  });
  eq(commitAToken[0], token.address, "commitment A → token");

  step(6, "Withdraw note A to a recipient");

  const recipient = "0xdead";
  await owner.execute({
    contractAddress: pool.address,
    entrypoint: "withdraw",
    calldata: [
      token.address,
      recipient,
      ...u256(HALF_NOTE),
      COMMIT_A,
      "0", // proof.len() (mock ignores)
      "0xCAFE", // nullifier
    ],
  });
  console.log(`    ✓ withdrew note A → ${recipient}`.green);

  // recipient now holds HALF_NOTE memecoin
  const recipientBal = await provider.callContract({
    contractAddress: token.address,
    entrypoint: "balance_of",
    calldata: [recipient],
  });
  const recipientBalU256 =
    (BigInt(recipientBal[1]) << 128n) | BigInt(recipientBal[0]);
  eq(
    "0x" + recipientBalU256.toString(16),
    "0x" + HALF_NOTE.toString(16),
    "recipient holds HALF_NOTE of token",
  );

  // pool now holds only HALF_NOTE memecoin (B is still inside)
  const poolBalAfter = await provider.callContract({
    contractAddress: token.address,
    entrypoint: "balance_of",
    calldata: [pool.address],
  });
  const poolBalAfterU256 =
    (BigInt(poolBalAfter[1]) << 128n) | BigInt(poolBalAfter[0]);
  eq(
    "0x" + poolBalAfterU256.toString(16),
    "0x" + HALF_NOTE.toString(16),
    "pool now holds only HALF_NOTE (B still inside)",
  );

  // Commit A is cleared
  const commitABalAfter = await provider.callContract({
    contractAddress: pool.address,
    entrypoint: "balance_of_commitment",
    calldata: [COMMIT_A],
  });
  eq(commitABalAfter[0], "0x0", "commitment A cleared (low)");
  eq(commitABalAfter[1], "0x0", "commitment A cleared (high)");

  // Nullifier is spent
  const nullSpent = await provider.callContract({
    contractAddress: pool.address,
    entrypoint: "is_nullifier_spent",
    calldata: ["0xCAFE"],
  });
  eq(nullSpent[0], "0x1", "nullifier 0xCAFE marked spent");

  console.log("\n  ── E2E completed successfully ──\n".bold.green);
}

main().catch((err) => {
  console.error("\n  E2E failed:".red, err);
  process.exit(1);
});
