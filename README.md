# Velodrome Finance

Velodrome is a next-generation AMM on Optimism, forked from Solidly (ve(3,3) model). It combines a Uniswap V2-style constant product AMM with a vote-escrow token economics layer where veNFT holders direct emissions to liquidity pools.

## Architecture

### AMM Core (Uniswap V2 derivative)


| Contract                  | SLOC | Description                                                                                                                  |
| ------------------------- | ---- | ---------------------------------------------------------------------------------------------------------------------------- |
| Pair.sol                  | 416  | AMM pair contract. Constant product (x*y=k) for volatile pairs, stableswap curve for stable pairs. Handles mint, burn, swap. |
| PairFees.sol              | 23   | Holds trading fees for a pair. Fees are claimed by the Gauge, not LPs directly.                                              |
| Router.sol                | 370  | User-facing router with slippage protection, deadlines, multi-hop swaps, WETH wrapping.                                      |
| VelodromeLibrary.sol      | 89   | Helper functions: pair address computation, reserve sorting, swap amount calculations.                                       |
| factories/PairFactory.sol | 82   | Factory for deploying Pair contracts. Manages fees, pausing, and pair registry.                                              |


### ve(3,3) Tokenomics Layer


| Contract  | SLOC | Description                                                                                                        |
| --------- | ---- | ------------------------------------------------------------------------------------------------------------------ |
| Gauge.sol | 545  | Staking contract for LP tokens. Distributes VELO emissions to stakers. Tracks voting state for reward eligibility. |
| Bribe.sol | 85   | Holds external bribe rewards for voters. Rewards distributed per epoch based on vote weight.                       |
| Voter.sol | 304  | Central coordination: gauge creation, vote accounting, emission distribution, bribe delivery.                      |


### Out of Scope

VotingEscrow.sol, Minter.sol, RewardsDistributor.sol, Velo.sol, governance contracts, and redemption contracts are NOT part of this shadow audit.

**Total in scope: ~1,914 SLOC across 8 contracts**

## Key Concepts

**Volatile vs Stable Pairs**: Pair.sol supports two curve types. Volatile pairs use `x * y = k` (same as Uniswap V2). Stable pairs use `x^3*y + y^3*x = k` for low-slippage stablecoin swaps.

**Gauges**: LP token staking contracts. When users stake LP tokens in a Gauge, they earn VELO emissions proportional to their share.

**Bribes**: External incentives deposited by protocols to attract votes to their pool's Gauge. Distributed to voters proportionally per epoch.

**Epochs**: Weekly periods (7 days). Voting, bribe distribution, and emission allocation operate on epoch boundaries. Note: reward DURATION within each epoch is 5 days (see `DURATION` constant in Gauge.sol), not the full 7-day epoch length.

**Voter**: The coordination hub. Creates Gauges/Bribes for new pairs, aggregates votes, triggers emission distribution, and delivers bribes.

## Gauge Reward Mechanics

Gauge.sol uses a **rewardPerToken accumulator** pattern (similar to Synthetix staking). Each reward token has a `rewardRate` (tokens per second) and a cumulative `rewardPerTokenStored`. A user's earned rewards = `balance * (rewardPerTokenStored - userRewardPerTokenPaid)`. Checkpoints track each user's `balance` and `voted` status at every state change. Rewards only accrue while the user's checkpoint `voted` flag is true. The flag is set by the Voter contract via `setVoteStatus()`.

## Reward Flow

```
Protocols deposit bribes -> Bribe.notifyRewardAmount()
                                   |
Epoch ends -> Voter.distribute() -> deliverBribes() -> transfers from Bribe to Gauge
                                   |
Users claim -> Gauge.getReward()
```

Bribe.sol has no standalone claim mechanism. Rewards move from Bribe to Gauge only via the Voter.distribute() -> deliverBribes() path.

## Reading Order

Start with **Pair.sol** and **Router.sol** (familiar Uniswap V2 patterns). Then read **Voter.sol** to understand the coordination layer. Finally, deep-dive **Gauge.sol** and **Bribe.sol** for the reward mechanics.

## What to Look For

- Initialization patterns across all contracts (who can call setup functions?)
- Who can call permissionless functions and at what cost
- How rewards flow from deposit to claim across contracts
- What assumptions checkpoint updates make about previous state

## Fee Structure

- Default volatile fee: 30 basis points (0.3%)
- Default stable fee: 1 basis point (0.01%)
- Fees go to PairFees contract, claimed by the Gauge for distribution

## Running Tests

```bash
cd contracts
npm install
npx hardhat test
```

# velodrome-shadow-audit-zealynx
