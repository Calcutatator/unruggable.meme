# Private TGE — Scope

Adds a **private TGE path on Ekubo** to the unruggable launchpad: launches whose **team allocation is delivered as STRK20 shielded notes** instead of public ERC20 transfers, while preserving every existing unruggable safety guarantee (locked LP, transfer restriction window, max-team-allocation cap).

This is a single, coherent first PR. A follow-up PR can add a **private buyer path** once the production STRK20 contracts publish their anonymous-DeFi-call interface — see *Out of scope (next PR)* below.

**Scope decision:** Ekubo is the only AMM target for the private launch path. Jediswap and StarkDeFi private variants are deliberately not included — production token launches go through Ekubo only. Existing public `launch_on_jediswap` / `launch_on_starkdefi` paths in the unruggable repo are untouched and remain available for any non-private launches.

---

## Background

**Unruggable.meme** ([keep-starknet-strange/unruggable.meme](https://github.com/keep-starknet-strange/unruggable.meme)) is a Cairo memecoin launchpad on Starknet. Two-stage flow:

1. `Factory.create_memecoin(...)` — deploys an `UnruggableMemecoin` (ERC20 + extras).
2. `Factory.launch_on_{jediswap,ekubo,starkdefi}(launch_parameters, …)` — opens trading: seeds AMM liquidity, locks LP, distributes the team allocation publicly via `transfer`, sets the memecoin to `is_launched`.

Existing safety properties:
- Team allocation capped at 10% of supply (`MAX_SUPPLY_PERCENTAGE_TEAM_ALLOCATION`).
- Max 10 initial holders (`MAX_HOLDERS_LAUNCH`).
- LP locked via `LockManager` (Jediswap / StarkDeFi) or held inside `EkuboLauncher` (Ekubo NFT).
- Transfer-restriction window after launch: max % of supply per buy.

**STRK20** is StarkWare's upcoming "Scalable Compliant Privacy on Starknet" (whitepaper [IACR 2026/474](https://eprint.iacr.org/2026/474)). Notes-based UTXO state, multi-token single shielded pool, client-side STARK proofs, selective-unshield compliance, anonymous DeFi integration. **The production contract interface is not yet public** — this PR designs an `IShieldedPool` trait against the whitepaper's semantics and ships a `MockShieldedPool` for tests; the production STRK20 address is plugged in via constructor at deploy time.

## Problem

Today, when a memecoin launches via unruggable, the team allocation is distributed via public ERC20 `transfer` calls. Anyone can see which addresses received insider allocations and how much. For projects that want a **fair-looking public launch where insiders/team are not doxxed by their on-chain receipt**, there's no path. Adding STRK20 to the TGE flow closes that gap without removing any unruggable safety property and without forking the memecoin contract — it composes with the existing launchpad.

## Goals

1. New launch path `launch_private_on_ekubo` that delivers the team allocation as shielded notes inside a STRK20-shape pool, leaving the Ekubo AMM-side liquidity flow unchanged.
2. Faithful interface design against the STRK20 whitepaper so that production deployment is a constructor swap (mock pool → real STRK20 pool), not a contract rewrite.
3. Comprehensive tests covering validation pre-checks on the launch path, plus a full deposit-as-note → withdraw-to-public lifecycle on a real `UnruggableMemecoin`.

## Non-goals

- Shipping a real STRK20 implementation. We mock it. STRK20 is a separate StarkWare protocol; we integrate, not reimplement.
- Modifying the `UnruggableMemecoin` ERC20 contract. The memecoin stays vanilla — privacy lives in the pool, not the token.
- Private liquidity provision (LP shares as shielded notes). The AMM side stays public; only the team allocation goes shielded.
- Cross-chain shielding, frontend changes, off-chain note-discovery service. Out of scope.

## Design

### `IShieldedPool` trait

A minimal interface modelled on the STRK20 whitepaper's deposit / shielded-transfer / withdraw semantics. The interface is small enough to swap implementations at deploy time.

```cairo
#[derive(Drop, Serde, starknet::Store)]
struct EncryptedNote {
    payload: Span<felt252>, // ciphertext recipient decrypts to discover the note
}

#[starknet::interface]
trait IShieldedPool<TContractState> {
    /// Deposit `amount` of `token` into the pool, producing the listed note commitments.
    /// The caller must have approved `amount` to the pool. The sum of amounts encoded by
    /// the commitments must equal `amount` (enforced inside STRK20's deposit proof; in the
    /// mock we pass the amount-vector explicitly so we can assert the constraint without
    /// needing a proof system).
    fn deposit(
        ref self: TContractState,
        token: ContractAddress,
        amount: u256,
        commitments: Span<felt252>,
        note_amounts: Span<u256>,        // mock-only; production STRK20 enforces via proof
        encrypted_outputs: Span<EncryptedNote>,
    );

    /// Withdraw a note to a public recipient. Production version takes a STARK proof + nullifier;
    /// the mock takes the commitment + amount and looks them up in storage.
    fn withdraw(
        ref self: TContractState,
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
        commitment: felt252,
        proof: Span<felt252>,            // ignored by mock
        nullifier: felt252,              // tracked by mock to prevent double-spend
    );

    /// Shielded transfer (input notes → output notes). Out of MVP scope for the unruggable
    /// integration; defined here so the interface is complete.
    fn shielded_transfer(
        ref self: TContractState,
        proof: Span<felt252>,
        nullifiers: Span<felt252>,
        commitments: Span<felt252>,
        encrypted_outputs: Span<EncryptedNote>,
    );

    fn is_token_registered(self: @TContractState, token: ContractAddress) -> bool;
    fn register_token(ref self: TContractState, token: ContractAddress);
    fn current_root(self: @TContractState) -> felt252;
    fn balance_of_commitment(self: @TContractState, commitment: felt252) -> u256; // mock helper
}
```

**Interface differences vs. presumed production STRK20:**
- `note_amounts` is a mock-only argument; production STRK20 will enforce sum-equals-deposit inside the deposit proof. In tests we pass the vector to assert pool accounting without simulating Stwo.
- `withdraw` proof + nullifier are real production fields; the mock ignores `proof` but does enforce nullifier uniqueness for parity with how production will reject double-spends.

### `MockShieldedPool`

In-memory accounting only — enough to test integration:
- `LegacyMap<felt252, (ContractAddress, u256)>` from commitment → (token, amount).
- `LegacyMap<felt252, bool>` for spent nullifiers.
- `LegacyMap<ContractAddress, bool>` for registered tokens.
- On `deposit`: pull `amount` of `token` via `transfer_from`, record each commitment with its claimed amount, assert `sum(note_amounts) == amount`.
- On `withdraw`: assert nullifier unused, assert commitment exists with `(token, amount)`, mark nullifier spent, transfer `amount` of `token` to recipient.

This is **not** a STRK20 implementation; it is a fixture sufficient to verify that the unruggable factory drives the pool correctly. The production swap is a one-line address change.

### Factory extension

We extend `Factory` (not a separate `PrivateFactory` — fewer moving parts, existing unruggable users see a strict superset of the API):

- New constructor argument: `shielded_pool_address: ContractAddress`. Optional via zero-address sentinel: if zero, `launch_private_on_ekubo` reverts with `errors::SHIELDED_POOL_NOT_SET`. This keeps deployments without a STRK20 pool fully backward-compatible.
- New entry point in `IFactory`:
  - `launch_private_on_ekubo(launch_parameters, private_launch_parameters, ekubo_parameters)`
- New struct `PrivateLaunchParameters`:
  ```cairo
  #[derive(Drop, Serde)]
  struct PrivateLaunchParameters {
      note_commitments: Span<felt252>,
      note_amounts: Span<u256>,
      encrypted_outputs: Span<EncryptedNote>,
  }
  ```
- New event `MemecoinPrivateTGE { memecoin_address, shielded_pool, num_notes, total_shielded }` — deliberately omits any per-recipient detail.

### Private launch flow

`launch_private_on_ekubo(...)`:

1. `check_private_launch_parameters` — caller is owner, memecoin not launched, public `initial_holders` / `initial_holders_amounts` are empty (single source of truth), note arrays same-length and within `MAX_HOLDERS_LAUNCH`, team alloc within 10% cap, shielded pool configured, memecoin registered in pool.
2. Validate `ekubo_parameters` (fee, tick spacing, bound, starting price).
3. Create Ekubo concentrated liquidity exactly as in the public flow (LP held inside `EkuboLauncher`).
4. Approve the shielded pool to pull `team_allocation` of memecoin from the factory.
5. Call `shielded_pool.deposit(memecoin_address, team_allocation, note_commitments, note_amounts, encrypted_outputs)`.
6. Call `memecoin.set_launched(...)` with the same parameters as the public path.
7. Emit `MemecoinLaunched { … }` (existing) and `MemecoinPrivateTGE { … }` (new).

### Errors (added)

```
SHIELDED_POOL_NOT_SET
PRIVATE_LAUNCH_ARRAYS_LEN_DIF
PRIVATE_LAUNCH_NON_EMPTY_PUBLIC_HOLDERS
TOKEN_NOT_REGISTERED_IN_POOL
```

## File layout

```
packages/contracts/src/
  privacy.cairo                       # module re-exports
  privacy/
    interface.cairo                   # IShieldedPool + structs
    errors.cairo                      # privacy-specific error constants
  mocks/
    shielded_pool.cairo               # MockShieldedPool
  factory/
    interface.cairo                   # +launch_private_on_ekubo, +PrivateLaunchParameters
    factory.cairo                     # +shielded_pool_address storage, +launch_private_on_ekubo impl
  errors.cairo                        # +SHIELDED_POOL_NOT_SET etc.
  tests/
    unit_tests/
      test_shielded_pool.cairo        # MockShieldedPool unit tests
      test_private_launch.cairo       # validation pre-checks for launch_private_on_ekubo
      test_private_lifecycle.cairo    # deposit-as-note → withdraw-to-public on UnruggableMemecoin
```

## Test plan

**Result: 34 new unit tests added, all passing. Baseline 78 unit tests still passing — no regressions. A devnet-based E2E walkthrough script also passes end-to-end (see [`docs/private-tge-e2e.md`](private-tge-e2e.md)).**

The 18 pre-existing fork-test failures are unrelated: the repo's pinned `Scarb.toml` points at `https://rpc.nethermind.io/mainnet-juno/` which Nethermind has sunset, so the fork tests cannot reach a live RPC. This affects the `unruggable::tests::fork_tests::*` suite both before and after this PR.

Tests split across three new files:

**`test_shielded_pool.cairo`** (17 tests — MockShieldedPool sanity):
- `register_token` / `is_token_registered` / register-twice / register-zero rejections
- `deposit` happy path: balances move, commitments stored, root advances
- `deposit` rejects: unregistered token, array len mismatch, output len mismatch, no notes, sum mismatch, zero amount per note, duplicate commitment
- `withdraw` happy path: balance returned to recipient, nullifier marked spent, commitment cleared
- `withdraw` rejects: double spend, unknown commitment, wrong amount, wrong token
- Independent withdrawals (two recipients don't interfere)

**`test_private_launch.cairo`** (13 tests — validation pre-checks on `launch_private_on_ekubo`):
- `shielded_pool_address` getter
- Rejects when shielded pool address unset (zero)
- Rejects when caller is not memecoin owner
- Rejects when public `initial_holders` is non-empty (single source of truth)
- Rejects when `note_commitments.len() != note_amounts.len()`
- Rejects when `note_commitments.len() != encrypted_outputs.len()`
- Rejects when no notes provided
- Rejects when too many notes (over `MAX_HOLDERS_LAUNCH`)
- Rejects when team allocation exceeds 10% cap
- Rejects when token not registered in pool
- Rejects when memecoin not deployed by factory
- Rejects when quote token == memecoin

The full Ekubo happy path (validation passes, AMM liquidity created, team alloc deposited) requires the mainnet Ekubo deployment — same constraint as the existing public `launch_on_ekubo`. That path is exercisable via fork tests (currently broken due to a sunset RPC; out of scope to fix here).

**`test_private_lifecycle.cairo`** (4 tests — full deposit→withdraw on a real `UnruggableMemecoin`):
- Two-note deposit + two-recipient independent withdrawal: pool balance, commitment cleared, `(token, amount)` round-trips correctly
- Pool root advances on each deposit
- Post-withdraw recipient can publicly transfer the memecoin (verifies `UnruggableMemecoin._transfer` lets the pool send tokens out without hitting transfer restrictions)
- Three-note deposit with one withdrawal — the other two notes stay parked, partial withdrawals don't interfere

## Out of scope (next PR)

- **Private buyer path on Ekubo.** A `buy_private_on_ekubo` that lets a buyer deposit quote tokens into the shielded pool, prove an anonymous swap through Ekubo, and exit with a shielded note for the launched memecoin. This depends on STRK20's anonymous-DeFi-call interface, which the whitepaper describes conceptually but the public docs do not yet specify.
- **Compliance hooks.** Wiring the auditor entity / selective-unshield framework to launch metadata (e.g. attaching a regulator-readable memo to each team-allocation note).
- **Private airdrop helper.** Bulk-deposit-as-notes utility separate from the TGE flow.
- **Frontend changes.** This PR is contracts-only.
- **Fixing the broken fork-test RPC.** The pinned Nethermind RPC was sunset before this PR landed; updating it to a working endpoint would unblock the existing public Ekubo fork tests AND any future private-Ekubo fork test, but is unrelated to the privacy machinery and is left for a separate PR.

## Risks

- **Interface drift from real STRK20.** Mitigated by keeping `IShieldedPool` minimal and ABI-shaped to the whitepaper; the PR description flags that production deployment requires confirmation of the real STRK20 ABI.
- **Note-discovery UX.** Recipients have to know how to discover their notes off-chain. Out of scope for this contract PR but flagged so wallets know what UX they need to provide.
- **Anonymity-set size at launch.** A private TGE produces only as much privacy as the pool's anonymity set provides. If a project launches into an empty pool, the privacy story is weak. Documented as a UX warning, not a contract concern.

## Backward compatibility

Pure addition. Existing `launch_on_jediswap` / `launch_on_ekubo` / `launch_on_starkdefi` are byte-for-byte unchanged. Existing factory deployments that don't pass a `shielded_pool_address` (or pass zero) reject `launch_private_on_ekubo` and otherwise behave identically to today's contract.
