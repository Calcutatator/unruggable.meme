//! `MockShieldedPool` — a non-cryptographic stand-in for STRK20 used in tests.
//!
//! The pool tracks deposit accounting (commitment → token, amount), nullifier uniqueness,
//! and registered tokens. It does NOT verify zk-STARK proofs or hide anything from
//! observers — it exists so the unruggable factory's private TGE flow can be exercised
//! end-to-end without depending on a real STRK20 deployment. Production deployments
//! replace this with the real STRK20 pool address.

#[starknet::contract]
mod MockShieldedPool {
    use core::zeroable::Zeroable;
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use unruggable::privacy::errors;
    use unruggable::privacy::interface::{EncryptedNote, IShieldedPool};

    #[storage]
    struct Storage {
        tokens_registered: LegacyMap<ContractAddress, bool>,
        commitment_token: LegacyMap<felt252, ContractAddress>,
        commitment_amount: LegacyMap<felt252, u256>,
        nullifiers_spent: LegacyMap<felt252, bool>,
        tree_size: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TokenRegistered: TokenRegistered,
        Deposited: Deposited,
        Withdrawn: Withdrawn,
        ShieldedTransferred: ShieldedTransferred,
    }

    #[derive(Drop, starknet::Event)]
    struct TokenRegistered {
        token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposited {
        token: ContractAddress,
        depositor: ContractAddress,
        amount: u256,
        num_notes: u32,
        root_after: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawn {
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
        nullifier: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct ShieldedTransferred {
        num_inputs: u32,
        num_outputs: u32,
        root_after: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.tree_size.write(0);
    }

    #[abi(embed_v0)]
    impl ShieldedPoolImpl of IShieldedPool<ContractState> {
        fn deposit(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            commitments: Span<felt252>,
            note_amounts: Span<u256>,
            encrypted_outputs: Span<EncryptedNote>,
        ) {
            assert(self.tokens_registered.read(token), errors::POOL_TOKEN_NOT_REGISTERED);
            assert(commitments.len() == note_amounts.len(), errors::POOL_ARRAYS_LEN_DIF);
            assert(commitments.len() == encrypted_outputs.len(), errors::POOL_ARRAYS_LEN_DIF);
            assert(commitments.len() != 0, errors::POOL_ZERO_NOTES);

            // Sum amounts and assert each commitment is fresh.
            let mut total: u256 = 0;
            let mut i: usize = 0;
            loop {
                if i == commitments.len() {
                    break;
                }
                let commitment = *commitments.at(i);
                let note_amount = *note_amounts.at(i);
                // Reject zero amounts so that "amount==0" stays a clean "not-present" sentinel.
                assert(note_amount.is_non_zero(), errors::POOL_AMOUNT_MISMATCH);
                // Reject duplicate / already-used commitments.
                assert(
                    self.commitment_token.read(commitment).is_zero(),
                    errors::POOL_COMMITMENT_MISMATCH
                );
                self.commitment_token.write(commitment, token);
                self.commitment_amount.write(commitment, note_amount);
                total += note_amount;
                i += 1;
            };

            assert(total == amount, errors::POOL_AMOUNT_MISMATCH);

            // Pull funds from the depositor.
            let depositor = get_caller_address();
            let token_dispatcher = ERC20ABIDispatcher { contract_address: token };
            let ok = token_dispatcher
                .transfer_from(depositor, get_contract_address(), amount);
            assert(ok, 'Pool: transfer_from failed');

            // Advance the "tree" — in production this is the Merkle root recomputation;
            // here we just bump a counter so `current_root` changes per deposit.
            let new_size = self.tree_size.read() + commitments.len().into();
            self.tree_size.write(new_size);

            self
                .emit(
                    Deposited {
                        token,
                        depositor,
                        amount,
                        num_notes: commitments.len(),
                        root_after: new_size.into(),
                    }
                );
        }

        fn withdraw(
            ref self: ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
            commitment: felt252,
            proof: Span<felt252>, // ignored in mock
            nullifier: felt252,
        ) {
            assert(!self.nullifiers_spent.read(nullifier), errors::POOL_NULLIFIER_SPENT);
            let stored_token = self.commitment_token.read(commitment);
            assert(stored_token.is_non_zero(), errors::POOL_COMMITMENT_UNKNOWN);
            assert(stored_token == token, errors::POOL_COMMITMENT_MISMATCH);
            let stored_amount = self.commitment_amount.read(commitment);
            assert(stored_amount == amount, errors::POOL_COMMITMENT_MISMATCH);

            self.nullifiers_spent.write(nullifier, true);
            // Clear the commitment so the same record cannot be re-spent under a new nullifier.
            self.commitment_token.write(commitment, Zeroable::zero());
            self.commitment_amount.write(commitment, 0);

            let token_dispatcher = ERC20ABIDispatcher { contract_address: token };
            let ok = token_dispatcher.transfer(recipient, amount);
            assert(ok, 'Pool: transfer failed');

            self.emit(Withdrawn { token, recipient, amount, nullifier });
        }

        fn shielded_transfer(
            ref self: ContractState,
            proof: Span<felt252>, // ignored in mock
            nullifiers: Span<felt252>,
            commitments: Span<felt252>,
            encrypted_outputs: Span<EncryptedNote>,
        ) {
            assert(commitments.len() == encrypted_outputs.len(), errors::POOL_ARRAYS_LEN_DIF);

            // Mark inputs spent.
            let mut i: usize = 0;
            loop {
                if i == nullifiers.len() {
                    break;
                }
                let n = *nullifiers.at(i);
                assert(!self.nullifiers_spent.read(n), errors::POOL_NULLIFIER_SPENT);
                self.nullifiers_spent.write(n, true);
                i += 1;
            };

            // Add outputs as fresh commitments. The mock cannot verify input==output value
            // sums because notes are opaque (no `note_amounts` here); production STRK20 does
            // this inside the proof. The mock therefore lets transfers be value-arbitrary —
            // tests should rely on `deposit` / `withdraw` for value-conservation assertions.
            let mut j: usize = 0;
            loop {
                if j == commitments.len() {
                    break;
                }
                let c = *commitments.at(j);
                // Output commitments from a transfer carry no token in the mock — production
                // STRK20 handles this through the proof; for the mock we just record presence
                // with a sentinel non-zero token value (here, the contract's own address) and
                // amount 0. Tests should not call `withdraw` on transfer outputs in the mock.
                assert(
                    self.commitment_token.read(c).is_zero(), errors::POOL_COMMITMENT_MISMATCH
                );
                self.commitment_token.write(c, get_contract_address());
                j += 1;
            };

            let new_size = self.tree_size.read() + commitments.len().into();
            self.tree_size.write(new_size);

            self
                .emit(
                    ShieldedTransferred {
                        num_inputs: nullifiers.len(),
                        num_outputs: commitments.len(),
                        root_after: new_size.into(),
                    }
                );
        }

        fn is_token_registered(self: @ContractState, token: ContractAddress) -> bool {
            self.tokens_registered.read(token)
        }

        fn register_token(ref self: ContractState, token: ContractAddress) {
            assert(token.is_non_zero(), 'Pool: zero token');
            assert(
                !self.tokens_registered.read(token), errors::POOL_TOKEN_ALREADY_REGISTERED
            );
            self.tokens_registered.write(token, true);
            self.emit(TokenRegistered { token });
        }

        fn current_root(self: @ContractState) -> felt252 {
            self.tree_size.read().into()
        }

        fn balance_of_commitment(self: @ContractState, commitment: felt252) -> u256 {
            self.commitment_amount.read(commitment)
        }

        fn token_of_commitment(self: @ContractState, commitment: felt252) -> ContractAddress {
            self.commitment_token.read(commitment)
        }

        fn is_nullifier_spent(self: @ContractState, nullifier: felt252) -> bool {
            self.nullifiers_spent.read(nullifier)
        }
    }
}
