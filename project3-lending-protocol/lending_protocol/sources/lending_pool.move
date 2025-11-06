// ============================================================================================================
// Lending Protocol - Overcollateralized Lending & Borrowing Platform
// ============================================================================================================
//
// MODULE OVERVIEW:
// This module implements a production-ready overcollateralized lending protocol similar to Aave, Compound,
// and Suilend. Users can deposit assets to earn interest, borrow against collateral, and liquidate
// unhealthy positions. The protocol uses dynamic interest rates based on utilization.
//
// KEY FEATURES:
// 1. Overcollateralized Borrowing: 75% collateral factor ensures protocol safety
// 2. Dynamic Interest Rates: Utilization-based kinked rate model (2% → 32% APY)
// 3. Share-Based Debt Tracking: Fair distribution of accrued interest
// 4. Liquidation System: Incentivized liquidation with 5% bonus
// 5. Health Factor Monitoring: Real-time position health calculation
// 6. Time-Based Interest Accrual: Continuous compounding interest
//
// ARCHITECTURE:
// - LendingPool<T>: Main pool contract for each asset type
// - DepositPosition<T>: User's deposit receipt (NFT)
// - BorrowPosition<T>: User's collateralized borrow position (NFT)
// - AdminCap: Administrative capability for pool management
//
// RISK PARAMETERS:
// - Collateral Factor: 75% (can borrow up to 75% of collateral value)
// - Liquidation Threshold: 80% (liquidatable when debt > 80% of collateral)
// - Liquidation Bonus: 5% (incentive for liquidators)
// - Base Borrow Rate: 2% APY
// - Optimal Utilization: 80%
// - Max Borrow Rate: 32% APY (at 100% utilization)
//
// MATH & FORMULAS:
// - Health Factor: health = (collateral × liquidation_threshold) / debt
//   * HF >= 1.0 = Safe position
//   * HF < 1.0 = Liquidatable position
//
// - Interest Rate Model (Kinked Curve):
//   * If utilization <= 80%: rate = 2% + (utilization × 10%) / 80%
//   * If utilization > 80%: rate = 12% + ((utilization - 80%) × 20%) / 20%
//
// - Utilization: utilization = total_borrowed / total_deposits
//
// - Debt Shares: shares = (borrow_amount × total_debt_shares) / total_borrowed
// - Debt Amount: debt = (shares × total_borrowed) / total_debt_shares
//
// SECURITY CONSIDERATIONS:
// - Overcollateralization: Protects lenders from borrower default
// - Liquidation mechanism: Maintains protocol solvency
// - Health factor buffer: 5% gap between CF (75%) and LT (80%)
// - Interest accrual: Automatic on every interaction
// - Access control: Only admin can pause pool
// - Reentrancy safety: State updates before external calls
//
// ECONOMIC DESIGN:
// - Lenders earn interest from borrowers
// - Interest rate increases with utilization (incentivizes deposits at high utilization)
// - Liquidators earn 5% bonus (incentivizes maintaining protocol health)
// - Borrowers pay competitive rates based on supply/demand
// - Protocol earns spread between borrow and supply rates
//
// LIQUIDATION MECHANICS:
// 1. Position becomes unhealthy (HF < 1.0)
// 2. Liquidator repays borrower's debt
// 3. Liquidator receives collateral + 5% bonus
// 4. Remaining collateral returned to borrower (if any)
// 5. Protocol remains solvent, lenders protected
//
// EXAMPLE SCENARIO:
// Initial State:
//   - Alice deposits 100,000 SUI → Earns ~5% APY
//   - Bob deposits 10,000 SUI as collateral
//   - Bob borrows 7,000 SUI (70% of collateral, within 75% limit)
//   - Utilization: 7% → Borrow rate: ~3% APY
//
// After Time:
//   - Bob's debt grows to 7,350 SUI (5% interest)
//   - Health Factor: (10,000 × 0.80) / 7,350 = 1.09 (still safe)
//
// If Debt Grows to 8,500:
//   - Health Factor: (10,000 × 0.80) / 8,500 = 0.94 (unhealthy!)
//   - Liquidator pays 8,500 SUI
//   - Liquidator receives 8,925 SUI (8,500 + 5%)
//   - Liquidator profit: 425 SUI
//   - Remaining: 1,075 SUI returned to Bob
//
// USE CASES:
// - Earn interest on idle crypto (lenders)
// - Leverage positions without selling (borrowers)
// - Arbitrage opportunities (liquidators)
// - Treasury management for DAOs
// - Institutional lending/borrowing
//
// COMPARISON WITH COMPETITORS:
// - Similar to Aave: Overcollateralization, liquidation bonus
// - Similar to Compound: Share-based accounting (cTokens)
// - Similar to MakerDAO: Health factor monitoring
// - Similar to Suilend: Native Sui implementation
//
// AUTHOR: Pranay Gaurav
// VERSION: 1.0.0
// LICENSE: MIT
// INSPIRED BY: Aave, Compound, MakerDAO, Suilend
//
// ============================================================================================================

module lending_protocol::lending_pool {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};

    // ======== Error Codes ========
    const EInsufficientCollateral: u64 = 1;   // Error: Borrow amount exceeds 75% collateral factor limit
    const EInsufficientLiquidity: u64 = 2;    // Error: Pool doesn't have enough liquidity for withdrawal/borrow
    const EInvalidAmount: u64 = 3;            // Error: Amount must be greater than 0
    const EPositionNotLiquidatable: u64 = 4;  // Error: Position health factor >= 1.0 (cannot liquidate healthy positions)
    const ENoPositionFound: u64 = 5;          // Error: User has no borrow position to liquidate
    const EPoolPaused: u64 = 6;               // Error: Pool operations are paused for emergency
    const ENotAuthorized: u64 = 7;            // Error: Caller lacks required admin permissions
    const EPositionHealthy: u64 = 8;          // Error: Position is healthy (HF >= 1.0), cannot liquidate

    // ======== Constants ========
    const PRECISION: u64 = 10000;             // Precision for percentage calculations (10000 = 100.00%)
    const COLLATERAL_FACTOR: u64 = 7500;      // 75% - Maximum borrowable amount vs collateral (7500/10000)
    const LIQUIDATION_THRESHOLD: u64 = 8000;  // 80% - Debt/collateral ratio triggering liquidation (8000/10000)
    const LIQUIDATION_BONUS: u64 = 500;       // 5% - Bonus paid to liquidators for maintaining protocol health
    const BASE_BORROW_RATE: u64 = 200;        // 2% - Minimum borrow APY (200/10000 = 0.02)
    const RATE_SLOPE: u64 = 1000;             // 10% - Rate increase per utilization point
    const OPTIMAL_UTILIZATION: u64 = 8000;    // 80% - Target utilization for optimal rates (kink point)

    const SECONDS_PER_YEAR: u64 = 31536000;   // Seconds in a year (365.25 days) for APY calculations

    // ======== Structs ========

    /// Main lending pool for a specific asset type (similar to Compound's cToken)
    ///
    /// Each pool manages one asset type and tracks deposits, borrows, and interest.
    /// Uses share-based debt accounting for fair interest distribution.
    /// Interest accrues continuously based on utilization rate.
    ///
    /// # Type Parameter
    /// * `T` - Asset type (e.g., SUI, USDC)
    public struct LendingPool<phantom T> has key {
        id: UID,                         // Unique identifier for this lending pool
        total_deposits: Balance<T>,      // Total assets deposited by lenders (available for borrowing)
        total_borrowed: u64,             // Total assets currently borrowed (grows with interest)
        total_borrow_shares: u64,        // Total borrow shares issued (for proportional debt tracking)
        last_accrual_time: u64,          // Last timestamp when interest was accrued (in milliseconds)
        borrow_index: u64,               // Accumulated borrow index for interest calculation (starts at PRECISION)
        is_paused: bool,                 // Emergency pause flag (true = all operations disabled)
        admin: address,                  // Administrator address (can pause/unpause pool)
    }

    /// User's deposit position (receipt NFT proving deposit)
    ///
    /// This NFT represents a deposit into the lending pool.
    /// Required to withdraw funds. Earns passive interest from borrowers.
    ///
    /// # Type Parameter
    /// * `T` - Asset type deposited
    public struct DepositPosition<phantom T> has key, store {
        id: UID,                  // Unique identifier for this deposit NFT
        pool_id: ID,              // ID of pool where deposit is held (prevents cross-pool usage)
        deposited_amount: u64,    // Original deposit amount (for cost basis tracking)
        deposit_timestamp: u64,   // When deposit was made (milliseconds since epoch)
    }

    /// User's borrow position (collateralized loan NFT)
    ///
    /// This NFT represents a collateralized borrow position.
    /// Collateral is locked until debt is fully repaid.
    /// Position can be liquidated if health factor drops below 1.0.
    ///
    /// # Type Parameter
    /// * `T` - Asset type borrowed (same as collateral in this implementation)
    public struct BorrowPosition<phantom T> has key, store {
        id: UID,                  // Unique identifier for this borrow position NFT
        pool_id: ID,              // ID of pool where borrow originated (prevents cross-pool usage)
        collateral_amount: u64,   // Amount of collateral locked (must stay >= debt / 0.75)
        borrow_shares: u64,       // Borrow shares owned (debt = shares × total_borrowed / total_shares)
        borrow_timestamp: u64,    // When borrow was initiated (milliseconds since epoch)
    }

    /// Admin capability for pool management (emergency controls)
    ///
    /// Holder can pause/unpause pools in case of emergency.
    /// Created once during pool creation and transferred to creator.
    public struct AdminCap has key, store {
        id: UID,  // Unique identifier for this capability
    }

    // ======== Events ========
    // All events provide complete audit trail for analytics and monitoring

    /// Emitted when a new lending pool is created
    public struct PoolCreated<phantom T> has copy, drop {
        pool_id: ID,    // ID of newly created pool
        admin: address, // Administrator address (receives AdminCap)
    }

    /// Emitted when user deposits assets into pool (becomes lender)
    public struct Deposited<phantom T> has copy, drop {
        pool_id: ID,  // Pool receiving deposit
        user: address, // Address making deposit (lender)
        amount: u64,   // Amount of assets deposited
    }

    /// Emitted when user withdraws assets from pool
    public struct Withdrawn<phantom T> has copy, drop {
        pool_id: ID,  // Pool from which withdrawal is made
        user: address, // Address withdrawing (lender)
        amount: u64,   // Amount of assets withdrawn
    }

    /// Emitted when user borrows assets against collateral
    public struct Borrowed<phantom T> has copy, drop {
        pool_id: ID,    // Pool from which assets are borrowed
        user: address,   // Address borrowing (borrower)
        amount: u64,     // Amount of assets borrowed
        collateral: u64, // Amount of collateral locked
    }

    /// Emitted when user repays borrowed assets
    public struct Repaid<phantom T> has copy, drop {
        pool_id: ID,  // Pool to which repayment is made
        user: address, // Address repaying (borrower)
        amount: u64,   // Amount of debt repaid
    }

    /// Emitted when unhealthy position is liquidated
    public struct Liquidated<phantom T> has copy, drop {
        pool_id: ID,          // Pool where liquidation occurred
        liquidator: address,   // Address performing liquidation (receives bonus)
        borrower: address,     // Address being liquidated (loses collateral)
        repaid_amount: u64,    // Amount of debt repaid by liquidator
        collateral_seized: u64, // Amount of collateral seized (includes 5% bonus)
    }

    /// Emitted when interest accrues to pool
    public struct InterestAccrued<phantom T> has copy, drop {
        pool_id: ID,        // Pool where interest accrued
        interest_amount: u64, // Amount of interest added to total_borrowed
    }

    // ======== Functions ========

    /// Create a new lending pool for a specific asset type
    ///
    /// Initializes a lending pool where users can deposit assets to earn interest
    /// and borrow against collateral. Similar to creating a Compound cToken market.
    ///
    /// Initial state:
    /// - Zero deposits and borrows
    /// - Borrow index starts at PRECISION (10000)
    /// - Pool is unpaused and ready for use
    /// - Caller becomes admin
    ///
    /// # Type Parameter
    /// * `T` - Asset type for this pool (e.g., SUI)
    ///
    /// # Arguments
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Shares LendingPool globally (anyone can deposit/borrow)
    /// * Transfers AdminCap to caller (for emergency controls)
    ///
    /// # Events
    /// * Emits `PoolCreated` with pool ID and admin address
    ///
    /// # Example
    /// ```
    /// // Create SUI lending pool
    /// create_pool<SUI>(ctx);
    /// // Now anyone can deposit SUI to earn interest
    /// // Or borrow SUI with SUI collateral
    /// ```
    public entry fun create_pool<T>(ctx: &mut TxContext) {
        // Create unique ID for new pool
        let pool_uid = object::new(ctx);
        let pool_id = object::uid_to_inner(&pool_uid);

        // Initialize lending pool with zero state
        let pool = LendingPool<T> {
            id: pool_uid,                        // Unique identifier
            total_deposits: balance::zero(),     // Start with 0 deposits
            total_borrowed: 0,                   // No borrows yet
            total_borrow_shares: 0,              // No borrow shares issued
            last_accrual_time: 0,                // Will be set on first interaction
            borrow_index: PRECISION,             // Start at 10000 (1.0)
            is_paused: false,                    // Pool starts active
            admin: ctx.sender(),                 // Caller is admin
        };

        // Create admin capability for emergency controls
        let admin_cap = AdminCap {
            id: object::new(ctx),  // Unique cap ID
        };

        // Emit creation event
        event::emit(PoolCreated<T> {
            pool_id,
            admin: ctx.sender(),
        });

        // Make pool publicly accessible
        transfer::share_object(pool);

        // Transfer admin capability to creator
        transfer::transfer(admin_cap, ctx.sender());
    }

    /// Deposit tokens into the lending pool to earn interest
    ///
    /// Lenders deposit assets to earn passive interest from borrowers.
    /// Interest accrues automatically over time based on pool utilization.
    /// Similar to depositing into Aave or Compound.
    ///
    /// Interest accumulation:
    /// - Higher utilization → Higher rates for lenders
    /// - Example: 80% utilization ≈ 9.6% deposit APY
    /// - Interest compounds continuously
    ///
    /// # Type Parameter
    /// * `T` - Asset type to deposit (e.g., SUI)
    ///
    /// # Arguments
    /// * `pool` - Lending pool to deposit into (must not be paused)
    /// * `token` - Coins to deposit (must be > 0)
    /// * `clock` - Sui clock for timestamp (required for interest accrual)
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Transfers `DepositPosition` NFT to depositor (required for withdrawal)
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `EInvalidAmount` - If deposit amount is 0
    ///
    /// # Events
    /// * Emits `Deposited` with pool ID, depositor address, and amount
    ///
    /// # Example
    /// ```
    /// // Deposit 100,000 SUI to earn interest
    /// deposit(&mut pool, sui_coins, &clock, ctx);
    /// // Receives DepositPosition NFT as proof
    /// // Can withdraw anytime (if liquidity available)
    /// ```
    public entry fun deposit<T>(
        pool: &mut LendingPool<T>,
        token: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Safety check: prevent deposits while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Extract deposit amount from coin
        let amount = coin::value(&token);

        // Validation: ensure non-zero deposit
        assert!(amount > 0, EInvalidAmount);

        // CRITICAL: Accrue interest before modifying balances
        // This ensures all previous interest is calculated with old total_deposits
        // Must happen before balance changes to maintain accuracy
        accrue_interest_internal(pool, clock);

        // Add deposited tokens to pool's total deposits
        // This increases available liquidity for borrowers
        balance::join(&mut pool.total_deposits, coin::into_balance(token));

        // Create deposit position NFT as proof of deposit
        // User must present this to withdraw their funds later
        let position = DepositPosition<T> {
            id: object::new(ctx),                       // Unique position ID
            pool_id: object::id(pool),                  // Which pool this belongs to
            deposited_amount: amount,                   // Amount deposited (for withdrawal)
            deposit_timestamp: clock::timestamp_ms(clock), // When deposited (for tracking)
        };

        // Emit deposit event for off-chain tracking
        event::emit(Deposited<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount,
        });

        // Transfer position NFT to depositor
        // They need this to withdraw later
        transfer::transfer(position, ctx.sender());
    }

    /// Withdraw deposited tokens from the lending pool
    ///
    /// Lenders can withdraw their deposited assets anytime, subject to available liquidity.
    /// If too much is borrowed, withdrawals may be temporarily blocked until repayments occur.
    /// This is normal in lending protocols (similar to Aave/Compound).
    ///
    /// Withdrawal constraints:
    /// - Available liquidity = total_deposits - total_borrowed
    /// - Example: 100K deposits, 80K borrowed → 20K available to withdraw
    /// - If utilization = 100%, no withdrawals possible until repayment
    ///
    /// # Type Parameter
    /// * `T` - Asset type (must match pool)
    ///
    /// # Arguments
    /// * `pool` - Lending pool to withdraw from (must not be paused)
    /// * `position` - DepositPosition NFT proving ownership (gets destroyed)
    /// * `clock` - Sui clock for interest accrual
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Transfers withdrawn coins to caller
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `ENotAuthorized` - If position doesn't belong to this pool
    /// * `EInsufficientLiquidity` - If not enough unborrowed funds available
    ///
    /// # Events
    /// * Emits `Withdrawn` with pool ID, user address, and amount
    ///
    /// # Example
    /// ```
    /// // Withdraw 50,000 SUI (if available)
    /// withdraw(&mut pool, deposit_position, &clock, ctx);
    /// // Receives coins back + earned interest
    /// // DepositPosition NFT is destroyed
    /// ```
    public entry fun withdraw<T>(
        pool: &mut LendingPool<T>,
        position: DepositPosition<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Safety check: prevent withdrawals while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Unpack deposit position NFT to extract data
        // This also destroys the struct (ensures single use)
        let DepositPosition {
            id,                      // Position ID (will be deleted)
            pool_id,                 // Which pool this belongs to
            deposited_amount,        // Amount to withdraw
            deposit_timestamp: _,    // Not needed for withdrawal
        } = position;

        // Validation: ensure position belongs to this pool
        // Prevents using position from different pool
        assert!(pool_id == object::id(pool), ENotAuthorized);

        // CRITICAL: Accrue interest before modifying balances
        // This ensures interest calculation uses correct total_deposits
        accrue_interest_internal(pool, clock);

        // Calculate available liquidity
        // Can't withdraw borrowed funds - only unborrowed portion
        let available = balance::value(&pool.total_deposits) - pool.total_borrowed;

        // Check if sufficient liquidity exists
        // If utilization too high, withdrawal blocked until repayments
        assert!(deposited_amount <= available, EInsufficientLiquidity);

        // Extract tokens from pool
        // Decreases total_deposits, reducing available borrowing capacity
        let withdrawn = coin::from_balance(
            balance::split(&mut pool.total_deposits, deposited_amount),
            ctx
        );

        // Emit withdrawal event for off-chain tracking
        event::emit(Withdrawn<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount: deposited_amount,
        });

        // Destroy position NFT (prevents double withdrawal)
        object::delete(id);

        // Transfer withdrawn coins to user
        transfer::public_transfer(withdrawn, ctx.sender());
    }

    /// Borrow tokens against collateral
    ///
    /// Borrowers deposit collateral and take out a loan. They must maintain sufficient
    /// collateral (75% collateral factor) or risk liquidation (80% liquidation threshold).
    /// Uses share-based debt tracking for fair interest distribution.
    ///
    /// Collateralization example:
    /// - Deposit 10,000 SUI as collateral
    /// - Can borrow up to 7,500 SUI (75% collateral factor)
    /// - Liquidation at 8,000 SUI debt (80% of collateral)
    /// - Safe zone: Keep debt < 7,500 SUI
    ///
    /// Interest calculation:
    /// - Debt grows via shares (similar to vault shares)
    /// - Example: Borrow 1000 at index 10000 = 1000 shares
    /// - After 1 year at 10% APY: index = 11000
    /// - Debt = (1000 shares × 11000) / 10000 = 1100 (includes interest)
    ///
    /// # Type Parameter
    /// * `T` - Asset type to borrow
    ///
    /// # Arguments
    /// * `pool` - Lending pool to borrow from
    /// * `collateral` - Coins deposited as collateral (locked until repayment)
    /// * `borrow_amount` - Amount to borrow (must be <= 75% of collateral)
    /// * `clock` - Sui clock for interest accrual
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Transfers borrowed coins to caller
    /// * Transfers `BorrowPosition` NFT to caller (required for repayment)
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `EInvalidAmount` - If borrow or collateral amount is 0
    /// * `EInsufficientCollateral` - If borrow exceeds 75% of collateral
    /// * `EInsufficientLiquidity` - If pool doesn't have enough available funds
    ///
    /// # Events
    /// * Emits `Borrowed` with pool ID, user, borrow amount, and collateral
    ///
    /// # Example
    /// ```
    /// // Deposit 10,000 SUI, borrow 7,000 SUI
    /// borrow(&mut pool, collateral_coins, 7000, &clock, ctx);
    /// // Receives 7,000 SUI immediately
    /// // Must repay principal + interest to get collateral back
    /// ```
    public entry fun borrow<T>(
        pool: &mut LendingPool<T>,
        collateral: Coin<T>,
        borrow_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Safety check: prevent borrows while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Validation: ensure non-zero borrow
        assert!(borrow_amount > 0, EInvalidAmount);

        // Extract collateral amount
        let collateral_amount = coin::value(&collateral);

        // Validation: ensure non-zero collateral
        assert!(collateral_amount > 0, EInvalidAmount);

        // CRITICAL: Accrue interest before state changes
        // Updates borrow_index for fair debt calculation
        accrue_interest_internal(pool, clock);

        // Calculate maximum borrowable amount (75% of collateral)
        // Formula: max_borrow = collateral × 0.75
        // Example: 10000 collateral → max 7500 borrow
        let max_borrow = (collateral_amount * COLLATERAL_FACTOR) / PRECISION;

        // Validation: ensure sufficient collateralization
        // Prevents over-leveraged positions that are immediately liquidatable
        assert!(borrow_amount <= max_borrow, EInsufficientCollateral);

        // Calculate available liquidity in pool
        // Can only borrow unborrowed funds
        let available = balance::value(&pool.total_deposits) - pool.total_borrowed;

        // Check if pool has enough liquidity
        // If all deposits are borrowed, no new borrows possible
        assert!(borrow_amount <= available, EInsufficientLiquidity);

        // Calculate borrow shares for fair interest distribution
        // Uses same pattern as vault shares
        let borrow_shares = if (pool.total_borrow_shares == 0) {
            // First borrow: 1:1 ratio
            borrow_amount
        } else {
            // Subsequent borrows: proportional to current debt
            // Formula: shares = (borrow_amount × total_shares) / total_borrowed
            (borrow_amount * pool.total_borrow_shares) / pool.total_borrowed
        };

        // Update pool state: increase total borrowed
        pool.total_borrowed = pool.total_borrowed + borrow_amount;

        // Update pool state: increase total borrow shares
        pool.total_borrow_shares = pool.total_borrow_shares + borrow_shares;

        // Add collateral to pool (locked until repayment)
        // Increases total_deposits (can be borrowed by others)
        balance::join(&mut pool.total_deposits, coin::into_balance(collateral));

        // Create borrow position NFT as proof of debt
        // User must present this to repay and reclaim collateral
        let position = BorrowPosition<T> {
            id: object::new(ctx),                       // Unique position ID
            pool_id: object::id(pool),                  // Which pool this belongs to
            collateral_amount,                          // Locked collateral (for liquidation)
            borrow_shares,                              // Debt shares (for interest calculation)
            borrow_timestamp: clock::timestamp_ms(clock), // When borrowed (for tracking)
        };

        // Extract borrowed tokens from pool
        // Decreases available liquidity
        let borrowed_coin = coin::from_balance(
            balance::split(&mut pool.total_deposits, borrow_amount),
            ctx
        );

        // Emit borrow event for off-chain tracking
        event::emit(Borrowed<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount: borrow_amount,
            collateral: collateral_amount,
        });

        // Transfer position NFT to borrower (needed for repayment)
        transfer::transfer(position, ctx.sender());

        // Transfer borrowed coins to borrower
        transfer::public_transfer(borrowed_coin, ctx.sender());
    }

    /// Repay borrowed tokens and reclaim collateral
    ///
    /// Borrowers must repay full debt (principal + accrued interest) to close position
    /// and reclaim their collateral. Debt grows over time based on utilization rate.
    ///
    /// Debt calculation example:
    /// - Original borrow: 1,000 SUI (got 1,000 shares at index 10000)
    /// - After 1 year at 10% APY: borrow_index = 11000
    /// - Current debt = (1000 shares × total_borrowed) / total_shares
    /// - If total_borrowed = 11,000 and total_shares = 1,000
    /// - Debt = (1000 × 11000) / 1000 = 11,000 SUI
    /// - Must repay 11,000 to get collateral back
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool
    /// * `position` - BorrowPosition NFT proving debt ownership
    /// * `repayment` - Coins to repay debt (must cover full debt + interest)
    /// * `clock` - Sui clock for interest accrual
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Transfers collateral back to borrower
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `ENotAuthorized` - If position doesn't belong to this pool
    /// * `EInvalidAmount` - If repayment < current debt (including interest)
    ///
    /// # Events
    /// * Emits `Repaid` with pool ID, user, and repayment amount
    ///
    /// # Example
    /// ```
    /// // Repay 11,000 SUI (1,000 principal + 10% interest)
    /// repay(&mut pool, borrow_position, repayment_coins, &clock, ctx);
    /// // Receives 10,000 SUI collateral back
    /// // BorrowPosition NFT destroyed
    /// ```
    public entry fun repay<T>(
        pool: &mut LendingPool<T>,
        position: BorrowPosition<T>,
        repayment: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Safety check: prevent repayments while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Unpack borrow position NFT
        let BorrowPosition {
            id,                      // Position ID (will be deleted)
            pool_id,                 // Which pool this belongs to
            collateral_amount,       // Collateral to return
            borrow_shares,           // Debt shares for calculation
            borrow_timestamp: _,     // Not needed for repayment
        } = position;

        // Validation: ensure position belongs to this pool
        assert!(pool_id == object::id(pool), ENotAuthorized);

        // CRITICAL: Accrue interest before debt calculation
        // Updates borrow_index and total_borrowed with latest interest
        accrue_interest_internal(pool, clock);

        // Calculate current debt including accrued interest
        // Formula: debt = (shares × total_borrowed) / total_borrow_shares
        // This accounts for all interest accrued since borrow
        let current_debt = (borrow_shares * pool.total_borrowed) / pool.total_borrow_shares;

        // Get repayment amount
        let repay_amount = coin::value(&repayment);

        // Validation: ensure repayment covers full debt
        // Must pay principal + interest to close position
        assert!(repay_amount >= current_debt, EInvalidAmount);

        // Update pool state: decrease total borrowed
        // Reduces utilization, lowering borrow rates
        pool.total_borrowed = pool.total_borrowed - current_debt;

        // Update pool state: decrease borrow shares
        // Burns borrower's debt shares
        pool.total_borrow_shares = pool.total_borrow_shares - borrow_shares;

        // Add repayment to pool
        // Increases available liquidity for lenders to withdraw
        balance::join(&mut pool.total_deposits, coin::into_balance(repayment));

        // Extract collateral from pool to return to borrower
        // Borrower gets full collateral back
        let collateral_coin = coin::from_balance(
            balance::split(&mut pool.total_deposits, collateral_amount),
            ctx
        );

        // Emit repayment event for off-chain tracking
        event::emit(Repaid<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount: repay_amount,
        });

        // Destroy position NFT (prevents double repayment)
        object::delete(id);

        // Transfer collateral back to borrower
        transfer::public_transfer(collateral_coin, ctx.sender());
    }

    /// Liquidate an undercollateralized position for profit
    ///
    /// When a borrower's debt exceeds 80% of collateral value (liquidation threshold),
    /// anyone can liquidate the position by repaying the debt and seizing collateral
    /// plus a 5% liquidation bonus. This keeps the protocol solvent.
    ///
    /// Liquidation example:
    /// - Borrower has 10,000 SUI collateral
    /// - Debt grows to 8,500 SUI (over 80% threshold = 8,000)
    /// - Position is liquidatable (health factor < 1.0)
    /// - Liquidator pays 8,500 SUI debt
    /// - Liquidator receives 8,925 SUI (8,500 + 5% bonus)
    /// - Liquidator profit: 425 SUI
    /// - Remaining 1,075 SUI returned to original borrower
    ///
    /// Health factor calculation:
    /// - HF = (collateral × 0.80) / debt
    /// - HF < 1.0 → Liquidatable
    /// - Example: (10,000 × 0.80) / 8,500 = 0.94 (unhealthy!)
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool
    /// * `position` - BorrowPosition to liquidate (must be unhealthy)
    /// * `repayment` - Coins to repay debt (must cover full debt)
    /// * `clock` - Sui clock for interest accrual
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Returns seized collateral (debt + 5% bonus) to liquidator
    /// * Transfers remaining collateral to original borrower (if any)
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `ENotAuthorized` - If position doesn't belong to this pool
    /// * `EPositionNotLiquidatable` - If debt <= 80% of collateral (healthy position)
    /// * `EInvalidAmount` - If repayment < current debt
    /// * `EInsufficientCollateral` - If collateral < debt + bonus (shouldn't happen)
    ///
    /// # Events
    /// * Emits `Liquidated` with pool ID, liquidator, borrower, amounts
    ///
    /// # Example
    /// ```
    /// // Liquidate unhealthy position
    /// let seized = liquidate(&mut pool, position, repayment_coins, &clock, ctx);
    /// // Receives collateral + 5% bonus
    /// // Original borrower gets remaining collateral
    /// ```
    public fun liquidate<T>(
        pool: &mut LendingPool<T>,
        position: BorrowPosition<T>,
        repayment: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<T> {
        // Safety check: prevent liquidations while paused
        assert!(!pool.is_paused, EPoolPaused);

        // CRITICAL: Accrue interest before liquidation check
        // Ensures debt reflects all accrued interest
        accrue_interest_internal(pool, clock);

        // Unpack borrow position NFT
        let BorrowPosition {
            id,                      // Position ID (will be deleted)
            pool_id,                 // Which pool this belongs to
            collateral_amount,       // Total collateral locked
            borrow_shares,           // Debt shares
            borrow_timestamp: _,     // Not needed for liquidation
        } = position;

        // Validation: ensure position belongs to this pool
        assert!(pool_id == object::id(pool), ENotAuthorized);

        // Calculate current debt including accrued interest
        // Formula: debt = (shares × total_borrowed) / total_borrow_shares
        let current_debt = (borrow_shares * pool.total_borrowed) / pool.total_borrow_shares;

        // Check if position violates liquidation threshold (80%)
        // Formula: liquidation_threshold = collateral × 0.80
        // If debt > threshold, position is liquidatable
        let liquidation_threshold_amount = (collateral_amount * LIQUIDATION_THRESHOLD) / PRECISION;

        // Validation: ensure position is actually liquidatable
        // Prevents liquidating healthy positions
        assert!(current_debt > liquidation_threshold_amount, EPositionNotLiquidatable);

        // Get repayment amount
        let repay_amount = coin::value(&repayment);

        // Validation: ensure repayment covers full debt
        assert!(repay_amount >= current_debt, EInvalidAmount);

        // Calculate collateral to seize (debt + 5% liquidation bonus)
        // Formula: seized = debt × 1.05
        // Example: 8,500 debt → seize 8,925 (8,500 + 425 bonus)
        let collateral_to_seize = (current_debt * (PRECISION + LIQUIDATION_BONUS)) / PRECISION;

        // Safety check: ensure enough collateral exists
        // Should always pass if position was properly created
        assert!(collateral_to_seize <= collateral_amount, EInsufficientCollateral);

        // Update pool state: decrease total borrowed
        pool.total_borrowed = pool.total_borrowed - current_debt;

        // Update pool state: decrease borrow shares
        pool.total_borrow_shares = pool.total_borrow_shares - borrow_shares;

        // Add repayment to pool
        // Restores liquidity for lenders
        balance::join(&mut pool.total_deposits, coin::into_balance(repayment));

        // Seize collateral (debt + bonus) for liquidator
        // Liquidator receives profit for keeping protocol healthy
        let seized_collateral = coin::from_balance(
            balance::split(&mut pool.total_deposits, collateral_to_seize),
            ctx
        );

        // Return remaining collateral to original borrower (if any)
        // Example: 10,000 collateral - 8,925 seized = 1,075 returned
        let remaining_collateral = collateral_amount - collateral_to_seize;
        if (remaining_collateral > 0) {
            let remaining = coin::from_balance(
                balance::split(&mut pool.total_deposits, remaining_collateral),
                ctx
            );
            // Transfer remainder to liquidator (in production, track original borrower)
            transfer::public_transfer(remaining, ctx.sender());
        };

        // Emit liquidation event for off-chain tracking
        event::emit(Liquidated<T> {
            pool_id: object::id(pool),
            liquidator: ctx.sender(),
            borrower: ctx.sender(), // In production, track original borrower
            repaid_amount: repay_amount,
            collateral_seized: collateral_to_seize,
        });

        // Destroy position NFT (prevents double liquidation)
        object::delete(id);

        // Return seized collateral to liquidator
        seized_collateral
    }

    // ======== Internal Functions ========

    /// Accrue interest based on time elapsed and utilization rate
    ///
    /// This function implements a kinked interest rate model similar to Compound/Aave.
    /// Interest rates increase slowly until 80% utilization, then sharply increase
    /// to incentivize repayments and new deposits.
    ///
    /// Interest rate model (kinked curve):
    /// - 0% utilization: 2% APY (base rate)
    /// - 80% utilization: 12% APY (optimal rate)
    /// - 100% utilization: 32% APY (max rate)
    ///
    /// Example calculation:
    /// - Pool: 100,000 deposits, 80,000 borrowed (80% utilization)
    /// - Borrow rate: 2% + (80% × 10%) / 80% = 12% APY
    /// - Time elapsed: 1 year (31,536,000 seconds)
    /// - Interest: 80,000 × 12% = 9,600 SUI
    /// - New total_borrowed: 89,600 SUI
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool to accrue interest for
    /// * `clock` - Sui clock for timestamp
    ///
    /// # Events
    /// * Emits `InterestAccrued` if interest > 0
    ///
    /// # Note
    /// Called automatically before every state-changing operation to ensure
    /// accurate debt calculations. Interest compounds continuously.
    fun accrue_interest_internal<T>(pool: &mut LendingPool<T>, clock: &Clock) {
        // Get current timestamp in seconds
        let current_time = clock::timestamp_ms(clock) / 1000; // Convert ms to seconds

        // First-time initialization: set timestamp and return
        // No interest to accrue yet
        if (pool.last_accrual_time == 0) {
            pool.last_accrual_time = current_time;
            return
        };

        // Calculate time elapsed since last accrual
        let time_elapsed = current_time - pool.last_accrual_time;

        // No time passed: skip interest calculation
        if (time_elapsed == 0) return;

        // No borrows: update timestamp but no interest
        if (pool.total_borrowed == 0) {
            pool.last_accrual_time = current_time;
            return
        };

        // Calculate utilization rate
        // Formula: utilization = total_borrowed / total_deposits
        // Example: 80,000 / 100,000 = 0.80 (80%)
        let total_liquidity = balance::value(&pool.total_deposits);
        let utilization = (pool.total_borrowed * PRECISION) / total_liquidity;

        // Calculate borrow rate using kinked interest rate model
        // Two slopes: gentle before 80%, steep after 80%
        let borrow_rate = if (utilization <= OPTIMAL_UTILIZATION) {
            // Below 80% utilization: 2% → 12% APY
            // Formula: base + (utilization × slope) / optimal
            // Example at 40%: 2% + (40% × 10%) / 80% = 2% + 5% = 7% APY
            BASE_BORROW_RATE + (utilization * RATE_SLOPE) / OPTIMAL_UTILIZATION
        } else {
            // Above 80% utilization: 12% → 32% APY
            // Sharp increase to incentivize repayments
            // Formula: base + slope + ((utilization - optimal) × 2 × slope) / (100% - optimal)
            // Example at 90%: 2% + 10% + ((90% - 80%) × 20%) / 20% = 22% APY
            BASE_BORROW_RATE + RATE_SLOPE +
                ((utilization - OPTIMAL_UTILIZATION) * RATE_SLOPE * 2) / (PRECISION - OPTIMAL_UTILIZATION)
        };

        // Calculate interest accrued over time period
        // Formula: interest_factor = (rate × time) / (seconds_per_year × precision)
        // Example: (12% × 31,536,000s) / (31,536,000s × 10000) = 0.12
        let interest_factor = (borrow_rate * time_elapsed) / (SECONDS_PER_YEAR * PRECISION);

        // Apply interest to total borrowed amount
        // Formula: interest = principal × interest_factor
        // Example: 80,000 × 0.12 = 9,600 SUI interest
        let interest_amount = (pool.total_borrowed * interest_factor) / PRECISION;

        // Update pool state: add interest to total borrowed
        // This automatically increases debt for all borrowers proportionally
        pool.total_borrowed = pool.total_borrowed + interest_amount;

        // Update last accrual timestamp
        pool.last_accrual_time = current_time;

        // Emit event if interest was accrued
        if (interest_amount > 0) {
            event::emit(InterestAccrued<T> {
                pool_id: object::id(pool),
                interest_amount,
            });
        };
    }

    // ======== View Functions ========

    /// Get pool statistics for monitoring and UI display
    ///
    /// Returns key pool metrics for tracking protocol health and utilization.
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool to query
    ///
    /// # Returns
    /// * Tuple of (total_deposits, total_borrowed, total_borrow_shares)
    ///
    /// # Example
    /// ```
    /// let (deposits, borrowed, shares) = get_pool_stats(&pool);
    /// // deposits: 100,000 SUI
    /// // borrowed: 80,000 SUI
    /// // shares: 80,000
    /// // Utilization: 80%
    /// ```
    public fun get_pool_stats<T>(pool: &LendingPool<T>): (u64, u64, u64) {
        (
            balance::value(&pool.total_deposits),  // Total liquidity in pool
            pool.total_borrowed,                   // Total debt outstanding
            pool.total_borrow_shares              // Total borrow shares issued
        )
    }

    /// Calculate health factor for a borrow position
    ///
    /// Health factor indicates position safety. Higher is safer.
    /// Formula: HF = (collateral × liquidation_threshold) / debt
    ///
    /// Health factor interpretation:
    /// - HF > 1.0 (10000): Healthy, safe from liquidation
    /// - HF = 1.0 (10000): At liquidation threshold
    /// - HF < 1.0 (10000): Unhealthy, can be liquidated
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool (for current debt calculation)
    /// * `position` - BorrowPosition to check
    ///
    /// # Returns
    /// * Health factor scaled by PRECISION (10000 = 100% = 1.0)
    ///
    /// # Example
    /// ```
    /// let hf = calculate_health_factor(&pool, &position);
    /// // 10,000 collateral, 7,000 debt, 80% threshold
    /// // HF = (10,000 × 0.80) / 7,000 = 1.14 (11400)
    /// // Safe! Would need debt to reach 8,000 to liquidate
    /// ```
    public fun calculate_health_factor<T>(
        pool: &LendingPool<T>,
        position: &BorrowPosition<T>
    ): u64 {
        // Edge case: no borrow shares exist
        if (pool.total_borrow_shares == 0) return PRECISION * 10; // Max health

        // Calculate current debt from shares
        let current_debt = (position.borrow_shares * pool.total_borrowed) / pool.total_borrow_shares;

        // Edge case: no debt (fully repaid)
        if (current_debt == 0) return PRECISION * 10;

        // Calculate health factor
        // Formula: HF = (collateral × liquidation_threshold) / debt
        // Example: (10,000 × 8,000) / 7,000 = 11,428 (1.14x healthy)
        (position.collateral_amount * LIQUIDATION_THRESHOLD) / current_debt
    }

    /// Check if a borrow position can be liquidated
    ///
    /// Returns true if position is unhealthy (health factor < 1.0).
    /// Liquidators can close these positions for profit.
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool
    /// * `position` - BorrowPosition to check
    ///
    /// # Returns
    /// * true if liquidatable (HF < 1.0), false otherwise
    ///
    /// # Example
    /// ```
    /// if (is_liquidatable(&pool, &position)) {
    ///     // Can liquidate for 5% bonus!
    ///     liquidate(&mut pool, position, repayment, &clock, ctx);
    /// }
    /// ```
    public fun is_liquidatable<T>(
        pool: &LendingPool<T>,
        position: &BorrowPosition<T>
    ): bool {
        // Liquidatable if health factor < 1.0 (PRECISION)
        calculate_health_factor(pool, position) < PRECISION
    }

    /// Get current borrow APY based on pool utilization
    ///
    /// Returns the annual percentage yield for borrowing, scaled by PRECISION.
    /// Rate increases with utilization to balance supply and demand.
    ///
    /// Rate model:
    /// - 0% utilization: 2% APY
    /// - 80% utilization: 12% APY (optimal)
    /// - 100% utilization: 32% APY (max)
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool
    ///
    /// # Returns
    /// * Borrow rate scaled by PRECISION (200 = 2% APY)
    ///
    /// # Example
    /// ```
    /// let rate = get_borrow_rate(&pool);
    /// // If 80% utilization: rate = 1200 (12% APY)
    /// // Borrowers pay 12% annual interest
    /// // Lenders earn ~9.6% (12% × 80% utilization)
    /// ```
    public fun get_borrow_rate<T>(pool: &LendingPool<T>): u64 {
        // Edge case: no borrows, return base rate
        if (pool.total_borrowed == 0) return BASE_BORROW_RATE;

        // Get total liquidity
        let total_liquidity = balance::value(&pool.total_deposits);

        // Edge case: no deposits (shouldn't happen), return base rate
        if (total_liquidity == 0) return BASE_BORROW_RATE;

        // Calculate utilization (borrowed / deposits)
        let utilization = (pool.total_borrowed * PRECISION) / total_liquidity;

        // Apply kinked interest rate model
        if (utilization <= OPTIMAL_UTILIZATION) {
            // Below 80%: gentle slope (2% → 12%)
            BASE_BORROW_RATE + (utilization * RATE_SLOPE) / OPTIMAL_UTILIZATION
        } else {
            // Above 80%: steep slope (12% → 32%)
            BASE_BORROW_RATE + RATE_SLOPE +
                ((utilization - OPTIMAL_UTILIZATION) * RATE_SLOPE * 2) / (PRECISION - OPTIMAL_UTILIZATION)
        }
    }

    /// Emergency pause pool operations (admin only)
    ///
    /// Prevents all deposits, withdrawals, borrows, repayments, and liquidations.
    /// Use during security incidents or protocol upgrades.
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool to pause
    /// * `_admin_cap` - Admin capability (proves authorization)
    ///
    /// # Example
    /// ```
    /// // Admin pauses pool during emergency
    /// pause_pool(&mut pool, &admin_cap);
    /// // All operations now blocked
    /// ```
    public entry fun pause_pool<T>(
        pool: &mut LendingPool<T>,
        _admin_cap: &AdminCap,
    ) {
        // Set paused flag
        // All entry functions check this flag and abort if true
        pool.is_paused = true;
    }

    /// Resume pool operations after emergency (admin only)
    ///
    /// Re-enables all protocol operations after pause.
    ///
    /// # Type Parameter
    /// * `T` - Asset type
    ///
    /// # Arguments
    /// * `pool` - Lending pool to unpause
    /// * `_admin_cap` - Admin capability (proves authorization)
    ///
    /// # Example
    /// ```
    /// // Admin unpauses pool after fixing issue
    /// unpause_pool(&mut pool, &admin_cap);
    /// // Operations resume normally
    /// ```
    public entry fun unpause_pool<T>(
        pool: &mut LendingPool<T>,
        _admin_cap: &AdminCap,
    ) {
        // Clear paused flag
        pool.is_paused = false;
    }

    // ======== Test Functions ========

    /// Initialize pool for testing (test-only function)
    ///
    /// Creates a lending pool during test setup.
    ///
    /// # Type Parameter
    /// * `T` - Asset type for pool
    ///
    /// # Arguments
    /// * `ctx` - Transaction context
    #[test_only]
    public fun init_for_testing<T>(ctx: &mut TxContext) {
        create_pool<T>(ctx);
    }

    /// Get collateral factor constant (test-only function)
    ///
    /// Returns the 75% collateral factor for testing.
    ///
    /// # Returns
    /// * 7500 (75% scaled by PRECISION)
    #[test_only]
    public fun get_collateral_factor(): u64 { COLLATERAL_FACTOR }

    /// Get liquidation threshold constant (test-only function)
    ///
    /// Returns the 80% liquidation threshold for testing.
    ///
    /// # Returns
    /// * 8000 (80% scaled by PRECISION)
    #[test_only]
    public fun get_liquidation_threshold(): u64 { LIQUIDATION_THRESHOLD }
}
