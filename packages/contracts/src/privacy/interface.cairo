//! Interface for a STRK20-shape shielded pool.
//!
//! This trait is designed against the STRK20 whitepaper "Scalable Compliant Privacy on Starknet"
//! (IACR 2026/474). The production STRK20 contracts are not yet public; the interface here
//! captures the deposit / shielded-transfer / withdraw primitives a launchpad needs, and
//! `MockShieldedPool` (in `mocks/shielded_pool.cairo`) provides a non-cryptographic stand-in for
//! tests. Production deployment swaps the mock for the real STRK20 pool address.

use starknet::ContractAddress;

#[derive(Copy, Drop, Serde)]
struct EncryptedNote {
    payload: Span<felt252>,
}

#[starknet::interface]
trait IShieldedPool<TContractState> {
    /// Deposit `amount` of `token` into the pool, producing the listed note commitments.
    /// The caller must have approved `amount` of `token` to the pool.
    ///
    /// `commitments[i]` is the public commitment for note `i`. `note_amounts[i]` is the amount
    /// committed in note `i`. The sum of `note_amounts` must equal `amount`.
    /// `encrypted_outputs[i]` is the ciphertext the recipient decrypts off-chain to discover
    /// note `i`.
    ///
    /// In production STRK20 the sum-equals-deposit constraint is enforced inside the deposit
    /// proof; the mock takes `note_amounts` explicitly so tests can assert pool accounting
    /// without simulating Stwo.
    fn deposit(
        ref self: TContractState,
        token: ContractAddress,
        amount: u256,
        commitments: Span<felt252>,
        note_amounts: Span<u256>,
        encrypted_outputs: Span<EncryptedNote>,
    );

    /// Withdraw a single note publicly to `recipient`.
    ///
    /// `commitment` identifies the note being spent. `nullifier` is the spend-time value that
    /// prevents double-spend (must be unique pool-wide). `proof` is a STARK proof that
    /// `nullifier` was correctly derived from the spending key for `commitment` and that
    /// `commitment` is in the current commitment tree; the mock ignores `proof` but does
    /// enforce `nullifier` uniqueness.
    fn withdraw(
        ref self: TContractState,
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
        commitment: felt252,
        proof: Span<felt252>,
        nullifier: felt252,
    );

    /// Shielded transfer: spend input notes (revealing their nullifiers) and produce output
    /// notes (revealing their commitments). Defined for completeness; not used by the
    /// launchpad TGE flow.
    fn shielded_transfer(
        ref self: TContractState,
        proof: Span<felt252>,
        nullifiers: Span<felt252>,
        commitments: Span<felt252>,
        encrypted_outputs: Span<EncryptedNote>,
    );

    /// Whether `token` is recognised by the pool. STRK20's single pool supports many ERC20s;
    /// registration may carry asset metadata used by the compliance / selective-unshield
    /// framework.
    fn is_token_registered(self: @TContractState, token: ContractAddress) -> bool;

    /// Register `token` so deposits and withdrawals can reference it. Permissionless in the
    /// mock; the production policy is left to STRK20.
    fn register_token(ref self: TContractState, token: ContractAddress);

    /// Current Merkle root of the commitment tree. Mock returns a simple counter-derived
    /// value; production returns the real Merkle root.
    fn current_root(self: @TContractState) -> felt252;

    /// Helpers (mock-only convenience). Production STRK20 will not expose per-commitment
    /// state — that defeats the privacy story. These exist so tests can assert pool state
    /// without leaking through the production interface.
    fn balance_of_commitment(self: @TContractState, commitment: felt252) -> u256;
    fn token_of_commitment(self: @TContractState, commitment: felt252) -> ContractAddress;
    fn is_nullifier_spent(self: @TContractState, nullifier: felt252) -> bool;
}
