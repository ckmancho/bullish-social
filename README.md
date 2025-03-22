# Bullish Social Ecosystem Smart Contracts

This repository contains the smart contracts for the Bullish Social ecosystem, including decentralized governance, reward distribution, and the native ERC-20 token. Below is a brief overview of each contract and its functionality.

## Contracts Overview

### 1. BSGovernor Contract: Decentralized On-chain Governance
The BSGovernor contract facilitates decentralized decision-making for protocol upgrades, parameter adjustments, and critical operations. It combines liquid democracy with timelocked execution for security-sensitive actions. Key features include:

- **Proposal Lifecycle**: Proposals go through creation, voting, finalization, and execution stages.
- **Voting Power**: Derived from historical leaderboard ranks (individual and club).
- **Interim Governance**: A transitional mode for bootstrapping, allowing the interim governor to fast-track proposals.
- **Restricted Functions**: Critical functions (e.g., token transfers) are restricted for enhanced security.

### 2. BSReward Contract: Decentralized Reward Distribution System
The BSReward contract distributes BUSO tokens to users based on their weekly performance in individual and club leaderboards. Key features include:

- **Weekly Reward Cycles**: Rewards are distributed weekly using Merkle proofs for off-chain data validation.
- **Dynamic Reward Tiers**: DAO-controlled reward tiers and parameters.
- **Security Mechanisms**: On-chain bans for abusive users/clubs, reentrancy guards, and nonce checks.
- **Reward Distribution**: Individual and club rewards are calculated based on rank and performance.

### 3. BSToken Contract: Native ERC-20 Token
The BSToken contract is the foundational ERC-20 token for the Bullish Social ecosystem. Key features include:

- **Tokenomics**: Fixed maximum supply of 256,000,000 tokens with predefined distribution percentages.
- **Vesting Mechanism**: Tokens allocated to team, marketing, and partners are locked in vesting wallets.

## Usage

### BSGovernor
- `createProposal`: Submit a proposal with target contract, function selector, and arguments.
- `castVote`: Vote on active proposals using rank proofs.
- `finalizeProposal`: Finalize proposals after the voting period.
- `executeProposal`: Execute approved proposals post-timelock.

### BSReward
- `addWeekData`: Initialize a new week with Merkle root.
- `useSnapshot`: Claim rewards using Merkle-validated snapshots.
- `calculateRewardPiece`: Compute reward allocation based on rank and performance.

### BSToken
- `initialize`: Distribute tokens to specified addresses during contract deployment.
- `setTrustedAddress`: Set or unset a trusted address (governor only).

## Security

- **Reentrancy Protection**: All contracts are secured against reentrancy attacks.
- **Restricted Functions**: Critical functions are restricted to trusted addresses or the interim governor.
- **On-chain Bans**: Abusive users and clubs can be banned from claiming rewards.

## License
This project is licensed under the MIT License. See the LICENSE file for details.

## Contact
For any questions or support, please reach out to us at [support@bullish.social](mailto:support@bullish.social).
