/// Lending Protocol - Overcollateralized Lending and Borrowing
/// Features: deposits, borrows, interest accrual, liquidations, health factors
module lending_protocol::lending_pool {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};

    // ======== Error Codes ========
    const EInsufficientCollateral: u64 = 1;
    const EInsufficientLiquidity: u64 = 2;
    const EInvalidAmount: u64 = 3;
    const EPositionNotLiquidatable: u64 = 4;
    const ENoPositionFound: u64 = 5;
    const EPoolPaused: u64 = 6;
    const ENotAuthorized: u64 = 7;
    const EPositionHealthy: u64 = 8;

    // ======== Constants ========
    const PRECISION: u64 = 10000;
    const COLLATERAL_FACTOR: u64 = 7500; // 75% - how much can be borrowed against collateral
    const LIQUIDATION_THRESHOLD: u64 = 8000; // 80% - when position can be liquidated
    const LIQUIDATION_BONUS: u64 = 500; // 5% - bonus for liquidators
    const BASE_BORROW_RATE: u64 = 200; // 2% base borrow rate
    const RATE_SLOPE: u64 = 1000; // 10% rate slope based on utilization
    const OPTIMAL_UTILIZATION: u64 = 8000; // 80% optimal utilization

    const SECONDS_PER_YEAR: u64 = 31536000;

    // ======== Structs ========

    /// Main lending pool for a specific asset
    public struct LendingPool<phantom T> has key {
        id: UID,
        /// Total deposits in the pool
        total_deposits: Balance<T>,
        /// Total amount borrowed
        total_borrowed: u64,
        /// Total borrow shares
        total_borrow_shares: u64,
        /// Last time interest was accrued
        last_accrual_time: u64,
        /// Accumulated borrow index
        borrow_index: u64,
        /// Pool paused status
        is_paused: bool,
        /// Admin address
        admin: address,
    }

    /// User's deposit position
    public struct DepositPosition<phantom T> has key, store {
        id: UID,
        pool_id: ID,
        deposited_amount: u64,
        deposit_timestamp: u64,
    }

    /// User's borrow position
    public struct BorrowPosition<phantom T> has key, store {
        id: UID,
        pool_id: ID,
        /// Collateral amount deposited
        collateral_amount: u64,
        /// Borrow shares (not actual amount)
        borrow_shares: u64,
        /// Timestamp of borrow
        borrow_timestamp: u64,
    }

    /// Admin capability
    public struct AdminCap has key, store {
        id: UID,
    }

    // ======== Events ========

    public struct PoolCreated<phantom T> has copy, drop {
        pool_id: ID,
        admin: address,
    }

    public struct Deposited<phantom T> has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
    }

    public struct Withdrawn<phantom T> has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
    }

    public struct Borrowed<phantom T> has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
        collateral: u64,
    }

    public struct Repaid<phantom T> has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
    }

    public struct Liquidated<phantom T> has copy, drop {
        pool_id: ID,
        liquidator: address,
        borrower: address,
        repaid_amount: u64,
        collateral_seized: u64,
    }

    public struct InterestAccrued<phantom T> has copy, drop {
        pool_id: ID,
        interest_amount: u64,
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
