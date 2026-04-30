//! End-to-end pool integration tests.
//!
//! These tests exercise the full deposit-as-note → withdraw-to-public flow against a real
//! `UnruggableMemecoin` (deployed directly, with the test address acting as the
//! "factory_contract" that holds the supply). They verify the privacy machinery
//! independently of the launch wrapper — which on the production path is
//! `launch_private_on_ekubo` and requires the mainnet Ekubo deployment to drive end-to-end.

use core::option::OptionTrait;
use core::traits::TryInto;
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{
    declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, start_warp, stop_warp,
    TxInfoMock
};
use starknet::{ContractAddress, contract_address_const};
use unruggable::privacy::interface::{
    EncryptedNote, IShieldedPoolDispatcher, IShieldedPoolDispatcherTrait
};
use unruggable::tests::unit_tests::utils::{
    deploy_mock_shielded_pool, OWNER, NAME, SYMBOL, DEFAULT_INITIAL_SUPPLY, pow_256,
    DefaultTxInfoMock
};
use unruggable::token::interface::{
    IUnruggableMemecoinDispatcher, IUnruggableMemecoinDispatcherTrait
};

fn one_payload() -> Span<felt252> {
    array![0x42].span()
}

fn note(payload: Span<felt252>) -> EncryptedNote {
    EncryptedNote { payload }
}

/// Deploys an `UnruggableMemecoin` directly. The caller of this function becomes the
/// memecoin's `factory_contract` and holds the entire initial supply. This is the same
/// pattern the existing repo uses in `deploy_standalone_memecoin`.
fn deploy_memecoin_owned_by_caller(
    owner: ContractAddress
) -> (IUnruggableMemecoinDispatcher, ContractAddress) {
    let contract = declare('UnruggableMemecoin');
    let mut calldata = array![];
    Serde::serialize(@owner, ref calldata);
    Serde::serialize(@NAME(), ref calldata);
    Serde::serialize(@SYMBOL(), ref calldata);
    Serde::serialize(@DEFAULT_INITIAL_SUPPLY(), ref calldata);
    let address = contract.deploy(@calldata).expect('memecoin deploy failed');

    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(1234);
    snforge_std::start_spoof(CheatTarget::One(address), tx_info);

    (IUnruggableMemecoinDispatcher { contract_address: address }, address)
}

#[test]
fn test_pool_round_trip_with_unruggable_memecoin() {
    // Test address deploys the memecoin → test address is `factory_contract` and holds the
    // entire supply. We then drive the pool integration that `launch_private_on_ekubo`
    // would on production.
    let (memecoin, memecoin_address) = deploy_memecoin_owned_by_caller(OWNER());
    let (pool, pool_address) = deploy_mock_shielded_pool();

    // Register the memecoin in the pool.
    pool.register_token(memecoin_address);

    // Test address (the supply holder) approves the pool.
    let half: u256 = 105_000 * pow_256(10, 18);
    let team_alloc: u256 = half * 2_u256;
    memecoin.approve(pool_address, team_alloc);

    // Deposit team allocation as two notes.
    pool
        .deposit(
            memecoin_address,
            team_alloc,
            array![0xA1, 0xB2].span(),
            array![half, half].span(),
            array![note(one_payload()), note(one_payload())].span(),
        );

    assert(memecoin.balance_of(pool_address) == team_alloc, 'pool received tokens');
    assert(pool.token_of_commitment(0xA1) == memecoin_address, 'commit A token');
    assert(pool.balance_of_commitment(0xA1) == half, 'commit A amount');
    assert(pool.token_of_commitment(0xB2) == memecoin_address, 'commit B token');
    assert(pool.balance_of_commitment(0xB2) == half, 'commit B amount');

    // Two recipients withdraw independently.
    let r1: ContractAddress = 'recipient_1'.try_into().unwrap();
    let r2: ContractAddress = 'recipient_2'.try_into().unwrap();
    let proof: Array<felt252> = array![];

    pool.withdraw(memecoin_address, r1, half, 0xA1, proof.span(), 0xCAFE);
    assert(memecoin.balance_of(r1) == half, 'r1 balance');
    assert(memecoin.balance_of(pool_address) == half, 'pool half left');
    assert(pool.balance_of_commitment(0xA1) == 0, 'A1 cleared');
    assert(pool.balance_of_commitment(0xB2) == half, 'B2 still held');

    pool.withdraw(memecoin_address, r2, half, 0xB2, proof.span(), 0xBEEF);
    assert(memecoin.balance_of(r2) == half, 'r2 balance');
    assert(memecoin.balance_of(pool_address) == 0, 'pool drained');
    assert(pool.balance_of_commitment(0xB2) == 0, 'B2 cleared');
}

#[test]
fn test_pool_round_trip_root_advances() {
    let (memecoin, memecoin_address) = deploy_memecoin_owned_by_caller(OWNER());
    let (pool, pool_address) = deploy_mock_shielded_pool();

    pool.register_token(memecoin_address);

    let amount: u256 = 50 * pow_256(10, 18);
    memecoin.approve(pool_address, amount * 2_u256);

    let root_before = pool.current_root();
    pool
        .deposit(
            memecoin_address,
            amount,
            array![0x9001].span(),
            array![amount].span(),
            array![note(one_payload())].span(),
        );
    let root_after_first = pool.current_root();
    assert(root_after_first != root_before, 'root advances on first deposit');

    pool
        .deposit(
            memecoin_address,
            amount,
            array![0x9002].span(),
            array![amount].span(),
            array![note(one_payload())].span(),
        );
    let root_after_second = pool.current_root();
    assert(
        root_after_second != root_after_first, 'root advances on second deposit'
    );
}

#[test]
fn test_post_withdraw_recipient_can_publicly_transfer() {
    // After withdraw, the recipient holds the memecoin like any ERC20 holder. Public
    // transfers work; we mirror the existing repo's transfer-restriction behaviour by
    // not setting the memecoin "launched" — which means restrictions are disabled (see
    // `apply_transfer_restrictions`'s early-return on `!is_launched`).
    let (memecoin, memecoin_address) = deploy_memecoin_owned_by_caller(OWNER());
    let (pool, pool_address) = deploy_mock_shielded_pool();

    pool.register_token(memecoin_address);

    let alloc: u256 = 100 * pow_256(10, 18);
    memecoin.approve(pool_address, alloc);
    pool
        .deposit(
            memecoin_address,
            alloc,
            array![0x1234].span(),
            array![alloc].span(),
            array![note(one_payload())].span(),
        );

    let recipient: ContractAddress = 'recipient'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(memecoin_address, recipient, alloc, 0x1234, proof.span(), 0xC0FFEE);
    assert(memecoin.balance_of(recipient) == alloc, 'recipient received');

    // Recipient transfers half publicly to a third party.
    let third_party: ContractAddress = 'third_party'.try_into().unwrap();
    let send_amount: u256 = 10 * pow_256(10, 18);
    start_prank(CheatTarget::One(memecoin_address), recipient);
    memecoin.transfer(third_party, send_amount);
    stop_prank(CheatTarget::One(memecoin_address));

    assert(memecoin.balance_of(third_party) == send_amount, 'third_party received');
    assert(memecoin.balance_of(recipient) == alloc - send_amount, 'recipient minus send');
}

#[test]
fn test_partial_withdrawals_when_one_recipient_does_not_claim() {
    // Three notes; one recipient withdraws, the other two notes stay parked in the pool.
    let (memecoin, memecoin_address) = deploy_memecoin_owned_by_caller(OWNER());
    let (pool, pool_address) = deploy_mock_shielded_pool();

    pool.register_token(memecoin_address);

    let third: u256 = 30 * pow_256(10, 18);
    let total: u256 = third * 3_u256;
    memecoin.approve(pool_address, total);

    pool
        .deposit(
            memecoin_address,
            total,
            array![0x1, 0x2, 0x3].span(),
            array![third, third, third].span(),
            array![note(one_payload()), note(one_payload()), note(one_payload())].span(),
        );

    let recipient: ContractAddress = 'recipient'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(memecoin_address, recipient, third, 0x2, proof.span(), 0xC1);

    assert(memecoin.balance_of(recipient) == third, 'recipient holds third');
    assert(memecoin.balance_of(pool_address) == third * 2_u256, 'pool holds 2/3');
    assert(pool.balance_of_commitment(0x1) == third, 'commit 1 untouched');
    assert(pool.balance_of_commitment(0x2) == 0, 'commit 2 cleared');
    assert(pool.balance_of_commitment(0x3) == third, 'commit 3 untouched');
}
