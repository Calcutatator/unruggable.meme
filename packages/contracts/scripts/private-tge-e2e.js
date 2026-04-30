// scripts/private-tge-e2e.js
//
// End-to-end devnet walkthrough for the Private TGE feature.
//
// What this does:
//   1. Connects to a local starknet-devnet (default http://127.0.0.1:5050)
//   2. Declares & deploys: ERC20 quote token, LockManager, mock Jediswap (FactoryC1 +
//      RouterC1), MockShieldedPool, UnruggableMemecoin class, Factory
//   3. Creates a memecoin via the Factory
//   4. Registers the memecoin in the shielded pool
//   5. Calls launch_private_on_jediswap — seeds AMM liquidity AND deposits the team
//      allocation into the shielded pool as opaque notes
//   6. Verifies on-chain state (pool balance, commitments)
//   7. Withdraws a note to a recipient and verifies the recipient received memecoin
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
  CallData,
  json,
  shortString,
  cairo,
  hash,
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

const ETH_INITIAL_SUPPLY = 500_000_000n * 10n ** 18n;
const DEFAULT_INITIAL_SUPPLY = 21_000_000n * 10n ** 18n; // memecoin supply
const HALF_NOTE = 105_000n * 10n ** 18n; // 0.5% of supply per note
const TEAM_ALLOCATION = HALF_NOTE * 2n; // 1% of supply
const ETH_AMOUNT = 1n * 10n ** 18n; // 1 ETH for AMM liquidity
const MIN_LOCKTIME = 15_721_200; // 6 months
const TRANSFER_RESTRICTION_DELAY = 1000;
const MAX_PERCENTAGE_BUY_LAUNCH = 200; // 2%

// --------------------------------------------------------------------------- main

async function main() {
  console.log("\n  ── Private TGE — devnet E2E ──\n".bold);
  console.log(`  devnet at ${DEVNET_URL}`.gray);

  const provider = new RpcProvider({ nodeUrl: DEVNET_URL, specVersion: "0.8.1" });
  const owner = await getDevnetAccount(provider);
  console.log(`  owner    ${shortHex(owner.address)}`.gray);

  step(1, "Declare & deploy supporting contracts");

  // 1a. Quote token (acts as ETH for the launch's quote-side liquidity).
  const quoteToken = await declareAndDeploy(owner, "ERC20Token", [
    ...u256(ETH_INITIAL_SUPPLY),
    owner.address,
  ]);

  // 1b. LockPosition (declared only — used by LockManager).
  const lockPositionClassHash = await declareClass(owner, "LockPosition");

  // 1c. LockManager.
  const lockManager = await declareAndDeploy(owner, "LockManager", [
    MIN_LOCKTIME.toString(),
    lockPositionClassHash,
  ]);

  // 1d. Mock Jediswap. Pair class is declared only; FactoryC1 takes its class hash.
  const pairClassHash = await declareClass(owner, "PairC1");
  const jediFactory = await declareAndDeploy(owner, "FactoryC1", [
    pairClassHash,
    owner.address,
  ]);
  const jediRouter = await declareAndDeploy(owner, "RouterC1", [
    jediFactory.address,
  ]);

  // 1e. The shielded pool we're integrating.
  const pool = await declareAndDeploy(owner, "MockShieldedPool", []);

  // 1f. UnruggableMemecoin class (declared; instances created by the factory).
  const memecoinClassHash = await declareClass(owner, "UnruggableMemecoin");

  // 1g. Factory — extended with shielded_pool_address.
  // Constructor calldata layout (raw felts; matches Cairo serialisation):
  //   memecoin_class_hash, lock_manager_address,
  //   exchanges_len, [exchanges...], migrated_tokens_len, [migrated...], shielded_pool_address
  // Each exchanges entry is (variant_idx, address); SupportedExchanges::Jediswap = 0.
  const factoryCalldata = [
    memecoinClassHash,
    lockManager.address,
    "1", // exchanges array length
    "0", // SupportedExchanges::Jediswap
    jediRouter.address,
    "0", // migrated_tokens array length
    pool.address,
  ];
  const factoryClassHash = await declareClass(owner, "Factory");
  const factoryAddress = await deployContract(
    owner,
    "Factory",
    factoryClassHash,
    factoryCalldata,
  );

  step(2, "Create memecoin via Factory");

  const NAME = shortString.encodeShortString("E2EMeme");
  const SYMBOL = shortString.encodeShortString("E2E");
  const SALT = shortString.encodeShortString("e2e_salt");

  const createTx = await owner.execute({
    contractAddress: factoryAddress,
    entrypoint: "create_memecoin",
    calldata: [
      owner.address,
      NAME,
      SYMBOL,
      ...u256(DEFAULT_INITIAL_SUPPLY),
      SALT,
    ],
  });
  await owner.waitForTransaction(createTx.transaction_hash);

  // Extract memecoin address from the MemecoinCreated event.
  const createReceipt = await provider.getTransactionReceipt(createTx.transaction_hash);
  // Find the event whose first key == hash of "MemecoinCreated".
  const memecoinCreatedSelector = hash.getSelectorFromName("MemecoinCreated");
  const ev = createReceipt.events.find(
    (e) => num.toHex(e.from_address) === num.toHex(factoryAddress),
  );
  if (!ev) throw new Error("MemecoinCreated event not found");
  // Event data layout (from factory.cairo): owner, name, symbol, initial_supply (u256 = 2 felts), memecoin_address
  const memecoinAddress = ev.data[ev.data.length - 1];
  console.log(`    memecoin ${shortHex(memecoinAddress)}`.gray);

  step(3, "Register memecoin in shielded pool");

  await owner.execute({
    contractAddress: pool.address,
    entrypoint: "register_token",
    calldata: [memecoinAddress],
  });
  console.log(`    ✓ registered`.green);

  step(4, "Approve quote token for AMM liquidity");

  await owner.execute({
    contractAddress: quoteToken.address,
    entrypoint: "approve",
    calldata: [factoryAddress, ...u256(ETH_AMOUNT)],
  });
  console.log(`    ✓ approved ${ETH_AMOUNT} of quote token to factory`.green);

  step(5, "launch_private_on_jediswap");
  console.log(
    "    seeds AMM liquidity AND deposits team allocation as shielded notes\n".gray,
  );

  // Two notes — recipients are off-chain, we just commit to them here.
  const COMMIT_A = "0xAAA";
  const COMMIT_B = "0xBBB";
  // EncryptedNote = { payload: Span<felt252> }; payload is a 1-felt placeholder.
  const launchPrivateCalldata = [
    // LaunchParameters
    memecoinAddress, // memecoin_address
    TRANSFER_RESTRICTION_DELAY.toString(), // transfer_restriction_delay
    MAX_PERCENTAGE_BUY_LAUNCH.toString(), // max_percentage_buy_launch
    quoteToken.address, // quote_address
    "0", // initial_holders.len()
    "0", // initial_holders_amounts.len()
    // PrivateLaunchParameters
    "2", // note_commitments.len()
    COMMIT_A,
    COMMIT_B,
    "2", // note_amounts.len()
    ...u256(HALF_NOTE), // amount A (low, high)
    ...u256(HALF_NOTE), // amount B (low, high)
    "2", // encrypted_outputs.len()
    "1", // payload A length
    "0x42", // payload A
    "1", // payload B length
    "0x42", // payload B
    // quote_amount: u256
    ...u256(ETH_AMOUNT),
    // unlock_time: u64 — far future, well past now+MIN_LOCKTIME
    "9999999999",
  ];

  const launchTx = await owner.execute({
    contractAddress: factoryAddress,
    entrypoint: "launch_private_on_jediswap",
    calldata: launchPrivateCalldata,
  });
  await owner.waitForTransaction(launchTx.transaction_hash);
  console.log(`    ✓ launched (tx ${shortHex(launchTx.transaction_hash)})`.green);

  step(6, "Verify on-chain state");

  // memecoin.is_launched()
  const isLaunched = await provider.callContract({
    contractAddress: memecoinAddress,
    entrypoint: "is_launched",
  });
  eq(isLaunched[0], "0x1", "memecoin.is_launched() == true");

  // memecoin.balance_of(pool) == TEAM_ALLOCATION
  const poolBal = await provider.callContract({
    contractAddress: memecoinAddress,
    entrypoint: "balance_of",
    calldata: [pool.address],
  });
  const poolBalU256 = (BigInt(poolBal[1]) << 128n) | BigInt(poolBal[0]);
  eq(
    "0x" + poolBalU256.toString(16),
    "0x" + TEAM_ALLOCATION.toString(16),
    `pool holds team_allocation (${TEAM_ALLOCATION})`,
  );

  // pool.balance_of_commitment(COMMIT_A) == HALF_NOTE
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

  // pool.token_of_commitment(COMMIT_A) == memecoinAddress
  const commitAToken = await provider.callContract({
    contractAddress: pool.address,
    entrypoint: "token_of_commitment",
    calldata: [COMMIT_A],
  });
  eq(commitAToken[0], memecoinAddress, "commitment A → memecoin");

  // factory.shielded_pool_address() == pool.address
  const factoryPool = await provider.callContract({
    contractAddress: factoryAddress,
    entrypoint: "shielded_pool_address",
  });
  eq(factoryPool[0], pool.address, "factory.shielded_pool_address() == pool");

  step(7, "Withdraw note A to a recipient");

  // Make up a recipient address (any felt-shaped value works as a Cairo ContractAddress).
  const recipient = "0xdead";
  await owner.execute({
    contractAddress: pool.address,
    entrypoint: "withdraw",
    calldata: [
      memecoinAddress, // token
      recipient, // recipient
      ...u256(HALF_NOTE), // amount
      COMMIT_A, // commitment
      "0", // proof.len() (mock ignores)
      "0xCAFE", // nullifier
    ],
  });
  console.log(`    ✓ withdrew note A → ${recipient}`.green);

  // recipient now holds HALF_NOTE memecoin
  const recipientBal = await provider.callContract({
    contractAddress: memecoinAddress,
    entrypoint: "balance_of",
    calldata: [recipient],
  });
  const recipientBalU256 =
    (BigInt(recipientBal[1]) << 128n) | BigInt(recipientBal[0]);
  eq(
    "0x" + recipientBalU256.toString(16),
    "0x" + HALF_NOTE.toString(16),
    `recipient holds HALF_NOTE memecoin`,
  );

  // pool now holds only HALF_NOTE memecoin (B is still inside)
  const poolBalAfter = await provider.callContract({
    contractAddress: memecoinAddress,
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
  eq(commitABalAfter[0], "0x0", "commitment A cleared");
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
