// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { VestingWallet } from "@openzeppelin/contracts/finance/VestingWallet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title ERC20 Token contract for the Bullish Social ecosystem
 * @author ckmancho
 * 
 * Official Links:
 * - Website: https://bullish.social
 * - Twitter: https://x.com/bullishsocial 
 * - Documentation: https://docs.bullish.social
 */
contract BSToken is ERC20, ERC20Burnable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    //Supply
    uint256 constant private MAX_SUPPLY = 256000000 * 1e18;
    uint256 public totalBurned;
    
    //Initial supply distribution
    uint8 constant private REWARD_PERCENTAGE = 50;
    uint8 constant private LIQUIDITY_PERCENTAGE = 15;
    uint8 constant private TEAM_PERCENTAGE = 15;
    uint8 constant private MARKETING_PERCENTAGE = 10;
    uint8 constant private TREASURY_PERCENTAGE = 5;
    uint8 constant private PARTNERS_PERCENTAGE = 3;
    uint8 constant private AFFILIATE_ACTIVITY_PERCENTAGE = 2;

    //Data
    uint64 immutable private i_initialTimestamp;
    address private s_governorAddress;
    address private s_rewarderAddress;
    bool private s_initialized;

    /* TRUSTED ADDRESSES FOR GOVERNOR */
    mapping(address => bool) private s_trustedAddresses;

    /* EVENTS */
    event TrustedAddressSet(address indexed target, bool indexed isTrusted);
    event VestingWalletSet(address indexed target, address indexed beneficiary, uint256 indexed amount, uint64 startTimestamp, uint64 durationSeconds);

    /* ERRORS */
    error BS__OnlyRewarderAllowed(address rewarderContractAddress);
    error BS__OnlyGovernorAllowed(address governorContractAddress);
    error BS__InsufficientBalance(uint256 balance, uint256 missingAmount);

    /* MODIFIERS */
    modifier onlyGovernor() {
        if (msg.sender != s_governorAddress) revert BS__OnlyGovernorAllowed(s_governorAddress);
        _;
    }

    /*  TOKENOMICS
        - Total Supply: 256,000,000
        - Reward & Incentives: %50
        - Liquidity & Fair launch: %15
        - Team members: %15
        - Marketing: %10
        - Treasury: %5
        - Partners: %3
        - Affiliate & Activity Rewards: %2
    */
    constructor () ERC20("Bullish Social", "BUSO") Ownable(msg.sender) {
        i_initialTimestamp = uint64(block.timestamp);
        s_trustedAddresses[address(this)] = true;
    }

    /**
     * @notice Initializes the contract by distributing tokens to specified addresses.
     * @dev This function can only be called once by the owner.
     */
    function initialize(
        address governorAddress,
        address rewarderAddress,
        address teamMembersAddress,
        address marketingAddress,
        address partnersAddress
    ) external onlyOwner nonReentrant {
        address zero = address(0);
        require(!s_initialized, "Already initialized");
        require(
            governorAddress != zero &&
            rewarderAddress != zero &&
            teamMembersAddress != zero &&
            marketingAddress != zero &&
            partnersAddress != zero,
            "Invalid address"
        );

        s_initialized = true;
        s_governorAddress = governorAddress;
        s_rewarderAddress = rewarderAddress;

        /* Initial mint */
        {
            //Reward & Incentives (%50)
            mint(rewarderAddress, _calculateSupply(REWARD_PERCENTAGE));

            //Liquidity & Fair launch (%15)
            mint(msg.sender, _calculateSupply(LIQUIDITY_PERCENTAGE));
            
            //Governor Treasury (%5), Initial Affiliate and Activity will be stored in treasury (%2)
            mint(governorAddress, _calculateSupply(TREASURY_PERCENTAGE));
            mint(governorAddress, _calculateSupply(AFFILIATE_ACTIVITY_PERCENTAGE));

            //Vesting (Team members %15, Marketing %10, Partners %3)
            _setVesting(teamMembersAddress, _calculateSupply(TEAM_PERCENTAGE), i_initialTimestamp + 180 days, 365 days);
            _setVesting(marketingAddress, _calculateSupply(MARKETING_PERCENTAGE), i_initialTimestamp, 545 days);
            _setVesting(partnersAddress, _calculateSupply(PARTNERS_PERCENTAGE), i_initialTimestamp + 180, 545 days);
        }

        _setTrustedAddress(governorAddress, true);
        _setTrustedAddress(rewarderAddress, true);
    }

    /**
     * @notice Burns a specified amount of tokens from the caller's balance.
     * @param amount The amount of tokens to burn.
     */
    function burn(uint256 amount) public override {
        uint256 balance = balanceOf(msg.sender);
        if (balance < amount) {
            revert BS__InsufficientBalance(balance, amount - balance);
        }

        totalBurned += amount;
        _burn(msg.sender, amount);
    }

    /**
     * @notice Sets a trusted address.
     * @dev Only callable by the governor.
     * @param addr The address to set as trusted.
     * @param isTrusted Whether the address should be trusted or not.
     */
    function setTrustedAddress(address addr, bool isTrusted) external onlyGovernor {
        require(addr != address(0), "Invalid address");
        require(addr != s_governorAddress && addr != s_rewarderAddress, "Restricted address");
        
        _setTrustedAddress(addr, isTrusted);
    }

    /**
     * @notice Updates the rewarder address.
     * @dev Only callable by the governor.
     * @param addr The address to set as rewarder.
     */
    function updateRewarderAddress(address addr) external onlyGovernor {
        require(s_initialized, "Cannot change the address before initializing the token");
        require(addr != address(0), "Invalid address");

        s_rewarderAddress = addr;
        _setTrustedAddress(addr, true);
    }

    /**
     * @notice Allows the governor to recover any ERC20 tokens or ETH sent to this contract by mistake.
     * @dev Only callable by the governor.
     * @param tokenAddress Address of the ERC20 token to recover (use address(0) for ETH).
     */
    function recoverStuckTokens(address tokenAddress) public onlyGovernor nonReentrant {
        require(s_governorAddress != address(0), "Governor address is not set");

        // Is the token address zero? If so, we will transfer ETH.
        if (tokenAddress == address(0)) {
            // Transfer ETH to the governor address.
            (bool success, ) = s_governorAddress.call{value: address(this).balance}("");
            require(success, "ETH transfer failed");
        } else {
            // Transfer the specified ERC20 token to the treasury.
            IERC20 token = IERC20(tokenAddress);
            uint256 balance = token.balanceOf(address(this));
            token.safeTransfer(s_governorAddress, balance);
        }
    }

    function maxSupply() public pure returns(uint256) {
        return MAX_SUPPLY;
    }

    function rewardSupply() external view returns(uint256) {
        return balanceOf(s_rewarderAddress);
    }

    function treasuryBalance() external view returns(uint256) {
        return balanceOf(s_governorAddress);
    }

    function getGovernorAddress() external view returns(address) {
        return s_governorAddress;
    }

    function getRewarderAddress() external view returns(address) {
        return s_rewarderAddress;
    }

    /**
     * @notice Checks if an address is trusted.
     * @param addr The address to check.
     * @return Whether the address is trusted or not.
     */
    function isTrustedAddress(address addr) external view returns(bool) {
        return s_trustedAddresses[addr];
    }

    /* PRIVATE FUNCTIONS */
    
    /// @notice Mint function is called only during initialize function
    function mint(address to, uint256 amount) private {
        require((totalSupply() + amount) <= maxSupply(), "BS__MaxSupplyReached");
        _mint(to, amount);
    }

    /**
     * @notice Sets or unsets a trusted address.
     * @param addr The address to set or unset as trusted.
     * @param isTrusted Whether the address should be trusted or not.
     */
    function _setTrustedAddress(address addr, bool isTrusted) private {
        s_trustedAddresses[addr] = isTrusted;
        emit TrustedAddressSet(addr, isTrusted);
    }

    /**
     * @notice Creates a vesting wallet and mints tokens to it.
     * @dev Only callable in the initialize function.
     * @param addr The beneficiary address of the vesting wallet.
     * @param amount The amount of tokens to vest.
     * @param startTimestamp The start timestamp of the vesting period.
     * @param durationSeconds The duration of the vesting period in seconds.
     */
    function _setVesting(address addr, uint256 amount, uint64 startTimestamp, uint64 durationSeconds) private {
        VestingWallet vesting = new VestingWallet(addr, startTimestamp, durationSeconds);
        address vestingAddress = address(vesting);
        mint(vestingAddress, amount);
        _setTrustedAddress(vestingAddress, true);

        emit VestingWalletSet(vestingAddress, addr, amount, startTimestamp, durationSeconds);
    }

    /**
     * @notice Calculates the token amount based on a percentage of the maximum supply.
     * @param percent The percentage of the maximum supply to calculate.
     * @return The calculated token amount.
     */
    function _calculateSupply(uint64 percent) private pure returns(uint256) {
        return (MAX_SUPPLY * percent) / 100;
    }
}