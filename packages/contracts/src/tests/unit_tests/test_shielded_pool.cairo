use core::traits::TryInto;
use core::zeroable::Zeroable;
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank, CheatTarget};
use starknet::{ContractAddress, contract_address_const};
use unruggable::privacy::interface::{
    EncryptedNote, IShieldedPoolDispatcher, IShieldedPoolDispatcherTrait
};
use unruggable::tests::unit_tests::utils::{deploy_mock_shielded_pool, OWNER};

// ---------- helpers ---------------------------------------------------------

fn deploy_token_with_supply(owner: ContractAddress, supply: u256) -> (ERC20ABIDispatcher, ContractAddress) {
    let token = declare('ERC20Token');
    let mut calldata = array![];
    Serde::serialize(@supply, ref calldata);
    Serde::serialize(@owner, ref calldata);
    let address = token.deploy(@calldata).unwrap();
    (ERC20ABIDispatcher { contract_address: address }, address)
}

fn one_payload() -> Span<felt252> {
    array![0x42].span()
}

fn note(payload: Span<felt252>) -> EncryptedNote {
    EncryptedNote { payload }
}

// ---------- registration ---------------------------------------------------

#[test]
fn test_register_token() {
    let (pool, _) = deploy_mock_shielded_pool();
    let (_, token_address) = deploy_token_with_supply(OWNER(), 1_000_000);
    assert(!pool.is_token_registered(token_address), 'should not be registered');
    pool.register_token(token_address);
    assert(pool.is_token_registered(token_address), 'should be registered');
}

#[test]
#[should_panic(expected: ('Pool: token already registered',))]
fn test_register_token_twice_panics() {
    let (pool, _) = deploy_mock_shielded_pool();
    let (_, token_address) = deploy_token_with_supply(OWNER(), 1_000_000);
    pool.register_token(token_address);
    pool.register_token(token_address);
}

#[test]
#[should_panic(expected: ('Pool: zero token',))]
fn test_register_zero_token_panics() {
    let (pool, _) = deploy_mock_shielded_pool();
    pool.register_token(Zeroable::zero());
}

// ---------- deposit --------------------------------------------------------

#[test]
fn test_deposit_happy_path() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000_000);
    pool.register_token(token_address);

    // Owner approves the pool to pull 100 tokens.
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 100);
    stop_prank(CheatTarget::One(token_address));

    let commitments = array![0x111, 0x222].span();
    let amounts: Array<u256> = array![60, 40];
    let p1 = one_payload();
    let p2 = one_payload();
    let outputs = array![note(p1), note(p2)].span();

    let root_before = pool.current_root();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 100, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));

    assert(token.balance_of(pool_address) == 100, 'pool didnt receive tokens');
    assert(token.balance_of(owner) == 999_900, 'owner balance not deducted');
    assert(pool.balance_of_commitment(0x111) == 60, 'wrong stored amount 1');
    assert(pool.balance_of_commitment(0x222) == 40, 'wrong stored amount 2');
    assert(pool.token_of_commitment(0x111) == token_address, 'wrong token 1');
    assert(pool.token_of_commitment(0x222) == token_address, 'wrong token 2');
    assert(pool.current_root() != root_before, 'root not advanced');
}

#[test]
#[should_panic(expected: ('Pool: token not registered',))]
fn test_deposit_unregistered_token_panics() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000);
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 10);
    stop_prank(CheatTarget::One(token_address));

    let commitments = array![0x1].span();
    let amounts = array![10_u256];
    let outputs = array![note(one_payload())].span();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 10, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
#[should_panic(expected: ('Pool: array lengths differ',))]
fn test_deposit_arrays_len_mismatch_panics() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000);
    pool.register_token(token_address);
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 10);
    stop_prank(CheatTarget::One(token_address));

    let commitments = array![0x1, 0x2].span();
    let amounts = array![10_u256]; // mismatched length
    let outputs = array![note(one_payload()), note(one_payload())].span();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 10, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
#[should_panic(expected: ('Pool: array lengths differ',))]
fn test_deposit_outputs_len_mismatch_panics() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000);
    pool.register_token(token_address);
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 10);
    stop_prank(CheatTarget::One(token_address));

    let commitments = array![0x1].span();
    let amounts = array![10_u256];
    let outputs = array![note(one_payload()), note(one_payload())].span(); // extra output
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 10, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
#[should_panic(expected: ('Pool: no notes provided',))]
fn test_deposit_zero_notes_panics() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000);
    pool.register_token(token_address);

    let commitments: Span<felt252> = array![].span();
    let amounts: Array<u256> = array![];
    let outputs: Span<EncryptedNote> = array![].span();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 0, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
#[should_panic(expected: ('Pool: sum != deposit amount',))]
fn test_deposit_sum_mismatch_panics() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000);
    pool.register_token(token_address);
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 100);
    stop_prank(CheatTarget::One(token_address));

    let commitments = array![0x1, 0x2].span();
    let amounts = array![60_u256, 30_u256]; // sums to 90 but we claim 100
    let outputs = array![note(one_payload()), note(one_payload())].span();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 100, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
#[should_panic(expected: ('Pool: sum != deposit amount',))]
fn test_deposit_zero_amount_per_note_panics() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000);
    pool.register_token(token_address);
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 100);
    stop_prank(CheatTarget::One(token_address));

    let commitments = array![0x1, 0x2].span();
    let amounts = array![100_u256, 0_u256]; // zero amount on second note
    let outputs = array![note(one_payload()), note(one_payload())].span();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 100, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
#[should_panic(expected: ('Pool: commitment token/amount',))]
fn test_deposit_duplicate_commitment_panics() {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000);
    pool.register_token(token_address);
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 100);
    stop_prank(CheatTarget::One(token_address));

    let commitments = array![0x1, 0x1].span(); // duplicate
    let amounts = array![50_u256, 50_u256];
    let outputs = array![note(one_payload()), note(one_payload())].span();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 100, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
}

// ---------- withdraw -------------------------------------------------------

fn fresh_pool_with_deposit(
) -> (IShieldedPoolDispatcher, ContractAddress, ERC20ABIDispatcher, ContractAddress) {
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let owner = OWNER();
    let (token, token_address) = deploy_token_with_supply(owner, 1_000_000);
    pool.register_token(token_address);
    start_prank(CheatTarget::One(token_address), owner);
    token.approve(pool_address, 100);
    stop_prank(CheatTarget::One(token_address));
    let commitments = array![0xAAA, 0xBBB].span();
    let amounts = array![60_u256, 40_u256];
    let outputs = array![note(one_payload()), note(one_payload())].span();
    start_prank(CheatTarget::One(pool_address), owner);
    pool.deposit(token_address, 100, commitments, amounts.span(), outputs);
    stop_prank(CheatTarget::One(pool_address));
    (pool, pool_address, token, token_address)
}

#[test]
fn test_withdraw_happy_path() {
    let (pool, _, token, token_address) = fresh_pool_with_deposit();
    let recipient: ContractAddress = 'recipient1'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(token_address, recipient, 60, 0xAAA, proof.span(), 0xCAFE);
    assert(token.balance_of(recipient) == 60, 'recipient didnt get tokens');
    assert(pool.is_nullifier_spent(0xCAFE), 'nullifier not marked spent');
    assert(pool.balance_of_commitment(0xAAA) == 0, 'commitment not cleared');
}

#[test]
#[should_panic(expected: ('Pool: nullifier already spent',))]
fn test_withdraw_double_spend_panics() {
    let (pool, _, _, token_address) = fresh_pool_with_deposit();
    let recipient: ContractAddress = 'r1'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(token_address, recipient, 60, 0xAAA, proof.span(), 0xCAFE);
    pool.withdraw(token_address, recipient, 60, 0xBBB, proof.span(), 0xCAFE);
}

#[test]
#[should_panic(expected: ('Pool: unknown commitment',))]
fn test_withdraw_unknown_commitment_panics() {
    let (pool, _, _, token_address) = fresh_pool_with_deposit();
    let recipient: ContractAddress = 'r1'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(token_address, recipient, 50, 0xDEAD, proof.span(), 0xC1);
}

#[test]
#[should_panic(expected: ('Pool: commitment token/amount',))]
fn test_withdraw_wrong_amount_panics() {
    let (pool, _, _, token_address) = fresh_pool_with_deposit();
    let recipient: ContractAddress = 'r1'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(token_address, recipient, 99, 0xAAA, proof.span(), 0xC1);
}

#[test]
#[should_panic(expected: ('Pool: commitment token/amount',))]
fn test_withdraw_wrong_token_panics() {
    let (pool, _, _, _) = fresh_pool_with_deposit();
    // Use a token address that doesn't match what was deposited.
    let fake_token: ContractAddress = 'fake_token'.try_into().unwrap();
    let recipient: ContractAddress = 'r1'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(fake_token, recipient, 60, 0xAAA, proof.span(), 0xC1);
}

#[test]
fn test_independent_withdrawals_dont_interfere() {
    let (pool, _, token, token_address) = fresh_pool_with_deposit();
    let r1: ContractAddress = 'r1'.try_into().unwrap();
    let r2: ContractAddress = 'r2'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(token_address, r1, 60, 0xAAA, proof.span(), 0xC1);
    assert(token.balance_of(r1) == 60, 'r1 wrong balance');
    assert(token.balance_of(r2) == 0, 'r2 should be 0 yet');
    assert(pool.balance_of_commitment(0xBBB) == 40, 'r2 commitment intact');
    pool.withdraw(token_address, r2, 40, 0xBBB, proof.span(), 0xC2);
    assert(token.balance_of(r2) == 40, 'r2 wrong balance after');
    assert(pool.balance_of_commitment(0xBBB) == 0, 'r2 commitment not cleared');
}
