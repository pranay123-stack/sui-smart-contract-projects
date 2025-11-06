/// Token Vault Module
/// A secure vault for depositing and withdrawing tokens with yield accrual
/// Features: deposits, withdrawals, yield mechanism, emergency pause, access control
module token_vault::vault {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::event;

    // ======== Error Codes ========
    const ENotAuthorized: u64 = 1;
    const EVaultPaused: u64 = 2;
    const EInsufficientBalance: u64 = 3;
    const EInvalidAmount: u64 = 4;
    const EAlreadyPaused: u64 = 5;
    const ENotPaused: u64 = 6;

    // ======== Constants ========
    const YIELD_RATE_PRECISION: u64 = 10000; // 0.01% precision
    const DEFAULT_YIELD_RATE: u64 = 500; // 5% annual yield (500/10000)

    // ======== Structs ========

    /// The main vault object that holds tokens
    public struct Vault has key {
        id: UID,
        balance: Balance<SUI>,
        total_shares: u64,
        yield_rate: u64, // Annual yield rate in basis points
        last_update: u64,
        is_paused: bool,
        admin: address,
    }

    /// User's vault receipt representing their share
    public struct VaultReceipt has key, store {
        id: UID,
        vault_id: ID,
        shares: u64,
        deposited_amount: u64,
        deposit_timestamp: u64,
    }

    /// Admin capability for vault management
    public struct AdminCap has key, store {
        id: UID,
        vault_id: ID,
    }

    // ======== Events ========

    public struct VaultCreated has copy, drop {
        vault_id: ID,
        admin: address,
    }

    public struct Deposited has copy, drop {
        vault_id: ID,
        user: address,
        amount: u64,
        shares: u64,
    }

    public struct Withdrawn has copy, drop {
        vault_id: ID,
        user: address,
        amount: u64,
        shares_burned: u64,
    }

    public struct YieldAccrued has copy, drop {
        vault_id: ID,
        amount: u64,
    }

    public struct VaultPaused has copy, drop {
        vault_id: ID,
    }

    public struct VaultUnpaused has copy, drop {
        vault_id: ID,
    }

    // ======== Functions ========

    /// Create a new vault
    public entry fun create_vault(ctx: &mut TxContext) {
        let vault_uid = object::new(ctx);
        let vault_id = object::uid_to_inner(&vault_uid);
        let admin = ctx.sender();

        let vault = Vault {
            id: vault_uid,
            balance: balance::zero(),
            total_shares: 0,
            yield_rate: DEFAULT_YIELD_RATE,
            last_update: ctx.epoch(),
            is_paused: false,
            admin,
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
            vault_id,
        };

        event::emit(VaultCreated {
            vault_id,
            admin,
        });

        transfer::share_object(vault);
        transfer::transfer(admin_cap, admin);
    }

    /// Deposit tokens into the vault
    public entry fun deposit(
        vault: &mut Vault,
        token: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!vault.is_paused, EVaultPaused);

        let amount = coin::value(&token);
        assert!(amount > 0, EInvalidAmount);

        // Calculate shares based on current vault state
        let shares = if (vault.total_shares == 0) {
            amount
        } else {
            let current_balance = balance::value(&vault.balance);
            (amount * vault.total_shares) / current_balance
        };

        // Add to vault balance
        let deposit_balance = coin::into_balance(token);
        balance::join(&mut vault.balance, deposit_balance);

        // Update total shares
        vault.total_shares = vault.total_shares + shares;

        // Create receipt for user
        let receipt = VaultReceipt {
            id: object::new(ctx),
            vault_id: object::id(vault),
            shares,
            deposited_amount: amount,
            deposit_timestamp: ctx.epoch(),
        };

        event::emit(Deposited {
            vault_id: object::id(vault),
            user: ctx.sender(),
            amount,
            shares,
        });

        transfer::transfer(receipt, ctx.sender());
    }

    /// Withdraw tokens from the vault
    public entry fun withdraw(
        vault: &mut Vault,
        receipt: VaultReceipt,
        ctx: &mut TxContext
    ) {
        assert!(!vault.is_paused, EVaultPaused);

        let VaultReceipt {
            id,
            vault_id,
            shares,
            deposited_amount: _,
            deposit_timestamp: _,
        } = receipt;

        assert!(vault_id == object::id(vault), ENotAuthorized);
        assert!(shares <= vault.total_shares, EInsufficientBalance);

        // Calculate withdrawal amount based on shares
        let current_balance = balance::value(&vault.balance);
        let withdrawal_amount = (shares * current_balance) / vault.total_shares;

        assert!(withdrawal_amount <= current_balance, EInsufficientBalance);

        // Update vault state
        vault.total_shares = vault.total_shares - shares;

        // Withdraw tokens
        let withdrawn_balance = balance::split(&mut vault.balance, withdrawal_amount);
        let withdrawn_coin = coin::from_balance(withdrawn_balance, ctx);

        event::emit(Withdrawn {
            vault_id: object::id(vault),
            user: ctx.sender(),
            amount: withdrawal_amount,
            shares_burned: shares,
        });

        object::delete(id);
        transfer::public_transfer(withdrawn_coin, ctx.sender());
    }

    /// Accrue yield to the vault (simulated)
    public entry fun accrue_yield(
        vault: &mut Vault,
        _admin_cap: &AdminCap,
        yield_amount: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!vault.is_paused, EVaultPaused);

        let amount = coin::value(&yield_amount);
        let yield_balance = coin::into_balance(yield_amount);
        balance::join(&mut vault.balance, yield_balance);

        vault.last_update = ctx.epoch();

        event::emit(YieldAccrued {
            vault_id: object::id(vault),
            amount,
        });
    }

    /// Pause the vault (emergency function)
    public entry fun pause_vault(
        vault: &mut Vault,
        admin_cap: &AdminCap,
        _ctx: &mut TxContext
    ) {
        assert!(object::id(vault) == admin_cap.vault_id, ENotAuthorized);
        assert!(!vault.is_paused, EAlreadyPaused);

        vault.is_paused = true;

        event::emit(VaultPaused {
            vault_id: object::id(vault),
        });
    }

    /// Unpause the vault
    public entry fun unpause_vault(
        vault: &mut Vault,
        admin_cap: &AdminCap,
        _ctx: &mut TxContext
    ) {
        assert!(object::id(vault) == admin_cap.vault_id, ENotAuthorized);
        assert!(vault.is_paused, ENotPaused);

        vault.is_paused = false;

        event::emit(VaultUnpaused {
            vault_id: object::id(vault),
        });
    }

    /// Update yield rate
    public entry fun update_yield_rate(
        vault: &mut Vault,
        admin_cap: &AdminCap,
        new_rate: u64,
        _ctx: &mut TxContext
    ) {
        assert!(object::id(vault) == admin_cap.vault_id, ENotAuthorized);
        vault.yield_rate = new_rate;
    }

    // ======== View Functions ========

    /// Get vault balance
    public fun get_vault_balance(vault: &Vault): u64 {
        balance::value(&vault.balance)
    }

    /// Get total shares
    public fun get_total_shares(vault: &Vault): u64 {
        vault.total_shares
    }

    /// Get vault status
    public fun is_paused(vault: &Vault): bool {
        vault.is_paused
    }

    /// Get receipt information
    public fun get_receipt_shares(receipt: &VaultReceipt): u64 {
        receipt.shares
    }

    /// Calculate current value of shares
    public fun calculate_share_value(vault: &Vault, shares: u64): u64 {
        if (vault.total_shares == 0) {
            0
        } else {
            let current_balance = balance::value(&vault.balance);
            (shares * current_balance) / vault.total_shares
        }
    }

    // ======== Test Functions ========

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        create_vault(ctx);
    }
}
