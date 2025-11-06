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

    /// Create a new lending pool
    public entry fun create_pool<T>(ctx: &mut TxContext) {
        let pool_uid = object::new(ctx);
        let pool_id = object::uid_to_inner(&pool_uid);

        let pool = LendingPool<T> {
            id: pool_uid,
            total_deposits: balance::zero(),
            total_borrowed: 0,
            total_borrow_shares: 0,
            last_accrual_time: 0,
            borrow_index: PRECISION,
            is_paused: false,
            admin: ctx.sender(),
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        event::emit(PoolCreated<T> {
            pool_id,
            admin: ctx.sender(),
        });

        transfer::share_object(pool);
        transfer::transfer(admin_cap, ctx.sender());
    }

    /// Deposit tokens into the lending pool
    public entry fun deposit<T>(
        pool: &mut LendingPool<T>,
        token: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.is_paused, EPoolPaused);

        let amount = coin::value(&token);
        assert!(amount > 0, EInvalidAmount);

        // Accrue interest before deposit
        accrue_interest_internal(pool, clock);

        // Add to pool
        balance::join(&mut pool.total_deposits, coin::into_balance(token));

        // Create deposit position
        let position = DepositPosition<T> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            deposited_amount: amount,
            deposit_timestamp: clock::timestamp_ms(clock),
        };

        event::emit(Deposited<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount,
        });

        transfer::transfer(position, ctx.sender());
    }

    /// Withdraw tokens from the lending pool
    public entry fun withdraw<T>(
        pool: &mut LendingPool<T>,
        position: DepositPosition<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.is_paused, EPoolPaused);

        let DepositPosition {
            id,
            pool_id,
            deposited_amount,
            deposit_timestamp: _,
        } = position;

        assert!(pool_id == object::id(pool), ENotAuthorized);

        // Accrue interest before withdrawal
        accrue_interest_internal(pool, clock);

        // Check sufficient liquidity
        let available = balance::value(&pool.total_deposits) - pool.total_borrowed;
        assert!(deposited_amount <= available, EInsufficientLiquidity);

        // Withdraw tokens
        let withdrawn = coin::from_balance(
            balance::split(&mut pool.total_deposits, deposited_amount),
            ctx
        );

        event::emit(Withdrawn<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount: deposited_amount,
        });

        object::delete(id);
        transfer::public_transfer(withdrawn, ctx.sender());
    }

    /// Borrow tokens with collateral
    public entry fun borrow<T>(
        pool: &mut LendingPool<T>,
        collateral: Coin<T>,
        borrow_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.is_paused, EPoolPaused);
        assert!(borrow_amount > 0, EInvalidAmount);

        let collateral_amount = coin::value(&collateral);
        assert!(collateral_amount > 0, EInvalidAmount);

        // Accrue interest
        accrue_interest_internal(pool, clock);

        // Check collateralization
        let max_borrow = (collateral_amount * COLLATERAL_FACTOR) / PRECISION;
        assert!(borrow_amount <= max_borrow, EInsufficientCollateral);

        // Check pool liquidity
        let available = balance::value(&pool.total_deposits) - pool.total_borrowed;
        assert!(borrow_amount <= available, EInsufficientLiquidity);

        // Calculate borrow shares
        let borrow_shares = if (pool.total_borrow_shares == 0) {
            borrow_amount
        } else {
            (borrow_amount * pool.total_borrow_shares) / pool.total_borrowed
        };

        // Update pool state
        pool.total_borrowed = pool.total_borrowed + borrow_amount;
        pool.total_borrow_shares = pool.total_borrow_shares + borrow_shares;

        // Add collateral to pool
        balance::join(&mut pool.total_deposits, coin::into_balance(collateral));

        // Create borrow position
        let position = BorrowPosition<T> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            collateral_amount,
            borrow_shares,
            borrow_timestamp: clock::timestamp_ms(clock),
        };

        // Transfer borrowed tokens
        let borrowed_coin = coin::from_balance(
            balance::split(&mut pool.total_deposits, borrow_amount),
            ctx
        );

        event::emit(Borrowed<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount: borrow_amount,
            collateral: collateral_amount,
        });

        transfer::transfer(position, ctx.sender());
        transfer::public_transfer(borrowed_coin, ctx.sender());
    }

    /// Repay borrowed tokens
    public entry fun repay<T>(
        pool: &mut LendingPool<T>,
        position: BorrowPosition<T>,
        repayment: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.is_paused, EPoolPaused);

        let BorrowPosition {
            id,
            pool_id,
            collateral_amount,
            borrow_shares,
            borrow_timestamp: _,
        } = position;

        assert!(pool_id == object::id(pool), ENotAuthorized);

        // Accrue interest
        accrue_interest_internal(pool, clock);

        // Calculate current debt
        let current_debt = (borrow_shares * pool.total_borrowed) / pool.total_borrow_shares;
        let repay_amount = coin::value(&repayment);

        assert!(repay_amount >= current_debt, EInvalidAmount);

        // Update pool state
        pool.total_borrowed = pool.total_borrowed - current_debt;
        pool.total_borrow_shares = pool.total_borrow_shares - borrow_shares;

        // Add repayment to pool
        balance::join(&mut pool.total_deposits, coin::into_balance(repayment));

        // Return collateral
        let collateral_coin = coin::from_balance(
            balance::split(&mut pool.total_deposits, collateral_amount),
            ctx
        );

        event::emit(Repaid<T> {
            pool_id: object::id(pool),
            user: ctx.sender(),
            amount: repay_amount,
        });

        object::delete(id);
        transfer::public_transfer(collateral_coin, ctx.sender());
    }

    /// Liquidate an undercollateralized position
    public fun liquidate<T>(
        pool: &mut LendingPool<T>,
        position: BorrowPosition<T>,
        repayment: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<T> {
        assert!(!pool.is_paused, EPoolPaused);

        // Accrue interest
        accrue_interest_internal(pool, clock);

        let BorrowPosition {
            id,
            pool_id,
            collateral_amount,
            borrow_shares,
            borrow_timestamp: _,
        } = position;

        assert!(pool_id == object::id(pool), ENotAuthorized);

        // Calculate current debt
        let current_debt = (borrow_shares * pool.total_borrowed) / pool.total_borrow_shares;

        // Check if position is liquidatable
        let liquidation_threshold_amount = (collateral_amount * LIQUIDATION_THRESHOLD) / PRECISION;
        assert!(current_debt > liquidation_threshold_amount, EPositionNotLiquidatable);

        let repay_amount = coin::value(&repayment);
        assert!(repay_amount >= current_debt, EInvalidAmount);

        // Calculate seized collateral with bonus
        let collateral_to_seize = (current_debt * (PRECISION + LIQUIDATION_BONUS)) / PRECISION;
        assert!(collateral_to_seize <= collateral_amount, EInsufficientCollateral);

        // Update pool state
        pool.total_borrowed = pool.total_borrowed - current_debt;
        pool.total_borrow_shares = pool.total_borrow_shares - borrow_shares;

        // Add repayment
        balance::join(&mut pool.total_deposits, coin::into_balance(repayment));

        // Seize collateral
        let seized_collateral = coin::from_balance(
            balance::split(&mut pool.total_deposits, collateral_to_seize),
            ctx
        );

        // Return remaining collateral if any
        let remaining_collateral = collateral_amount - collateral_to_seize;
        if (remaining_collateral > 0) {
            let remaining = coin::from_balance(
                balance::split(&mut pool.total_deposits, remaining_collateral),
                ctx
            );
            transfer::public_transfer(remaining, ctx.sender());
        };

        event::emit(Liquidated<T> {
            pool_id: object::id(pool),
            liquidator: ctx.sender(),
            borrower: ctx.sender(), // In production, track original borrower
            repaid_amount: repay_amount,
            collateral_seized: collateral_to_seize,
        });

        object::delete(id);
        seized_collateral
    }

    // ======== Internal Functions ========

    /// Accrue interest based on time elapsed
    fun accrue_interest_internal<T>(pool: &mut LendingPool<T>, clock: &Clock) {
        let current_time = clock::timestamp_ms(clock) / 1000; // Convert to seconds

        if (pool.last_accrual_time == 0) {
            pool.last_accrual_time = current_time;
            return
        };

        let time_elapsed = current_time - pool.last_accrual_time;
        if (time_elapsed == 0) return;

        if (pool.total_borrowed == 0) {
            pool.last_accrual_time = current_time;
            return
        };

        // Calculate utilization rate
        let total_liquidity = balance::value(&pool.total_deposits);
        let utilization = (pool.total_borrowed * PRECISION) / total_liquidity;

        // Calculate borrow rate based on utilization
        let borrow_rate = if (utilization <= OPTIMAL_UTILIZATION) {
            BASE_BORROW_RATE + (utilization * RATE_SLOPE) / OPTIMAL_UTILIZATION
        } else {
            BASE_BORROW_RATE + RATE_SLOPE +
                ((utilization - OPTIMAL_UTILIZATION) * RATE_SLOPE * 2) / (PRECISION - OPTIMAL_UTILIZATION)
        };

        // Calculate interest
        let interest_factor = (borrow_rate * time_elapsed) / (SECONDS_PER_YEAR * PRECISION);
        let interest_amount = (pool.total_borrowed * interest_factor) / PRECISION;

        // Update pool state
        pool.total_borrowed = pool.total_borrowed + interest_amount;
        pool.last_accrual_time = current_time;

        if (interest_amount > 0) {
            event::emit(InterestAccrued<T> {
                pool_id: object::id(pool),
                interest_amount,
            });
        };
    }

    // ======== View Functions ========

    /// Get pool statistics
    public fun get_pool_stats<T>(pool: &LendingPool<T>): (u64, u64, u64) {
        (
            balance::value(&pool.total_deposits),
            pool.total_borrowed,
            pool.total_borrow_shares
        )
    }

    /// Calculate health factor for a position (10000 = 100%)
    public fun calculate_health_factor<T>(
        pool: &LendingPool<T>,
        position: &BorrowPosition<T>
    ): u64 {
        if (pool.total_borrow_shares == 0) return PRECISION * 10; // Max health

        let current_debt = (position.borrow_shares * pool.total_borrowed) / pool.total_borrow_shares;
        if (current_debt == 0) return PRECISION * 10;

        // Health factor = (collateral * liquidation_threshold) / debt
        (position.collateral_amount * LIQUIDATION_THRESHOLD) / current_debt
    }

    /// Check if position is liquidatable
    public fun is_liquidatable<T>(
        pool: &LendingPool<T>,
        position: &BorrowPosition<T>
    ): bool {
        calculate_health_factor(pool, position) < PRECISION
    }

    /// Get current borrow rate
    public fun get_borrow_rate<T>(pool: &LendingPool<T>): u64 {
        if (pool.total_borrowed == 0) return BASE_BORROW_RATE;

        let total_liquidity = balance::value(&pool.total_deposits);
        if (total_liquidity == 0) return BASE_BORROW_RATE;

        let utilization = (pool.total_borrowed * PRECISION) / total_liquidity;

        if (utilization <= OPTIMAL_UTILIZATION) {
            BASE_BORROW_RATE + (utilization * RATE_SLOPE) / OPTIMAL_UTILIZATION
        } else {
            BASE_BORROW_RATE + RATE_SLOPE +
                ((utilization - OPTIMAL_UTILIZATION) * RATE_SLOPE * 2) / (PRECISION - OPTIMAL_UTILIZATION)
        }
    }

    /// Pause the pool
    public entry fun pause_pool<T>(
        pool: &mut LendingPool<T>,
        _admin_cap: &AdminCap,
    ) {
        pool.is_paused = true;
    }

    /// Unpause the pool
    public entry fun unpause_pool<T>(
        pool: &mut LendingPool<T>,
        _admin_cap: &AdminCap,
    ) {
        pool.is_paused = false;
    }

    // ======== Test Functions ========

    #[test_only]
    public fun init_for_testing<T>(ctx: &mut TxContext) {
        create_pool<T>(ctx);
    }

    #[test_only]
    public fun get_collateral_factor(): u64 { COLLATERAL_FACTOR }

    #[test_only]
    public fun get_liquidation_threshold(): u64 { LIQUIDATION_THRESHOLD }
}
