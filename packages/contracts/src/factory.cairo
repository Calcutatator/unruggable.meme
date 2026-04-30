mod factory;
mod interface;
use factory::Factory;

use interface::{IFactory, IFactoryDispatcher, IFactoryDispatcherTrait};
use unruggable::privacy::interface::EncryptedNote;

#[derive(Copy, Drop, Serde)]
struct LaunchParameters {
    memecoin_address: starknet::ContractAddress,
    transfer_restriction_delay: u64,
    max_percentage_buy_launch: u16,
    quote_address: starknet::ContractAddress,
    initial_holders: Span<starknet::ContractAddress>,
    initial_holders_amounts: Span<u256>,
}

/// Parameters for the private TGE path. The team allocation is delivered as STRK20 shielded
/// notes; recipient identities never appear on-chain.
///
/// `note_commitments[i]`, `note_amounts[i]`, and `encrypted_outputs[i]` describe note `i`.
/// All three spans must have the same length, must be non-empty, and the sum of
/// `note_amounts` is the team allocation. The number of notes is capped by
/// `MAX_HOLDERS_LAUNCH` for parity with the public flow.
#[derive(Copy, Drop, Serde)]
struct PrivateLaunchParameters {
    note_commitments: Span<felt252>,
    note_amounts: Span<u256>,
    encrypted_outputs: Span<EncryptedNote>,
}
