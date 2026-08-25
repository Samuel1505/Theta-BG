# Repository Audit — Phase 0

Date: 2026-08-25

## Starting state

Prior to this build, the repository contained a single file: `Theta-BG.md`, a
project brief / pitch document for a UHI10 hookathon submission. No Foundry
project, no Solidity sources, no tests, no deployment scripts, no frontend
existed. `git log` shows one prior commit ("added project brief").

This is a **greenfield build**. There is no existing architecture to
reconcile with, no legacy contracts to preserve, and no prior test suite to
extend. Every contract, script, and test described in this document set is
new.

## What was scaffolded in this pass

```
foundry.toml
lib/forge-std          (Foundry testing library)
lib/v4-core             (Uniswap v4 core — installed for direct source inspection)
lib/v4-periphery        (Uniswap v4 periphery — hook utilities, StateLibrary consumers)
lib/openzeppelin-contracts (ERC4626, ERC20, SafeERC20, ReentrancyGuard primitives)
src/
test/
script/
```

`forge init` seeded a default `Counter.sol` template — this was deleted since
it is unrelated to Theta-BG and the instructions are explicit about not
preserving irrelevant scaffolding.

## Reusable components

None — there is nothing pre-existing beyond the brief itself.

## Outdated / incorrect components

The brief (`Theta-BG.md`) contains several claims that do not survive contact
with actual v4/EVM semantics. These are catalogued in detail in
`V4_ARCHITECTURE_VALIDATION.md` and `MECHANISM.md`. Summary of the most
consequential:

1. **EIP-1153 transient storage cannot hold the three-transaction sandwich
   ring buffer.** Transient storage is cleared at the end of every
   transaction (EIP-1153 spec, and confirmed in the installed
   `TransientStateLibrary`/`Lock.sol` usage in v4-core — see
   `V4_ARCHITECTURE_VALIDATION.md` §2). A classic sandwich is three separate
   transactions (front-run tx, victim tx, back-run tx) that happen to land in
   the same block. `tstore` in transaction 1 is gone before transaction 2
   begins. The ring buffer **must** live in persistent storage, keyed by
   pool + block number, with a "logical reset" (compare stored block number
   to `block.number` on read) rather than actual clearing.

2. **"Priority ordering" is not something a hook can grant.** A hook cannot
   influence block-builder transaction ordering. The bond can gate access
   (revert unbonded searcher-flagged swaps, or charge them a higher fee) but
   it cannot promise "priority lane" in the sequencing sense the brief
   implies. Wording and mechanism are corrected in `MECHANISM.md`.

3. **LP pro-rata claims cannot enumerate LPs.** v4 does not give a hook an
   enumerable LP list. The design uses a fee-growth-style
   reward-per-liquidity accumulator (the same pattern Uniswap itself uses
   for swap fee accounting), checkpointed on `afterAddLiquidity` /
   `afterRemoveLiquidity`, not the naive "iterate LPs" model implied by the
   brief.

4. **"Zero external dependencies" is inaccurate** once an ERC4626 strategy
   (Aave/Morpho) is in the loop — that is an external trust boundary and is
   documented as such in `SECURITY.md` / `LIMITATIONS.md`.

5. Several brief P&L examples (e.g. "$10,000 LP, +50% ETH move → +$150") are
   illustrative, not derived from a simulation. They are excluded from
   contracts/docs going forward per the "no unsupported claims" rule; if
   wanted for a demo they must be clearly labeled as scenario illustrations.

## Dependency versions (pinned after install)

See `V4_ARCHITECTURE_VALIDATION.md` for exact commit hashes once `forge
install` completes, recorded here for reproducibility.

## Risks carried forward

- No testnet deployment yet — deferred until the user supplies a Unichain
  Sepolia RPC URL and deployer key (deployment scripts will be written and
  left unexecuted).
- LP accounting uses a scoped simplification (pool-wide liquidity-weighted
  accumulator, not in-range-only precision) — documented as a deliberate
  scope decision in `LIMITATIONS.md`, not hidden.
- ERC4626 strategy integration is behind an adapter interface so the core
  insurance/slash accounting does not depend on Aave/Morpho specifics; the
  hackathon build ships a deterministic mock strategy for testing, with a
  real-strategy adapter to be wired at deployment time.
