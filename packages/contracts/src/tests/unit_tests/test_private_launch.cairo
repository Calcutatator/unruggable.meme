//! Validation tests for `launch_private_on_ekubo`. The full Ekubo happy path requires the
//! mainnet Ekubo deployment (this repo only fork-tests Ekubo) — out of scope for unit
//! tests. What we CAN verify here is that every pre-check fires correctly. The
//! pool-integration happy path (deposit → withdraw of an UnruggableMemecoin) lives in
//! `test_private_lifecycle.cairo` and exercises the pool independently of the launch
//! wrapper.

use core::option::OptionTrait;
use core::traits::TryInto;
use core::zeroable::Zeroable;
use ekubo::types::i129::i129;
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{
    declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, TxInfoMock
};
use starknet::{ContractAddress, contract_address_const};
use unruggable::exchanges::ekubo_adapter::EkuboPoolParameters;
use unruggable::exchanges::SupportedExchanges;
use unruggable::factory::{
    IFactory, IFactoryDispatcher, IFactoryDispatcherTrait, LaunchParameters, PrivateLaunchParameters
};
use unruggable::privacy::interface::{
    EncryptedNote, IShieldedPoolDispatcher, IShieldedPoolDispatcherTrait
};
use unruggable::tests::unit_tests::utils::{
    deploy_jedi_amm_factory_and_router, deploy_meme_factory_with_pool, deploy_mock_shielded_pool,
    deploy_eth_with_owner, OWNER, NAME, SYMBOL, DEFAULT_INITIAL_SUPPLY, SALT, MEMEFACTORY_ADDRESS,
    DEFAULT_MIN_LOCKTIME, TRANSFER_RESTRICTION_DELAY, MAX_PERCENTAGE_BUY_LAUNCH, pow_256,
    DefaultTxInfoMock
};
use unruggable::token::interface::{
    IUnruggableMemecoinDispatcher, IUnruggableMemecoinDispatcherTrait
};

// ---------- helpers --------------------------------------------------------

fn setup() -> (
    IFactoryDispatcher,
    IShieldedPoolDispatcher,
    ContractAddress,
    ContractAddress, // memecoin address
    ERC20ABIDispatcher,
) {
    setup_with_owner(OWNER())
}

fn setup_with_owner(
    owner: ContractAddress
) -> (
    IFactoryDispatcher,
    IShieldedPoolDispatcher,
    ContractAddress,
    ContractAddress,
    ERC20ABIDispatcher,
) {
    // We use the standard deploy_meme_factory_with_pool (which only registers Jediswap by
    // default, since that's what has an in-repo mock). For Ekubo validation tests we don't
    // need a real Ekubo launchpad — `check_private_launch_parameters` reverts before the
    // exchange-address check is reached.
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

    (factory, pool, pool_address, memecoin_address, eth)
}

fn one_payload() -> Span<felt252> {
    array![0x42].span()
}

fn note(payload: Span<felt252>) -> EncryptedNote {
    EncryptedNote { payload }
}

fn standard_private_params() -> PrivateLaunchParameters {
    let half_alloc: u256 = 105_000 * pow_256(10, 18);
    PrivateLaunchParameters {
        note_commitments: array![0xAAA, 0xBBB].span(),
        note_amounts: array![half_alloc, half_alloc].span(),
        encrypted_outputs: array![note(one_payload()), note(one_payload())].span(),
    }
}

fn standard_launch_params(
    memecoin_address: ContractAddress, eth: ContractAddress
) -> LaunchParameters {
    LaunchParameters {
        memecoin_address,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth,
        initial_holders: array![].span(),
        initial_holders_amounts: array![].span(),
    }
}

fn valid_ekubo_params() -> EkuboPoolParameters {
    EkuboPoolParameters {
        fee: 0xc49ba5e353f7d00000000000000000,
        tick_spacing: 5982,
        starting_price: i129 { mag: 4600158, sign: false },
        bound: 88712960,
    }
}

// ---------- shielded_pool_address getter -----------------------------------

#[test]
fn test_shielded_pool_address_getter() {
    let (factory, _, pool_address, _, _) = setup();
    assert(factory.shielded_pool_address() == pool_address, 'wrong pool address getter');
}

#[test]
fn test_shielded_pool_address_zero_when_not_set() {
    let (_, router_address) = deploy_jedi_amm_factory_and_router();
    let factory_address = deploy_meme_factory_with_pool(router_address, Zeroable::zero());
    let factory = IFactoryDispatcher { contract_address: factory_address };
    assert(factory.shielded_pool_address() == Zeroable::zero(), 'should be zero');
}

// ---------- validation reverts on launch_private_on_ekubo ------------------

#[test]
#[should_panic(expected: ('Shielded pool not configured',))]
fn test_launch_private_on_ekubo_pool_not_set_panics() {
    let owner = OWNER();
    let (_, router_address) = deploy_jedi_amm_factory_and_router();
    let factory_address = deploy_meme_factory_with_pool(router_address, Zeroable::zero());
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

    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(1234);
    snforge_std::start_spoof(CheatTarget::One(memecoin_address), tx_info);

    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();

    start_prank(CheatTarget::One(factory_address), owner);
    factory.launch_private_on_ekubo(launch_params, private_params, valid_ekubo_params());
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_launch_private_on_ekubo_not_owner_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, eth) = setup();

    let attacker: ContractAddress = 'attacker'.try_into().unwrap();
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), attacker);
    factory.launch_private_on_ekubo(launch_params, standard_private_params(), valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Public holders must be empty',))]
fn test_launch_private_on_ekubo_with_public_holders_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, eth) = setup();

    let bad = LaunchParameters {
        memecoin_address,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth.contract_address,
        initial_holders: array!['alice'.try_into().unwrap()].span(),
        initial_holders_amounts: array![100_u256].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(bad, standard_private_params(), valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Private arrays length differ',))]
fn test_launch_private_on_ekubo_arrays_len_differ_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, eth) = setup();

    let bad = PrivateLaunchParameters {
        note_commitments: array![0xAAA, 0xBBB].span(),
        note_amounts: array![100_u256].span(),
        encrypted_outputs: array![note(one_payload()), note(one_payload())].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(launch_params, bad, valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Private arrays length differ',))]
fn test_launch_private_on_ekubo_outputs_len_differ_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, eth) = setup();

    let bad = PrivateLaunchParameters {
        note_commitments: array![0xAAA, 0xBBB].span(),
        note_amounts: array![50_u256, 50_u256].span(),
        encrypted_outputs: array![note(one_payload())].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(launch_params, bad, valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('No notes provided',))]
fn test_launch_private_on_ekubo_no_notes_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, eth) = setup();

    let empty = PrivateLaunchParameters {
        note_commitments: array![].span(),
        note_amounts: array![].span(),
        encrypted_outputs: array![].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(launch_params, empty, valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Max number of holders reached',))]
fn test_launch_private_on_ekubo_too_many_notes_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, eth) = setup();

    let mut commits: Array<felt252> = array![];
    let mut amounts: Array<u256> = array![];
    let mut outputs: Array<EncryptedNote> = array![];
    let mut i: u32 = 0;
    loop {
        if i == 11 {
            break;
        }
        commits.append((0x200 + i).into());
        amounts.append(1_u256);
        outputs.append(note(one_payload()));
        i += 1;
    };

    let bad = PrivateLaunchParameters {
        note_commitments: commits.span(),
        note_amounts: amounts.span(),
        encrypted_outputs: outputs.span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(launch_params, bad, valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Max team allocation reached',))]
fn test_launch_private_on_ekubo_team_alloc_too_big_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, eth) = setup();

    let cap_plus_one: u256 = 2_100_001 * pow_256(10, 18);
    let bad = PrivateLaunchParameters {
        note_commitments: array![0xAAA].span(),
        note_amounts: array![cap_plus_one].span(),
        encrypted_outputs: array![note(one_payload())].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(launch_params, bad, valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Token not registered in pool',))]
fn test_launch_private_on_ekubo_token_not_registered_panics() {
    let owner = OWNER();
    let (_, router_address) = deploy_jedi_amm_factory_and_router();
    let (_, pool_address) = deploy_mock_shielded_pool();
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
    // Deliberately skip pool.register_token(memecoin_address).

    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(1234);
    snforge_std::start_spoof(CheatTarget::One(memecoin_address), tx_info);

    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory_address), owner);
    factory.launch_private_on_ekubo(launch_params, standard_private_params(), valid_ekubo_params());
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('Token not deployed by factory',))]
fn test_launch_private_on_ekubo_not_unruggable_panics() {
    let owner = OWNER();
    let (factory, pool, _, _, eth) = setup();

    let fake_memecoin: ContractAddress = 'fake_memecoin'.try_into().unwrap();
    pool.register_token(fake_memecoin);

    let bad = LaunchParameters {
        memecoin_address: fake_memecoin,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth.contract_address,
        initial_holders: array![].span(),
        initial_holders_amounts: array![].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(bad, standard_private_params(), valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Quote token is memecoin',))]
fn test_launch_private_on_ekubo_quote_is_memecoin_panics() {
    let owner = OWNER();
    let (factory, _, _, memecoin_address, _) = setup();

    let bad = LaunchParameters {
        memecoin_address,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: memecoin_address, // pointing at itself
        initial_holders: array![].span(),
        initial_holders_amounts: array![].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory.launch_private_on_ekubo(bad, standard_private_params(), valid_ekubo_params());
    stop_prank(CheatTarget::One(factory.contract_address));
}
