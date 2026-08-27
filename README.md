# Theta-BG

A Uniswap v4 hook: bonded searcher priority lane, on-chain same-block
sandwich detection, and a self-compounding LP insurance vault funded by
slashed bonds. Built for UHI10 — Sustainable Liquidity & MEV Protection.

> Sandwich me and lose your bond — and that bond becomes LP yield,
> automatically, on-chain, in the same block.

This repository is a from-scratch, senior-engineering-reviewed
implementation, not a direct transcription of the original pitch document
(`Theta-BG.md`). Several of that document's mechanism claims did not survive
contact with actual Uniswap v4 / EVM semantics and were corrected — read
`V4_ARCHITECTURE_VALIDATION.md` first if you're comparing this code against
the original pitch.

## Start here

| Doc | What's in it |
|---|---|
| [`REPOSITORY_AUDIT.md`](REPOSITORY_AUDIT.md) | Starting state, what changed, dependency versions |
| [`V4_ARCHITECTURE_VALIDATION.md`](V4_ARCHITECTURE_VALIDATION.md) | Every mechanism checked against real v4-core source — what v4 actually does, what Theta-BG needed, and what was corrected |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Contract responsibilities, data flow, why one registry / many vaults |
| [`MECHANISM.md`](MECHANISM.md) | The five-condition predicate formalized, bond economics, insurance-vault semantics |
| [`SECURITY.md`](SECURITY.md) | Threat model by actor, invariants |
| [`LIMITATIONS.md`](LIMITATIONS.md) | What this build does *not* do yet, stated explicitly |
| [`DEPLOYMENT.md`](DEPLOYMENT.md) | Live on Unichain Sepolia — verified addresses, and a real on-chain slash with transaction hashes |

## Contracts

```
src/ThetaBGHook.sol            IHooks implementation
src/SearcherRegistry.sol        Bond accounting (one instance, shared across pools)
src/LPInsuranceVault.sol        Insurance accounting (one instance per pool)
src/libraries/SandwichPredicate.sol   Pure five-condition predicate
```

## Dependencies

`lib/` is gitignored — at ~100MB of vendored Uniswap v4 / OpenZeppelin /
forge-std source it doesn't belong in the repo, and these were installed as
plain cloned directories rather than proper git submodules (some upstream
submodules inside `v4-core`/`v4-periphery` don't check out cleanly via a
straight `forge install`). After cloning this repo, restore them with:

```shell
git clone --depth 1 https://github.com/foundry-rs/forge-std.git lib/forge-std
git clone --depth 1 https://github.com/Uniswap/v4-core.git lib/v4-core
git clone --depth 1 https://github.com/Uniswap/v4-periphery.git lib/v4-periphery
git clone --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/openzeppelin-contracts
git clone --depth 1 https://github.com/transmissions11/solmate.git lib/v4-core/lib/solmate
```

(`v4-core`'s own `lib/openzeppelin-contracts` submodule comes along with its
clone; only `lib/v4-core/lib/solmate` needs the extra step above, since
`Deployers.sol`'s test helpers depend on it.)

## Build & test

```shell
forge build
forge test
```

252 tests across 8 suites — pure predicate unit + fuzz tests, registry and
vault unit + fuzz tests, a full end-to-end integration suite against a real
`PoolManager`, a dedicated false-positive checklist, an adversarial suite,
and two Foundry invariant suites (128,000 randomized calls each). See
`LIMITATIONS.md` §"Testing" for the exact breakdown, including two verified
findings the adversarial suite surfaced.

```shell
forge test -vv                                    # verbose
forge test --match-path "test/ThetaBGHook.t.sol"  # integration only
forge test --match-path "test/invariant/*"        # invariant suites only
```

## Status

Contracts and tests are real and passing against actual `v4-core` /
`v4-periphery` / OpenZeppelin dependencies (see `remappings.txt`). **Live on
Unichain Sepolia** — see `DEPLOYMENT.md` for verified contract addresses and
a real, on-chain sandwich detection + slash at production thresholds
(transaction hashes included). A live read-and-write console is built in
`web/` (Vite + React + wagmi/viem + RainbowKit) — it reads all state from
chain and drives the searcher bond lifecycle and LP insurance claims from a
connected wallet. See `web/README.md`, and `LIMITATIONS.md` for what's
deliberately deferred.
