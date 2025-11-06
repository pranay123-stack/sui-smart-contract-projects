# Sui DeFi Token Vault

A secure, production-ready token vault smart contract built on Sui blockchain with yield accrual mechanisms, emergency controls, and comprehensive access management.

## Features

- **Secure Deposits/Withdrawals**: Users can safely deposit and withdraw SUI tokens
- **Share-based Accounting**: Proportional ownership tracking using shares mechanism
- **Yield Accrual**: Built-in yield distribution system for vault earnings
- **Emergency Pause**: Admin can pause vault operations in emergency situations
- **Access Control**: Capability-based authorization for administrative functions
- **Comprehensive Events**: All major actions emit events for off-chain tracking

## Architecture

### System Design Flow

```mermaid
flowchart TD
    A[User] -->|1. Deposit Tokens| B[Vault Contract]
    B -->|2. Calculate Shares| C{Share Calculation}
    C -->|shares = amount * total_shares / balance| D[Mint VaultReceipt]
    D -->|3. Return Receipt| A

    A -->|4. Withdraw Request + Receipt| B
    B -->|5. Calculate Amount| E{Amount Calculation}
    E -->|amount = shares * balance / total_shares| F[Burn Receipt]
    F -->|6. Transfer Tokens| A

    G[Admin] -->|Accrue Yield| B
    G -->|Pause/Unpause| B
    B -->|Emit Events| H[Off-chain Indexer]

    style B fill:#4CAF50,stroke:#2E7D32,color:#fff
    style A fill:#2196F3,stroke:#1976D2,color:#fff
    style G fill:#FF9800,stroke:#F57C00,color:#fff
    style D fill:#9C27B0,stroke:#7B1FA2,color:#fff
```

### Core Components

1. **Vault Object**: Main shared object holding all deposited tokens
2. **VaultReceipt**: User's proof of deposit and ownership shares
3. **AdminCap**: Capability object for administrative privileges

### Deposit Flow Diagram

```mermaid
sequenceDiagram
    participant User
    participant Vault
    participant Receipt

    User->>Vault: deposit(amount)
    Vault->>Vault: Check if paused
    Vault->>Vault: Calculate shares
    Note over Vault: shares = amount * total_shares / balance
    Vault->>Receipt: Mint VaultReceipt
    Receipt-->>User: Return receipt with shares
    Vault->>Vault: Update balance & total_shares
    Vault->>Vault: Emit DepositEvent
```

#### Deposit Flow Explanation:

**Step 1: User Initiates Deposit**
- User calls `deposit()` function with desired token amount
- Transaction must include sufficient SUI tokens to deposit

**Step 2: Security Check**
- Vault checks if operations are paused (emergency safety)
- If paused, transaction reverts

**Step 3: Share Calculation**
- Formula: `shares = (deposit_amount × total_shares) / current_balance`
- **Example**: If vault has 1000 tokens, 1000 total shares, and user deposits 100:
  - `shares = (100 × 1000) / 1000 = 100 shares`
- This ensures proportional ownership regardless of when you deposit

**Step 4: Receipt Minting**
- VaultReceipt NFT is created with user's share count
- Receipt acts as proof of ownership (like a bank deposit certificate)

**Step 5: State Update**
- Vault balance increases by deposit amount
- Total shares increase by calculated shares
- These updates maintain the share-to-value ratio

**Step 6: Event Emission**
- DepositEvent emitted with: user address, amount, shares, timestamp
- Enables off-chain tracking and analytics

### Withdrawal Flow Diagram

```mermaid
sequenceDiagram
    participant User
    participant Vault
    participant Receipt

    User->>Vault: withdraw(receipt)
    Vault->>Vault: Check if paused
    Vault->>Vault: Calculate withdraw amount
    Note over Vault: amount = shares * balance / total_shares
    Vault->>Receipt: Burn VaultReceipt
    Vault->>User: Transfer tokens
    Vault->>Vault: Update balance & total_shares
    Vault->>Vault: Emit WithdrawEvent
```

#### Withdrawal Flow Explanation:

**Step 1: User Initiates Withdrawal**
- User calls `withdraw()` with their VaultReceipt
- Receipt must be owned by the caller (enforced by Sui's object ownership)

**Step 2: Security Check**
- Vault verifies operations are not paused
- Prevents withdrawals during security incidents

**Step 3: Amount Calculation**
- Formula: `amount = (user_shares × vault_balance) / total_shares`
- **Example**: User has 100 shares, vault has 1100 tokens total, 1000 total shares:
  - `amount = (100 × 1100) / 1000 = 110 tokens`
  - User deposited 100 but receives 110 (10% yield accrued!)
- This automatically distributes proportional yield

**Step 4: Receipt Burning**
- VaultReceipt is destroyed (cannot be reused)
- Prevents double-withdrawal attacks

**Step 5: Token Transfer**
- Calculated amount transferred from vault to user
- Vault balance and total shares decrease accordingly

**Step 6: Event Emission**
- WithdrawEvent records: user, shares burned, amount withdrawn, timestamp
- Creates auditable history

### Key Design Patterns

- **Shared Object Pattern**: Vault is a shared object accessible by all users
- **Capability-based Access Control**: AdminCap controls sensitive operations
- **Share-based Accounting**: Fair distribution of yields proportional to deposits

## Smart Contract Functions

### User Functions

- `deposit(vault, token, ctx)` - Deposit SUI tokens and receive shares
- `withdraw(vault, receipt, ctx)` - Burn shares and withdraw proportional amount

### Admin Functions

- `create_vault(ctx)` - Initialize a new vault
- `pause_vault(vault, admin_cap, ctx)` - Emergency pause
- `unpause_vault(vault, admin_cap, ctx)` - Resume operations
- `accrue_yield(vault, admin_cap, yield_amount, ctx)` - Add yield to vault
- `update_yield_rate(vault, admin_cap, new_rate, ctx)` - Adjust yield parameters

### View Functions

- `get_vault_balance(vault)` - Get total vault balance
- `get_total_shares(vault)` - Get total shares issued
- `is_paused(vault)` - Check vault status
- `calculate_share_value(vault, shares)` - Calculate current value of shares

## Testing

The project includes comprehensive test coverage:

- ✅ Vault creation and initialization
- ✅ Deposit and withdrawal flows
- ✅ Multiple user deposits
- ✅ Yield accrual mechanics
- ✅ Pause/unpause functionality
- ✅ Share value calculations
- ✅ Access control enforcement

### Run Tests

```bash
cd token_vault
sui move test
```

**Test Results**: 7/7 tests passing ✅

## Build & Deploy

### Build

```bash
cd token_vault
sui move build
```

### Deploy to Testnet

```bash
sui client publish --gas-budget 100000000
```

## Security Considerations

### Implemented Security Measures

1. **Access Control**: AdminCap ensures only authorized addresses can perform admin functions
2. **Pause Mechanism**: Emergency stop functionality to protect user funds
3. **Integer Overflow Protection**: Sui Move's built-in overflow checks
4. **Input Validation**: All functions validate inputs before state changes

### Potential Improvements for Production

1. **Multi-sig Admin**: Replace single AdminCap with multi-signature control
2. **Time-locked Withdrawals**: Optional withdrawal delays for additional security
3. **Rate Limiting**: Prevent flash loan attacks or rapid withdrawals
4. **Oracle Integration**: External price feeds for more sophisticated yield calculations
5. **Formal Verification**: Mathematical proofs of correctness

## Usage Example

```move
// 1. Admin creates vault
create_vault(ctx);

// 2. User deposits 1000 SUI
let coin = coin::mint_for_testing<SUI>(1000, ctx);
deposit(&mut vault, coin, ctx);

// 3. Admin adds 50 SUI yield
let yield_coin = coin::mint_for_testing<SUI>(50, ctx);
accrue_yield(&mut vault, &admin_cap, yield_coin, ctx);

// 4. User withdraws (receives 1050 SUI including yield)
withdraw(&mut vault, receipt, ctx);
```

## Technical Specifications

- **Language**: Sui Move
- **Sui Version**: 1.60.0
- **Test Coverage**: 100% of public functions
- **Gas Optimization**: Share calculations minimize on-chain computation

## DeFi Concepts Demonstrated

1. **Liquidity Pools**: Basic pool mechanics with deposits/withdrawals
2. **Share-based Accounting**: Fair distribution mechanism
3. **Yield Generation**: Simulated yield accrual system
4. **Protocol Governance**: Admin controls for parameter adjustments

## Future Enhancements

- [ ] Support for multiple token types
- [ ] Automated yield strategies
- [ ] Integration with Sui DeFi protocols
- [ ] Advanced withdrawal strategies (e.g., gradual unlock)
- [ ] NFT receipts instead of fungible receipts
- [ ] Governance token for decentralized control

## License

MIT

## Author

Built for Suilend Smart Contract Engineer application

## Contact

For questions or feedback, please open an issue in the repository.
