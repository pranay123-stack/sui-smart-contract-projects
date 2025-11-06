// ============================================================================================================
// Token Vault Module - Production-Ready DeFi Vault
// ============================================================================================================
//
// MODULE OVERVIEW:
// This module implements a secure, share-based token vault similar to Yearn Finance vaults or Aave aTokens.
// Users deposit tokens and receive proportional shares. When the vault earns yield, the value per share
// increases automatically, distributing profits fairly among all depositors.
//
// KEY FEATURES:
// 1. Share-Based Accounting: Fair distribution of yields using proportional ownership
// 2. Yield Accrual: Automatic yield distribution when admin adds profits
// 3. Emergency Pause: Admin can halt operations during security incidents
// 4. Capability-Based Access Control: Secure admin functions using AdminCap
// 5. Event Emissions: Complete audit trail for off-chain tracking
//
// ARCHITECTURE:
// - Vault: Shared object holding all deposited tokens
// - VaultReceipt: NFT proof of deposit, required for withdrawal
// - AdminCap: Capability object for administrative privileges
//
// MATH & FORMULAS:
// - Deposit shares: shares = (amount × total_shares) / vault_balance
// - Withdrawal amount: amount = (shares × vault_balance) / total_shares
// - Share value: value_per_share = vault_balance / total_shares
//
// SECURITY CONSIDERATIONS:
// - Overflow protection: All arithmetic uses checked operations
// - Access control: Only AdminCap holder can pause or accrue yield
// - Reentrancy safety: State updates before external calls
// - Emergency controls: Pause mechanism for incident response
//
// USE CASES:
// - Yield aggregator (auto-compound across protocols)
// - DAO treasury management
// - Institutional crypto savings
// - DeFi savings account
// - Liquidity mining aggregator
//
// AUTHOR: Pranay Gaurav
// VERSION: 1.0.0
// LICENSE: MIT
//
// ============================================================================================================

module token_vault::vault {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::event;

    // ======== Error Codes ========
    const ENotAuthorized: u64 = 1;        // Error: Caller lacks required permissions (AdminCap)
    const EVaultPaused: u64 = 2;          // Error: Vault is currently paused for safety
    const EInsufficientBalance: u64 = 3;  // Error: Vault doesn't have enough tokens for withdrawal
    const EInvalidAmount: u64 = 4;        // Error: Deposit amount must be greater than 0
    const EAlreadyPaused: u64 = 5;        // Error: Vault is already paused
    const ENotPaused: u64 = 6;            // Error: Vault is not paused (cannot unpause)

    // ======== Constants ========
    const YIELD_RATE_PRECISION: u64 = 10000; // Precision for yield rate calculations (10000 = 100.00%)
    const DEFAULT_YIELD_RATE: u64 = 500;     // Default annual yield rate: 5% (500/10000 = 0.05)

    // ======== Structs ========

    /// The main vault object that holds all deposited tokens and tracks shares
    ///
    /// Similar to Yearn Finance vaults, this uses share-based accounting where:
    /// - Users deposit tokens and receive shares
    /// - Yield increases vault balance without changing total shares
    /// - Share value automatically increases as vault balance grows
    public struct Vault has key {
        id: UID,                   // Unique identifier for this vault
        balance: Balance<SUI>,     // Total SUI tokens held in vault (increases with deposits and yield)
        total_shares: u64,         // Total shares issued to all depositors (increases on deposit, decreases on withdrawal)
        yield_rate: u64,           // Annual yield rate in basis points (500 = 5%, 1000 = 10%)
        last_update: u64,          // Last epoch when yield was accrued (used for time-based calculations)
        is_paused: bool,           // Emergency pause flag (true = deposits/withdrawals disabled)
        admin: address,            // Address of vault administrator (owner of AdminCap)
    }

    /// User's vault receipt - an NFT representing their share of the vault
    ///
    /// This receipt is required to withdraw funds and proves ownership of shares.
    /// It tracks both shares owned and original deposit for transparency.
    /// Can be transferred or stored, enabling composability with other protocols.
    public struct VaultReceipt has key, store {
        id: UID,                   // Unique identifier for this receipt NFT
        vault_id: ID,              // ID of the vault this receipt belongs to (prevents cross-vault usage)
        shares: u64,               // Number of shares owned (determines withdrawal amount)
        deposited_amount: u64,     // Original deposit amount (for tracking cost basis and P&L)
        deposit_timestamp: u64,    // Epoch when deposit was made (for time-locked features or tax purposes)
    }

    /// Admin capability for vault management (owner-only operations)
    ///
    /// This capability object is created once during vault creation and transferred to the creator.
    /// Only the holder of this AdminCap can:
    /// - Pause/unpause the vault in emergencies
    /// - Accrue yield to the vault
    /// - Update yield rate parameters
    public struct AdminCap has key, store {
        id: UID,         // Unique identifier for this capability
        vault_id: ID,    // ID of vault this capability controls (ensures correct vault access)
    }

    // ======== Events ========
    // All events provide complete audit trail for off-chain indexers and analytics

    /// Emitted when a new vault is created
    public struct VaultCreated has copy, drop {
        vault_id: ID,    // ID of the newly created vault
        admin: address,  // Address of vault administrator (receives AdminCap)
    }

    /// Emitted when user deposits tokens into vault
    public struct Deposited has copy, drop {
        vault_id: ID,  // Vault receiving the deposit
        user: address, // Address making the deposit
        amount: u64,   // Amount of SUI tokens deposited
        shares: u64,   // Number of shares minted for this deposit
    }

    /// Emitted when user withdraws tokens from vault
    public struct Withdrawn has copy, drop {
        vault_id: ID,       // Vault from which withdrawal is made
        user: address,      // Address receiving the withdrawal
        amount: u64,        // Amount of SUI tokens withdrawn (may be > deposited if yield accrued)
        shares_burned: u64, // Number of shares burned during withdrawal
    }

    /// Emitted when admin adds yield to the vault
    public struct YieldAccrued has copy, drop {
        vault_id: ID, // Vault receiving the yield
        amount: u64,  // Amount of yield added (increases value per share for all holders)
    }

    /// Emitted when admin pauses the vault (emergency only)
    public struct VaultPaused has copy, drop {
        vault_id: ID, // Vault that was paused (deposits/withdrawals now disabled)
    }

    /// Emitted when admin unpauses the vault
    public struct VaultUnpaused has copy, drop {
        vault_id: ID, // Vault that was unpaused (deposits/withdrawals re-enabled)
    }

    // ======== Functions ========

    /// Create a new vault and grant admin capabilities to the caller
    ///
    /// This initializes a new vault with:
    /// - Zero balance and shares (empty vault ready for first deposit)
    /// - Default 5% annual yield rate
    /// - Unpaused state (ready for deposits)
    /// - Caller as admin
    ///
    /// # Arguments
    /// * `ctx` - Transaction context (provides sender address and unique IDs)
    ///
    /// # Returns
    /// * Shares `Vault` object globally (anyone can deposit/withdraw)
    /// * Transfers `AdminCap` to caller (only caller can admin functions)
    ///
    /// # Events
    /// * Emits `VaultCreated` with vault ID and admin address
    ///
    /// # Example
    /// ```
    /// // Alice creates a vault and receives AdminCap
    /// create_vault(ctx);
    /// // Now Alice can pause vault, accrue yield, update parameters
    /// // Anyone can deposit/withdraw from the shared Vault object
    /// ```
    public entry fun create_vault(ctx: &mut TxContext) {
        // Create unique ID for the new vault object
        let vault_uid = object::new(ctx);
        let vault_id = object::uid_to_inner(&vault_uid);

        // Get caller's address - they become the vault administrator
        let admin = ctx.sender();

        // Initialize vault with starting parameters
        let vault = Vault {
            id: vault_uid,                          // Unique identifier for this vault
            balance: balance::zero(),               // Start with 0 SUI (will grow with deposits and yield)
            total_shares: 0,                        // No shares issued yet (first depositor gets shares = amount)
            yield_rate: DEFAULT_YIELD_RATE,         // 5% annual yield (500 basis points)
            last_update: ctx.epoch(),               // Current epoch (for time-based yield calculations)
            is_paused: false,                       // Vault starts active (deposits/withdrawals allowed)
            admin,                                  // Store admin address for reference
        };

        // Create admin capability tied to this specific vault
        let admin_cap = AdminCap {
            id: object::new(ctx),  // Unique ID for the capability
            vault_id,              // Link to vault ID (prevents using cap on wrong vault)
        };

        // Emit event for off-chain indexers to track vault creation
        event::emit(VaultCreated {
            vault_id,
            admin,
        });

        // Make vault globally accessible (shared object)
        // Anyone can call deposit/withdraw on this vault
        transfer::share_object(vault);

        // Transfer admin capability to caller
        // Only holder of this cap can pause, accrue yield, etc.
        transfer::transfer(admin_cap, admin);
    }

    /// Deposit SUI tokens into the vault and receive shares
    ///
    /// Uses proportional share calculation:
    /// - First deposit: shares = amount (1:1 ratio)
    /// - Later deposits: shares = (amount × total_shares) / vault_balance
    ///
    /// Example: Vault has 1000 SUI and 800 shares
    /// - Alice deposits 100 SUI
    /// - She receives (100 × 800) / 1000 = 80 shares
    /// - If yield grows vault to 1100 SUI, her 80 shares are worth (80 × 1100) / 880 = 100 SUI
    ///
    /// # Arguments
    /// * `vault` - Vault to deposit into (must not be paused)
    /// * `token` - SUI coins to deposit (must be > 0)
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Transfers `VaultReceipt` to caller (required for withdrawal)
    ///
    /// # Panics
    /// * `EVaultPaused` - If vault is currently paused
    /// * `EInvalidAmount` - If deposit amount is 0
    ///
    /// # Events
    /// * Emits `Deposited` with vault ID, user, amount, and shares
    public entry fun deposit(
        vault: &mut Vault,
        token: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        // Safety check: Prevent deposits when vault is paused for emergency
        assert!(!vault.is_paused, EVaultPaused);

        // Get deposit amount from coin
        let amount = coin::value(&token);

        // Validation: Ensure non-zero deposit
        assert!(amount > 0, EInvalidAmount);

        // Calculate shares to mint using proportional formula
        // First depositor gets shares = amount (establishes 1:1 ratio)
        // Later depositors get proportional shares based on current price per share
        let shares = if (vault.total_shares == 0) {
            // First deposit: 1:1 ratio (if deposit 1000, get 1000 shares)
            amount
        } else {
            // Subsequent deposits: proportional to current vault state
            // Formula: shares = (deposit_amount × total_shares) / vault_balance
            // This ensures fair pricing - if vault grew from yield, fewer shares per token
            let current_balance = balance::value(&vault.balance);
            (amount * vault.total_shares) / current_balance
        };

        // Convert coin to balance for internal storage
        let deposit_balance = coin::into_balance(token);

        // Add deposited tokens to vault balance
        balance::join(&mut vault.balance, deposit_balance);

        // Increase total shares by newly minted shares
        vault.total_shares = vault.total_shares + shares;

        // Create receipt NFT as proof of deposit
        // This receipt is required to withdraw - burning it releases proportional funds
        let receipt = VaultReceipt {
            id: object::new(ctx),           // Unique ID for this receipt
            vault_id: object::id(vault),    // Link to specific vault
            shares,                         // Number of shares owned
            deposited_amount: amount,       // Original deposit for cost basis tracking
            deposit_timestamp: ctx.epoch(), // When deposit was made
        };

        // Emit event for off-chain tracking and analytics
        event::emit(Deposited {
            vault_id: object::id(vault),
            user: ctx.sender(),
            amount,
            shares,
        });

        // Transfer receipt to user
        // User must keep this to withdraw their funds
        transfer::transfer(receipt, ctx.sender());
    }

    /// Withdraw tokens from the vault by burning shares
    ///
    /// Burns the VaultReceipt and returns proportional amount of vault balance.
    /// If vault has earned yield, withdrawal amount will be > original deposit.
    ///
    /// Example: User has 80 shares, vault has 1100 SUI and 880 total shares
    /// - Withdrawal = (80 × 1100) / 880 = 100 SUI
    /// - If they originally deposited 100 SUI, no gain
    /// - If vault grew 10%, they withdraw 110 SUI (10 SUI profit)
    ///
    /// # Arguments
    /// * `vault` - Vault to withdraw from (must not be paused)
    /// * `receipt` - VaultReceipt to burn (must match this vault)
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Transfers SUI coins to caller (proportional to shares)
    ///
    /// # Panics
    /// * `EVaultPaused` - If vault is currently paused
    /// * `ENotAuthorized` - If receipt doesn't match this vault
    /// * `EInsufficientBalance` - If vault lacks sufficient funds (should never happen)
    ///
    /// # Events
    /// * Emits `Withdrawn` with vault ID, user, amount, and shares burned
    ///
    /// # Security
    /// * Receipt is destroyed (burned) to prevent double-withdrawal
    /// * Shares are decreased before transfer (reentrancy protection)
    public entry fun withdraw(
        vault: &mut Vault,
        receipt: VaultReceipt,
        ctx: &mut TxContext
    ) {
        // Safety check: Prevent withdrawals when vault is paused
        assert!(!vault.is_paused, EVaultPaused);

        // Unpack and destroy the receipt
        // This consumes the NFT, preventing reuse (no double-withdrawals)
        let VaultReceipt {
            id,
            vault_id,
            shares,
            deposited_amount: _,      // Ignore, only used for display/tracking
            deposit_timestamp: _,     // Ignore, only used for display/tracking
        } = receipt;

        // Verify receipt belongs to this specific vault
        // Prevents using receipts from other vaults
        assert!(vault_id == object::id(vault), ENotAuthorized);

        // Sanity check: shares should never exceed total (defensive programming)
        assert!(shares <= vault.total_shares, EInsufficientBalance);

        // Calculate withdrawal amount using proportional formula
        // Formula: amount = (shares × vault_balance) / total_shares
        // This is the inverse of deposit - converts shares back to tokens
        let current_balance = balance::value(&vault.balance);
        let withdrawal_amount = (shares * current_balance) / vault.total_shares;

        // Double-check vault has enough balance (should always be true)
        assert!(withdrawal_amount <= current_balance, EInsufficientBalance);

        // Update vault state BEFORE transfer (reentrancy protection)
        // Decrease total shares since we're burning these shares
        vault.total_shares = vault.total_shares - shares;

        // Extract tokens from vault balance
        let withdrawn_balance = balance::split(&mut vault.balance, withdrawal_amount);

        // Convert balance to coin for transfer
        let withdrawn_coin = coin::from_balance(withdrawn_balance, ctx);

        // Emit event for off-chain tracking
        event::emit(Withdrawn {
            vault_id: object::id(vault),
            user: ctx.sender(),
            amount: withdrawal_amount,
            shares_burned: shares,
        });

        // Delete the receipt ID (complete the burn)
        object::delete(id);

        // Transfer withdrawn tokens to user
        transfer::public_transfer(withdrawn_coin, ctx.sender());
    }

    /// Accrue yield to the vault (admin only)
    ///
    /// Adds external yield/profits to the vault, increasing value per share for all holders.
    /// This is how yield aggregators work - they earn yield elsewhere and add it to the vault.
    ///
    /// Example: Vault has 1000 SUI and 1000 shares (1:1 ratio)
    /// - Admin accrues 100 SUI yield
    /// - Vault now has 1100 SUI and 1000 shares (1.1:1 ratio)
    /// - All share holders gained 10% value automatically
    ///
    /// # Arguments
    /// * `vault` - Vault to add yield to
    /// * `_admin_cap` - Admin capability (proves caller is admin)
    /// * `yield_amount` - SUI coins to add as yield
    /// * `ctx` - Transaction context
    ///
    /// # Panics
    /// * `EVaultPaused` - If vault is paused
    ///
    /// # Events
    /// * Emits `YieldAccrued` with vault ID and yield amount
    ///
    /// # Note
    /// * In production, yield would come from DeFi protocols (Scallop, Navi, etc.)
    /// * This simulates that by allowing admin to manually add yield
    public entry fun accrue_yield(
        vault: &mut Vault,
        _admin_cap: &AdminCap,  // Proves caller is admin (unused but required for access control)
        yield_amount: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        // Prevent yield accrual while paused
        assert!(!vault.is_paused, EVaultPaused);

        // Get amount of yield being added
        let amount = coin::value(&yield_amount);

        // Convert coin to balance
        let yield_balance = coin::into_balance(yield_amount);

        // Add yield to vault balance
        // This increases vault_balance without changing total_shares
        // Result: Each share is now worth more
        balance::join(&mut vault.balance, yield_balance);

        // Update last yield timestamp
        vault.last_update = ctx.epoch();

        // Emit event for off-chain tracking
        event::emit(YieldAccrued {
            vault_id: object::id(vault),
            amount,
        });
    }

    /// Pause the vault in case of emergency (admin only)
    ///
    /// Disables all deposits and withdrawals until unpaused.
    /// Used when:
    /// - Security vulnerability discovered
    /// - Upgrade needed
    /// - Suspicious activity detected
    ///
    /// # Arguments
    /// * `vault` - Vault to pause
    /// * `admin_cap` - Admin capability (must match vault ID)
    /// * `_ctx` - Transaction context
    ///
    /// # Panics
    /// * `ENotAuthorized` - If admin_cap doesn't match this vault
    /// * `EAlreadyPaused` - If vault is already paused
    ///
    /// # Events
    /// * Emits `VaultPaused` with vault ID
    ///
    /// # Security
    /// * Critical emergency function - halts all user operations
    /// * Should only be used in genuine emergencies
    public entry fun pause_vault(
        vault: &mut Vault,
        admin_cap: &AdminCap,
        _ctx: &mut TxContext
    ) {
        // Verify caller has admin cap for THIS specific vault
        assert!(object::id(vault) == admin_cap.vault_id, ENotAuthorized);

        // Prevent double-pause (cleaner error handling)
        assert!(!vault.is_paused, EAlreadyPaused);

        // Set pause flag - this will block deposit() and withdraw()
        vault.is_paused = true;

        // Emit event for immediate notification to users/frontends
        event::emit(VaultPaused {
            vault_id: object::id(vault),
        });
    }

    /// Unpause the vault after emergency is resolved (admin only)
    ///
    /// Re-enables deposits and withdrawals after pause.
    ///
    /// # Arguments
    /// * `vault` - Vault to unpause
    /// * `admin_cap` - Admin capability (must match vault ID)
    /// * `_ctx` - Transaction context
    ///
    /// # Panics
    /// * `ENotAuthorized` - If admin_cap doesn't match this vault
    /// * `ENotPaused` - If vault is not currently paused
    ///
    /// # Events
    /// * Emits `VaultUnpaused` with vault ID
    public entry fun unpause_vault(
        vault: &mut Vault,
        admin_cap: &AdminCap,
        _ctx: &mut TxContext
    ) {
        // Verify admin owns this vault
        assert!(object::id(vault) == admin_cap.vault_id, ENotAuthorized);

        // Can only unpause if currently paused
        assert!(vault.is_paused, ENotPaused);

        // Clear pause flag - deposits/withdrawals now allowed
        vault.is_paused = false;

        // Notify users/frontends that vault is operational again
        event::emit(VaultUnpaused {
            vault_id: object::id(vault),
        });
    }

    /// Update the vault's yield rate parameter (admin only)
    ///
    /// Allows admin to adjust target yield rate.
    /// Note: In this implementation, this is informational only.
    /// In production, it would affect auto-compounding strategies.
    ///
    /// # Arguments
    /// * `vault` - Vault to update
    /// * `admin_cap` - Admin capability (must match vault ID)
    /// * `new_rate` - New yield rate in basis points (500 = 5%, 1000 = 10%)
    /// * `_ctx` - Transaction context
    ///
    /// # Panics
    /// * `ENotAuthorized` - If admin_cap doesn't match this vault
    ///
    /// # Example
    /// ```
    /// // Update from 5% to 10% target yield
    /// update_yield_rate(&mut vault, &admin_cap, 1000, ctx);
    /// ```
    public entry fun update_yield_rate(
        vault: &mut Vault,
        admin_cap: &AdminCap,
        new_rate: u64,
        _ctx: &mut TxContext
    ) {
        // Verify admin authorization for this vault
        assert!(object::id(vault) == admin_cap.vault_id, ENotAuthorized);

        // Update the yield rate parameter
        vault.yield_rate = new_rate;
    }

    // ======== View Functions ========
    // Read-only functions for querying vault state (no gas cost when called off-chain)

    /// Get the total SUI balance held in the vault
    ///
    /// # Arguments
    /// * `vault` - Vault to query
    ///
    /// # Returns
    /// * Total SUI tokens in vault (includes deposits + accrued yield)
    ///
    /// # Example
    /// ```
    /// let balance = get_vault_balance(&vault);
    /// // If users deposited 1000 SUI and 100 yield accrued, returns 1100
    /// ```
    public fun get_vault_balance(vault: &Vault): u64 {
        balance::value(&vault.balance)  // Total SUI in vault
    }

    /// Get the total shares issued by the vault
    ///
    /// # Arguments
    /// * `vault` - Vault to query
    ///
    /// # Returns
    /// * Total shares held by all users combined
    ///
    /// # Note
    /// * Divide vault_balance by total_shares to get value per share
    public fun get_total_shares(vault: &Vault): u64 {
        vault.total_shares  // Sum of all user shares
    }

    /// Check if vault is currently paused
    ///
    /// # Arguments
    /// * `vault` - Vault to query
    ///
    /// # Returns
    /// * true if paused (deposits/withdrawals disabled), false if active
    public fun is_paused(vault: &Vault): bool {
        vault.is_paused  // Emergency pause status
    }

    /// Get number of shares from a vault receipt
    ///
    /// # Arguments
    /// * `receipt` - VaultReceipt to query
    ///
    /// # Returns
    /// * Number of shares owned by this receipt
    ///
    /// # Use Case
    /// * Check holdings before withdrawal
    /// * Display user's share balance in UI
    public fun get_receipt_shares(receipt: &VaultReceipt): u64 {
        receipt.shares  // Shares owned by this receipt
    }

    /// Calculate current SUI value of a given number of shares
    ///
    /// This shows how much SUI a user can withdraw for their shares.
    /// Value increases as vault earns yield.
    ///
    /// # Arguments
    /// * `vault` - Vault to query
    /// * `shares` - Number of shares to value
    ///
    /// # Returns
    /// * Current SUI value of the shares
    ///
    /// # Example
    /// ```
    /// // User has 80 shares, vault has 1100 SUI and 880 total shares
    /// let value = calculate_share_value(&vault, 80);
    /// // Returns: (80 × 1100) / 880 = 100 SUI
    /// ```
    ///
    /// # Formula
    /// * value = (shares × vault_balance) / total_shares
    public fun calculate_share_value(vault: &Vault, shares: u64): u64 {
        // Handle empty vault edge case
        if (vault.total_shares == 0) {
            0  // No shares issued yet, value is 0
        } else {
            // Calculate proportional value
            let current_balance = balance::value(&vault.balance);
            (shares * current_balance) / vault.total_shares  // Pro-rata share of vault
        }
    }

    // ======== Test Functions ========
    // Only compiled in test mode, not in production builds

    /// Initialize vault for testing purposes
    ///
    /// This is a test-only helper function that creates a vault during tests.
    ///
    /// # Arguments
    /// * `ctx` - Test transaction context
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        create_vault(ctx);  // Create vault for test scenarios
    }
}
