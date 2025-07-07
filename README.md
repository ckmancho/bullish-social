# Bullish Social Ecosystem Smart Contracts

This repository contains the smart contracts for the Bullish Social ecosystem, featuring advanced decentralized governance, leaderboard-based reward distribution, and the BUSO ERC-20 token. Below is a overview of each contract and its basic functionality.

## Project Links  
- **Website**: [https://bullish.social](https://bullish.social)
- **Documentation/Whitepaper**: [https://docs.bullish.social](https://docs.bullish.social)  
- **X (Twitter)**: [https://x.com/bullishsocial](https://x.com/bullishsocial)  

## Contracts Overview

### 1. BSGovernor Contract: Advanced On-chain Governance System
The BSGovernor contract implements decentralized decision-making for protocol upgrades, parameter adjustments, and critical operations. It combines liquid democracy with timelocked execution for security-sensitive actions. Key features include:

- **Proposal Lifecycle**: Proposals go through creation, voting, finalization, timelock, and execution stages.
- **Voting Power**: Derived from historical leaderboard ranks (individual and club).
- **Interim Governance**: Special bootstrap mode with emergency reactivation after 60 days of inactivity
- **Restricted Functions**: Critical functions (e.g., token transfers) are restricted for enhanced security.
- **DAO-Configurable Parameters**:
  - Quorum thresholds (5-60%)
  - Approval thresholds (70-90%)
  - Eligible historical weeks (2-8)
  - Maximum rank considered eligible to vote (100-1000)
  - and more...

### 2. BSReward Contract: Decentralized Reward Distribution System
The BSReward contract distributes BUSO tokens based on weekly individual and club leaderboard rankings with Merkle-proof validation. Key features include:

- **Weekly Reward Cycles**: Rewards are distributed weekly using Merkle proofs for off-chain data validation.
- **Dynamic Reward Tiers**: DAO-controlled reward tiers and parameters. 
- **Security Mechanisms**: On-chain bans for abusive users/clubs, reentrancy guards, and nonce checks.
- **Reward Distribution**: Individual and club rewards are calculated based on rank and performance.
- **DAO Controls**:
  - Adjustable reward levels
  - Configurable individual/club reward ratios
  - Score weight adjustments
  - Maximum club size settings
  - and more...

### 3. BSToken Contract: Native ERC-20 Token
The BSToken contract implements the BUSO token with comprehensive vesting and governance integration. Key features include:

- **Tokenomics**:
  - Fixed max supply: 256,000,000 BUSO
  - Initial distribution:
    - 50% Rewards & Incentives
    - 15% Liquidity & Fair Launch
    - 15% Team (initial on-chain vested)
    - 10% Marketing (initial on-chain vested)
    - 5% Treasury
    - 3% Partners (initial on-chain vested)
    - 2% Initial Affiliate & Activity Rewards

- **Governance Integration**:
  - Trusted address system
  - Governor-controlled functions
  - Rewarder contract management

## Usage

### BSGovernor
- `createProposal`: Submit proposals with multiple executions
- `castVote`: Vote on active proposals using rank proofs.
- `finalizeProposal`: Determine proposal voting outcome after voting
- `executeProposal`: Execute approved proposals post-timelock
- `reactivateInterimGovernance`: Emergency reactivation after inactivity

### BSReward
- `addWeekData`: Initialize new reward week with Merkle root and weekly metadata
- `useSnapshot`: Claim rewards using snapshots and Merkle Proofs

### BSToken
- `initialize`: Initialize token distribution
- `setTrustedAddress`: Set or unset a trusted address (governor only).

## Security Architecture
- **Reentrancy Protection**: All state-changing functions secured
- **Restricted Functions**:
  - Critical token operations (transfers, burns)
  - Rewarder contract updates
  - Treasury withdrawals
  - More with DAO-Controlled mapping
- **Multi-Layered Access Control**:
  - Owner-restricted initialization
  - Governor-only administrative functions
  - Signer-validated week data
- **Verification Systems**:
  - Merkle proofs for off-chain data
  - Rank proof validation
  - Nonce checks: Implements a commit-reveal scheme
- **Emergency Safeguards**:
  - Proposal time locks
  - Execution windows
  - Interim governance fallback
- **On-chain Bans**: Abusive users and clubs can be banned from claiming rewards by the DAO

## License
This project is licensed under the MIT License. See the LICENSE file for details.

## Contact
For any questions or support, please reach out to us at [support@bullish.social](mailto:support@bullish.social).
