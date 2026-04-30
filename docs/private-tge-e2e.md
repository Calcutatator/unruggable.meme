# Private TGE — E2E walkthrough

End-to-end devnet test for the Private TGE feature. The script
[`packages/contracts/scripts/private-tge-e2e.js`](../packages/contracts/scripts/private-tge-e2e.js)
declares all required contract classes, deploys them, and walks through the full flow:

1. Declare & deploy: ERC20 quote token, LockManager, mock Jediswap router/factory,
   `MockShieldedPool`, `UnruggableMemecoin` class, `Factory`.
2. Create a memecoin via the Factory.
3. Register the memecoin in the shielded pool.
4. Approve the factory to spend the quote token.
5. Call `launch_private_on_jediswap` — seeds AMM liquidity AND deposits the team
   allocation into the shielded pool as opaque notes.
6. Read on-chain state and assert: memecoin launched, pool holds the team allocation,
   commitments stored with the right `(token, amount)`, factory's pool getter returns
   the configured pool.
7. Withdraw one of the notes to a recipient. Assert: recipient receives the memecoin
   amount, pool's balance reduces, the spent commitment is cleared, the nullifier is
   marked spent.

Each assertion prints a `✓` line. If any fails the script exits non-zero.

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

Expected output (about 30s on a laptop):

```
  ── Private TGE — devnet E2E ──

  devnet at http://127.0.0.1:5050
  owner    0x34ba56…79ba

[1] Declare & deploy supporting contracts
  declare ERC20Token             class_hash=0x6ccb9c…26e4
  deploy  ERC20Token             address=0x42f143…6b99
  …

[2] Create memecoin via Factory
    memecoin 0x2e322a…1f0b

[3] Register memecoin in shielded pool
    ✓ registered

[4] Approve quote token for AMM liquidity
    ✓ approved 1000000000000000000 of quote token to factory

[5] launch_private_on_jediswap
    seeds AMM liquidity AND deposits team allocation as shielded notes

    ✓ launched (tx 0x317202…015d)

[6] Verify on-chain state
    ✓ memecoin.is_launched() == true
    ✓ pool holds team_allocation (210000000000000000000000)
    ✓ pool stores commitment A with HALF_NOTE
    ✓ commitment A → memecoin
    ✓ factory.shielded_pool_address() == pool

[7] Withdraw note A to a recipient
    ✓ withdrew note A → 0xdead
    ✓ recipient holds HALF_NOTE memecoin
    ✓ pool now holds only HALF_NOTE (B still inside)
    ✓ commitment A cleared
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

It is NOT exercising real Jediswap either — we use the in-repo `FactoryC1` / `RouterC1`
mocks. The Ekubo and StarkDeFi launch paths are covered at the validation level by the
snforge unit tests in [`test_private_launch.cairo`](../packages/contracts/src/tests/unit_tests/test_private_launch.cairo);
full AMM-side coverage for those would require the existing fork tests (currently broken
because the pinned `Scarb.toml` points at a sunset Nethermind RPC — out of scope for this
PR).

## Where to look in the script

- `step(1, …)` — declarations and deployments. The constructor calldata layouts match
  the Cairo serialisation of `LaunchParameters` / `PrivateLaunchParameters`; see comments
  inline.
- `step(5, …)` — the launch call. Note that `initial_holders` and
  `initial_holders_amounts` are empty — the private path uses note commitments as the
  single source of truth for team allocation.
- `step(6, …)` — every check is a direct RPC call to a view function on the deployed
  contracts.

## If it fails

- "LOCK TOO SHORT": the `unlock_time` constant in the script is now hard-coded to a far-
  future timestamp; if your devnet is set to a far-future time, increase it further.
- "Insufficient transaction data": this is a devnet warning during fee estimation on
  fresh chains and is silenced in the script; if you see it, it's harmless.
- "Class hash already declared": you re-ran the script on the same devnet without
  restarting it. Either restart devnet or wait — the script uses `declareIfNot` so this
  shouldn't be fatal.
- Anything else: open the issue with the full error and the script will print the failing
  step.
