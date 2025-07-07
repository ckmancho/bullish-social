// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/BSTokenInterface.sol";

/**
 * @title BSReward: Decentralized Leaderboard-Based Reward System
 * @author ckmancho
 * @notice Distributes BUSO tokens to users based on weekly individual/club leaderboard rankings.
 * @dev Uses Merkle proofs for off-chain data validation, DAO-controlled parameters, and anti-abuse mechanisms.
 * 
 * Key Features:
 * - Weekly cycles with Merkle-validated snapshots.
 * - Dynamic reward levels and allocation (DAO-governed).
 * - The DAO has full control over reward parameters, bans, and token recovery.
 * - Transparent and secure reward calculations.
 * 
 * - Official Website: https://bullish.social
 * - Official X: https://x.com/bullishsocial
 */
contract BSReward is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Immutable data
    address immutable private i_signer;
    BSTokenInterface immutable private i_token;

    // Array of reward levels, each level corresponds to a specific reward amount.
    uint256[15] public rewardLevels = [1, 4096, 8192, 16384, 32768, 57344, 86016, 107520, 134400, 168000, 210000, 262500, 328125, 410156, 512695];
    
    // Stores the current reward configuration, controlled by the DAO.
    RewardConfig private s_config;

    // On-chain bans - DAO Controlled
    mapping(address => bool) private s_bannedUsers; //These users will not be able to claim snapshot rewards
    mapping(uint64 => bool) private s_bannedClubs; //Users that member of these clubs won't be able to claim club rewards

    // Week data
    uint256 private constant WEEK_DURATION = 7 days; // Duration of a week in seconds (7 days).
    uint256 private s_startTime = 1737936000; // Timestamp of the first week's start. Monday, 13 January 2025 00:00:00
    WeekData[] private s_weekData;
    
    // Tracking mappings
    mapping(uint64 => mapping(uint64 => bool)) private s_weeklyUsedSnapshotIds; //Used snapshot IDs for each week (weekId => snapshotId => isUsed).
    mapping(uint64 => mapping(uint64 => SavedRank)) private s_usedIndividualRanks; //Used individual ranks for each week (weekId => rank => SavedRank).
    mapping(uint64 => mapping(uint64 => mapping(uint64 => address))) private s_usedClubMemberRank; //Used club member ranks for each week (weekId => clubRank => memberRank => user address).
    mapping(uint64 => uint64) private s_weeklyUsedSnapshotCount; // Used snapshot count for each week (weekId => count).
    mapping(bytes32 => bool) private s_usedSnapshots; // Used snapshot hashes (snapshotHash => isUsed).

    /// @notice Reward configuration parameters. Updateable by DAO.
    struct RewardConfig {
        /// @notice Current reward level (0-14)
        uint8 rewardLevel;
        
        /// @notice Maximum number of users eligible for individual rewards (5-10000)
        uint32 rewardIndividualMax;
        
        /// @notice Maximum number of clubs eligible for club rewards (10-100000)
        uint32 rewardClubMax;
        
        /// @notice Percentage of rewards allocated to individual users, rest for club rewards (1-30)
        uint8 rewardToIndividualPercent;

        /// @notice Percentage of score weight in the individual reward calculation (0-100). Rest of the percent is for rank weight.
        uint8 individualScoreWeight;

        /// @notice Percentage of score weight in the club reward calculation (0-100). Rest of the percent is for rank weight.
        uint8 clubScoreWeight;

        /// @notice Maximum number of members allowed per club (100-1000)
        uint32 maxClubMembers;

        /// @notice Allows others to claim rewards for snapshot owners
        bool allowClaimsForOthers;
    }

    struct RewardPool {
        uint256 totalRewardAmount;          // Total reward amount for the pool
        uint256 remainingRewardAmount;      // Remaining reward amount in the pool
        uint256 rankRewardPiece;            // Rank reward piece for the pool
        uint256 scoreRewardPiece;           // Score reward piece for the pool
        uint256 totalScores;                // Total scores for the pool (used for score-based calculations)
        uint8 scoreWeight;                  // Weight of score in the reward calculation (0-100%) rest is for rank weight
    }

    struct WeeklyRewardData {
        uint8 rewardLevel;                  // Reward Level
        uint8 rewardToIndividualPercent;    // Percentage of rewards allocated to individual users (rest is going to club rewards)
        RewardPool ipool;                   // Individual reward pool data
        RewardPool cpool;                   // Club reward pool data
    }

    /// @notice Weekly reward data structure
    struct WeekData {
        uint64  id;                         // Week ID
        uint32  nonce;                      // Week Nonce
        uint256 date;                       // Start timestamp
        Status  status;                     // Current Status (NOT_EXIST, ONGOING, EXPIRED)

        bytes32 root;                       // MerkleTree Root Hash for snapshots
        
        uint32  totalNumberOfSnapshot;      // Total number of snapshots
        uint32  totalNumberOfIndividualEntries; // Total number of individual entries in the leaderboard
        uint32  totalNumberOfClubEntries;   // Total number of club entries in the leaderboard
        uint32  maxClubMembers;             // Maximum number of members allowed per club

        WeeklyRewardData rewardData;        // Reward data for the week
    }

    /// @notice Represents a snapshot of user data for reward claims.
    struct Snapshot {
        uint64  id;
        uint64  weekIndex;
        uint64  weekNonce;
        address user;
        IndividualData individual;
        ClubData club;
    }

    /// @notice Stores individual user data, used to calculate rewards.
    struct IndividualData {
        uint64 score;
        uint64 rank;
    }

    /// @notice Stores club data for reward calculation and distribution.
    struct ClubData {
        uint64 id;
        uint64 score;
        uint64 rank;
        uint8 distributionMethod;
        uint64 memberCount;
        uint64 memberRank;
        uint64 memberScore;
    }

    /// @notice Structure to store used individual ranks for each week.
    struct SavedRank {
        address user;
        uint64  score;
    }

    /// @notice Structure for week status.
    enum Status {
        NOT_EXIST,
        ONGOING,
        EXPIRED
    }

    /// @notice Represents the club reward distribution method.
    enum DistributionMethod {
        SHARED,
        RANK_BASED,
        SCORE_BASED,
        BALANCED
    }

    /* ERRORS */
    error BSReward__OnlySignerAllowed(address owner);
    error BSReward__OnlyDAOAllowed(address daoAddress);

    /* EVENTS */
    event WeekDataAdded(uint256 indexed weekId, uint256 indexed date, uint256 indexed totalRewardAmount);
    event SnapshotUsed(address indexed forAddress, uint256 indexed weekId, uint256 individualReward, uint256 clubReward);
    event IndividualRankUsed(uint256 indexed weekId, address indexed user, uint64 score, uint64 indexed rank, uint256 reward);
    event ClubMemberRankUsed(uint256 indexed weekId, address indexed user, uint64 clubId, uint64 indexed clubRank, uint64 clubScore, uint64 memberRank, uint256 reward);
    event ERC20Transferred(address indexed erc20, address indexed to, uint256 indexed amount);

    /* DAO UPDATE EVENTS */
    event RewardLevelIncreased(uint8 indexed previousLevel, uint8 indexed newLevel);
    event RewardLevelDecreased(uint8 indexed previousLevel, uint8 indexed newLevel);
    event RewardLevelSet(uint8 indexed previousLevel, uint8 indexed newLevel);
    event MaxIndividualsSet(uint64 indexed previous, uint64 indexed newValue);
    event MaxClubsSet(uint64 indexed previous, uint64 indexed newValue);
    event RewardToIndividualPercentSet(uint8 indexed previous, uint8 indexed newValue);
    event IndividualScoreWeightSet(uint8 indexed previous, uint8 indexed newValue);
    event ClubScoreWeightSet(uint8 indexed previous, uint8 indexed newValue);
    event MaxClubMembersSet(uint64 indexed previous, uint64 indexed newValue);
    event BannedUserSet(address indexed user, bool indexed isBanned);
    event BannedClubSet(uint64 indexed clubId, bool indexed isBanned);
    event AllowClaimsForOtherSet(bool indexed isAllowed);

    /* MODIFIERS */
    modifier onlySigner() {
        if (msg.sender != i_signer) revert BSReward__OnlySignerAllowed(i_signer);
        _;
    }

    modifier onlyDAO() {
        address daoAddress = i_token.getGovernorAddress();
        if (msg.sender != daoAddress) revert BSReward__OnlyDAOAllowed(daoAddress);
        _;
    }

    modifier requiresWeekData(uint256 weekId) {
        require(weekId < s_weekData.length && s_weekData[weekId].status != Status.NOT_EXIST, "BSReward__NoWeekData");
        _;
    }

    /* CONSTRUCTOR */
    constructor(address tokenAddress, uint32 initialMaxIndividualRank, uint32 initialMaxClubRank) {
        i_signer = msg.sender;
        i_token = BSTokenInterface(tokenAddress);

        //Set config
        s_config.rewardLevel = 1; //test:1
        s_config.rewardIndividualMax = initialMaxIndividualRank;
        s_config.rewardClubMax = initialMaxClubRank;
        s_config.rewardToIndividualPercent = 25;
        s_config.individualScoreWeight = 50; //test:50
        s_config.clubScoreWeight = 65; //test:65
        s_config.maxClubMembers = 100;
        s_config.allowClaimsForOthers = false;

        //Set start time as current ongoing week. AddWeekData will be available after the week we are in.
        s_startTime = getWeekStart(block.timestamp);
    }

    /* FUNCTIONS */

    /**
     * @notice Adds new week data to the contract.
     * @dev Only callable by the signer. Validates inputs and calculates reward pools.
     * @param nonce A nonce value for the week.
     * @param totalNumberOfSnapshot The total number of snapshots for the week.
     * @param totalNumberOfIndividualEntries The total number of individual entries for the week.
     * @param totalNumberOfClubEntries The total number of club entries for the week.
     * @param totalIndividualScores The total individual scores for the week.
     * @param totalClubScores The total club scores for the week.
     * @param root The Merkle tree root hash for the week's snapshots.
     */
    function addWeekData(
        uint32 nonce,
        uint32 totalNumberOfSnapshot,
        uint32 totalNumberOfIndividualEntries,
        uint32 totalNumberOfClubEntries,
        uint32 totalIndividualScores,
        uint32 totalClubScores,
        bytes32 root
    ) external onlySigner {
        uint256 lastWeekDate = getLastWeekDate();
        uint256 nextWeekDate = getWeekStart(block.timestamp);
        
        // Check if the week is still ongoing. We need to wait until the week is over to add new week data
        require(nextWeekDate >= lastWeekDate + WEEK_DURATION, "BSReward__WeekIsStillOngoing");

        // Ensure there is at least one snapshot
        require(totalNumberOfSnapshot > 0, "BSReward__NotEnoughSnapshots");

        // Validate total number of individual scores
        require(totalIndividualScores > 0, "BSReward__InvalidIndividualScores");

        // Validate nonce
        require(nonce >= 100000000 && nonce <= 999999999, "BSReward__InvalidNonce");

        // Calculate total reward amount based on the current reward level
        uint256 totalRewardAmount = (rewardLevels[s_config.rewardLevel] * 1e18);

        // Check remaining reward supply for totalt reward amount
        uint256 remainingRewardSupply = getRemainingRewardSupply();
        if (remainingRewardSupply < totalRewardAmount) {
            //If the remaining supply is less than this week's reward amount, use the entire remaining supply to calculate rewards.
            totalRewardAmount = remainingRewardSupply;
        }

        // Validate maximum individual and club ranks
        require(totalNumberOfIndividualEntries <= s_config.rewardIndividualMax, "BSReward__MaxIndividualRanksExceeds");
        require(totalNumberOfClubEntries <= s_config.rewardClubMax, "BSReward__MaxClubRankExceeds");

        // Weights
        WeeklyRewardData memory rewardData = _calculateWeeklyRewardData(
            totalRewardAmount,
            totalNumberOfIndividualEntries,
            totalNumberOfClubEntries,
            totalIndividualScores,
            totalClubScores
        );

        // Create week data
        WeekData memory data = WeekData({
            id: uint64(s_weekData.length),
            nonce: nonce,
            date: nextWeekDate,
            status: Status.ONGOING,
            root: root,
            totalNumberOfSnapshot: totalNumberOfSnapshot,
            totalNumberOfIndividualEntries: totalNumberOfIndividualEntries,
            totalNumberOfClubEntries: totalNumberOfClubEntries,
            maxClubMembers: s_config.maxClubMembers,
            rewardData: rewardData
        });

        s_weekData.push(data);
        emit WeekDataAdded(s_weekData.length - 1, data.date, totalRewardAmount);

        // Expire the oldest week if there are more than 8 weeks
        if (s_weekData.length >= 9) {
            uint256 expiredWeekId = s_weekData.length - 9;
            s_weekData[expiredWeekId].status = Status.EXPIRED;
        }
    }

    function _calculateWeeklyRewardData(
        uint256 totalRewardAmount,
        uint32 totalNumberOfIndividualEntries,
        uint32 totalNumberOfClubEntries,
        uint32 totalIndividualScores,
        uint32 totalClubScores
    ) internal view returns (WeeklyRewardData memory) {
        // Calculate Individual reward pool and reward pieces
        uint256 individualRewardPool = (totalRewardAmount * s_config.rewardToIndividualPercent) / 100;
        uint256 individualRankRewardPiece = 0;
        uint256 individualScoreRewardPiece = 0;
        if (totalNumberOfIndividualEntries > 0) {
            uint8 scoreWeight = s_config.individualScoreWeight;
            uint8 rankWeight = 100 - scoreWeight;

            individualRankRewardPiece = calculateRankRewardPiece(totalNumberOfIndividualEntries, individualRewardPool, rankWeight);
            individualScoreRewardPiece = calculateScoreRewardPiece(totalIndividualScores, individualRewardPool, scoreWeight);
        }

        // Calculate Club reward pool and reward pieces
        uint256 clubRewardPool = totalNumberOfClubEntries == 0 ? 0 : totalRewardAmount - individualRewardPool;
        uint256 clubRankRewardPiece = 0;
        uint256 clubScoreRewardPiece = 0;
        if (totalNumberOfClubEntries > 0 && totalClubScores > 0) {
            uint8 scoreWeight = s_config.clubScoreWeight;
            uint8 rankWeight = 100 - scoreWeight;

            clubRankRewardPiece = calculateRankRewardPiece(totalNumberOfClubEntries, clubRewardPool, rankWeight);
            clubScoreRewardPiece = calculateScoreRewardPiece(totalClubScores, clubRewardPool, scoreWeight);
        }

        // Create and return the WeeklyRewardData structure
        return WeeklyRewardData({
            rewardLevel: s_config.rewardLevel,
            rewardToIndividualPercent: s_config.rewardToIndividualPercent,
            ipool: RewardPool({
                totalRewardAmount: individualRewardPool,
                remainingRewardAmount: individualRewardPool,
                rankRewardPiece: individualRankRewardPiece,
                scoreRewardPiece: individualScoreRewardPiece,
                scoreWeight: s_config.individualScoreWeight,
                totalScores: totalIndividualScores
            }),
            cpool: RewardPool({
                totalRewardAmount: clubRewardPool,
                remainingRewardAmount: clubRewardPool,
                rankRewardPiece: clubRankRewardPiece,
                scoreRewardPiece: clubScoreRewardPiece,
                scoreWeight: s_config.clubScoreWeight,
                totalScores: totalClubScores
            })
        });
    }

    /**
     * @notice Allows users to claim rewards using their snapshots.
     * @dev Verifies the snapshot and Merkle proof, then calculates and transfers rewards.
     * @param snapshot The snapshot data of the user.
     * @param proof The Merkle proof for the snapshot.
     */
    function useSnapshot(
        Snapshot memory snapshot,
        bytes32[] memory proof
    ) external nonReentrant {
        // Verify and get Week Data
        WeekData memory data = _verifyWeekData(snapshot);
        WeeklyRewardData memory rewardData = data.rewardData;
        
        // Verify and get Snapshot Hash
        bytes32 snapshotHash = _verifySnapshot(snapshot, proof, data);

        // Snapshot is legit.
        // Calculate user reward
        uint256 individualReward = _useIndividualReward(snapshot, data);
        uint256 clubReward = _useClubMemberReward(snapshot, data);
        
        // Set snapshot as used
        s_usedSnapshots[snapshotHash] = true; //isUsed
        s_weeklyUsedSnapshotCount[snapshot.weekIndex] += 1; //increase
        s_weeklyUsedSnapshotIds[snapshot.weekIndex][snapshot.id] = true; //isUsed

        // Reduce from reward pool
        if (individualReward > 0) {
            require(rewardData.ipool.remainingRewardAmount >= individualReward, "BSReward__RewardPoolExceeds");
            s_weekData[snapshot.weekIndex].rewardData.ipool.remainingRewardAmount -= individualReward;
        }

        if (clubReward > 0) {
            require(rewardData.cpool.remainingRewardAmount >= clubReward, "BSReward__ClubRewardPoolExceeds");
            s_weekData[snapshot.weekIndex].rewardData.cpool.remainingRewardAmount -= clubReward;
        }

        // Check remaining reward supply
        uint256 totalRewardAmount = individualReward + clubReward;
        uint256 remainingRewardSupply = getRemainingRewardSupply();
        require(remainingRewardSupply >= totalRewardAmount, "BSReward__InsufficientRewardSupply");

        // Transfer reward
        IERC20(i_token).safeTransfer(snapshot.user, totalRewardAmount);

        emit SnapshotUsed(snapshot.user, snapshot.weekIndex, individualReward, clubReward);
    }

    /**
     * @notice Increases the reward level by one.
     * @dev Only callable by the DAO.
     */
    function increaseRewardLevel() external onlyDAO {
        require(s_config.rewardLevel + 1 < rewardLevels.length, "BSReward__RewardLevelExceeds");

        emit RewardLevelIncreased(s_config.rewardLevel, s_config.rewardLevel + 1);
        s_config.rewardLevel += 1;
    }

    /**
     * @notice Decreases the reward level by one.
     * @dev Only callable by the DAO.
     */
    function decreaseRewardLevel() external onlyDAO {
        require(s_config.rewardLevel > 0, "BSReward__MinimumRewardLevelReached");

        emit RewardLevelDecreased(s_config.rewardLevel, s_config.rewardLevel - 1);
        s_config.rewardLevel -= 1;
    }

    /**
     * @notice Sets the reward level to a specific level index.
     * @dev Only callable by the DAO.
     * @param newLevel Level index to set see `rewardLevels`
     */
    function setRewardLevel(uint8 newLevel) external onlyDAO {
        require(newLevel < rewardLevels.length, "BSReward__RewardLevelExceeds");

        emit RewardLevelSet(s_config.rewardLevel, newLevel);
        s_config.rewardLevel = newLevel;
    }

    /**
     * @notice Bans/unbans a user from claiming rewards
     * @dev Only callable by DAO. Affects both individual and club rewards.
     * @param user Address to update
     * @param isBanned New ban status
     */
    function setBannedUser(address user, bool isBanned) external onlyDAO {
        require(s_bannedUsers[user] != isBanned, "State is already in the desired condition");

        s_bannedUsers[user] = isBanned;
        emit BannedUserSet(user, isBanned);
    }

    /**
     * @notice Bans/unbans a club from claiming rewards
     * @dev Only callable by DAO. Affects all members of the club to claim rewards.
     * @param clubId Club to ban/unban
     * @param isBanned New ban status
     */
    function setBannedClub(uint64 clubId, bool isBanned) external onlyDAO {
        require(s_bannedClubs[clubId] != isBanned, "State is already in the desired condition");

        s_bannedClubs[clubId] = isBanned;
        emit BannedClubSet(clubId, isBanned);
    }

    /**
     * @notice Enables or disables claiming rewards for other users.
     * @dev Only callable by the DAO.
     * @dev When allowed, user 'B' can call useSnapshot to claim rewards for user 'A'.
     * @param isAllowed True to allow claiming for others, false to disable.
     */
    function setAllowClaimsForOthers(bool isAllowed) external onlyDAO nonReentrant {
        require(s_config.allowClaimsForOthers != isAllowed, "State is already in the desired condition");

        emit AllowClaimsForOtherSet(isAllowed);
        s_config.allowClaimsForOthers = isAllowed;
    }

    /**
     * @notice Sets maximum number of individual reward recipients
     * @dev Only callable by DAO. Affects future weeks.
     * @param newValue New maximum (5-10000)
     */
    function setMaxIndividualUsersToReward(uint32 newValue) external onlyDAO {
        require(newValue >= 5 && newValue <= 10000, "Max individual users to reward must be between 5 and 10000");

        emit MaxIndividualsSet(s_config.rewardIndividualMax, newValue);
        s_config.rewardIndividualMax = newValue;
    }

    /**
     * @notice Sets the maximum number of clubs eligible for weekly rewards.
     * @dev Only callable by the DAO. Affects future weeks' reward distribution.
     * @param newValue The new maximum number of clubs (10-100000).
     */
    function setMaxClubsToReward(uint32 newValue) external onlyDAO {
        require(newValue >= 10 && newValue <= 100000, "Max clubs to reward must be between 10 and 100000");

        emit MaxClubsSet(s_config.rewardClubMax, newValue);
        s_config.rewardClubMax = newValue;
    }

    /**
     * @notice Sets the percentage of rewards allocated to individual users.
     * @dev Only callable by the DAO. The remaining percentage is allocated to club rewards. Affects future weeks.
     * @param newValue The new percentage value (1-30).
     */
    function setRewardToIndividualPercent(uint8 newValue) external onlyDAO {
        require(newValue >= 1 && newValue <= 30, "Reward to individual percent must be between 1 and 30");

        emit RewardToIndividualPercentSet(s_config.rewardToIndividualPercent, newValue);
        s_config.rewardToIndividualPercent = newValue;
    }

    /**
     * @notice Sets the percentage of club score weight in the reward calculation.
     * @dev Only callable by the DAO. The remaining percentage is allocated to rank weight. Affects future weeks.
     * @param newValue The new percentage value (0-100).
     */
    function setClubRewardScoreWeight(uint8 newValue) external onlyDAO {
        require(newValue >= 0 && newValue <= 100, "Reward score weight must be between 0 and 100");

        emit ClubScoreWeightSet(s_config.clubScoreWeight, newValue);
        s_config.clubScoreWeight = newValue;
    }

    /**
     * @notice Sets the percentage of individual score weight in the reward calculation.
     * @dev Only callable by the DAO. The remaining percentage is allocated to rank weight. Affects future weeks.
     * @param newValue The new percentage value (0-100).
     */
    function setIndividualRewardScoreWeight(uint8 newValue) external onlyDAO {
        require(newValue >= 0 && newValue <= 100, "Reward score weight must be between 0 and 100");

        emit IndividualScoreWeightSet(s_config.individualScoreWeight, newValue);
        s_config.individualScoreWeight = newValue;
    }

    /**
     * @notice Sets the maximum number of members allowed per club.
     * @dev Only callable by the DAO. Affects club reward distribution calculations.
     * @param newValue The new maximum number of members (100-1000).
     * @dev Reverts if the new value is outside the allowed range.
     */
    function setMaxClubMembers(uint32 newValue) external onlyDAO {
        require(newValue >= 100 && newValue <= 1000, "Max club members must be between 100 and 1000");

        emit MaxClubMembersSet(s_config.maxClubMembers, newValue);
        s_config.maxClubMembers = newValue;
    }

    /**
     * @notice Transfers ERC20 tokens to the treasury address.
     * @dev This function is treated as restricted function on the governance contract. Only callable by the DAO.
     * @param erc20 The address of the ERC20 token.
     * @param amount The amount of tokens to transfer.
     */
    function transferERC20ToTreasury(address erc20, uint256 amount) external onlyDAO nonReentrant {
        require(amount > 0, "BSReward__AmountMustBeGreaterThanZero");
        require(IERC20(erc20).balanceOf(address(this)) >= amount, "BSReward__InsufficientBalance");

        address governorAddress = i_token.getGovernorAddress();
        require(governorAddress != address(0), "BSReward__InvalidTreasuryAddress");

        IERC20(erc20).safeTransfer(governorAddress, amount);
        emit ERC20Transferred(erc20, governorAddress, amount);
    }

    /**
     * @notice Internal function to validate week data for a snapshot.
     * @dev Reverts if the week does not exist, is expired, or has a nonce mismatch.
     * @param snapshot The user's snapshot data.
     * @return data The validated week data.
     */
    function _verifyWeekData(Snapshot memory snapshot) internal view returns(WeekData memory) {
        require(s_weekData.length > 0, "BSReward__NoWeekData");
        require(snapshot.weekIndex < s_weekData.length && s_weekData[snapshot.weekIndex].status != Status.NOT_EXIST, "BSReward__WeekNotExist");
        
        //Get weekData
        WeekData memory data = s_weekData[snapshot.weekIndex];
        require(data.status == Status.ONGOING, "BSReward__WeekExpired");
        require(data.nonce == snapshot.weekNonce, "BSReward__WeekNonceMismatch");
        
        return data;
    }

    /**
     * @notice Validate a snapshot and its Merkle proof.
     * @dev Internal function with comprehensive checks
     * @param snapshot The user's snapshot data.
     * @param proof The Merkle proof for the snapshot.
     * @param data The week data for the snapshot's week.
     * @return snapshotHash The hash of the validated snapshot.
     */
    function _verifySnapshot(
        Snapshot memory snapshot,
        bytes32[] memory proof,
        WeekData memory data
    ) internal view returns(bytes32) {
        //First, verify the snapshot. Throws error if the snapshot is not valid
        //Verify proof
        bytes32 snapshotHash = encodeSnapshot(snapshot);
        require(verifyWithLeaf(snapshotHash, data.root, proof), "BSReward__InvalidProof");

        //Verify sender address
        if (!s_config.allowClaimsForOthers) {
            require(snapshot.user == msg.sender, "BSReward__AddressMismatch");
        }

        //Check user is banned
        require(!s_bannedUsers[snapshot.user], "BSReward__UserIsBanned");

        //Check snapshot is used
        require(!s_usedSnapshots[snapshotHash], "BSReward__SnapshotAlreadyUsed");

        //Check used snapshot count
        require(s_weeklyUsedSnapshotCount[snapshot.weekIndex] < data.totalNumberOfSnapshot, "BSReward__TotalUsedSnapshotExceeds");

        //Check snapshot ID is used
        require(!s_weeklyUsedSnapshotIds[snapshot.weekIndex][snapshot.id], "BSReward__SnapshotIdUsed");

        return snapshotHash;
    }

    /**
     * @notice Internal function to process individual rewards and mark the rank as used.
     * @dev Called during `useSnapshot` to deduct rewards from the individual pool.
     * @param snapshot The user's snapshot data.
     * @param data The week data for the snapshot's week.
     * @return individualReward The reward amount allocated to the user.
     */
    function _useIndividualReward(Snapshot memory snapshot, WeekData memory data) internal returns(uint256) {
        uint256 individualReward = calculateIndividualReward(snapshot);
        
        // Snapshot - calculate individual reward
        if (snapshot.individual.rank > 0 && snapshot.individual.rank <= data.totalNumberOfIndividualEntries) {
            //Check individual rank is used
            require(s_usedIndividualRanks[snapshot.weekIndex][snapshot.individual.rank].user == address(0), "BSReward__RankAlreadyRewarded");
            
            //Set rank as used
            SavedRank memory savedRank;
            savedRank.user = snapshot.user;
            savedRank.score = snapshot.individual.score;

            // (WeekIndex -> IndividualRank) = {user, address}
            s_usedIndividualRanks[snapshot.weekIndex][snapshot.individual.rank] = savedRank;
            emit IndividualRankUsed(snapshot.weekIndex, snapshot.user, snapshot.individual.score, snapshot.individual.rank, individualReward);
        }

        return individualReward;
    }

    /**
     * @notice Internal function to process club member rewards and mark the rank as used.
     * @dev Called during `useSnapshot` to deduct rewards from the club pool.
     * @param snapshot The user's snapshot data.
     * @param data The week data for the snapshot's week.
     * @return clubReward The reward amount allocated to the user.
     */
    function _useClubMemberReward(Snapshot memory snapshot, WeekData memory data) internal returns(uint256) {
        //Calculate member's reward amount
        uint256 memberReward = calculateClubMemberReward(snapshot);
        
        //If user has club and the club is eligible for rewards, set (ClubRank -> MemberRank) as used
        ClubData memory club = snapshot.club;
        if (club.rank > 0 && club.rank <= data.totalNumberOfClubEntries) {
            //Check and set club member rank as used
            require(s_usedClubMemberRank[snapshot.weekIndex][club.rank][club.memberRank] == address(0), "BSReward__MemberRankAlreadyRewarded");
            s_usedClubMemberRank[snapshot.weekIndex][club.rank][club.memberRank] = snapshot.user;
            emit ClubMemberRankUsed(snapshot.weekIndex, snapshot.user, snapshot.club.id, snapshot.club.rank, snapshot.club.score, snapshot.club.memberRank, memberReward);
        }

        return memberReward;
    }

    /**
     * @notice Calculates the start timestamp of the week containing the given timestamp.
     * @dev Aligns timestamps to weekly boundaries
     * @param timestamp Any timestamp within the target week
     * @return alignedStart Start timestamp of containing week
     */
    function getWeekStart(uint256 timestamp) public view returns (uint256 alignedStart) {
        if (timestamp < s_startTime) {
            return s_startTime;
        }

        uint256 diff = ((timestamp - s_startTime) / WEEK_DURATION) * WEEK_DURATION;
        return s_startTime + diff;
    }

    /**
     * @notice Calculates the individual reward for a user's snapshot.
     * @dev Uses the user's rank and week data to determine the reward amount.
     * @param snapshot The user's snapshot data.
     * @return individualReward The calculated individual reward amount.
     */
    function calculateIndividualReward(Snapshot memory snapshot) requiresWeekData(snapshot.weekIndex) public view returns(uint256 individualReward) {
        // Snapshot - calculate individual reward
        WeekData memory data = s_weekData[snapshot.weekIndex];
        if (snapshot.individual.rank > 0 && snapshot.individual.rank <= data.totalNumberOfIndividualEntries) {
            // Check if the numbers are valid
            require(snapshot.individual.score <= data.rewardData.ipool.totalScores, "BSReward__InvalidIndividualScore");

            // Reward distribution is balanced between rank and score
            uint256 rankReward = calculateRankReward(data.totalNumberOfIndividualEntries, snapshot.individual.rank, data.rewardData.ipool.rankRewardPiece);
            uint256 scoreReward = calculateScoreReward(snapshot.individual.score, data.rewardData.ipool.scoreRewardPiece);
            individualReward = rankReward + scoreReward;
        }
    }

    /**
     * @notice Calculates the club member reward for a user's snapshot.
     * @dev This function checks various conditions to ensure the club is eligible for rewards.
     *      It verifies the club's rank, club's score, member count, member rank, and distribution method.
     *      If the club is banned, it returns 0 as the reward, not reverts an error.
     *      That means individual users can still claim their individual rewards.
     *      Otherwise, it calculates the total reward amount for the club and distributes it
     *      based on the specified distribution method (shared or performance-based).
     * @param snapshot The user's snapshot data.
     * @return clubMemberReward The calculated reward amount for club member.
     */
    function calculateClubMemberReward(Snapshot memory snapshot) requiresWeekData(snapshot.weekIndex) public view returns(uint256 clubMemberReward) {
        WeekData memory data = s_weekData[snapshot.weekIndex];

        //Club Snapshot - calculate reward
        ClubData memory club = snapshot.club;

        //If user has club and the club is eligible for rewards.
        //Club rank should be between 1 and total number of club entries
        //Club score should be greater than 0, if not, it means the club is not eligible for rewards
        if (club.rank > 0 && club.rank <= data.totalNumberOfClubEntries && club.score > 0) {
            //Check if the numbers are valid
            require(club.memberCount > 0, "BSReward__InvalidMemberCount");
            require(club.memberCount <= data.maxClubMembers, "BSReward__MaxMembersExceeds");
            require(club.memberRank > 0, "BSReward__InvalidMemberRank");
            require(club.memberRank <= data.maxClubMembers, "BSReward__MaxClubMemberRankExceeds");
            require(club.memberRank <= club.memberCount, "BSReward__MaxMemberRankReached");
            require(club.distributionMethod <= 3, "BSReward__InvalidClubDistributionMethod");
            require(club.score <= data.rewardData.cpool.totalScores, "BSReward__InvalidClubScore");
            require(club.memberScore <= club.score, "BSReward__InvalidMemberScore");

            //Check club is banned
            if (s_bannedClubs[snapshot.club.id]) {
                return 0; //No club reward, not throwing error. Individual users can still claim their individual rewards
            }

            //Total reward amount for the club
            uint256 rewardPoolForClub = calculateClubReward(club.rank, club.score, snapshot.weekIndex);

            //Calculate member's reward based on the distribution method
            if (club.distributionMethod == uint8(DistributionMethod.SHARED)) {
                // Reward distribution is shared among all members
                clubMemberReward = rewardPoolForClub / club.memberCount;
            } else if (club.distributionMethod == uint8(DistributionMethod.RANK_BASED)) {
                // Reward distribution is based on rank
                uint256 rewardPiece = calculateRankRewardPiece(club.memberCount, rewardPoolForClub, 100);
                clubMemberReward = calculateRankReward(club.memberCount, club.memberRank, rewardPiece);
            } else if (club.distributionMethod == uint8(DistributionMethod.SCORE_BASED)) {
                // Reward distribution is based on score
                uint256 scoreRewardPiece = calculateScoreRewardPiece(club.score, rewardPoolForClub, 100);
                clubMemberReward = calculateScoreReward(club.memberScore, scoreRewardPiece);
            } else if (club.distributionMethod == uint8(DistributionMethod.BALANCED)) {
                // Reward distribution is balanced between rank and score
                uint8 scoreWeight = data.rewardData.cpool.scoreWeight;
                uint8 rankWeight = 100 - scoreWeight;

                uint256 rankRewardPiece = calculateRankRewardPiece(club.memberCount, rewardPoolForClub, rankWeight);
                uint256 scoreRewardPiece = calculateScoreRewardPiece(club.score, rewardPoolForClub, scoreWeight);
                
                uint256 rankReward = calculateRankReward(club.memberCount, club.memberRank, rankRewardPiece);
                uint256 scoreReward = calculateScoreReward(club.memberScore, scoreRewardPiece);
                clubMemberReward = rankReward + scoreReward;
            }
        }
    }

    /**
     * @param clubRank The rank of the club.
     * @dev Calculates the total reward amount for a club based on its rank and score.
     * @param clubScore The score of the club.
     * @param weekIndex Week Index for which the reward is being calculated.
     * @return clubReward The total reward amount for the club.
     */
    function calculateClubReward(uint64 clubRank, uint64 clubScore, uint256 weekIndex) requiresWeekData(weekIndex) public view returns(uint256 clubReward) {
        WeekData memory data = s_weekData[weekIndex];
        
        uint256 rewardPoolFromRank = calculateRankReward(data.totalNumberOfClubEntries, clubRank, data.rewardData.cpool.rankRewardPiece);
        uint256 rewardPoolFromScore = calculateScoreReward(clubScore, data.rewardData.cpool.scoreRewardPiece);

        clubReward = rewardPoolFromRank + rewardPoolFromScore;
    }

    /**
     * @notice Returns the last week's date.
     * @dev This value will be used to determine the start date of the next week, and this cycle will continue for weeks
     */
    function getLastWeekDate() public view returns(uint256) {
        return s_weekData.length == 0 ? s_startTime : s_weekData[s_weekData.length - 1].date;
    }

    /**
     * @notice Returns the remaining reward supply in the contract.
     */
    function getRemainingRewardSupply() public view returns(uint256) {
        return i_token.balanceOf(address(this));
    }

    /**
     * @notice Returns the week data for a specific week index.
     * @return The week data struct.
     */
    function getWeekData(uint256 index) external view returns(WeekData memory) {
        return s_weekData[index];
    }

    /**
     * @notice Returns the latest week ID.
     */
    function getWeekId() external view returns(uint256) {
        require(s_weekData.length > 0, "BSReward__NoWeekData");
        return s_weekData.length - 1;
    }

    /**
     * @notice Returns the current reward configuration.
     * @dev View function to fetch the reward configuration struct.
     * @return The reward configuration struct.
     */
    function getRewardConfig() external view returns(RewardConfig memory) {
        return s_config;
    }

    /**
     * @notice Checks if a user is banned from claiming rewards.
     */
    function isUserBanned(address user) external view returns(bool) {
        return s_bannedUsers[user];
    }

    /**
     * @notice Checks if a club is banned from claiming rewards.
     */
    function isClubBanned(uint64 clubId) external view returns(bool) {
        return s_bannedClubs[clubId];
    }

    function isSnapshotUsed(Snapshot memory snapshot) external view returns(bool) {
        return s_usedSnapshots[encodeSnapshot(snapshot)];
    }

    function calculateSnapshotReward(Snapshot memory snapshot) external view returns (uint256) {
        uint256 individualReward = calculateIndividualReward(snapshot);
        uint256 clubReward = calculateClubMemberReward(snapshot);
        return individualReward + clubReward;
    }

    function getWeekRemainingClubPool(uint256 weekIndex) external view returns(uint256) {
        return s_weekData[weekIndex].rewardData.cpool.remainingRewardAmount;
    }

    function getWeekRemainingIndividualPool(uint256 weekIndex) external view returns(uint256) {
        return s_weekData[weekIndex].rewardData.ipool.remainingRewardAmount;
    }

    function getUsedSnapshotCount(uint64 weekIndex) external view returns(uint64) {
        return s_weeklyUsedSnapshotCount[weekIndex];
    }

    function getWeekTotalNumberOfIndividualEntries(uint256 weekIndex) requiresWeekData(weekIndex) external view returns(uint64) {
        return s_weekData[weekIndex].totalNumberOfIndividualEntries;
    }

    function getWeekTotalNumberOfClubEntries(uint256 weekIndex) requiresWeekData(weekIndex) external view returns(uint64) {
        return s_weekData[weekIndex].totalNumberOfClubEntries;
    }

    function getIndividualRankScore(uint64 weekIndex, uint64 rank) external view returns(uint256) {
        return s_usedIndividualRanks[weekIndex][rank].score;
    }

    function getIndividualRankHolder(uint64 weekIndex, uint64 rank) external view returns(address) {
        return s_usedIndividualRanks[weekIndex][rank].user;
    }

    function getClubRankHolder(uint64 weekIndex, uint64 clubRank, uint64 memberRank) external view returns(address) {
        return s_usedClubMemberRank[weekIndex][clubRank][memberRank];
    }

    function getRewardLevel() external view returns(uint8) {
        return s_config.rewardLevel;
    }

    function getRewardToIndividualPercent() external view returns(uint8) {
        return s_config.rewardToIndividualPercent;
    }

    function getMaxClubsToReward() external view returns(uint256) {
        return s_config.rewardClubMax;
    }

    function getMaxIndividualUsersToReward() external view returns(uint256) {
        return s_config.rewardIndividualMax;
    }

    function getIndividualScoreWeightPercent() external view returns(uint8) {
        return s_config.individualScoreWeight;
    }

    function getClubScoreWeightPercent() external view returns(uint8) {
        return s_config.clubScoreWeight;
    }

    function getWeekCount() external view returns(uint256) {
        return s_weekData.length;
    }

    /**
     * @notice Calculates the reward piece for a given number of receivers and total reward.
     * @dev Returned piece will be used to calculate rewards
     * @param receivers The total number of reward receivers.
     * @param totalReward The total reward amount/pool.
     * @return The calculated reward piece.
     */
    function calculateRankRewardPiece(uint64 receivers, uint256 totalReward, uint8 rankWeight) public pure returns(uint256) {
        //Calculate sum of ranks (∑) eg. 1+2+3+4...168+169+170
        uint256 totalRank = receivers * (receivers + 1) / 2;

        //Calculate reward piece
        uint256 rewardPiece = totalReward / totalRank; // for user rewards, use: individualRewardPiece * (totalUsers - rank + 1)
        return (rewardPiece * rankWeight) / 100; // Get percentage of the piece
    }

    /**
     * @notice Calculates the reward piece for a specific score weight.
     * @param totalScore The total score of all rankings.
     * @param totalReward The total reward amount/pool.
     * @param scoreWeightPercent The percentage of the score weight (0-100%)
     * @return The calculated reward piece.
     */
    function calculateScoreRewardPiece(uint64 totalScore, uint256 totalReward, uint8 scoreWeightPercent) public pure returns(uint256) {
        uint256 piece = totalReward / totalScore;
        return (piece * scoreWeightPercent) / 100; // Get percentage of the piece
    }

    /**
     * @notice Calculates the reward for a specific rank.
     * @param totalReceivers The total number of reward receivers.
     * @param rank The rank of the receiver.
     * @param rewardPiece The reward piece calculated for the receivers.
     * @return The calculated reward amount.
     */
    function calculateRankReward(uint64 totalReceivers, uint64 rank, uint256 rewardPiece) public pure returns(uint256) {
        return rewardPiece * (totalReceivers - rank + 1);
    }

    /**
     * @notice Calculates the reward for a specific score.
     * @param score The score of the receiver.
     * @param rewardPiece The reward piece calculated for the score.
     * @return The calculated reward amount.
     */
    function calculateScoreReward(uint64 score, uint256 rewardPiece) public pure returns(uint256) {
        return score * rewardPiece;
    }

    /**
     * @notice Verifies a snapshot against a Merkle root and proof.
     * @param snapshot The snapshot data to verify.
     * @param root The Merkle root hash.
     * @param proof The Merkle proof for the snapshot.
     */
    function verify(Snapshot memory snapshot, bytes32 root, bytes32[] memory proof) public pure returns (bool) {
        bytes32 leaf = encodeSnapshot(snapshot);
        return verifyWithLeaf(leaf, root, proof);
    }

    function verifyWithLeaf(bytes32 leaf, bytes32 root, bytes32[] memory proof) public pure returns (bool) {
        return MerkleProof.verify(proof, root, leaf);
    }
    
    /**
     * @notice Encodes a Snapshot struct into a bytes32 hash.
     * @dev Uses keccak256 to hash the concatenated encoded snapshot data.
     * @param s The Snapshot struct to be encoded.
     * @return bytes32 The resulting hash of the encoded snapshot.
     */
    function encodeSnapshot(Snapshot memory s) public pure returns(bytes32) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(
            s.id, s.weekIndex, s.weekNonce, s.user, s.individual.score, s.individual.rank,
            s.club.id, s.club.score, s.club.rank, s.club.distributionMethod, s.club.memberCount, s.club.memberRank, s.club.memberScore
        ))));
        return leaf;
    }
}