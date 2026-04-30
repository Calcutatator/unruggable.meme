//! Privacy-specific error constants.

const POOL_TOKEN_NOT_REGISTERED: felt252 = 'Pool: token not registered';
const POOL_AMOUNT_MISMATCH: felt252 = 'Pool: sum != deposit amount';
const POOL_ARRAYS_LEN_DIF: felt252 = 'Pool: array lengths differ';
const POOL_ZERO_NOTES: felt252 = 'Pool: no notes provided';
const POOL_COMMITMENT_UNKNOWN: felt252 = 'Pool: unknown commitment';
const POOL_COMMITMENT_MISMATCH: felt252 = 'Pool: commitment token/amount';
const POOL_NULLIFIER_SPENT: felt252 = 'Pool: nullifier already spent';
const POOL_TOKEN_ALREADY_REGISTERED: felt252 = 'Pool: token already registered';
