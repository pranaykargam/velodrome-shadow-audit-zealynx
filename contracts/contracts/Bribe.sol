// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import './interfaces/IERC20.sol';
import './interfaces/IBribe.sol';
import './interfaces/IGauge.sol';

contract Bribe is IBribe {
  uint internal constant DURATION = 5 days; // rewards are released over the voting period
  uint internal constant BRIBE_LAG = 1 days;
  uint internal constant COOLDOWN = 12 hours;
  uint internal constant MAX_REWARD_TOKENS = 16;

  address public gauge;
  mapping(address => mapping(uint => uint)) public tokenRewardsPerEpoch;
  address[] public rewards;
  mapping(address => bool) public isReward;

  event NotifyReward(address indexed from, address indexed reward, uint epoch, uint amount);

  // simple re-entrancy check
  uint internal _unlocked = 1;
  modifier lock() {
      require(_unlocked == 1);
      _unlocked = 2;
      _;
      _unlocked = 1;
  }

// @auditbug(not found)🔴 Gauge-setup can be front-run due to missing caller check
// @auditnotes
// Missing access control: anyone can call setGauge() before the factory.
// Restrict the caller (e.g., onlyFactory) to prevent front-running during initialization.
  function setGauge(address _gauge) external {
    require(gauge == address(0), "gauge already set");
    gauge = _gauge;
  }

  function getEpochStart(uint timestamp) public view returns (uint) {
    uint bribeStart = timestamp - (timestamp % (7 days)) + BRIBE_LAG;
    uint bribeEnd = bribeStart + DURATION - COOLDOWN;
    return timestamp < bribeEnd ? bribeStart : bribeStart + 7 days;
  }

// @auditbug🔴 medium 
// @auditnotes
// notifyRewardAmount() is permissionless, so anyone can add arbitrary ERC20 tokens.
// Attackers can fill the bounded rewards[] array with junk and block legitimate reward tokens.
//
// @recommendation
// Restrict new reward tokens with access control or a whitelist, or require a meaningful minimum deposit.
  function notifyRewardAmount(address token, uint amount) external lock {
      require(amount > 0);
      if (!isReward[token]) {
        require(rewards.length < MAX_REWARD_TOKENS, "too many rewards tokens");
      }
      // bribes kick in at the start of next bribe period
      uint adjustedTstamp = getEpochStart(block.timestamp);
      uint epochRewards = tokenRewardsPerEpoch[token][adjustedTstamp];


// @auditbug🔴 medium 
// @auditbug notifyRewardAmount() records the declared `amount` before checking the actual tokens received, so fee-on-transfer tokens make `tokenRewardsPerEpoch` larger than the real balance and can permanently lock rewards.
// @recommendation Measure the balance delta and store `received = balanceAfter - balanceBefore`, or explicitly reject fee-on-transfer tokens in `notifyRewardAmount()`.
// @auditnotes Future audits should flag any token deposit flow that trusts the input `amount` instead of actual received balance, especially when the contract later distributes or withdraws those tokens.
      _safeTransferFrom(token, msg.sender, address(this), amount);
      tokenRewardsPerEpoch[token][adjustedTstamp] = epochRewards + amount;

      if (!isReward[token]) {
          isReward[token] = true;
          rewards.push(token);
          IGauge(gauge).addBribeRewardToken(token);
      }

      emit NotifyReward(msg.sender, token, adjustedTstamp, amount);
  }

  function rewardsListLength() external view returns (uint) {
      return rewards.length;
  }

  function addRewardToken(address token) external {
    require(msg.sender == gauge);
    if (!isReward[token]) {
      require(rewards.length < MAX_REWARD_TOKENS, "too many rewards tokens");
      isReward[token] = true;
      rewards.push(token);
    }
  }

  function swapOutRewardToken(uint i, address oldToken, address newToken) external {
    require(msg.sender == gauge);
    require(rewards[i] == oldToken);
    isReward[oldToken] = false;
    isReward[newToken] = true;
    rewards[i] = newToken;
  }

// @audit 2 bugs 
  function deliverReward(address token, uint epochStart) external lock returns (uint) {
    require(msg.sender == gauge);
    uint rewardPerEpoch = tokenRewardsPerEpoch[token][epochStart];
    if (rewardPerEpoch > 0) {
      _safeTransfer(token, address(gauge), rewardPerEpoch);
    }
    return rewardPerEpoch;
  }

  function _safeTransfer(address token, address to, uint256 value) internal {
      require(token.code.length > 0);
      (bool success, bytes memory data) =
      token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
      require(success && (data.length == 0 || abi.decode(data, (bool))));
  }

  function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
      require(token.code.length > 0);
      (bool success, bytes memory data) =
      token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
      require(success && (data.length == 0 || abi.decode(data, (bool))));
  }
}
