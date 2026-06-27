

## Summary of Findings (short)
- Total issues: 10 — 0 Critical, 4 High/Medium, 6 Low  
- Main classes: permissioning, checkpoint logic, reentrancy/locking, reward accounting, token-swap invariants.  
- Quick remediation priorities: (1) Locking & reentrancy, (2) access controls on permissionless functions, (3) checkpoint correctness.

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

### Issue 5 — batchRewardPerToken is permissionless and unlocked
Severity: Medium
What: Anyone can call batchRewardPerToken which writes rewardPerTokenStored/lastUpdateTime without protection.
Impact: Gas griefing, manipulated reward checkpoints, or inconsistent state if combined with other writers.
Suggested quick fix:
- Add access control and/or apply lock modifier.
Code hint:
- function batchRewardPerToken(address token, uint maxRuns) external lock { require(msg.sender == voter); ... }

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

### Issue 7 — notifyRewardAmount is permissionless
Severity: Medium
What: Anyone can call notifyRewardAmount(token, amount) (transfers required) which changes rewardRate and timing.
Impact: Griefing by repeatedly changing reward schedules, or expensive state churn.
Suggested quick fix:
- Limit to authorized distributors: require(msg.sender == voter || msg.sender == IGaugeFactory(factory).team()).
- Add sanity limits (max amount per epoch).
Code hint:
- require(authorized[msg.sender], "not authorized");

***

### Issue 8 — swapOutRewardToken does not migrate balances
Severity: Low
What: swapOutRewardToken reassigns rewards[i] without copying per-token accounting (stored rates, user pointers).
Impact: Orphaned accounting, wrong rewards shown to users, possible reward loss/confusion.
Suggested quick fix:
- Prevent swap if token has non-zero accounting, or migrate rewardPerTokenStored/lastUpdateTime and update user mappings.
Code hint:
- require(rewardPerTokenNumCheckpoints[oldToken] == 0 && IERC20(oldToken).balanceOf(address(this)) == 0, "token in use");

***

### Issue 9 — _notifyBribeAmount skips balance checks
Severity: Low
What: _notifyBribeAmount sets rewardRate/periodFinish for bribe tokens but doesn't verify the contract holds the tokens.
Impact: rewardRate may exceed real balance/DURATION; left() can be inconsistent.
Suggested quick fix:
- Mirror notifyRewardAmount checks: require(rewardRate <= IERC20(token).balanceOf(address(this)) / DURATION).
- Set lastUpdateTime consistently to epochStart.
Code hint:
- uint balance = IERC20(token).balanceOf(address(this)); require(amount <= balance);

***

### Issue 10 — time math edge-cases in reward calculations
Severity: Low
What: reward/time math uses combinations of min/max and checkpoint timestamps that can misattribute small amounts around period boundaries.
Impact: Minor rounding/time-slice inaccuracies; tricky test cases around 7-day boundaries.
Suggested quick fix:
- Consolidate time clipping into clear helper functions and add unit tests for boundary cases.
Code hint:
- helper clipToPeriod(uint t) internal view returns (uint) { return Math.min(periodFinish[token], Math.max(startTime, t)); }

*** 

// pair.sol

1. `PERMIT_TYPEHASH` — malformed constant (won't compile / wrong digest)

soliditybytes32 internal constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
Count the hex digits after 0x — there are 65, not 64. A bytes32 literal must be exactly 32 bytes (64 hex chars). As written this either fails to compile or (depending on toolchain leniency) gets silently truncated/misinterpreted, which would make every permit() call compute the wrong EIP-712 digest and make signatures unverifiable/forgeable in unexpected ways.

Fix — use the correct, standard hash value (note it ends in c8, not c9):
soliditybytes32 internal constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faa


02. `_safeTransfer — to == address(this) not excluded, and fee-on-transfer tokens break invariant accounting`
Not a crash bug, but worth flagging: _update0/_update1 assume the full amount they pass actually lands in fees contract and is reflected 1:1 in the K-check balances. If token0/token1 is a fee-on-transfer or rebasing token, _balance0/_balance1 after the transfer won't match the accounting, and the K check in swap() can pass on a state that under-collateralizes LPs. This is a known footgun for Uniswap-V2-style pairs — worth a comment/guard if you intend to support arbitrary ERC20s, or an explicit allowlist if not.