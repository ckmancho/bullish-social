// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface BSTokenInterface is IERC20 {
    function getGovernorAddress() external view returns(address);
    function getRewarderAddress() external view returns(address);
    function rewardSupply() external view returns(uint256);
    function isTrustedAddress(address addr) external view returns(bool);
    function burn(uint256 amount) external;
    function updateRewarderAddress(address addr) external;
}