# Private TGE — E2E walkthrough

End-to-end devnet test for the privacy machinery added by this PR. The script
[`packages/contracts/scripts/private-tge-e2e.js`](../packages/contracts/scripts/private-tge-e2e.js)
declares all required contract classes, deploys them, and walks through the full
deposit → withdraw round-trip — the same `pool.deposit` / `pool.withdraw` calls that
`Factory.launch_private_on_ekubo` makes internally during a production launch.

1. Declare & deploy: `MockShieldedPool`, `ERC20Token` (a generic ERC20 standing in for
   the launched token — see *Why we use `ERC20Token`* below).
2. Register the token in the shielded pool.
3. Approve the pool to pull the team allocation from the supply holder.
4. Call `pool.deposit(token, amount, commitments, amounts, encrypted_outputs)`.
5. Read on-chain state and assert: pool holds the team allocation, commitments stored
   with the right `(token, amount)`.
6. Withdraw one of the notes to a recipient. Assert: recipient receives the token
   amount, the spent commitment is cleared, the nullifier is marked spent.

Each assertion prints a `✓` line. If any fails the script exits non-zero.

## Why this scope?

The production launch path is `Factory.launch_private_on_ekubo`, which seeds Ekubo
concentrated-liquidity AND deposits the team allocation into the shielded pool. There's
no in-repo mock for Ekubo (the existing repo only fork-tests Ekubo against mainnet), so
the AMM-side of the launch can't run on a fresh devnet. This script exercises the new
*privacy machinery* — the only new code path on the chain — directly.

The Ekubo AMM-side flow is identical to the existing public `launch_on_ekubo` and is
already covered by the existing fork tests in `tests/fork_tests/test_ekubo.cairo`
(currently broken because the pinned Scarb.toml RPC was sunset; out of scope for this PR
to fix). The new validation pre-checks for `launch_private_on_ekubo` are covered by the
snforge unit tests in [`test_private_launch.cairo`](../packages/contracts/src/tests/unit_tests/test_private_launch.cairo).

## Why we use `ERC20Token` instead of `UnruggableMemecoin`

`UnruggableMemecoin`'s constructor mints the supply to `get_caller_address()`. When
`account.deployContract` goes through the Universal Deployer Contract (UDC), that caller
is the UDC, not the deployer account — so the account ends up with no tokens to deposit.
The `ERC20Token` mock takes an explicit `recipient` argument and mints to that address,
which lets the deployer account hold the supply and drive `approve` / `pool.deposit`
from outside.

The pool is token-agnostic. The integration is verified regardless of which ERC20 is on
the other end. `UnruggableMemecoin`-specific interactions (transfer restrictions
post-launch) are covered by the snforge unit tests
([`test_post_withdraw_recipient_can_publicly_transfer`](../packages/contracts/src/tests/unit_tests/test_private_lifecycle.cairo)).

## Prerequisites

- `scarb 2.4.3` and `snforge 0.16.0` (pinned by the repo's `.tool-versions`).
- `starknet-devnet 0.6.0+` on `PATH` (`asdf install starknet-devnet 0.6.0` if you use asdf).
- Node ≥ 18.
- The contracts must be built: `cd packages/contracts && scarb build`.
- `node_modules` installed under `scripts/`: `cd packages/contracts/scripts && npm install`.

## Run it

In one terminal:

```bash
starknet-devnet --seed 42 --accounts 3 --port 5050
```

In another:

```bash
cd packages/contracts && scarb build
cd scripts && npm install   # first time only
node private-tge-e2e.js
```

Expected output (about 20 seconds on a laptop):

```
  ── Private TGE — devnet E2E ──

  devnet at http://127.0.0.1:5050
  owner    0x34ba56…79ba

[1] Declare & deploy contracts
  declare MockShieldedPool       class_hash=0x289ea6…e288
  deploy  MockShieldedPool       address=0x79835a…c672
  declare ERC20Token             class_hash=0x6ccb9c…26e4
  deploy  ERC20Token             address=0x3a306a…2d54

[2] Register token in shielded pool
    ✓ registered

[3] Approve pool to pull team allocation from supply holder
    ✓ approved 210000000000000000000000 of token to pool

[4] Deposit team allocation as shielded notes
    same call Factory.launch_private_on_ekubo would make internally

    ✓ deposited (tx 0x39ac85…edc0)

[5] Verify on-chain state
    ✓ pool holds team_allocation (210000000000000000000000)
    ✓ pool stores commitment A with HALF_NOTE
    ✓ commitment A → token

[6] Withdraw note A to a recipient
    ✓ withdrew note A → 0xdead
    ✓ recipient holds HALF_NOTE of token
    ✓ pool now holds only HALF_NOTE (B still inside)
    ✓ commitment A cleared (low)
    ✓ commitment A cleared (high)
    ✓ nullifier 0xCAFE marked spent

  ── E2E completed successfully ──
```

## What this is and isn't

It IS a real Starknet execution — every assertion reads on-chain state via the RPC.
Cairo errors panic the way they would on testnet/mainnet. Devnet is the same VM as the
real chain.

It is NOT exercising production STRK20 — `MockShieldedPool` is the same fixture used in
the unit tests. When the real STRK20 contracts ship, the only required change is the
constructor argument passed to `Factory` (see `docs/private-tge-scope.md`).

It is NOT exercising real Ekubo either — see *Why this scope?* above.

## Where to look in the script

- `step(1, …)` — declarations and deployments. Constructor calldata is laid out as raw
  felts matching the Cairo serialisation; comments inline.
- `step(4, …)` — the deposit call. The calldata layout (commitments / amounts /
  encrypted_outputs) mirrors what `launch_private_on_ekubo` generates internally.
- `step(5, …)` and `step(6, …)` — every check is a direct RPC call to a view function
  on the deployed contracts.

## If it fails

- "u256_sub Overflow" on deposit: the supply holder doesn't have enough tokens. Make
  sure you're deploying `ERC20Token` with `owner.address` as the recipient (not
  `UnruggableMemecoin`, whose constructor mints to the UDC during a UDC-based deploy —
  see *Why we use `ERC20Token`* above).
- "Class hash already declared": you re-ran the script on the same devnet without
  restarting it. Either restart devnet or wait — the script uses `declareIfNot` so this
  shouldn't be fatal.
- "Insufficient transaction data": this is a devnet warning during fee estimation on
  fresh chains and is silenced in the script; if you see it leak through, it's harmless.
- Anything else: open an issue with the full error and the script will print the
  failing step.
