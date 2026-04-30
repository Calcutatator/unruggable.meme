//! Unit tests for `launch_private_on_*`. The Jediswap path gets full happy-path coverage
//! with the local Jediswap mock; for Ekubo and StarkDeFi we verify the validation pre-checks
//! fire (the existing repo's pattern is to leave full AMM-side coverage to fork tests, which
//! depend on a live RPC).

use core::option::OptionTrait;
use core::traits::TryInto;
use core::zeroable::Zeroable;
use ekubo::types::i129::i129;
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{
    declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, start_warp, stop_warp,
    TxInfoMock
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
use unruggable::tests::addresses::{ETH_ADDRESS};
use unruggable::tests::unit_tests::utils::{
    deploy_jedi_amm_factory_and_router, deploy_meme_factory_with_pool, deploy_mock_shielded_pool,
    deploy_eth_with_owner, OWNER, NAME, SYMBOL, DEFAULT_INITIAL_SUPPLY, SALT, MEMEFACTORY_ADDRESS,
    DEFAULT_MIN_LOCKTIME, TRANSFER_RESTRICTION_DELAY, MAX_PERCENTAGE_BUY_LAUNCH, pow_256,
    DefaultTxInfoMock
};
use unruggable::token::interface::{
    IUnruggableMemecoinDispatcher, IUnruggableMemecoinDispatcherTrait
};
use unruggable::token::memecoin::LiquidityType;

// ---------- helpers --------------------------------------------------------

fn setup() -> (
    IFactoryDispatcher,
    IShieldedPoolDispatcher,
    ContractAddress,
    IUnruggableMemecoinDispatcher,
    ContractAddress,
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
    IUnruggableMemecoinDispatcher,
    ContractAddress,
    ERC20ABIDispatcher,
) {
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

    let memecoin = IUnruggableMemecoinDispatcher { contract_address: memecoin_address };

    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(1234);
    snforge_std::start_spoof(CheatTarget::One(memecoin_address), tx_info);

    (factory, pool, pool_address, memecoin, memecoin_address, eth)
}

fn one_payload() -> Span<felt252> {
    array![0x42].span()
}

fn note(payload: Span<felt252>) -> EncryptedNote {
    EncryptedNote { payload }
}

/// Standard private params: two notes summing to ~1% of supply.
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

fn approve_eth(
    eth: ERC20ABIDispatcher, factory_address: ContractAddress, owner: ContractAddress
) {
    let eth_amount: u256 = 1 * pow_256(10, 18);
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.approve(factory_address, eth_amount);
    stop_prank(CheatTarget::One(eth.contract_address));
}

// ---------- happy path -----------------------------------------------------

#[test]
fn test_launch_private_on_jediswap_happy_path() {
    let owner = OWNER();
    let (factory, pool, pool_address, memecoin, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();
    let team_alloc: u256 = 210_000 * pow_256(10, 18);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    start_warp(CheatTarget::One(memecoin_address), 1);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
    stop_warp(CheatTarget::One(memecoin_address));

    assert(memecoin.is_launched(), 'memecoin should be launched');
    assert(memecoin.get_team_allocation() == team_alloc, 'team_allocation wrong');
    match memecoin.liquidity_type().unwrap() {
        LiquidityType::JediERC20(_) => (),
        LiquidityType::StarkDeFiERC20(_) => panic_with_felt252('wrong liquidity type'),
        LiquidityType::EkuboNFT(_) => panic_with_felt252('wrong liquidity type'),
    };

    assert(memecoin.balance_of(pool_address) == team_alloc, 'pool balance wrong');
    assert(pool.token_of_commitment(0xAAA) == memecoin_address, 'wrong commitment token A');
    assert(pool.token_of_commitment(0xBBB) == memecoin_address, 'wrong commitment token B');
    let half: u256 = 105_000 * pow_256(10, 18);
    assert(pool.balance_of_commitment(0xAAA) == half, 'wrong commitment amount A');
    assert(pool.balance_of_commitment(0xBBB) == half, 'wrong commitment amount B');
}

#[test]
fn test_launch_private_zero_team_allocation_works() {
    let owner = OWNER();
    let (factory, pool, pool_address, memecoin, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let private_params = PrivateLaunchParameters {
        note_commitments: array![0x999].span(),
        note_amounts: array![1_u256].span(),
        encrypted_outputs: array![note(one_payload())].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    start_warp(CheatTarget::One(memecoin_address), 1);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
    stop_warp(CheatTarget::One(memecoin_address));

    assert(memecoin.is_launched(), 'should be launched');
    assert(memecoin.get_team_allocation() == 1, 'team_allocation should be 1');
    assert(pool.balance_of_commitment(0x999) == 1, 'commitment 1');
    assert(memecoin.balance_of(pool_address) == 1, 'pool balance');
}

#[test]
fn test_launch_private_max_holders_works() {
    let owner = OWNER();
    let (factory, _, _, memecoin, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let per_note: u256 = 210_000 * pow_256(10, 18);
    let mut commits: Array<felt252> = array![];
    let mut amounts: Array<u256> = array![];
    let mut outputs: Array<EncryptedNote> = array![];
    let mut i: u32 = 0;
    loop {
        if i == 10 {
            break;
        }
        commits.append((0x100 + i).into());
        amounts.append(per_note);
        outputs.append(note(one_payload()));
        i += 1;
    };

    let private_params = PrivateLaunchParameters {
        note_commitments: commits.span(),
        note_amounts: amounts.span(),
        encrypted_outputs: outputs.span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    start_warp(CheatTarget::One(memecoin_address), 1);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
    stop_warp(CheatTarget::One(memecoin_address));

    assert(memecoin.is_launched(), 'should be launched');
    assert(memecoin.get_team_allocation() == per_note * 10_u256, 'team_allocation wrong');
}

// ---------- reverts --------------------------------------------------------

#[test]
#[should_panic(expected: ('Shielded pool not configured',))]
fn test_launch_private_pool_not_set_panics() {
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

    approve_eth(eth, factory_address, owner);
    let mut tx_info: TxInfoMock = Default::default();
    tx_info.transaction_hash = Option::Some(1234);
    snforge_std::start_spoof(CheatTarget::One(memecoin_address), tx_info);

    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();
    start_prank(CheatTarget::One(factory_address), owner);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_launch_private_caller_not_owner_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let attacker: ContractAddress = 'attacker'.try_into().unwrap();
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();

    start_prank(CheatTarget::One(factory.contract_address), attacker);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Already launched',))]
fn test_launch_private_already_launched_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();
    start_prank(CheatTarget::One(factory.contract_address), owner);
    start_warp(CheatTarget::One(memecoin_address), 1);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );

    let private_params2 = PrivateLaunchParameters {
        note_commitments: array![0xCCC].span(),
        note_amounts: array![1_u256].span(),
        encrypted_outputs: array![note(one_payload())].span(),
    };
    factory
        .launch_private_on_jediswap(
            launch_params, private_params2, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
    stop_warp(CheatTarget::One(memecoin_address));
}

#[test]
#[should_panic(expected: ('Public holders must be empty',))]
fn test_launch_private_with_public_holders_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let bad_launch_params = LaunchParameters {
        memecoin_address,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth.contract_address,
        initial_holders: array!['alice'.try_into().unwrap()].span(),
        initial_holders_amounts: array![100_u256].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory
        .launch_private_on_jediswap(
            bad_launch_params,
            standard_private_params(),
            1 * pow_256(10, 18),
            DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Private arrays length differ',))]
fn test_launch_private_arrays_len_differ_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let bad_private = PrivateLaunchParameters {
        note_commitments: array![0xAAA, 0xBBB].span(),
        note_amounts: array![100_u256].span(),
        encrypted_outputs: array![note(one_payload()), note(one_payload())].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory
        .launch_private_on_jediswap(
            launch_params, bad_private, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Private arrays length differ',))]
fn test_launch_private_outputs_len_differ_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let bad_private = PrivateLaunchParameters {
        note_commitments: array![0xAAA, 0xBBB].span(),
        note_amounts: array![50_u256, 50_u256].span(),
        encrypted_outputs: array![note(one_payload())].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory
        .launch_private_on_jediswap(
            launch_params, bad_private, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('No notes provided',))]
fn test_launch_private_no_notes_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let empty_private = PrivateLaunchParameters {
        note_commitments: array![].span(),
        note_amounts: array![].span(),
        encrypted_outputs: array![].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory
        .launch_private_on_jediswap(
            launch_params, empty_private, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Max number of holders reached',))]
fn test_launch_private_too_many_notes_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

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

    let bad_private = PrivateLaunchParameters {
        note_commitments: commits.span(),
        note_amounts: amounts.span(),
        encrypted_outputs: outputs.span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory
        .launch_private_on_jediswap(
            launch_params, bad_private, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Max team allocation reached',))]
fn test_launch_private_team_alloc_too_big_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let cap_plus_one: u256 = 2_100_001 * pow_256(10, 18);
    let bad_private = PrivateLaunchParameters {
        note_commitments: array![0xAAA].span(),
        note_amounts: array![cap_plus_one].span(),
        encrypted_outputs: array![note(one_payload())].span(),
    };
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory
        .launch_private_on_jediswap(
            launch_params, bad_private, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Token not registered in pool',))]
fn test_launch_private_token_not_registered_panics() {
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

    approve_eth(eth, factory_address, owner);

    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();

    start_prank(CheatTarget::One(factory_address), owner);
    factory
        .launch_private_on_jediswap(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('Token not deployed by factory',))]
fn test_launch_private_not_unruggable_panics() {
    let owner = OWNER();
    let (factory, pool, _, _, _, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let fake_memecoin: ContractAddress = 'fake_memecoin'.try_into().unwrap();
    pool.register_token(fake_memecoin);

    let bad_launch = LaunchParameters {
        memecoin_address: fake_memecoin,
        transfer_restriction_delay: TRANSFER_RESTRICTION_DELAY,
        max_percentage_buy_launch: MAX_PERCENTAGE_BUY_LAUNCH,
        quote_address: eth.contract_address,
        initial_holders: array![].span(),
        initial_holders_amounts: array![].span(),
    };

    start_prank(CheatTarget::One(factory.contract_address), owner);
    factory
        .launch_private_on_jediswap(
            bad_launch, standard_private_params(), 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

// ---------- Ekubo and StarkDeFi: validation pre-checks fire ---------------

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
    let ekubo_params = EkuboPoolParameters {
        fee: 0xc49ba5e353f7d00000000000000000,
        tick_spacing: 5982,
        starting_price: i129 { mag: 4600158, sign: false },
        bound: 88712960,
    };

    start_prank(CheatTarget::One(factory_address), owner);
    factory.launch_private_on_ekubo(launch_params, private_params, ekubo_params);
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('Shielded pool not configured',))]
fn test_launch_private_on_starkdefi_pool_not_set_panics() {
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
    factory
        .launch_private_on_starkdefi(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_launch_private_on_ekubo_not_owner_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let attacker: ContractAddress = 'attacker'.try_into().unwrap();
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();
    let ekubo_params = EkuboPoolParameters {
        fee: 0xc49ba5e353f7d00000000000000000,
        tick_spacing: 5982,
        starting_price: i129 { mag: 4600158, sign: false },
        bound: 88712960,
    };

    start_prank(CheatTarget::One(factory.contract_address), attacker);
    factory.launch_private_on_ekubo(launch_params, private_params, ekubo_params);
    stop_prank(CheatTarget::One(factory.contract_address));
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_launch_private_on_starkdefi_not_owner_panics() {
    let owner = OWNER();
    let (factory, _, _, _, memecoin_address, eth) = setup();
    approve_eth(eth, factory.contract_address, owner);

    let attacker: ContractAddress = 'attacker'.try_into().unwrap();
    let launch_params = standard_launch_params(memecoin_address, eth.contract_address);
    let private_params = standard_private_params();

    start_prank(CheatTarget::One(factory.contract_address), attacker);
    factory
        .launch_private_on_starkdefi(
            launch_params, private_params, 1 * pow_256(10, 18), DEFAULT_MIN_LOCKTIME,
        );
    stop_prank(CheatTarget::One(factory.contract_address));
}

// ---------- shielded_pool_address getter -----------------------------------

#[test]
fn test_shielded_pool_address_getter() {
    let (factory, _, pool_address, _, _, _) = setup();
    assert(factory.shielded_pool_address() == pool_address, 'wrong pool address getter');
}

#[test]
fn test_shielded_pool_address_zero_when_not_set() {
    let (_, router_address) = deploy_jedi_amm_factory_and_router();
    let factory_address = deploy_meme_factory_with_pool(router_address, Zeroable::zero());
    let factory = IFactoryDispatcher { contract_address: factory_address };
    assert(factory.shielded_pool_address() == Zeroable::zero(), 'should be zero');
}
