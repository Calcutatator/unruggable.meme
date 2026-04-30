//! End-to-end lifecycle tests: launch private → withdraw notes → memecoin balances on the
//! public side behave normally afterwards.

use core::option::OptionTrait;
use core::traits::TryInto;
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{
    declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, start_warp, stop_warp,
    TxInfoMock
};
use starknet::{ContractAddress, contract_address_const};
use unruggable::factory::{
    IFactoryDispatcher, IFactoryDispatcherTrait, LaunchParameters, PrivateLaunchParameters
};
use unruggable::privacy::interface::{
    EncryptedNote, IShieldedPoolDispatcher, IShieldedPoolDispatcherTrait
};
use unruggable::tests::unit_tests::utils::{
    deploy_jedi_amm_factory_and_router, deploy_meme_factory_with_pool, deploy_mock_shielded_pool,
    deploy_eth_with_owner, OWNER, NAME, SYMBOL, DEFAULT_INITIAL_SUPPLY, SALT,
    DEFAULT_MIN_LOCKTIME, TRANSFER_RESTRICTION_DELAY, MAX_PERCENTAGE_BUY_LAUNCH, pow_256,
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

fn launch_private_setup() -> (
    IFactoryDispatcher,
    IShieldedPoolDispatcher,
    ContractAddress,
    IUnruggableMemecoinDispatcher,
    ContractAddress,
    ERC20ABIDispatcher,
) {
    let owner = OWNER();
    let (_, router_address) = deploy_jedi_amm_factory_and_router();
    let (pool, pool_address) = deploy_mock_shielded_pool();
    let factory_address = deploy_meme_factory_with_pool(router_address, pool_address);
    let factory = IFactoryDispatcher { contract_address: factory_address };
    let (eth, _) = deploy_eth_with_owner(owner);

    start_prank(CheatTarget::One(factory_address), owner);
    let memecoin_address = factory
        .create_memecoin(
            owner: owner,
            name: NAME(),
            symbol: SYMBOL(),
            initial_supply: DEFAULT_INITIAL_SUPPLY(),
            contract_address_salt: SALT(),
        );
    stop_prank(CheatTarget::One(factory_address));

    pool.register_token(memecoin_address);

    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(1234);
    snforge_std::start_spoof(CheatTarget::One(memecoin_address), tx_info);

    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };
    (factory, pool, pool_address, memecoin, memecoin_address, eth)
}

#[test]
fn test_lifecycle_two_recipients_withdraw_independently() {
    let owner = OWNER();
    let (factory, pool, pool_address, memecoin, memecoin_address, eth) = launch_private_setup();

    let eth_amount: u256 = 1 * pow_256(10, 18);
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.approve(factory.contract_address, eth_amount);
    stop_prank(CheatTarget::One(eth.contract_address));

    let half: u256 = 105_000 * pow_256(10, 18);
    let private_params = PrivateLaunchParameters {
        note_commitments: array![0xA1, 0xB2].span(),
        note_amounts: array![half, half].span(),
        encrypted_outputs: array![note(one_payload()), note(one_payload())].span(),
    };
    let launch_params = LaunchParameters {
        memecoin_address,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth.contract_address,
        initial_holders: array![].span(),
        initial_holders_amounts: array![].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    start_warp(CheatTarget::One(memecoin_address), 1);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, eth_amount, DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
    stop_warp(CheatTarget::One(memecoin_address));

    let team_alloc: u256 = half + half;
    assert(memecoin.balance_of(pool_address) == team_alloc, 'pool team alloc');

    let r1: ContractAddress = 'recipient_1'.try_into().unwrap();
    let r2: ContractAddress = 'recipient_2'.try_into().unwrap();
    let proof: Array<felt252> = array![];

    pool.withdraw(memecoin_address, r1, half, 0xA1, proof.span(), 0xCAFE);
    assert(memecoin.balance_of(r1) == half, 'r1 balance');
    assert(memecoin.balance_of(pool_address) == half, 'pool balance after r1');
    assert(pool.balance_of_commitment(0xA1) == 0, 'A1 cleared');
    assert(pool.balance_of_commitment(0xB2) == half, 'B2 still held');

    pool.withdraw(memecoin_address, r2, half, 0xB2, proof.span(), 0xBEEF);
    assert(memecoin.balance_of(r2) == half, 'r2 balance');
    assert(memecoin.balance_of(pool_address) == 0, 'pool drained');
    assert(pool.balance_of_commitment(0xB2) == 0, 'B2 cleared');
}

#[test]
fn test_lifecycle_post_withdraw_public_transfer_works() {
    let owner = OWNER();
    let (factory, pool, _, memecoin, memecoin_address, eth) = launch_private_setup();

    let eth_amount: u256 = 1 * pow_256(10, 18);
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.approve(factory.contract_address, eth_amount);
    stop_prank(CheatTarget::One(eth.contract_address));

    let alloc: u256 = 100 * pow_256(10, 18);
    let private_params = PrivateLaunchParameters {
        note_commitments: array![0x1234].span(),
        note_amounts: array![alloc].span(),
        encrypted_outputs: array![note(one_payload())].span(),
    };
    let launch_params = LaunchParameters {
        memecoin_address,
        transfer_restriction_delay: 0,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth.contract_address,
        initial_holders: array![].span(),
        initial_holders_amounts: array![].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    start_warp(CheatTarget::One(memecoin_address), 1);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, eth_amount, DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));

    let recipient: ContractAddress = 'recipient'.try_into().unwrap();
    let proof: Array<felt252> = array![];
    pool.withdraw(memecoin_address, recipient, alloc, 0x1234, proof.span(), 0xC0FFEE);
    assert(memecoin.balance_of(recipient) == alloc, 'recipient got funds');

    start_warp(CheatTarget::One(memecoin_address), 1000);

    let third_party: ContractAddress = 'third_party'.try_into().unwrap();
    let send_amount: u256 = 10 * pow_256(10, 18);
    start_prank(CheatTarget::One(memecoin_address), recipient);
    memecoin.transfer(third_party, send_amount);
    stop_prank(CheatTarget::One(memecoin_address));
    stop_warp(CheatTarget::One(memecoin_address));

    assert(memecoin.balance_of(third_party) == send_amount, 'third party balance');
    assert(memecoin.balance_of(recipient) == alloc - send_amount, 'recipient minus send');
}

#[test]
fn test_lifecycle_root_advances_on_deposit() {
    let owner = OWNER();
    let (factory, pool, _, _, memecoin_address, eth) = launch_private_setup();

    let eth_amount: u256 = 1 * pow_256(10, 18);
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.approve(factory.contract_address, eth_amount);
    stop_prank(CheatTarget::One(eth.contract_address));

    let root_before = pool.current_root();

    let alloc: u256 = 50 * pow_256(10, 18);
    let private_params = PrivateLaunchParameters {
        note_commitments: array![0x9001, 0x9002].span(),
        note_amounts: array![alloc, alloc].span(),
        encrypted_outputs: array![note(one_payload()), note(one_payload())].span(),
    };
    let launch_params = LaunchParameters {
        memecoin_address,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth.contract_address,
        initial_holders: array![].span(),
        initial_holders_amounts: array![].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    start_warp(CheatTarget::One(memecoin_address), 1);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, eth_amount, DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
    stop_warp(CheatTarget::One(memecoin_address));

    let root_after = pool.current_root();
    assert(root_after != root_before, 'root must advance');
}
