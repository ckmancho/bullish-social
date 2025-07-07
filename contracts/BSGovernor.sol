// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/BSRewardInterface.sol";
import "./interfaces/BSTokenInterface.sol";

/**
 * @title BSGovernor: On-Chain Governance and Proposal System for Bullish Social
 * @author ckmancho
 * @notice Advanced decentralized governance mechanism for protocol upgrades, parameter changes and treasury management
 * @dev Implements a governance system combining liquid democracy, time-locked executions, and configurable parameters
 *
 * Key Features:
 * - Proposal creation with weighted voting power based on historical individual and club leaderboard rankings
 * - Dual voting power system combining individual achievements and club leadership positions
 * - Time-locked execution for security critical operations
 * - Treasury management for protocol fees and asset distribution to ecosystem participants  
 * - Configurable governance parameters controlled by DAO including quorum, approval thresholds and voting duration
 * - Anti-spam protection with weekly proposal limits and duplicate proposal detection
 * - Interim governance mode for initial protocol bootstrapping
 * - Extensible function restriction system for protocol security
 *
 * Security Features:
 * - Reentrancy protection for execution functions
 * - Timelock delays for critical operations
 * - Trusted address restrictions for proposal targets (stored in BSToken contract, updated by DAO)
 * - Vote power verification through proofs (verified by BSReward contract)
 *
 * Official Links:
 * - Website: https://bullish.social
 * - Twitter: https://x.com/bullishsocial 
 * - Documentation: https://docs.bullish.social
 */
contract BSGovernor is ReentrancyGuard {
    //Data
    address immutable private i_interimOwner;
    BSTokenInterface immutable private i_token;
    BSRewardInterface immutable private i_rewarder;

    //Config
    uint256 constant public TIMELOCK_DURATION = 1 days; // 1 day after the votinig period ends
    uint256 constant public EXECUTION_DURATION = 5 days; // 5 days after the voting period ends
    DAOConfig private s_config;

    //Proposals
    Proposal[] private s_proposals;
    uint256 public lastSuccessfulExecutionTime;

    //Extended restricted functions (see: {isRestrictedFunction})
    mapping(bytes4 => bool) s_restrictedFunctions;

    //ProposalId -> User -> Vote Data (decision, power)
    mapping(uint64 => mapping(address => UserVote)) private s_userVotesByProposal;

    //WeekId -> User -> Proposal Counter (Max 4)
    mapping(uint64 => mapping(address => uint8)) private s_weeklyProposalCounter;

    //WeekId -> ProposalHash -> bool (If proposal with this hash is already created in this week)
    mapping(uint64 => mapping(bytes32 => bool)) private s_weeklyProposalHashs;

    //User Address -> ProposalId
    mapping(address => uint64[]) private s_userProposals;

    /* STRUCTS */

    /// @notice Governance configuration parameters controlled by DAO
    struct DAOConfig {
        /// @notice Minimum participation percentage (5-60)
        uint16 quorumThresholdPercent;
        
        /// @notice Minimum approval percentage (70-90)
        uint16 approvalThresholdPercent;
        
        /// @notice Historical weeks considered for voting power (2-8)
        /// @dev Only users who have been rewarded in the last 'eligibleWeekCount' weeks can have power to create and vote proposals
        uint16 eligibleWeekCount;
        
        /// @notice Maximum rank considered for voting power (100-1000)
        uint16 votingMaximumRank;

        /// @notice Voting duration in seconds (3-14 days)
        uint64 votingDuration;

        /// @notice Maximum number of executions per proposal (1-10)
        uint16 maxExecutionsPerProposal;
        
        /// @notice Interim governance activation status
        bool interimActive;
        
        /// @notice Allow only trusted targets to be called
        bool allowOnlyTrustedTargets;
    }

    struct UserVote {
        ProposalDecision decision;
        uint64 power;
    }

    struct IndividualRankProof {
        uint64 weekIndex;
        uint64 rank;
    }

    struct ClubRankProof {
        uint64 weekIndex;
        uint64 clubRank;
        uint64 memberRank;
    }

    struct Proposal {
        string title;                       // Proposal title provided by the proposer
        uint64 id;                          // Proposal ID
        uint64 yesVotes;                    // Accumulated yes vote power
        uint64 noVotes;                     // Accumulated no vote power
        uint64 totalVoters;                 // Total number of voters
        address proposer;                   // Proposal creator address

        // Initial
        uint256 startTime;                  // Voting start timestamp
        uint256 endTime;                    // Voting end timestamp
        uint64 maxWeekIndex;                // Latest week index for voting power
        uint64 minWeekIndex;                // Earliest week index for voting power
        uint64 quorumThreshold;             // Minimum votes required to process the proposal
        uint64 approvalThresholdPercent;    // Minimum approval percentage required to approve the proposal

        // Execute data
        ProposalExecution[] executions;     // List of execution calls

        // State
        bool ended;                         // Is proposal active?
        ProposalOutcome outcome;            // Voting outcome
        ProposalResult[] results;           // Execution result
    }

    /// @notice Proposal execution details
    struct ProposalExecution {
        address target;                     // Target contract address to call
        bytes4 selector;                    // Function selector to call
        bytes args;                         // Encoded function arguments
        uint256 value;                      // Ether value to send with the call
    }

    /// @notice Execution result details for proposals
    struct ProposalResult {
        ProposalExecutionStatus status;     // Final execution state
        bytes callResult;                   // Raw call result data
    }

    /// @notice Voting phase outcomes
    enum ProposalOutcome {
        PENDING,            // Vote still ongoing
        REJECTED,           // Rejected by majority
        QUORUM_NOT_MET,     // Insufficient participation
        APPROVED            // Approved by majority
    }

    /// @notice Post-approval execution states
    enum ProposalExecutionStatus {
        NOT_EXECUTED,       // Not executed yet
        SUCCESS,            // Successful execution
        FAILED,             // Execution reverted
        EXPIRED             // Execution window closed
    }

    /// @notice Individual voting decisions
    enum ProposalDecision {
        NOT_VOTED,
        YES,
        NO
    }

    /* CUSTOM ERRORS */
    error BS__OnlyDAOAllowed(address daoAddress);
    
    /* PROPOSAL EVENTS */
    event ProposalCreated(uint64 indexed proposalId, address indexed proposer);
    event ProposalVoted(uint64 indexed proposalId, address indexed user, bool indexed decision, uint64 power);
    event ProposalFinalized(uint64 indexed proposalId, ProposalOutcome indexed outcome);
    event ProposalExecuted(uint64 indexed proposalId, string title, address indexed executor, bool allSucceed);
    event ProposalExpired(uint64 indexed proposalId, string title);

    /* DAO UPDATE EVENTS */
    event QuorumThresholdPercentUpdated(uint16 indexed oldValue, uint16 indexed newValue);
    event ApprovalThresholdPercentUpdated(uint16 indexed oldValue, uint16 indexed newValue);
    event EligibleWeekCountUpdated(uint16 indexed oldValue, uint16 indexed newValue);
    event VotingMaximumRankUpdated(uint16 indexed oldValue, uint16 indexed newValue);
    event MaxExecutionsPerProposalUpdated(uint16 indexed oldValue, uint16 indexed newValue);
    event InterimStateUpdated(bool indexed isActive);
    event AllowOnlyTrustedTargetsUpdated(bool indexed isOn);
    event VotingDurationUpdated(uint64 indexed oldValue, uint64 indexed newValue);
    event RestrictedFunctionSet(bytes4 indexed selector, bool indexed isRestricted);

    /* MODIFIERS */
    modifier onlyDAO() {
        address daoAddress = i_token.getGovernorAddress();
        if (msg.sender != daoAddress) revert BS__OnlyDAOAllowed(daoAddress);
        _;
    }

    modifier requiresPower(IndividualRankProof[] memory individualRankProofs, ClubRankProof[] memory clubRankProofs) {
        uint256 power = getCurrentVotingPower(msg.sender, individualRankProofs, clubRankProofs);
        require(power > 0, "You don't have enough voting power to perform this action");
        _;
    }

    modifier requiresProposal(uint64 proposalId) {
        require(proposalId < s_proposals.length && s_proposals[proposalId].proposer != address(0), "Proposal with given ID does not exist");
        _;
    }

    /* CONSTRUCTOR */
    constructor(address tokenAddress, address rewarderAddress) {
        require(tokenAddress != address(0) && rewarderAddress != address(0), "Invalid token or rewarder address");

        i_token = BSTokenInterface(tokenAddress);
        i_rewarder = BSRewardInterface(rewarderAddress);
        i_interimOwner = msg.sender;

        s_config.interimActive = true;
        s_config.allowOnlyTrustedTargets = true;
        s_config.quorumThresholdPercent = 60;        //Initial value at production: %33
        s_config.approvalThresholdPercent = 80;
        s_config.eligibleWeekCount = 2;
        s_config.votingMaximumRank = 100;
        s_config.votingDuration = 4 days;
        s_config.maxExecutionsPerProposal = 5;
    }

    /**
     * @notice Creates a new proposal.
     * @dev This function requires the caller to have sufficient power as determined by the {requiresPower} modifier.
     * @param executions An array of ProposalExecution structs containing the details of each execution.
     * @param individualRankProofs An array of proofs for individual ranks to determine user's vote power.
     * @param clubRankProofs An array of proofs for club ranks to determine user's vote power.
     */
    function createProposal(
        string memory title,
        ProposalExecution[] memory executions,
        IndividualRankProof[] memory individualRankProofs,
        ClubRankProof[] memory clubRankProofs
    ) external requiresPower(individualRankProofs, clubRankProofs) {

        //Check execution count
        require(executions.length > 0, "Proposal must have at least one execution");
        require(executions.length <= s_config.maxExecutionsPerProposal, "Proposal cannot have that many of executions");

        //Check executions
        bool hasRestrictedFunctions = false;
        for (uint256 i = 0; i < executions.length; i++) {
            ProposalExecution memory execution = executions[i];

            //Check target address is trusted
            if (s_config.allowOnlyTrustedTargets) {
                require(i_token.isTrustedAddress(execution.target), "AllowOnlyTrustedTargets is enabled and target is not in the trusted list.");
            }

            //Check is the function restricted or has a value(sending ETH)
            bool isRestricted = isRestrictedFunction(execution.selector);
            if ((isRestricted || execution.value > 0) && msg.sender != i_interimOwner) {
                revert("Only interim owner can create this proposal because target function is restricted or proposal has value");
            } else if (isRestricted) {
                hasRestrictedFunctions = true;
            }
        }

        //Check is user banned
        require(!i_rewarder.isUserBanned(msg.sender), "You are banned by the DAO");

        //Check proposal count of sender (max 4 proposals in a week)
        _checkProposalCount(msg.sender);

        //Check title
        require(bytes(title).length <= 128, "Proposal title is too long, max 128 bytes allowed");

        // Proposal Data
        uint64 proposalId = uint64(s_proposals.length);
        uint64 maxWeekIndex = uint64(i_rewarder.getWeekId()); //Latest week (current week)
        uint64 minWeekIndex = calculateMinimumWeekIndex(maxWeekIndex);
        uint64 quorumThreshold = calculateQuorumThreshold(minWeekIndex, maxWeekIndex);

        bytes32 proposalHash = _calculateProposalHash(executions);
        require(!s_weeklyProposalHashs[maxWeekIndex][proposalHash], "Proposal with the same content is already created in this week");

        // Proposal Data
        s_proposals.push();

        Proposal storage proposal = s_proposals[proposalId];
        proposal.id = proposalId;
        proposal.title = title;
        proposal.startTime = block.timestamp;
        proposal.endTime = proposal.startTime + s_config.votingDuration;
        proposal.maxWeekIndex = maxWeekIndex;
        proposal.minWeekIndex = minWeekIndex;
        proposal.quorumThreshold = quorumThreshold;
        proposal.approvalThresholdPercent = s_config.approvalThresholdPercent;
        proposal.ended = false;
        proposal.proposer = msg.sender;

        // Copy executions from memory to storage
        _addExecutions(proposalId, executions);

        s_userProposals[msg.sender].push(proposalId);
        s_weeklyProposalHashs[maxWeekIndex][proposalHash] = true;
        emit ProposalCreated(proposalId, msg.sender);

        //If interim governance is enabled, the caller is the interim owner, and the target function is not in the restricted functions;
        //Skip the voting period and approve the proposal.
        //Interim owner will be able to execute this proposal after the time lock has passed (1 day).
        if (!hasRestrictedFunctions && s_config.interimActive && i_interimOwner == msg.sender) {
            //Approve the proposal
            proposal.endTime = block.timestamp; //Skip the voting period
            _approveProposal(proposal);
        }
    }

    /**
     * @notice Casts a vote on a proposal.
     * @dev This function allows a user to cast a vote on a specific proposal.
     *      The user must have enough voting power and must not have already voted on the proposal.
     * @param proposalId The ID of the proposal to vote on.
     * @param decision The decision of the vote (true for yes, false for no).
     * @param individualRankProofs An array of proofs for individual ranks to determine user's vote power.
     * @param clubRankProofs An array of proofs for club ranks to determine user's vote power.
     */
    function castVote(
        uint64 proposalId,
        bool decision,
        IndividualRankProof[] memory individualRankProofs,
        ClubRankProof[] memory clubRankProofs
    ) requiresProposal(proposalId) external {
        //Get proposal
        Proposal storage proposal = s_proposals[proposalId];

        //Is user voted on this proposal?
        address forUser = msg.sender;
        require(s_userVotesByProposal[proposalId][forUser].decision == ProposalDecision.NOT_VOTED, "Already voted for this proposal");

        //Get our vote power for this proposal
        uint64 power = getVotingPowerWithProposal(forUser, proposal.id, individualRankProofs, clubRankProofs);
        require(power > 0, "You don't have enough power to vote on this proposal.");

        //Check is proposal still active
        require(!proposal.ended && proposal.outcome == ProposalOutcome.PENDING, "Proposal is ended");
        require(block.timestamp < proposal.endTime, "Proposal voting period has passed");

        UserVote memory userVote;
        userVote.power = power;
        proposal.totalVoters += 1;

        if (decision) {
            proposal.yesVotes += power;
            userVote.decision = ProposalDecision.YES;
        } else {
            proposal.noVotes += power;
            userVote.decision = ProposalDecision.NO;
        }

        s_userVotesByProposal[proposalId][forUser] = userVote;
        emit ProposalVoted(proposalId, forUser, decision, power);
    }

    /**
     * @notice Finalizes a proposal based on the voting outcome and other conditions.
     * @dev This function can only be called after the proposal's voting period has ended.
     * It checks if the proposal meets the quorum threshold and determines if it is approved or rejected.
     * If approved, it attempts to execute the proposal within a specified time frame.
     * If the proposal is not executed within the time frame, it is marked as expired.
     * @param proposalId The ID of the proposal to finalize.
     */
    function finalizeProposal(
        uint64 proposalId
    ) external requiresProposal(proposalId) {
        //Get proposal
        Proposal storage proposal = s_proposals[proposalId];

        //Check voting period
        require(!proposal.ended && proposal.outcome == ProposalOutcome.PENDING, "Proposal is ended");
        require(block.timestamp >= proposal.endTime, "Proposal voting period is still ongoing");

        //Calculate decision
        uint64 yesVotes = proposal.yesVotes;
        uint64 noVotes = proposal.noVotes;
        uint64 totalVotes = yesVotes + noVotes;

        //Check minimum participation
        if (totalVotes == 0 || totalVotes < proposal.quorumThreshold) {
            _rejectProposal(proposal, ProposalOutcome.QUORUM_NOT_MET);
            return;
        }

        //Is it approved?
        uint64 yesPercentage = (yesVotes * 100) / totalVotes;
        if (yesPercentage >= proposal.approvalThresholdPercent) { //Include approval treshold percent in proposal data
            //Approved
            _approveProposal(proposal);
        } else {
            //Rejected
            _rejectProposal(proposal, ProposalOutcome.REJECTED);
        }
    }

    /**
     * @notice Executes an approved proposal after timelock
     * @dev Requires proposal to be approved and pass timelock/expiry checks
     * @dev Restricted functions can only be executed by interim owner
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(
        uint64 proposalId
    ) external nonReentrant requiresProposal(proposalId) {
        //Get proposal
        Proposal storage proposal = s_proposals[proposalId];

        //Proposal should be active and approved
        require(!proposal.ended && proposal.outcome == ProposalOutcome.APPROVED, "Proposal is not approved yet");

        //Check is the function restricted or has a value(sending ETH)
        for (uint256 i = 0; i < proposal.executions.length; i++) {
            ProposalExecution memory execution = proposal.executions[i];
            bool isRestricted = isRestrictedFunction(execution.selector);
            if ((execution.value > 0 || isRestricted) && msg.sender != i_interimOwner) {
                revert("Only interim owner can execute this proposal because target function is restricted, or proposal has value");
            }
        }

        //Check TimeLock
        uint256 timeLock = proposal.endTime + TIMELOCK_DURATION;
        require(block.timestamp >= timeLock, "Proposal can be executed after a day of the approval");
        
        //Check Expire date
        uint256 expireAt = proposal.endTime + EXECUTION_DURATION;
        
        if (block.timestamp >= expireAt) {
            //Set proposal as expired.
            _expireProposal(proposal);
        } else {
            //Execute the proposal
            _executeProposal(proposal);
        }
    }

    /**
     * @notice Updates DAO governance parameters
     * @dev Only callable by the DAO.
     * @param newValue New quorum threshold percentage (5-60)
     */
    function setQuorumThresholdPercent(uint16 newValue) external onlyDAO {
        require(newValue >= 5 && newValue <= 60, "Quorum threshold must be between 5 and 60");

        emit QuorumThresholdPercentUpdated(s_config.quorumThresholdPercent, newValue);
        s_config.quorumThresholdPercent = newValue;
    }

    /**
     * @notice Updates the minimum approval percentage required for proposals
     * @dev Only callable by the DAO.
     * @param newValue New approval threshold percentage (70-90)
     */
    function setApprovalThresholdPercent(uint16 newValue) external onlyDAO {
        require(newValue >= 70 && newValue <= 90, "Approval threshold must be between 70 and 90");

        emit ApprovalThresholdPercentUpdated(s_config.approvalThresholdPercent, newValue);
        s_config.approvalThresholdPercent = newValue;
    }

    /**
     * @notice Updates the number of historical weeks considered for voting power
     * @dev Only callable by the DAO.
     * @param newValue New eligible week count (2-8)
     */
    function setEligibleWeekCount(uint16 newValue) external onlyDAO {
        require(newValue >= 2 && newValue <= 8, "Eligible week count must be between 2 and 8");

        emit EligibleWeekCountUpdated(s_config.eligibleWeekCount, newValue);
        s_config.eligibleWeekCount = newValue;
    }

    /**
     * @notice Updates the maximum rank considered for voting power
     * @dev Only callable by the DAO.
     * @param newValue New maximum rank (100-1000)
     */
    function setVotingMaximumRank(uint16 newValue) external onlyDAO {
        require(newValue >= 100 && newValue <= 1000, "Voting maximum rank must be between 100 and 1000");

        emit VotingMaximumRankUpdated(s_config.votingMaximumRank, newValue);
        s_config.votingMaximumRank = newValue;
    }
    
    /**
     * @notice Updates proposal voting duration parameter
     * @dev Only callable by DAO.
     * @param newValue New voting duration in seconds
     */
    function setVotingDuration(uint64 newValue) external onlyDAO {
        require(newValue >= 3 days && newValue <= 14 days, "Voting duration must be between 3 and 14 days");

        emit VotingDurationUpdated(s_config.votingDuration, newValue);
        s_config.votingDuration = newValue;
    }

    /**
     * @notice Toggles interim governance state
     * @dev Only callable by the DAO.
     * @param isActive New state for interim governance
     */
    function setInterimState(bool isActive) external onlyDAO {
        require(s_config.interimActive != isActive, "State is already in the desired condition");

        s_config.interimActive = isActive;
        emit InterimStateUpdated(isActive);
    }

    /**
     * @notice Toggles trusted targets restriction
     * @dev Only callable by the DAO.
     * @param isOn New state for trusted targets restriction
     */
    function setAllowOnlyTrustedTargets(bool isOn) external onlyDAO {
        require(s_config.allowOnlyTrustedTargets != isOn, "State is already in the desired condition");

        s_config.allowOnlyTrustedTargets = isOn;
        emit AllowOnlyTrustedTargetsUpdated(isOn);
    }

    /**
     * @notice Restricts or unrestricts a function selector for proposal execution
     * @dev Only callable by the DAO. Prevents users from creating/executing proposals with restricted functions.
     * @param selector Function selector as bytes4
     * @param isRestricted Restricted or not
     */
    function setRestrictedFunction(bytes4 selector, bool isRestricted) external onlyDAO {
        require(s_restrictedFunctions[selector] != isRestricted, "State is already in the desired condition");

        s_restrictedFunctions[selector] = isRestricted;
        emit RestrictedFunctionSet(selector, isRestricted);
    }

    function setMaxExecutionsPerProposal(uint16 newValue) external onlyDAO {
        require(newValue >= 1 && newValue <= 10, "Max executions per proposal must be between 1 and 10");

        emit MaxExecutionsPerProposalUpdated(s_config.maxExecutionsPerProposal, newValue);
        s_config.maxExecutionsPerProposal = newValue;
    }

    /**
     * @notice Reactivates interim governance after 2 months of inactivity
     * @dev Can only be called by interim owner when no proposals executed for 60 days
     * @dev Resets interimActive flag and emits InterimStateUpdated event
     */
    function reactivateInterimGovernance() external {
        //Check last proposal execution date
        require(block.timestamp > lastSuccessfulExecutionTime + 60 days, "Interim governance can be activated after 2 months of the last successfull proposal execution");
        require(i_interimOwner == msg.sender, "Only interim governor can reactivate the interim governance");
        require(!s_config.interimActive, "Interim governance is already active");

        //Activate interim governance
        s_config.interimActive = true;
        emit InterimStateUpdated(true);
    }
    
    /**
     * @notice Marks proposal as approved
     * @dev Internal function called when execution period passes
     * @param proposal Proposal to be approved
     */
    function _approveProposal(
        Proposal storage proposal
    ) internal {
        proposal.outcome = ProposalOutcome.APPROVED;
        emit ProposalFinalized(proposal.id, ProposalOutcome.APPROVED);
    }

    /**
     * @dev Marks proposal as rejected and ended
     * @param proposal Proposal to be rejected
     * @param outcome The outcome to be assigned to the proposal.
     */
    function _rejectProposal(
        Proposal storage proposal,
        ProposalOutcome outcome
    ) internal {
        proposal.ended = true;
        proposal.outcome = outcome;
        emit ProposalFinalized(proposal.id, outcome);
    }

    /**
     * @notice Marks proposal as expired and ended
     * @dev Internal function called when execution period passes
     * @param proposal Proposal to be expired
     */
    function _expireProposal(
        Proposal storage proposal
    ) internal {
        proposal.ended = true;
        for (uint256 i = 0; i < proposal.executions.length; i++) {
            proposal.results[i].status = ProposalExecutionStatus.EXPIRED;
        }

        emit ProposalExpired(proposal.id, proposal.title);
    }

    /**
     * @dev Executes a proposal by calling the target contract with the provided function selector and arguments.
     * Sets the proposal as inactive and updates the proposal outcome based on the results of the call.
     * Emits a {ProposalFinalized} event with the proposal ID and outcome.
     * 
     * @param proposal The proposal to be executed.
     */

    function _executeProposal(
        Proposal storage proposal
    ) internal {
        //Set proposal as ended
        proposal.ended = true;

        //Call function
        bool allSucceed = true;
        for (uint256 i = 0; i < proposal.executions.length; i++) {
            ProposalExecution memory execution = proposal.executions[i];
            bytes memory callData = bytes.concat(
                execution.selector,
                execution.args
            );

            (bool success, bytes memory resultBytes) = execution.target.call{value: execution.value}(callData);
            if (!success) {
                allSucceed = false;
            }

            //Set proposal result and outcome
            ProposalExecutionStatus execStatus = success ? ProposalExecutionStatus.SUCCESS : ProposalExecutionStatus.FAILED;
            proposal.results[i].callResult = resultBytes;
            proposal.results[i].status = execStatus;
        }

        //Set last executed proposal
        if (allSucceed) {
            lastSuccessfulExecutionTime = block.timestamp;
        }

        emit ProposalExecuted(proposal.id, proposal.title, msg.sender, allSucceed);
    }

    /**
     * @dev Checks if the user has the right to create a new proposal.
     *      Each user can create at most 4 proposals in a week.
     * @param user The address of the user to check.
     * @notice This function increments the user's proposal counter for the current week.
     */
    function _checkProposalCount(address user) internal {
        uint64 currentWeekId = uint64(i_rewarder.getWeekId());

        uint8 counter = s_weeklyProposalCounter[currentWeekId][user];
        if (i_interimOwner != user) {
            require(counter < 4, "You can create up to 4 proposals per week");
        }
        
        s_weeklyProposalCounter[currentWeekId][user] += 1;
    }

    /**
     * @dev Adds executions to a proposal.
     * @param proposalId The ID of the proposal to which the executions are being added.
     * @param executions An array of ProposalExecution structs containing the details of each execution.
     */
    function _addExecutions(uint256 proposalId, ProposalExecution[] memory executions) internal {
        Proposal storage storedProposal = s_proposals[proposalId];
        for (uint256 i = 0; i < executions.length; i++) {
            storedProposal.executions.push(
                ProposalExecution({
                    target: executions[i].target,
                    selector: executions[i].selector,
                    args: executions[i].args,
                    value: executions[i].value
                })
            );

            storedProposal.results.push(
                ProposalResult({
                    callResult: "0x0",
                    status: ProposalExecutionStatus.NOT_EXECUTED
                })
            );
        }
    }

    /**
     * @notice Calculates the voting power of a user for a specific proposal.
     * @dev This function calculates the voting power based on individual and club rank proofs.
     * @param forUser The address of the user whose voting power is being queried.
     * @param proposalId The ID of the proposal for which the voting power is being calculated.
     * @param individualProofs An array of individual rank proofs for the user.
     * @param clubProofs An array of club rank proofs for the user.
     */
    function getVotingPowerWithProposal(
        address forUser,
        uint64 proposalId,
        IndividualRankProof[] memory individualProofs,
        ClubRankProof[] memory clubProofs
    ) requiresProposal(proposalId) public view returns(uint64) {
        return _calculateVotingPower(forUser, s_proposals[proposalId].maxWeekIndex, s_proposals[proposalId].minWeekIndex, individualProofs, clubProofs);
    }

    /**
     * @notice Retrieves the current voting power of a user.
     * @param forUser The address of the user whose voting power is being queried.
     * @param individualProofs An array of individual rank proofs for the user.
     * @param clubProofs An array of club rank proofs for the user.
     * @return The current voting power of the user.
     */
    function getCurrentVotingPower(
        address forUser,
        IndividualRankProof[] memory individualProofs,
        ClubRankProof[] memory clubProofs
    ) public view returns(uint64) {
        uint64 maxWeekIndex = uint64(i_rewarder.getWeekId());
        uint64 minWeekIndex = calculateMinimumWeekIndex(maxWeekIndex);
        return _calculateVotingPower(forUser, maxWeekIndex, minWeekIndex, individualProofs, clubProofs);
    }

    /**
     * @dev Calculates the quorum threshold based on the total number of individual entries
     *      from a specified week index.
     * @param minWeekIndex The week index from which to start the calculation.
     * @param maxWeekIndex The week index from which to end the calculation.
     * @return quorumThreshold The calculated quorum threshold.
     */
    function calculateQuorumThreshold(uint256 minWeekIndex, uint64 maxWeekIndex) public view returns(uint64) {
        uint256 totalVoteEntries = calculateMaximumVotes(minWeekIndex, maxWeekIndex);
        require(totalVoteEntries > 0, "There is not enough entries to calculate quorum threshold for the proposal");

        uint64 quorumThreshold = uint64((totalVoteEntries * s_config.quorumThresholdPercent) / 100);
        return quorumThreshold;//quorumThreshold > 0 ? quorumThreshold : 1;
    }

    /**
     * @dev Calculates the maximum number of votes based on the total number of individual
     *      and club entries from a specified week index.
     * @param minWeekIndex The week index from which to start the calculation.
     * @param maxWeekIndex The week index from which to end the calculation.
     * @return totalEntries The calculated maximum number of votes.
     */
    function calculateMaximumVotes(uint256 minWeekIndex, uint64 maxWeekIndex) public view returns(uint64) {
        uint64 totalEntries;

        // Only reward holders from the last 'eligibleWeekCount' weeks are eligible to vote
        for (uint256 index = minWeekIndex; index <= maxWeekIndex; index++) {
            uint64 totalNumberOfIndividualEntries = i_rewarder.getWeekTotalNumberOfIndividualEntries(index);
            uint64 totalNumberOfClubEntries = i_rewarder.getWeekTotalNumberOfClubEntries(index);
            totalEntries += totalNumberOfIndividualEntries + totalNumberOfClubEntries;
        }

        // Add interim owner's power
        uint256 interimOwnerPower = (maxWeekIndex - minWeekIndex + 1) * 2;
        totalEntries += uint64(interimOwnerPower);

        return totalEntries;
    }

    /**
     * @notice Calculates the minimum week index that is eligible for voting based on the
     *      specified week index and the eligible week count.
     * @param fromWeekIndex The week index from which to start the calculation.
     * @return minWeek The calculated minimum week index.
     */
    function calculateMinimumWeekIndex(uint256 fromWeekIndex) public view returns(uint64) {
        uint256 minWeek = (fromWeekIndex >= s_config.eligibleWeekCount)
            ? fromWeekIndex - s_config.eligibleWeekCount + 1
            : 0;
        
        return uint64(minWeek);
    }

    /**
     * @notice Verifies the proof of an individual's rank within a specified week range.
     * @param forUser The address of the user whose rank proof is being verified.
     * @param proof The proof containing the week index and rank of the user.
     * @param minWeekIndex The minimum week index within which the proof is considered eligible.
     * @param maxWeekIndex The maximum week index within which the proof is considered eligible.
     * @return bool Returns true if the proof is valid, otherwise false.
     */
    function verifyIndividualRankProof(address forUser, IndividualRankProof memory proof, uint64 minWeekIndex, uint64 maxWeekIndex) public view returns(bool) {
        // Check week index has power to vote on this proposal, and the owner of the rank
        return (
            proof.weekIndex >= minWeekIndex &&
            proof.weekIndex <= maxWeekIndex &&
            proof.rank <= s_config.votingMaximumRank &&
            i_rewarder.getIndividualRankHolder(proof.weekIndex, proof.rank) == forUser
        );
    }

    /**
     * @notice Verifies the proof of an club's member rank within a specified week range.
     * @param forUser The address of the user whose rank proof is being verified.
     * @param proof The proof containing the week index and club rank of the user.
     * @param minWeekIndex The minimum week index within which the proof is considered eligible.
     * @param maxWeekIndex The maximum week index within which the proof is considered eligible.
     * @return bool Returns true if the proof is valid, otherwise false.
     */
    function verifyClubRankProof(address forUser, ClubRankProof memory proof, uint64 minWeekIndex, uint64 maxWeekIndex) public view returns(bool) {
        // Check week index has power to vote on this proposal, and the owner of the rank
        // Only leaders of the clubs can have the vote power
        return (
            proof.weekIndex >= minWeekIndex &&
            proof.weekIndex <= maxWeekIndex &&
            proof.clubRank <= s_config.votingMaximumRank &&
            proof.memberRank == 1 &&
            i_rewarder.getClubRankHolder(proof.weekIndex, proof.clubRank, proof.memberRank) == forUser
        );
    }

    function getProposalCount() external view returns(uint256) {
        return s_proposals.length;
    }

    /**
     * @notice Retrieves a proposal by ID.
     * @param proposalId The ID of the proposal to get.
     * @return Proposal struct containing all details of the proposal.
     */
    function getProposal(uint64 proposalId) requiresProposal(proposalId) external view returns(Proposal memory) {
        return s_proposals[proposalId];
    }

    function getQuorumThreshold(uint64 proposalId) requiresProposal(proposalId) external view returns(uint64) {
        return s_proposals[proposalId].quorumThreshold;
    }

    function getYesPercentage(uint64 proposalId) requiresProposal(proposalId) external view returns(uint256) {
        uint256 totalVotes = s_proposals[proposalId].yesVotes + s_proposals[proposalId].noVotes;
        uint256 yesPercentage = (s_proposals[proposalId].yesVotes * 100) / totalVotes;
        return yesPercentage;
    }

    function getUserVote(uint64 proposalId, address user) external view returns(UserVote memory) {
        return s_userVotesByProposal[proposalId][user];
    }

    function isUserVoted(uint64 proposalId, address user) external view returns(bool) {
        return s_userVotesByProposal[proposalId][user].decision == ProposalDecision.NOT_VOTED ? false : true;
    }

    function isProposalEnded(uint64 proposalId) external view returns(bool) {
        return s_proposals[proposalId].ended;
    }

    function isProposalVotingOngoing(uint64 proposalId) external view returns(bool) {
        Proposal storage proposal = s_proposals[proposalId];
        return (proposal.outcome == ProposalOutcome.PENDING && !proposal.ended && block.timestamp < proposal.endTime);
    }

    function getMaximumVotes(uint64 proposalId) requiresProposal(proposalId) external view returns(uint64) {
        return calculateMaximumVotes(s_proposals[proposalId].minWeekIndex, s_proposals[proposalId].maxWeekIndex);
    }

    /**
     * @notice Returns current DAO configuration parameters
     * @return DAOConfig struct containing all governance settings
     */
    function getDAOConfig() external view returns (DAOConfig memory) {
        return s_config;
    }

    /**
     * @notice Returns the number of active proposals.
     */
    function getActiveProposalCount() external view returns(uint256 activeProposalCount) {
        uint256 count = 0;
        for (uint256 i = 0; i < s_proposals.length; i++) {
            if (!s_proposals[i].ended) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Returns the list of proposal IDs created by a user
     * @param user Address of the user to check
     * @return Array of proposal IDs created by the user
     */
    function getUserProposals(address user) external view returns(uint64[] memory) {
        return s_userProposals[user];
    }

    /**
     * @notice Checks if function selector is restricted
     * @dev Includes both DAO-defined and protocol-default restrictions
     * @param selector Function selector as bytes4
     */
    function isRestrictedFunction(bytes4 selector) public view returns(bool) {
        return (
            s_restrictedFunctions[selector] == true ||
            i_token.transfer.selector == selector ||
            i_token.transferFrom.selector == selector ||
            i_token.approve.selector == selector ||
            i_token.burn.selector == selector ||
            i_token.updateRewarderAddress.selector == selector ||
            i_rewarder.transferERC20ToTreasury.selector == selector
        );
    }

    /**
     * @notice Calculates the voting power for a range of weeks based on provided proofs.
     * @param forUser for which address
     * @param maxWeekIndex maximum allowed week index of the proposal.
     * @param minWeekIndex minimum allowed week index of the proposal.
     * @param individualProofs Array of individual rank proofs.
     * @param clubProofs Array of club rank proofs.
     * @return votingPower The total voting power (number of valid proofs).
     */
    function _calculateVotingPower(
        address forUser,
        uint64 maxWeekIndex,
        uint64 minWeekIndex,
        IndividualRankProof[] memory individualProofs,
        ClubRankProof[] memory clubProofs
    ) internal view returns(uint64 votingPower) {
        // Interim owner has the maximum power of users can have
        if (forUser == i_interimOwner) {
            uint64 interimVotingPower = (maxWeekIndex - minWeekIndex + 1) * 2;
            return interimVotingPower;
        }

        // Individual rank proofs
        for (uint256 i = 0; i < individualProofs.length; i++) {
            IndividualRankProof memory proof = individualProofs[i];

            // Check for duplicated entries
            for (uint256 j = i + 1; j < individualProofs.length; j++) {
                require(!_isIndividualRankProofEqual(individualProofs[i], individualProofs[j]), "Rank proof has been already used in this proposal");
            }

            // Verify and apply power
            if (verifyIndividualRankProof(forUser, proof, minWeekIndex, maxWeekIndex)) {
                votingPower += 1;
            }
        }
        
        // Club rank proofs
        for (uint256 i = 0; i < clubProofs.length; i++) {
            ClubRankProof memory proof = clubProofs[i];

            // Check for duplicated entries
            for (uint256 j = i + 1; j < clubProofs.length; j++) {
                require(!_isClubRankProofEqual(clubProofs[i], clubProofs[j]), "Rank proof has been already used in this proposal");
            }

            // Verify and apply power
            if (verifyClubRankProof(forUser, proof, minWeekIndex, maxWeekIndex)) {
                votingPower += 1;
            }
        }
        
        return votingPower;
    }

    /**
     * @notice Encodes all proposal executions into a single bytes32 hash.
     * @dev Hashes the concatenated target, selector, args, and value of each execution.
     * @param executions An array of ProposalExecution structs containing the details of each execution.
     * @return bytes32 The resulting hash of the encoded executions.
     */
    function _calculateProposalHash(
        ProposalExecution[] memory executions
    ) internal pure returns (bytes32) {
        bytes memory allData;
        for (uint256 i = 0; i < executions.length; i++) {
            allData = bytes.concat(allData, abi.encode(executions[i]));
        }
        return keccak256(allData);
    }

    function _isIndividualRankProofEqual(IndividualRankProof memory a, IndividualRankProof memory b) internal pure returns (bool) {
        return (a.weekIndex == b.weekIndex && a.rank == b.rank);
    }

    function _isClubRankProofEqual(ClubRankProof memory a, ClubRankProof memory b) internal pure returns (bool) {
        return (a.weekIndex == b.weekIndex && a.clubRank == b.clubRank && a.memberRank == b.memberRank);
    }

    receive() external payable { }
}