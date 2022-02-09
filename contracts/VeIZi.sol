// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.4;

import "./libraries/multicall.sol";
import "./libraries/Math.sol";
import "./libraries/FixedPoints.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';

import 'hardhat/console.sol';

contract VeiZi is Ownable, Multicall, ReentrancyGuard, ERC721Enumerable {
    using SafeERC20 for IERC20;
    
    /// @dev Point of segments
    ///  for each segment, y = bias - (t - blk) * slope
    struct Point {
        int256 bias;
        int256 slope;
        // start of segment
        uint256 blk;
    }

    /// @dev locked info of nft
    struct LockedBalance {
        // amount of token locked
        int256 amount;
        // end block
        uint256 end;
    }

    int128 constant DEPOSIT_FOR_TYPE = 0;
    int128 constant CREATE_LOCK_TYPE = 1;
    int128 constant INCREASE_LOCK_AMOUNT = 2;
    int128 constant INCREASE_UNLOCK_TIME = 3;

    /// @notice emit if user successfully deposit (calling increaseAmount, createLock increaseUnlockTime)
    /// @param nftId id of nft, starts from 1
    /// @param value amount of token locked
    /// @param lockBlk end block
    /// @param depositType createLock / increaseAmount / increaseUnlockTime
    /// @param blk start block
    event Deposit(uint256 indexed nftId, uint256 value, uint256 indexed lockBlk, int128 depositType, uint256 blk);

    /// @notice emit if user successfuly withdraw
    /// @param nftId id of nft, starts from 1
    /// @param value amount of token released
    /// @param blk block number when calling withdraw(...)
    event Withdraw(uint256 indexed nftId, uint256 value, uint256 blk);

    /// @notice emit if user successfully stake an nft
    /// @param nftId id of nft, starts from 1
    /// @param owner address of user
    event Stake(uint256 indexed nftId, address indexed owner);

    /// @notice emit if user unstake a staked nft
    /// @param nftId id of nft, starts from 1
    /// @param owner address of user
    event Unstake(uint256 indexed nftId, address indexed owner);

    /// @notice emit if total amount of locked token changes
    /// @param preSupply total amount before change
    /// @param supply total amount after change
    event Supply(uint256 preSupply, uint256 supply);

    /// @notice number of block in a week (estimated)
    uint256 public WEEK;
    /// @notice number of block during 4 years
    uint256 public MAXTIME;
    uint256 public secondsPerBlockX64;

    /// @notice erc-20 token to lock
    address public token;
    /// @notice total amount of locked token
    uint256 public supply;

    /// @notice num of nft generated
    uint256 public nftNum = 0;

    /// @notice locked info of each nft
    mapping(uint256 => LockedBalance) public nftLocked;

    uint256 public epoch;
    /// @notice weight-curve of total-weight of all nft
    mapping(uint256 => Point) public pointHistory;
    mapping(uint256 => int256) public slopeChanges;

    /// @notice weight-curve of each nft
    mapping(uint256 => mapping(uint256 => Point)) public nftPointHistory;
    mapping(uint256 => uint256) public nftPointEpoch;

    /// @notice total num of nft staked
    uint256 public stakeNum = 0; // +1 every calling stake(...)
    /// @notice total amount of staked iZi
    uint256 public stakeiZiAmount = 0;

    struct StakingStatus {
        uint256 stakingId;
        uint256 lockAmount;
        uint256 lastTouchBlock;
        uint256 lastTouchAccRewardPerShare;
    }
    
    /// @notice nftId to staking status
    mapping(uint256 => StakingStatus) public stakingStatus;
    /// @notice owner address of staked nft
    mapping(uint256 => address) public stakedNftOwners;
    /// @notice nftid the user staked, 0 for no staked. each user can stake atmost 1 nft
    mapping(address => uint256) public stakedNft;


    struct RewardInfo {
        /// @dev who provides reward
        address provider;
        /// @dev Accumulated Reward Tokens per share, times Q128.
        uint256 accRewardPerShare;
        /// @dev Reward amount for each block.
        uint256 rewardPerBlock;
        /// @dev Last block number that the accRewardRerShare is touched.
        uint256 lastTouchBlock;

        /// @dev The block number when NFT mining rewards starts/ends.
        uint256 startBlock;
        /// @dev The block number when NFT mining rewards starts/ends.
        uint256 endBlock;
    }

    /// @dev reward infos
    RewardInfo public rewardInfo;

    modifier checkAuth(uint256 nftId, bool allowStaked) {
        bool auth = _isApprovedOrOwner(msg.sender, nftId);
        if (allowStaked) {
            auth = auth || (stakedNft[msg.sender] == nftId);
        }
        require(auth, "Not Owner or Not exist!");
        _;
    }

    /// @notice constructor
    /// @param tokenAddr address of locked token
    /// @param _secondsPerBlockX64 seconds between two adj blocks, in 64-bit fix point format
    constructor(address tokenAddr, uint256 _secondsPerBlockX64, RewardInfo memory _rewardInfo) ERC721("VeiZi", "VeiZi") {
        token = tokenAddr;
        pointHistory[0].blk = block.number;

        WEEK = 7 * 24 * 3600 * (1<<64) / _secondsPerBlockX64;
        MAXTIME = (4 * 365 + 1) * 24 * 3600 * (1<<64)/ _secondsPerBlockX64;
        secondsPerBlockX64 = _secondsPerBlockX64;

        rewardInfo = _rewardInfo;
        rewardInfo.accRewardPerShare = 0;
        rewardInfo.lastTouchBlock = _rewardInfo.startBlock;
    }

    /// @notice get slope of last segment of weight-curve of an nft
    /// @param nftId id of nft, starts from 1
    function getLastNftSlope(uint256 nftId) external view returns(int256) {
        uint256 uepoch = nftPointEpoch[nftId];
        return nftPointHistory[nftId][uepoch].slope;
    }

    struct CheckPointState {
        int256 oldDslope;
        int256 newDslope;
        uint256 _epoch;
    }

    function _checkPoint(uint256 nftId, LockedBalance memory oldLocked, LockedBalance memory newLocked) internal {

        Point memory uOld;
        Point memory uNew;
        CheckPointState memory cpState;
        cpState.oldDslope = 0;
        cpState.newDslope = 0;
        cpState._epoch = epoch;

        if (nftId != 0) {
            if (oldLocked.end > block.number && oldLocked.amount > 0) {
                uOld.slope = oldLocked.amount / int256(MAXTIME);
                uOld.bias = uOld.slope * int256(oldLocked.end - block.number);
            }
            if (newLocked.end > block.number && newLocked.amount > 0) {
                uNew.slope = newLocked.amount / int256(MAXTIME);
                uNew.bias = uNew.slope * int256(newLocked.end - block.number);
            }
            cpState.oldDslope = slopeChanges[oldLocked.end];
            if (newLocked.end != 0) {
                if (newLocked.end == oldLocked.end) {
                    cpState.newDslope = cpState.oldDslope;
                } else {
                    cpState.newDslope = slopeChanges[newLocked.end];
                }
            }
        }

        Point memory lastPoint = Point({bias: 0, slope: 0, blk: block.number});
        if (cpState._epoch > 0) {
            lastPoint = pointHistory[cpState._epoch];
        }
        uint256 lastCheckPoint = lastPoint.blk;

        uint256 ti = (lastCheckPoint / WEEK) * WEEK;
        for (uint24 i = 0; i < 255; i ++) {
            ti += WEEK;
            int256 dSlope = 0;
            if (ti > block.number) {
                ti = block.number;
            } else {
                dSlope = slopeChanges[ti];
            }
            // ti >= lastCheckPoint
            lastPoint.bias -= lastPoint.slope * int256(ti - lastCheckPoint);
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            lastCheckPoint = ti;
            lastPoint.blk = ti;
            cpState._epoch += 1;

            if (ti == block.number) {
                lastPoint.blk = block.number;
                break;
            } else {
                pointHistory[cpState._epoch] = lastPoint;
            }
        }

        epoch = cpState._epoch;

        if (nftId != 0) {
            lastPoint.slope += (uNew.slope - uOld.slope);
            lastPoint.bias += (uNew.bias - uOld.bias);
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }

        }

        pointHistory[cpState._epoch] = lastPoint;

        if (nftId != 0) {
            if (oldLocked.end > block.number) {
                cpState.oldDslope += uOld.slope;
                if (newLocked.end == oldLocked.end) {
                    cpState.oldDslope -= uNew.slope;
                }
                slopeChanges[oldLocked.end] = cpState.oldDslope;
            }
            if (newLocked.end > block.number) {
                if (newLocked.end > oldLocked.end) {
                    cpState.newDslope -= uNew.slope;
                    slopeChanges[newLocked.end] = cpState.newDslope;
                }
            }
            uint256 nftEpoch = nftPointEpoch[nftId] + 1;
            uNew.blk = block.number;
            nftPointHistory[nftId][nftEpoch] = uNew;
            nftPointEpoch[nftId] = nftEpoch;
        }
        
    }

    function _depositFor(uint256 nftId, uint256 _value, uint256 unlockBlock, LockedBalance memory lockedBalance, int128 depositType) internal {
        
        LockedBalance memory _locked = lockedBalance;
        uint256 supplyBefore = supply;

        supply = supplyBefore + _value;

        LockedBalance memory oldLocked = LockedBalance({amount: _locked.amount, end: _locked.end});

        _locked.amount += int256(_value);

        if (unlockBlock != 0) {
            _locked.end = unlockBlock;
        }
        _checkPoint(nftId, oldLocked, _locked);
        nftLocked[nftId] = _locked;
        if (_value != 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), _value);
        }
        emit Deposit(nftId, _value, _locked.end, depositType, block.number);
        emit Supply(supplyBefore, supplyBefore + _value);
    }

    /// @notice push check point of two global curves to current block
    function checkPoint() external {
        _checkPoint(0, LockedBalance({amount: 0, end: 0}), LockedBalance({amount: 0, end: 0}));
    }

    /// @notice create a new lock and generate a new nft
    /// @param _value amount of token to lock
    /// @param _unlockTime future block number to unlock
    /// @return nftId id of generated nft, starts from 1
    function createLock(uint256 _value, uint256 _unlockTime) external nonReentrant returns(uint256 nftId) {
        uint256 unlockTime = (_unlockTime / WEEK) * WEEK;
        nftNum ++;
        nftId = nftNum; // id starts from 1
        _mint(msg.sender, nftId);
        LockedBalance memory _locked = nftLocked[nftId];
        require(_value > 0, "amount should >0");
        require(_locked.amount == 0, "Withdraw old tokens first");
        require(unlockTime > block.number, "Can only lock until time in the future");
        require(unlockTime <= block.number + MAXTIME, "Voting lock can be 4 years max");
        _depositFor(nftId, _value, unlockTime, _locked, CREATE_LOCK_TYPE);
    }

    /// @notice increase amount of locked token in an nft
    /// @param nftId id of nft, starts from 1
    /// @param _value increase amount
    function increaseAmount(uint256 nftId, uint256 _value) external nonReentrant {
        LockedBalance memory _locked = nftLocked[nftId];
        require(_value > 0, "amount should >0");
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.number, "Can only lock until time in the future");
        _depositFor(nftId, _value, 0, _locked, INCREASE_LOCK_AMOUNT);
        if (stakingStatus[nftId].stakingId != 0) {
            // this nft is staking
            stakeiZiAmount += _value;
            address stakingOwner = stakedNftOwners[nftId];
            _collectReward(nftId, stakingOwner);
        }
    }

    /// @notice increase unlock time of an nft
    /// @param nftId id of nft
    /// @param _unlockTime future block number to unlock
    function increaseUnlockTime(uint256 nftId, uint256 _unlockTime) external checkAuth(nftId, true) nonReentrant {
        LockedBalance memory _locked = nftLocked[nftId];
        uint256 unlockTime = (_unlockTime / WEEK) * WEEK;

        require(_locked.end > block.number, "Lock expired");
        require(_locked.amount > 0, "Nothing is locked");
        require(unlockTime > _locked.end, "Can only lock until time in the future");
        require(unlockTime <= block.number + MAXTIME, "Voting lock can be 4 years max");

        _depositFor(nftId, 0, unlockTime, _locked, INCREASE_UNLOCK_TIME);
    }

    /// @notice withdraw an unstaked-nft
    /// @param nftId id of nft
    function withdraw(uint256 nftId) external checkAuth(nftId, false) nonReentrant {
        LockedBalance memory _locked = nftLocked[nftId];
        require(block.number >= _locked.end, "The lock didn't expire");
        uint256 value = uint256(_locked.amount);

        LockedBalance memory oldLocked = LockedBalance({amount: _locked.amount, end: _locked.end});
        _locked.end = 0;
        _locked.amount  = 0;
        nftLocked[nftId] = _locked;
        uint256 supplyBefore = supply;
        supply = supplyBefore - value;

        _checkPoint(nftId, oldLocked, _locked);
        IERC20(token).safeTransfer(msg.sender, value);
        _burn(nftId);

        emit Withdraw(nftId, value, block.number);
        emit Supply(supplyBefore, supplyBefore - value);
    }

    /// @notice merge nftFrom to nftTo
    /// @param nftFrom nft id of nftFrom
    /// @param nftTo nft id of nftTo
    function merge(uint256 nftFrom, uint256 nftTo) external nonReentrant {
        require(_isApprovedOrOwner(msg.sender, nftFrom), "Not Owner of nftFrom");
        require(_isApprovedOrOwner(msg.sender, nftTo), "Not Owner of nftTo");
        require(stakingStatus[nftFrom].stakingId == 0, "nftFrom is staked");
        require(stakingStatus[nftTo].stakingId == 0, "nftTo is staked");
        require(nftFrom != nftTo, 'same nft!');

        LockedBalance memory lockedFrom = nftLocked[nftFrom];
        LockedBalance memory lockedTo = nftLocked[nftTo];
        require(lockedTo.end >= lockedFrom.end, "endblock of nftFrom cannot later than nftTo");

        // cancel lockedFrom in the weight-curve
        _checkPoint(nftFrom, lockedFrom, LockedBalance({amount: 0, end: lockedFrom.end}));
        LockedBalance memory newLockedTo = LockedBalance({amount: lockedTo.amount, end: lockedFrom.end});
        newLockedTo.amount += lockedFrom.amount;

        // add locked iZi of nftFrom to nftTo
        _checkPoint(nftTo, lockedTo, newLockedTo);
        nftLocked[nftFrom].amount = 0;
        _burn(nftFrom);
    }

    function _findBlockEpoch(uint256 _block, uint256 maxEpoch) internal view returns(uint256) {
        uint256 _min = 0;
        uint256 _max = maxEpoch;
        for (uint24 i = 0; i < 128; i ++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (pointHistory[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    /// @notice weight of nft at certain time after latest update of fhat nft
    /// @param nftId id of nft
    /// @param blockNumber specified blockNumber after latest update of this nft (amount change or end change)
    /// @return weight
    function nftVeiZi(uint256 nftId, uint256 blockNumber) public view returns(uint256) {
        uint256 _epoch = nftPointEpoch[nftId];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory lastPoint = nftPointHistory[nftId][_epoch];
            require(blockNumber >= lastPoint.blk, "Too early");
            lastPoint.bias -= lastPoint.slope * int256(blockNumber - lastPoint.blk);
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            return uint256(lastPoint.bias);
        }
    }
    

    /// notice weight of nft at certain time before latest update of fhat nft
    /// @param nftId id of nft
    /// @param _block specified blockNumber before latest update of this nft (amount change or end change)
    /// @return weight
    function nftVeiZiAt(uint256 nftId, uint256 _block) public view returns(uint256) {
        require(_block <= block.number, "Block Too Late");

        uint256 _min = 0;
        uint256 _max = nftPointEpoch[nftId];

        for (uint24 i = 0; i < 128; i ++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (nftPointHistory[nftId][_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        Point memory uPoint = nftPointHistory[nftId][_min];
        uPoint.bias -= uPoint.slope * (int256(_block) - int256(uPoint.blk));
        if (uPoint.bias < 0) {
            uPoint.bias = 0;
        }
        return uint256(uPoint.bias);
    }

    function _totalVeiZiAt(Point memory point, uint256 blk) internal view returns(uint256) {
        Point memory lastPoint = point;
        uint256 ti = (lastPoint.blk / WEEK) * WEEK;
        for (uint24 i = 0; i < 255; i ++) {
            ti += WEEK;
            int256 dSlope = 0;
            if (ti > blk) {
                ti = blk;
            } else {
                dSlope = slopeChanges[ti];
            }
            lastPoint.bias -= lastPoint.slope * int256(ti - lastPoint.blk);
            if (ti == blk) {
                break;
            }
            lastPoint.slope += dSlope;
            lastPoint.blk = ti;
        }
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(lastPoint.bias);
    }

    /// @notice total weight of all nft at a certain time after check-point of all-nft-collection's curve
    /// @param blk specified blockNumber, "certain time" in above line
    /// @return total weight
    function totalVeiZi(uint256 blk) external view returns(uint256) {
        uint256 _epoch = epoch;
        Point memory lastPoint = pointHistory[_epoch];
        require(blk >= lastPoint.blk, "Too Early");
        return _totalVeiZiAt(lastPoint, blk);
    }

    /// @notice total weight of all nft at a certain time before check-point of all-nft-collection's curve
    /// @param blk specified blockNumber, "certain time" in above line
    /// @return total weight
    function totalVeiZiAt(uint256 blk) external view returns(uint256) {
        require(blk <= block.number, "Block Too Late");
        uint256 _epoch = epoch;
        uint256 targetEpoch = _findBlockEpoch(blk, _epoch);

        Point memory point = pointHistory[targetEpoch];
        return _totalVeiZiAt(point, blk);
    }

    function _updateStakingStatus(uint256 tokenId) internal {
        StakingStatus storage t = stakingStatus[tokenId];
        t.lastTouchBlock = rewardInfo.lastTouchBlock;
        t.lastTouchAccRewardPerShare = rewardInfo.accRewardPerShare;
    }

    /// @notice Collect pending reward for a single veizi-nft. 
    /// @param tokenId The related position id.
    /// @param recipient who acquires reward
    function _collectReward(uint256 tokenId, address recipient) internal {
        StakingStatus memory t = stakingStatus[tokenId];
        
        _updateGlobalStatus();
        uint256 reward = (t.lockAmount * (rewardInfo.accRewardPerShare - t.lastTouchAccRewardPerShare)) / FixedPoints.Q128;
        if (reward > 0) {
            IERC20(token).safeTransferFrom(
                rewardInfo.provider,
                recipient,
                reward
            );
        }
        _updateStakingStatus(tokenId);
    }

    /// @notice stake an nft
    /// @param nftId id of nft
    function stake(uint256 nftId) external nonReentrant {
        require(nftLocked[nftId].end > block.number, "Lock expired");
        // nftId starts from 1, zero or not owner(including staked) cannot be transfered
        safeTransferFrom(msg.sender, address(this), nftId);
        require(stakedNft[msg.sender] == 0, "Has Staked!");

        _updateGlobalStatus();

        stakedNft[msg.sender] = nftId;
        stakedNftOwners[nftId] = msg.sender;

        stakeNum += 1;
        uint256 lockAmount = uint256(nftLocked[nftId].amount);
        stakingStatus[nftId] = StakingStatus({
            stakingId: stakeNum,
            lockAmount: lockAmount,
            lastTouchBlock: rewardInfo.lastTouchBlock,
            lastTouchAccRewardPerShare: rewardInfo.accRewardPerShare
        });
        stakeiZiAmount += lockAmount;

        emit Stake(nftId, msg.sender);
    }

    /// @notice unstake an nft
    /// @param nftId id of nft
    function unStake(uint256 nftId) external nonReentrant {
        require(stakedNft[msg.sender] == nftId, "Not Owner or Not staking!");
        stakingStatus[nftId].stakingId = 0;
        stakedNft[msg.sender] = 0;
        stakedNftOwners[nftId] = address(0);
        _collectReward(nftId, msg.sender);
        // refund nft
        safeTransferFrom(address(this), msg.sender, nftId);

        stakeiZiAmount -= uint256(nftLocked[nftId].amount);
        emit Unstake(nftId, msg.sender);
    }

    /// @notice get user's staking info
    /// @param user address of user
    /// @return nftId id of veizi-nft
    /// @return stakingId id of stake
    /// @return amount amount of locked iZi in nft
    function stakingInfo(address user) external view returns(uint256 nftId, uint256 stakingId, uint256 amount) {
        nftId = stakedNft[user];
        if (nftId != 0) {
            stakingId = stakingStatus[nftId].stakingId;
            amount = uint256(nftLocked[nftId].amount);
        } else {
            stakingId = 0;
            amount = 0;
        }
    }
    
    /// @notice Update the global status.
    function _updateGlobalStatus() internal {
        if (block.number <= rewardInfo.lastTouchBlock) {
            return;
        }
        if (rewardInfo.lastTouchBlock >= rewardInfo.endBlock) {
            return;
        }
        uint256 currBlockNumber = Math.min(block.number, rewardInfo.endBlock);
        if (stakeiZiAmount == 0) {
            rewardInfo.lastTouchBlock = currBlockNumber;
            return;
        }

        // tokenReward < 2^25 * 2^64 * 2^10, 15 years, 1000 r/block
        uint256 tokenReward = (currBlockNumber - rewardInfo.lastTouchBlock) * rewardInfo.rewardPerBlock;
        // tokenReward * Q128 < 2^(25 + 64 + 10 + 128)
        rewardInfo.accRewardPerShare = rewardInfo.accRewardPerShare + ((tokenReward * FixedPoints.Q128) / stakeiZiAmount);
        
        rewardInfo.lastTouchBlock = currBlockNumber;
    }

    /// @notice Return reward multiplier over the given _from to _to block.
    /// @param _from The start block.
    /// @param _to The end block.
    function _getRewardBlockNum(uint256 _from, uint256 _to)
        internal
        view
        returns (uint256)
    {
        if (_from > _to) {
            return 0;
        }
        if (_to <= rewardInfo.endBlock) {
            return _to - _from;
        } else if (_from >= rewardInfo.endBlock) {
            return 0;
        } else {
            return rewardInfo.endBlock - _from;
        }
    }

    /// @notice View function to see pending Reward for a single position.
    /// @param tokenId The related position id.
    /// @return reward iZi reward amount
    function pendingRewardOfToken(uint256 tokenId)
        public
        view
        returns (uint256 reward)
    {
        reward = 0;
        StakingStatus memory t = stakingStatus[tokenId];
        if (t.stakingId != 0) {
            // we are sure that stakeiZiAmount is not 0
            uint256 tokenReward = _getRewardBlockNum(
                rewardInfo.lastTouchBlock,
                block.number
            ) * rewardInfo.rewardPerBlock;
            // we are sure that stakeiZiAmount >= t.lockAmount
            uint256 rewardPerShare = rewardInfo.accRewardPerShare + (tokenReward * FixedPoints.Q128) / stakeiZiAmount;
            // l * (currentAcc - lastAcc)
            reward = (t.lockAmount * (rewardPerShare - t.lastTouchAccRewardPerShare)) / FixedPoints.Q128;
        }
    }

    /// @notice View function to see pending Reward for a user.
    /// @param user The related user address.
    /// @return reward iZi reward amount
    function pendingRewardOfAddress(address user)
        public
        view
        returns (uint256 reward)
    {
        reward = 0;
        uint256 tokenId = stakedNft[user];
        if (tokenId != 0) {
            reward = pendingRewardOfToken(tokenId);
        }
    }

    /// @notice collect pending reward if some user has a staked veizi-nft
    function collect() external nonReentrant {
        uint256 nftId = stakedNft[msg.sender];
        require(nftId != 0, 'No Staked veizi-nft!');
        _collectReward(nftId, msg.sender);
    }


    /// @notice Set new reward end block.
    /// @param _endBlock New end block.
    function modifyEndBlock(uint256 _endBlock) external onlyOwner {
        require(_endBlock > block.number, "OUT OF DATE");
        _updateGlobalStatus();
        // jump if origin endBlock < block.number
        rewardInfo.lastTouchBlock = block.number;
        rewardInfo.endBlock = _endBlock;
    }

    /// @notice Set new reward per block.
    /// @param _rewardPerBlock new reward per block
    function modifyRewardPerBlock(uint256 _rewardPerBlock)
        external
        onlyOwner
    {
        _updateGlobalStatus();
        rewardInfo.rewardPerBlock = _rewardPerBlock;
    }


    /// @notice Set new reward provider.
    /// @param provider New provider
    function modifyProvider(address provider)
        external
        onlyOwner
    {
        rewardInfo.provider = provider;
    }
}