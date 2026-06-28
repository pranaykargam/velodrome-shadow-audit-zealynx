
***

### Issue 1 — Permissionless claimFees()
`Severity`: 🔴High

`What`: Anybody can call claimFees(), which claims pair fees and forwards them to the bribe contract.

`Impact`: Repeated or malicious calls can grief fee flows, cause unexpected bribe interactions or timing issues.

Suggested quick fix:
- Restrict calls: require(msg.sender == voter || msg.sender == IGaugeFactory(factory).team());
- Or make claimFees() internal and call only from authorized flows.
Code hint:
- change function signature to: function claimFees() external lock { require(msg.sender == voter); ... }

***

### Issue 2 — 🟡 setVoteStatus only updates last checkpoint
Severity: Medium
What: setVoteStatus mutates only the last checkpoint or creates a zero-balance checkpoint, losing prior balance/voted context.
Impact: earned() can miscompute rewards for earlier epochs; vote history becomes inaccurate.
Suggested quick fix:
- When creating a new checkpoint, copy previous checkpoint's balance and voted flag.
Code hint:
- if (nCheckpoints > 0) prev = checkpoints[account][nCheckpoints-1]; checkpoints[account][nCheckpoints] = Checkpoint(block.timestamp, prev.balanceOf, voted);

***

### Issue 3 — 🟡 _writeCheckpoint reads uninitialized slot
Severity: Medium
What: _writeCheckpoint reads checkpoints[account][_nCheckPoints].voted to set prevVoteStatus — that's the new slot (uninitialized).
Impact: Prior voted state lost; subsequent reward logic may treat accounts as non-voted.
Suggested quick fix:
- Read checkpoints[account][_nCheckPoints - 1].voted when _nCheckPoints > 0.
Code hint:
- bool prevVoteStatus = (_nCheckPoints > 0) ? checkpoints[account][_nCheckPoints - 1].voted : false;

***

### Issue 4 — 🟡 getReward disables reentrancy guard around external call
Severity: Medium
What: getReward sets _unlocked = 1 before calling IVoter.distribute and then sets _unlocked back, effectively disabling the lock during an external call.
Impact: Reentrancy possible during distribute(), enabling double-claims or state corruption.
Suggested quick fix:
- Never manipulate _unlocked manually. Keep a single lock scope that covers all state changes and external calls, or call external contracts only after finishing critical state updates.
Code hint:
- Remove manual _unlocked assignments; call IVoter(voter).distribute(...) before entering locked section or after finishing state updates (but still with lock held if state depends on no reentrancy).

***



### Issue 6 —🟡 withdraw() splits lock coverage
Severity: Medium
What: withdraw() calls _updateRewardForAllTokens() outside of lock, then calls locked withdrawToken — leaves a reentrancy window.
Impact: State mismatch or reentrancy during the window; possible incorrect reward or withdrawal behavior.
Suggested quick fix:
- Apply lock to withdraw(), or move _updateRewardForAllTokens() inside withdrawToken.
Code hint:
- function withdraw(uint amount) public lock { _updateRewardForAllTokens(); withdrawToken(amount, tokenId); }

***









# pair.sol

1. `PERMIT_TYPEHASH` — malformed constant (won't compile / wrong digest)

soliditybytes32 internal constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
Count the hex digits after 0x — there are 65, not 64. A bytes32 literal must be exactly 32 bytes (64 hex chars). As written this either fails to compile or (depending on toolchain leniency) gets silently truncated/misinterpreted, which would make every permit() call compute the wrong EIP-712 digest and make signatures unverifiable/forgeable in unexpected ways.

Fix — use the correct, standard hash value (note it ends in c8, not c9):
soliditybytes32 internal constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faa

***

02. `_safeTransfer — to == address(this) not excluded, and fee-on-transfer tokens break invariant accounting`
Not a crash bug, but worth flagging: _update0/_update1 assume the full amount they pass actually lands in fees contract and is reflected 1:1 in the K-check balances. If token0/token1 is a fee-on-transfer or rebasing token, _balance0/_balance1 after the transfer won't match the accounting, and the K check in swap() can pass on a state that under-collateralizes LPs. This is a known footgun for Uniswap-V2-style pairs — worth a comment/guard if you intend to support arbitrary ERC20s, or an explicit allowlist if not.
***


# router.sol


01. ## 🟡 `Pair invariant accounting breaks for fee-on-transfer / rebasing tokens`

## Severity-  (low)


## Affected files

- `contracts/contracts/Pair.sol` 
- `contracts/contracts/Rouetr.sol`

## Affected functions

- `_safeTransfer(...)` in `Pair.sol`.  
- `_update(...)` / reserve update logic in `Pair.sol`.  
- `swap(...)` in `Pair.sol`.

## Description

The pair logic assumes that a token transfer of `amount` always credits exactly `amount` to the recipient. With fee-on-transfer tokens, the received amount is smaller than expected, so the pair’s balance and reserve accounting diverge. Rebasing tokens can also change balances outside of swaps, which breaks the same assumptions. 

## Vulnerable scenario

1. A user creates a pool with a fee-on-transfer or rebasing token.  
2. The pair records reserves as if transfers are exact.  
3. A swap or liquidity action happens, but the actual credited balance differs from the amount used in the math.  
4. The pair’s invariant checks and reserve updates operate on misleading values, so LP accounting becomes incorrect. 


## Impact
- LPs can end up with incorrect reserve accounting.  
- Price quotes can become misleading.  
- Liquidity may be under-collateralized relative to the pair’s internal accounting.  
- Users may waste gas by interacting with unsupported token types. 

## Recommendation

- Explicitly **disallow** fee-on-transfer and rebasing tokens in the factory/router.  
- Add a clear comment or revert guard if unsupported token types are detected.  
- If support is desired, implement special handling based on actual balance deltas instead of assumed transfer amounts.  
- Add tests for fee-on-transfer and rebasing token behavior so the limitation is enforced intentionally.[7][3][4]

***

02. ## 🟡 `WETH transfer uses assert() instead of require()`

## Severity
`Low`

## Affected files
`contracts/contracts/Router.sol` 

## Affected functions
`addLiquidityETH()`, any ETH-wrapping / multi-hop path that calls `weth.transfer(...)`

## Description
`assert(weth.transfer(...))` is used for an external call result. If the transfer fails, it reverts with a Panic instead of a clear error message. 

## Vulnerable scenario
A future or nonstandard WETH implementation returns `false`, or an edge case causes the transfer to fail, and the router reverts with an unhelpful panic. 

## Impact
Harder debugging, worse tooling behavior, and misleading revert semantics.

## Recommendation
Replace `assert` with:

```solidity
require(weth.transfer(pair, amountETH), "Router: WETH_TRANSFER_FAILED");
```
***



03. ## 🟡`No per-hop slippage check in multi-hop swap`

## Affected files
`contracts/contracts/Router.sol` 

## Affected functions
`getAmountsOut()`, `_swap()`, multi-hop swap entrypoints 

## Description
The router checks only the final output amount, not each hop. If an intermediate pair moves before execution, the route can still fail late or execute at a worse price.

## Vulnerable scenario
A multi-hop swap is quoted, then reserves on one hop change before execution. The router still uses the old amounts and only the final leg is protected.

## Impact
Misleading reverts, wasted gas, and weaker price protection for intermediate hops.

## Recommendation
Add a pair-existence check inside `getAmountsOut()`, or add per-hop minimums / re-quote at execution if stricter protection is needed.


***

04. ## 🟡 `No per-hop slippage check in multi-hop swap`

## Affected files
`contracts/contracts/Router.sol` 

## Affected functions
`getAmountsOut()`, `_swap()`, multi-hop swap entrypoints 

## Description
The router only checks the final output amount, not each hop. If an intermediate pool changes before execution, the route can still go through with a worse price. 

## Vulnerable scenario
A user quotes a multi-hop swap, then one intermediate pool moves before execution. The router still uses the old amounts. 

## Impact
Worse execution price, misleading revert, and extra gas wasted. 

## Recommendation
Add a pair-existence check in `getAmountsOut()`, or use per-hop minimums / re-quote at execution. 




Yes — here is the **short** Zealynx-style version for that finding. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Title
`Division by zero in stable-swap solver for empty pools`

## Severity
`Medium`

## Affected files
`contracts/contracts/VelodromeLibrary.sol`, and any caller that uses the stable quote path. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Affected functions
`_get_y(...)`, and the public quote helpers that reach it through stable-swap math. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Description
`_get_y()` divides by `_d(x0, y)`, and that denominator becomes zero when the pool is empty or fully imbalanced. In that case the quote reverts instead of returning a safe result. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Vulnerable scenario
A user queries a stable pair with zero reserves or near-zero reserves, the solver hits division by zero, and the quote fails. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Impact
Broken quotes, failed integrations, and poor availability for thin or empty pools. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Recommendation
Add a zero-reserve guard before entering the Newton solver, and revert with a clear error instead of relying on a division-by-zero panic. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Notes
- `getMinimumValue` has unused destructured values, but that is just dead code, not a bug.  
- The `// TODO make modifiable?` comment suggests unfinished design intent, but it is not exploitable by itself. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)


Here’s a short, Zealynx‑style version. [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Title
`Incorrect output due to extra normalization division in quoting functions`

## Severity
`Medium`

## Affected files
`contracts/contracts/VelodromeLibrary.sol` (or wherever these functions are defined) [academy.zealynx](https://academy.zealynx.io/shadow-arena/velodrome/audit)

## Affected functions
`getAmountOut(...)`  
`getTradeDiff(...)` (both overloads)  
`getSample(...)`

## Description
These functions call `_getAmountOut` (which already returns the correct token‑out amount) and then divide again by `amountIn` or `sample` with `* 1e18 / amountIn` (or `/ sample`). This converts the result into a price ratio instead of an amount, so callers expecting “amount of tokens out” receive a wrong value. It also introduces implicit division‑by‑zero panics when `amountIn` or `sample` is zero. 

## Impact
- Off‑chain integrators or contracts using these helpers may size swaps or set slippage based on incorrect outputs.  
- This can remove effective slippage protection or misprice positions/collateral.  
- Zero‑input or thin/imbalanced pools can trigger division‑by‑zero panics, hurting composability.

## Recommendation
Return `_getAmountOut(...)` directly and remove the extra `* 1e18 / amountIn` / `/ sample` normalization from all four functions. If a price ratio is needed, expose it in a separate, clearly named helper that explicitly handles zero denominators.