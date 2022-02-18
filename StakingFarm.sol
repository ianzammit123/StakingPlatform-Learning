// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakingFarm is Ownable{

    // Events
    event fundsStaked(address indexed _token, uint256 indexed _amount);
    event fundsUnstaked(address indexed _token);
    event stakingPaused(bool indexed _status, uint256 indexed _datetime);
    event stakingResumed(bool indexed _status, uint256 indexed _datetime);
    event unstakingPaused(bool indexed _status, uint256 indexed _datetime);
    event unstakingResumed(bool indexed _status, uint256 indexed _datetime);
    event flexyFeeUpdated(uint indexed _percetage);
    event rewardsClaimed(bool indexed _claimed, uint256 indexed _amount);

    // ENUMS
    enum STAKING_STATE { OPEN, CLOSED}
    enum UNSTAKE_STATE { OPEN, CLOSED}

    STAKING_STATE public staking_state;
    UNSTAKE_STATE public unstake_state;

    // Mappings
    /*
        Keep track of how many tokens and the balance for each unqiue token staked
        @address = token address
        @address = wallet address
    */
    mapping(address => mapping(address => uint256)) public stakingBalance;

    // Keep track of how many unique tokens the user is staking
    // @address = wallet address
    mapping(address => uint256) public uniqueTokensStaked;

    /*
        Keep track of total rewards claimed for each token allowed
        @address = token address
        @address = wallet address
    */
    mapping(address => mapping(address => uint256)) public totalClaimed;

     /*
        Keep a track of when the user can unstake
        @address = token address
        @address = wallet address
    */
    mapping(address => mapping(address => uint256)) public unstakeDate;

    /*
        Keep track of when the rewards start
        @address = token address
        @address = wallet address
    */
    mapping(address => mapping(address => uint256)) public rewardsStartDate;

    /*
        Is the user subject to a withdraw fee
        @address = token address
        @address = wallet address
    */
    mapping(address => mapping(address => bool)) public subjectToFee;
    mapping(address => uint256) public userStakingPeriod;

    address[] public stakers;
    address public poolTokenAddress;
    address private _owner;
    uint256 public totalStaked;
    address[] public allowedTokens;
    uint public flexibleStakingFee;

    uint public rewardsPerAmount;
    uint public poolTokenRewardRateFlexy;
    uint public poolTokenRewardRateMedium;
    uint public poolTokenRewardRateLong;

    uint256 public blockTime;

    // We will need access to the Pool token to send as rewards, stake and withdraw
    IERC20 internal poolToken;

    constructor(address _poolToken) public{
        _owner = msg.sender;
        poolToken = IERC20(_poolToken);
        poolTokenAddress = _poolToken;

        // Set the fee for flexible staking
        flexibleStakingFee = 2; // 2% fee
        poolTokenRewardRateFlexy = 25; // flexi
        poolTokenRewardRateMedium = 100; // 7-14
        poolTokenRewardRateLong = 200; // 21-35

        // This will be used in the calculation for rewards
        // e.g. User has 1000 tokens, if rewardsPerAmount == 100 we would divide TOKENS/rewardsPerAmount
        rewardsPerAmount = 100;

        // keep track of what we have staked in the contract!
        totalStaked = 0;

        // Open staking and withdraws
        staking_state = STAKING_STATE.OPEN;
        unstake_state = UNSTAKE_STATE.OPEN;

        // We only want to allow certain tokens to be staked in our platform
        allowedTokens.push(_poolToken);
    }

    /*
        // This is an admin util for updating the users staked balance
        @token = the token you want to update the balance for
        @user - the wallet address for the update
        @amount - the amount the new balance needs to be
    */
    function updateStakersBalance(address _token, address _user, uint256 _amount) public onlyOwner{
        stakingBalance[_token][_user] = _amount;
    }

    /*
        // This is an admin util for updating the unstake timestamp
        @token = the token you want to update the balance for
        @user - the wallet address for the update
        @_unlockdate - the new timestamp, this will be current day - num_of_days
        @_ignoreRequire - set to true when testing
    */
    function updateUnstakeDate(address _token, address _user, uint256 _unlockdate, bool _ignoreRequire) public onlyOwner{
        if(_ignoreRequire == false){
            require(_unlockdate >= block.timestamp);
        }
        unstakeDate[_token][_user] = _unlockdate;
    }

     /*
        // This is an admin util for updating the rewards starting timestamp
        @_date - the new timestamp for the rewards to start, e.g. today - 1 days
        @_token - the token this change needs to be applied for
        @user - the wallet address for the update
        @_ignoreRequire - set to true when testing
    */
    function updateRewardsStartDate(uint256 _date, address _token, address _user, bool _ignoreRequire) public onlyOwner{
        if(_ignoreRequire == false){
            require(_date >= block.timestamp);
        }
        rewardsStartDate[_token][_user] = _date;
    }

    function updateRewardPerAmount(uint _rewardPerAmount) public onlyOwner{
        require(_rewardPerAmount > 0, "The number can not be 0");
        rewardsPerAmount = _rewardPerAmount;
    }

    function updateFlexibleFee(uint _percentage) public onlyOwner{
        flexibleStakingFee = _percentage;
        emit flexyFeeUpdated(_percentage);
    }

    function pauseStaking() public onlyOwner{
        staking_state = STAKING_STATE.CLOSED;
        emit stakingPaused(true,block.timestamp);
    }

    function resumeStaking() public onlyOwner{
        staking_state = STAKING_STATE.OPEN;
        emit stakingResumed(true, block.timestamp);
    }

    function pauseUnstaking() public onlyOwner{
        unstake_state = UNSTAKE_STATE.CLOSED;
        emit unstakingPaused(true,block.timestamp);
    }

    function resumeUnstaking() public onlyOwner{
        unstake_state = UNSTAKE_STATE.OPEN;
        emit unstakingResumed(true, block.timestamp);
    }

    function addAllowedTokens(address _token) public onlyOwner {
        allowedTokens.push(_token);
    }

    function tokenIsAllowed(address _token) internal returns (bool) {
        for( uint256 allowedTokensIndex=0; allowedTokensIndex < allowedTokens.length; allowedTokensIndex++){
            if(allowedTokens[allowedTokensIndex] == _token){
                return true;
            }
        }
        return false;
    }

    function stakeFunds(uint256 _amount, address _token, uint256 _staking_period) public
    {
        require(staking_state == STAKING_STATE.OPEN, "Staking is currently disabled.");
        require(_amount > 0, "Amount staked must be more than 0");
        require(tokenIsAllowed(_token) == true, "You cant stake this token!");
        require(IERC20(_token).transferFrom(msg.sender, address(this), _amount) == true, "Failed to transfer funds!");

        updateUniqueTokensStaked(msg.sender, _token);
        stakingBalance[_token][msg.sender] = stakingBalance[_token][msg.sender] + _amount;

        // Set subjectToFee && rewardsStartDate for time periods > 7, 0-7 period will over write these values
        subjectToFee[_token][msg.sender] = false;
        rewardsStartDate[_token][msg.sender] = block.timestamp;

        if (uniqueTokensStaked[msg.sender] == 1){
            stakers.push(msg.sender);
        }

        // Set when the user can claim their tokens
        if(_staking_period == 0){
            unstakeDate[_token][msg.sender] = block.timestamp;
            subjectToFee[_token][msg.sender] = true;
            userStakingPeriod[msg.sender] = 0;
            rewardsStartDate[_token][msg.sender] = block.timestamp + 1 days;
        }

        if(_staking_period == 7){
            unstakeDate[_token][msg.sender] = block.timestamp + 7 days;
            userStakingPeriod[msg.sender] = 7;
        }

        if(_staking_period == 14){
            unstakeDate[_token][msg.sender] = block.timestamp + 14 days;
            userStakingPeriod[msg.sender] = 14;
        }

        if(_staking_period == 21){
            unstakeDate[_token][msg.sender] = block.timestamp + 21 days;
            userStakingPeriod[msg.sender] = 21;
        }

        if(_staking_period == 28){
            unstakeDate[_token][msg.sender] = block.timestamp + 28 days;
            userStakingPeriod[msg.sender] = 28;
        }

        if(_staking_period == 35){
            unstakeDate[_token][msg.sender] = block.timestamp + 35 days;
            userStakingPeriod[msg.sender] = 35;
        }

        // Update the total staked
        totalStaked = totalStaked + _amount;
        emit fundsStaked(_token, _amount);
    }

    function updateUniqueTokensStaked(address _user, address _token) internal {
        if (stakingBalance[_token][_user] <= 0){
            uniqueTokensStaked[_user] = uniqueTokensStaked[_user] + 1;
        }
    }

    function unStake(address _token) public{
        require(unstake_state == UNSTAKE_STATE.OPEN, "Unstaking is currently disabled.");
        require(block.timestamp >= unstakeDate[_token][msg.sender], "You cant unstake yet!");

        // How much of this token does the user hold
        uint256 current_balance = stakingBalance[_token][msg.sender];
        require(current_balance > 0, "You don't have assets staked");

        IERC20(_token).transfer(msg.sender, current_balance);
        stakingBalance[_token][msg.sender] = 0 ;
        uniqueTokensStaked[msg.sender] = uniqueTokensStaked[msg.sender] - 1;

        // Decrease the total amount staked
        totalStaked = totalStaked - current_balance;

        // set subject to fee false
        subjectToFee[_token][msg.sender] = false;

        // The tokens would have been withdrawn at this stage meaning the balance would be 0, we need to send the token balance to the claim function
        // Only run the claim function if the user is able to claim
        if(block.timestamp >= rewardsStartDate[_token][msg.sender]) {
            claimRewards(_token, current_balance, true, msg.sender);
        }

        /* Reset vars so they cant try and claim again */
        unstakeDate[_token][msg.sender] = block.timestamp + 1000 days;
        rewardsStartDate[_token][msg.sender] = block.timestamp + 1000 days;
        userStakingPeriod[msg.sender] = 1000;

        emit fundsUnstaked(_token);
    }

    function claimRewards(address _token, uint256 _current_balance, bool _useSentBalance, address _user) public{
        // Has the claim time period past
        require(block.timestamp >= unstakeDate[_token][_user] , "You cant unstake yet!");
        uint256 staking_period = userStakingPeriod[_user];
        require(block.timestamp >= rewardsStartDate[_token][_user], "You are not eligible for rewards yet, tokens must be held for at least 24hrs to enable rewards.");

        if(_useSentBalance == false){
            // We get the balance from stakeBalance mappping
            _current_balance = stakingBalance[_token][_user];
        }

        // Calculate how many days have past since the rewards starts date, we -  1 day from the rewardsStartDate because in the stake function
        // we added + 1 day for to the rewards for flexi type to stop people getting rewards straight away
        // This ony applied to flex
        uint256 stakingStarted;
        blockTime = block.timestamp;

        if(staking_period == 0){
            stakingStarted = rewardsStartDate[_token][_user] - 1 days;
        }else{
            stakingStarted = rewardsStartDate[_token][_user];
        }

        uint256 days_staked = (blockTime - stakingStarted) / 60 / 60 / 24;

        // ( 1000 / 100 ) * 500 * 1 = 5,000 tokens per day!
        // ( Tokens / rewards_condition ) * REWARD RATE * DAYS
        uint256 reward_rate = 0;

        if(staking_period == 0 || staking_period <= 7){
            reward_rate = poolTokenRewardRateFlexy;
        }

        if(staking_period > 7 && staking_period <= 21){
            reward_rate = poolTokenRewardRateMedium;
        }

        if(staking_period > 21){
            reward_rate = poolTokenRewardRateLong;
        }

        uint256 user_rewards = (_current_balance / rewardsPerAmount ) * reward_rate;
        user_rewards = user_rewards * days_staked;

        if(subjectToFee[_token][_user]){
            // get the current fee and minus the fee % from the total tokens owned
            uint256 decrease_amount = (user_rewards * flexibleStakingFee) / 100;
            uint256 user_rewards_with_fee = (user_rewards - decrease_amount);

            if(user_rewards_with_fee > 0){
                IERC20(poolTokenAddress).transfer(_user, user_rewards_with_fee);
                totalClaimed[_token][_user] = totalClaimed[_token][_user] + user_rewards_with_fee;
                emit rewardsClaimed(true, user_rewards_with_fee);
            }
        }else{
             // Send the user their rewards
            if(user_rewards > 0){
                IERC20(poolTokenAddress).transfer(_user, user_rewards);
                totalClaimed[_token][_user] = totalClaimed[_token][_user] + user_rewards;
                emit rewardsClaimed(true, user_rewards);
            }
        }

        /*
            If the request has come from the unStake function then we dont need to + 1 day
            If the user is just requested their claim and not unstaking then once claimed we need to - 1 day on the rewards
            This means they have to wait 24hrs to start rewards again
        */
        if(_useSentBalance == false){
          rewardsStartDate[_token][_user] = block.timestamp + 1 days;
        }
    }
}