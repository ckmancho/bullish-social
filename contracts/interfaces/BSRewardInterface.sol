// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface BSRewardInterface {
    function getIndividualRankHolder(uint64 weekIndex, uint64 rank) external view returns(address);
    function getIndividualRankScore(uint64 weekIndex, uint64 rank) external view returns(uint256);
    function getClubRankHolder(uint64 weekIndex, uint64 clubRank, uint64 memberRank) external view returns(address);
    function getWeekId() external view returns(uint256);
    function getWeekCount() external view returns(uint256);
    function getWeekTotalNumberOfIndividualEntries(uint256 weekIndex) external view returns(uint64);
    function getWeekTotalNumberOfClubEntries(uint256 weekIndex) external view returns(uint64);
    function isUserBanned(address user) external view returns(bool);
    
    function transferERC20ToTreasury(address erc20, uint256 amount) external;
}