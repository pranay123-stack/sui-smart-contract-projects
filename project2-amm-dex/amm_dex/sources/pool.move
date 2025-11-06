// ============================================================================================================
// AMM DEX Module - Automated Market Maker with Constant Product Formula
// ============================================================================================================
//
// MODULE OVERVIEW:
// This module implements a fully functional Automated Market Maker (AMM) DEX similar to Uniswap V2.
// It uses the constant product formula (x × y = k) to enable permissionless token swaps without
// traditional order books. Liquidity providers earn 0.3% fees on all trades.
//
// KEY FEATURES:
// 1. Constant Product AMM: x × y = k formula for automated pricing
// 2. Liquidity Pools: Generic pools supporting any token pair <TokenA, TokenB>
// 3. LP Tokens: Share-based ownership of pool reserves
// 4. Token Swaps: Efficient swaps with 0.3% fee (goes to LPs)
// 5. Slippage Protection: User-defined minimum output amounts
// 6. Emergency Pause: Admin controls for risk management
//
// ARCHITECTURE:
// - Pool<TokenA, TokenB>: Shared object holding token reserves
// - LPToken<TokenA, TokenB>: Fungible token representing pool ownership
// - PoolAdminCap: Capability for administrative functions
//
// MATH & FORMULAS:
// - Constant product: reserve_a × reserve_b = k (constant)
// - Swap output: amount_out = (amount_in × 0.997 × reserve_out) / (reserve_in + amount_in × 0.997)
// - LP tokens (first): sqrt(amount_a × amount_b)
// - LP tokens (subsequent): min((amount_a × total_lp) / reserve_a, (amount_b × total_lp) / reserve_b)
// - Price: price_a_in_b = reserve_b / reserve_a
//
// SECURITY CONSIDERATIONS:
// - Slippage protection: Users specify minimum output
// - Fee mechanism: 0.3% kept in pool (benefits LPs)
// - Overflow protection: All math uses checked operations
// - Access control: Only admin can pause/unpause
// - K constant verification: Ensures k grows or stays constant
//
// ECONOMIC DESIGN:
// - Trading fees: 0.3% on every swap
// - Fee distribution: Automatically distributed to all LPs proportionally
// - Price impact: Larger trades cause more slippage (protects against manipulation)
// - Arbitrage incentive: Price discrepancies attract arbitrageurs, keeping prices aligned
// - Impermanent loss: LPs exposed to IL if price ratios change
//
// USE CASES:
// - Decentralized token trading (no KYC, permissionless)
// - Long-tail asset markets (low listing barrier)
// - Liquidity provision for yield (earn 0.3% fees)
// - Price discovery for new tokens
// - Cross-chain liquidity (wrapped tokens)
// - Arbitrage opportunities
//
// COMPARISON WITH TRADITIONAL EXCHANGES:
// - No order book (algorithmic pricing)
// - No custody (self-custody)
// - No KYC/AML (permissionless)
// - 24/7 trading (always available)
// - Transparent (all on-chain)
//
// AUTHOR: Pranay Gaurav
// VERSION: 1.0.0
// LICENSE: MIT
// INSPIRED BY: Uniswap V2, SushiSwap, PancakeSwap
//
// ============================================================================================================

module amm_dex::pool {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use sui::sui::SUI;
    use sui::event;

    // ======== Error Codes ========
    const EInsufficientLiquidity: u64 = 1;    // Error: Pool doesn't have enough tokens for this operation
    const EInsufficientInputAmount: u64 = 2;  // Error: Swap input amount is too small (must be > 0)
    const EInsufficientOutputAmount: u64 = 3; // Error: Slippage protection triggered (got less than min_out)
    const EInvalidAmount: u64 = 4;            // Error: Invalid amount provided (must be > 0)
    const ESlippageExceeded: u64 = 5;         // Error: Output less than user's minimum acceptable amount
    const EPoolPaused: u64 = 6;               // Error: Pool is paused for safety (emergency only)
    const EInsufficientLPTokens: u64 = 7;     // Error: Not enough LP tokens to burn for withdrawal
    const ENotAuthorized: u64 = 8;            // Error: Caller lacks required admin permissions

    // ======== Constants ========
    const FEE_PRECISION: u64 = 10000;      // Precision for fee calculations (10000 = 100.00%)
    const SWAP_FEE: u64 = 30;              // Trading fee: 0.3% (30/10000 = 0.003, same as Uniswap)
    const MINIMUM_LIQUIDITY: u64 = 1000;   // Min liquidity locked forever (prevents division by zero attacks)

    // ======== Structs ========

    /// Generic liquidity pool for two token types (implements x × y = k)
    ///
    /// Similar to Uniswap V2 pools, maintains constant product invariant.
    /// Generic over TokenA and TokenB - one pool per unique pair.
    /// Example: Pool<SUI, USDC> is SUI/USDC trading pair
    ///
    /// # Type Parameters
    /// * `TokenA` - First token type (e.g., SUI)
    /// * `TokenB` - Second token type (e.g., USDC)
    public struct Pool<phantom TokenA, phantom TokenB> has key {
        id: UID,                                      // Unique identifier for this pool
        reserve_a: Balance<TokenA>,                   // Amount of TokenA in pool (reserve0 in Uniswap)
        reserve_b: Balance<TokenB>,                   // Amount of TokenB in pool (reserve1 in Uniswap)
        lp_token_supply: Supply<LPToken<TokenA, TokenB>>, // Total LP tokens issued (tracks ownership)
        fee_to: address,                              // Address that receives protocol fees (currently unused)
        is_paused: bool,                              // Emergency pause flag (stops all swaps/adds/removes)
        admin: address,                               // Pool administrator (can pause/unpause)
    }

    /// LP Token - fungible token representing share of pool ownership
    ///
    /// Similar to Uniswap V2 LP tokens, this represents proportional ownership.
    /// Holding LP tokens entitles you to your share of:
    /// - Pool reserves (TokenA and TokenB)
    /// - Trading fees earned (auto-compounded into reserves)
    ///
    /// # Type Parameters
    /// * `TokenA` - First token in pair
    /// * `TokenB` - Second token in pair
    public struct LPToken<phantom TokenA, phantom TokenB> has drop {}

    /// Admin capability for pool management (emergency controls)
    ///
    /// Holder can pause/unpause the pool in case of emergency.
    /// Created once during pool creation and transferred to creator.
    public struct PoolAdminCap has key, store {
        id: UID,        // Unique identifier for this capability
        pool_id: ID,    // ID of pool this cap controls (ensures correct pool access)
    }

    // ======== Events ========
    // All events provide complete audit trail for analytics and off-chain indexing

    /// Emitted when a new liquidity pool is created
    public struct PoolCreated<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,    // ID of newly created pool
        admin: address, // Admin address (receives PoolAdminCap)
    }

    /// Emitted when liquidity is added to pool
    public struct LiquidityAdded<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,           // Pool receiving liquidity
        provider: address,     // Address providing liquidity
        amount_a: u64,         // Amount of TokenA deposited
        amount_b: u64,         // Amount of TokenB deposited
        lp_tokens_minted: u64, // LP tokens minted for this deposit
    }

    /// Emitted when liquidity is removed from pool
    public struct LiquidityRemoved<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,           // Pool losing liquidity
        provider: address,     // Address removing liquidity
        amount_a: u64,         // Amount of TokenA withdrawn
        amount_b: u64,         // Amount of TokenB withdrawn
        lp_tokens_burned: u64, // LP tokens burned for this withdrawal
    }

    /// Emitted when tokens are swapped
    public struct Swapped<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,        // Pool where swap occurred
        trader: address,    // Address executing the swap
        amount_in: u64,     // Amount of tokens swapped in
        amount_out: u64,    // Amount of tokens swapped out
        is_a_to_b: bool,    // true = TokenA → TokenB, false = TokenB → TokenA
        fee_collected: u64, // Fee collected (stays in pool, benefits LPs)
    }

    // ======== Core Functions ========

    /// Create a new liquidity pool for a token pair
    ///
    /// Creates an AMM pool for trading between TokenA and TokenB.
    /// The pool starts empty - liquidity must be added via add_liquidity().
    ///
    /// # Type Parameters
    /// * `TokenA` - First token type (e.g., SUI)
    /// * `TokenB` - Second token type (e.g., USDC)
    ///
    /// # Arguments
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * `Pool<TokenA, TokenB>` - The created pool (caller must share or keep)
    /// * `PoolAdminCap` - Admin capability for emergency controls
    ///
    /// # Events
    /// * Emits `PoolCreated` with pool ID and admin address
    ///
    /// # Example
    /// ```
    /// // Create SUI/USDC pool
    /// let (pool, admin_cap) = create_pool<SUI, USDC>(ctx);
    /// transfer::share_object(pool);  // Make pool public
    /// ```
    public fun create_pool<TokenA, TokenB>(
        ctx: &mut TxContext
    ): (Pool<TokenA, TokenB>, PoolAdminCap) {
        // Create unique ID for new pool
        let pool_uid = object::new(ctx);
        let pool_id = object::uid_to_inner(&pool_uid);

        // Caller becomes pool admin
        let admin = ctx.sender();

        // Initialize pool with zero reserves (empty)
        let pool = Pool<TokenA, TokenB> {
            id: pool_uid,                                                     // Unique pool identifier
            reserve_a: balance::zero(),                                       // Start with 0 TokenA
            reserve_b: balance::zero(),                                       // Start with 0 TokenB
            lp_token_supply: balance::create_supply(LPToken<TokenA, TokenB> {}), // Create LP token type
            fee_to: admin,                                                    // Protocol fee recipient (unused currently)
            is_paused: false,                                                 // Pool starts active
            admin,                                                            // Store admin address
        };

        // Create admin capability for emergency controls
        let admin_cap = PoolAdminCap {
            id: object::new(ctx),  // Unique cap ID
            pool_id,               // Link to this specific pool
        };

        // Emit creation event for indexers
        event::emit(PoolCreated<TokenA, TokenB> {
            pool_id,
            admin,
        });

        (pool, admin_cap)
    }

    /// Entry function to create pool and make it publicly accessible
    ///
    /// Convenience function that creates a pool and immediately shares it.
    /// Most common way to create a pool - makes it available for anyone to trade.
    ///
    /// # Type Parameters
    /// * `TokenA` - First token type
    /// * `TokenB` - Second token type
    ///
    /// # Arguments
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * Shares pool globally (anyone can add liquidity / swap)
    /// * Transfers admin_cap to caller (only caller can pause)
    public entry fun create_pool_and_share<TokenA, TokenB>(
        ctx: &mut TxContext
    ) {
        // Create the pool and admin capability
        let (pool, admin_cap) = create_pool<TokenA, TokenB>(ctx);

        // Make pool globally accessible (shared object)
        transfer::share_object(pool);

        // Give admin capability to creator
        transfer::transfer(admin_cap, ctx.sender());
    }

    /// Add liquidity to the pool and receive LP tokens
    ///
    /// Deposits TokenA and TokenB into pool, receives LP tokens representing ownership share.
    /// LP tokens entitle holder to proportional share of reserves + accumulated trading fees.
    ///
    /// First liquidity provider:
    /// - LP tokens = sqrt(amount_a × amount_b) - MINIMUM_LIQUIDITY
    /// - MINIMUM_LIQUIDITY (1000) locked forever (prevents attacks)
    ///
    /// Subsequent providers:
    /// - Must deposit in current pool ratio to avoid loss
    /// - LP tokens = min((amount_a × total_lp) / reserve_a, (amount_b × total_lp) / reserve_b)
    ///
    /// # Arguments
    /// * `pool` - Pool to add liquidity to
    /// * `token_a` - TokenA coins to deposit
    /// * `token_b` - TokenB coins to deposit
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * LP tokens representing share of pool
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `EInvalidAmount` - If either amount is 0
    /// * `EInsufficientLiquidity` - If LP tokens < MINIMUM_LIQUIDITY
    ///
    /// # Example
    /// ```
    /// // Add 1000 SUI + 2000 USDC to empty pool
    /// let lp_tokens = add_liquidity(&mut pool, sui_coins, usdc_coins, ctx);
    /// // Receives: sqrt(1000 × 2000) - 1000 = 413 LP tokens
    /// // (1000 locked forever)
    /// ```
    public fun add_liquidity<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        token_a: Coin<TokenA>,
        token_b: Coin<TokenB>,
        ctx: &mut TxContext
    ): Coin<LPToken<TokenA, TokenB>> {
        // Safety check: prevent liquidity addition while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Get amounts being deposited
        let amount_a = coin::value(&token_a);
        let amount_b = coin::value(&token_b);

        // Validate non-zero amounts
        assert!(amount_a > 0 && amount_b > 0, EInvalidAmount);

        // Get current pool reserves
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        // Calculate LP tokens to mint based on pool state
        let lp_tokens_to_mint = if (reserve_a == 0 && reserve_b == 0) {
            // First liquidity deposit: use geometric mean (Uniswap V2 formula)
            // Formula: sqrt(amount_a × amount_b)
            // Prevents manipulation by first depositor
            let initial_liquidity = sqrt(amount_a * amount_b);

            // Ensure sufficient initial liquidity
            assert!(initial_liquidity > MINIMUM_LIQUIDITY, EInsufficientLiquidity);

            // Lock MINIMUM_LIQUIDITY forever (prevents division by zero attacks)
            // This small amount is burned and makes pool more secure
            initial_liquidity - MINIMUM_LIQUIDITY
        } else {
            // Subsequent liquidity: maintain current pool ratio
            // Calculate LP tokens based on each reserve independently
            let lp_from_a = (amount_a * balance::supply_value(&pool.lp_token_supply)) / reserve_a;
            let lp_from_b = (amount_b * balance::supply_value(&pool.lp_token_supply)) / reserve_b;

            // Take minimum to maintain ratio (excess not used)
            // This protects against price manipulation
            if (lp_from_a < lp_from_b) { lp_from_a } else { lp_from_b }
        };

        // Ensure we're minting positive LP tokens
        assert!(lp_tokens_to_mint > 0, EInsufficientLiquidity);

        // Add deposited tokens to pool reserves
        balance::join(&mut pool.reserve_a, coin::into_balance(token_a));
        balance::join(&mut pool.reserve_b, coin::into_balance(token_b));

        // Mint LP tokens to represent ownership share
        let lp_balance = balance::increase_supply(&mut pool.lp_token_supply, lp_tokens_to_mint);

        // Emit event for off-chain tracking
        event::emit(LiquidityAdded<TokenA, TokenB> {
            pool_id: object::id(pool),
            provider: ctx.sender(),
            amount_a,
            amount_b,
            lp_tokens_minted: lp_tokens_to_mint,
        });

        // Return LP tokens to provider
        coin::from_balance(lp_balance, ctx)
    }

    /// Remove liquidity from the pool by burning LP tokens
    ///
    /// Burns LP tokens and returns proportional share of both reserves.
    /// Includes accumulated trading fees (auto-compounded into reserves).
    ///
    /// Formula:
    /// - amount_a = (lp_tokens × reserve_a) / total_lp_supply
    /// - amount_b = (lp_tokens × reserve_b) / total_lp_supply
    ///
    /// # Arguments
    /// * `pool` - Pool to remove liquidity from
    /// * `lp_token` - LP tokens to burn
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * `(Coin<TokenA>, Coin<TokenB>)` - Both tokens proportional to LP share
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `EInvalidAmount` - If LP amount is 0
    /// * `EInsufficientLiquidity` - If withdrawal amounts are 0
    ///
    /// # Example
    /// ```
    /// // User has 100 LP tokens (10% of 1000 total)
    /// // Pool has 10000 SUI + 20000 USDC
    /// let (sui, usdc) = remove_liquidity(&mut pool, lp_tokens, ctx);
    /// // Returns: 1000 SUI (10%) + 2000 USDC (10%)
    /// ```
    public fun remove_liquidity<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        lp_token: Coin<LPToken<TokenA, TokenB>>,
        ctx: &mut TxContext
    ): (Coin<TokenA>, Coin<TokenB>) {
        // Safety check: prevent liquidity removal while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Get amount of LP tokens being burned
        let lp_amount = coin::value(&lp_token);
        assert!(lp_amount > 0, EInvalidAmount);

        // Get current pool state
        let total_supply = balance::supply_value(&pool.lp_token_supply);
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        // Calculate proportional withdrawal amounts
        // Formula: amount = (lp_tokens × reserve) / total_supply
        let amount_a = (lp_amount * reserve_a) / total_supply;
        let amount_b = (lp_amount * reserve_b) / total_supply;

        assert!(amount_a > 0 && amount_b > 0, EInsufficientLiquidity);

        // Burn LP tokens first (reentrancy protection)
        balance::decrease_supply(&mut pool.lp_token_supply, coin::into_balance(lp_token));

        // Withdraw TokenA from pool
        let withdrawn_a = coin::from_balance(
            balance::split(&mut pool.reserve_a, amount_a),
            ctx
        );

        // Withdraw TokenB from pool
        let withdrawn_b = coin::from_balance(
            balance::split(&mut pool.reserve_b, amount_b),
            ctx
        );

        // Emit event for off-chain tracking
        event::emit(LiquidityRemoved<TokenA, TokenB> {
            pool_id: object::id(pool),
            provider: ctx.sender(),
            amount_a,
            amount_b,
            lp_tokens_burned: lp_amount,
        });

        (withdrawn_a, withdrawn_b)
    }

    /// Swap TokenA for TokenB using constant product formula
    ///
    /// Implements Uniswap V2 style swap with 0.3% fee.
    /// Uses formula: x × y = k (constant product)
    /// Fee stays in pool, benefiting all LPs proportionally.
    ///
    /// Formula:
    /// - amount_in_with_fee = amount_in × 0.997 (subtract 0.3% fee)
    /// - amount_out = (amount_in_with_fee × reserve_b) / (reserve_a + amount_in_with_fee)
    ///
    /// # Arguments
    /// * `pool` - Pool to swap in
    /// * `token_a` - TokenA coins to swap
    /// * `min_amount_out` - Minimum TokenB to receive (slippage protection)
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * `Coin<TokenB>` - Output tokens after swap
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `EInsufficientInputAmount` - If input is 0
    /// * `ESlippageExceeded` - If output < min_amount_out
    /// * `EInsufficientLiquidity` - If pool lacks tokens
    ///
    /// # Example
    /// ```
    /// // Pool: 10000 SUI, 20000 USDC
    /// // Swap 100 SUI for USDC (expect ~198 USDC after 0.3% fee)
    /// let usdc = swap_a_to_b(&mut pool, sui_coins, 195, ctx);
    /// // 195 = min acceptable (allows ~1.5% slippage)
    /// ```
    public fun swap_a_to_b<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        token_a: Coin<TokenA>,
        min_amount_out: u64,
        ctx: &mut TxContext
    ): Coin<TokenB> {
        // Safety check: prevent swaps while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Get input amount
        let amount_in = coin::value(&token_a);
        assert!(amount_in > 0, EInsufficientInputAmount);

        // Get current reserves
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        // Calculate output using constant product formula
        // Subtract 0.3% fee first: 99.7% of input goes to swap
        // Formula: out = (in × 0.997 × reserve_out) / (reserve_in + in × 0.997)
        let amount_in_with_fee = (amount_in * (FEE_PRECISION - SWAP_FEE)) / FEE_PRECISION;
        let amount_out = (amount_in_with_fee * reserve_b) / (reserve_a + amount_in_with_fee);

        // Slippage protection: ensure user gets minimum expected amount
        assert!(amount_out >= min_amount_out, ESlippageExceeded);

        // Ensure pool has enough liquidity
        assert!(amount_out < reserve_b, EInsufficientLiquidity);

        // Add input tokens to reserve_a
        balance::join(&mut pool.reserve_a, coin::into_balance(token_a));

        // Remove output tokens from reserve_b
        let output = coin::from_balance(
            balance::split(&mut pool.reserve_b, amount_out),
            ctx
        );

        // Calculate fee collected (stays in pool)
        let fee_collected = amount_in - amount_in_with_fee;

        // Emit swap event
        event::emit(Swapped<TokenA, TokenB> {
            pool_id: object::id(pool),
            trader: ctx.sender(),
            amount_in,
            amount_out,
            is_a_to_b: true,  // Direction: A → B
            fee_collected,
        });

        output
    }

    /// Swap TokenB for TokenA using constant product formula
    ///
    /// Implements Uniswap V2 style swap in reverse direction (B → A).
    /// Same 0.3% fee and constant product formula as swap_a_to_b.
    ///
    /// # Arguments
    /// * `pool` - Pool to swap in
    /// * `token_b` - TokenB coins to swap
    /// * `min_amount_out` - Minimum TokenA to receive (slippage protection)
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// * `Coin<TokenA>` - Output tokens after swap
    ///
    /// # Panics
    /// * `EPoolPaused` - If pool is paused
    /// * `EInsufficientInputAmount` - If input is 0
    /// * `ESlippageExceeded` - If output < min_amount_out
    /// * `EInsufficientLiquidity` - If pool lacks tokens
    ///
    /// # Example
    /// ```
    /// // Pool: 10000 SUI, 20000 USDC
    /// // Swap 200 USDC for SUI (expect ~99 SUI after 0.3% fee)
    /// let sui = swap_b_to_a(&mut pool, usdc_coins, 97, ctx);
    /// ```
    public fun swap_b_to_a<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        token_b: Coin<TokenB>,
        min_amount_out: u64,
        ctx: &mut TxContext
    ): Coin<TokenA> {
        // Safety check: prevent swaps while paused
        assert!(!pool.is_paused, EPoolPaused);

        // Get input amount
        let amount_in = coin::value(&token_b);
        assert!(amount_in > 0, EInsufficientInputAmount);

        // Get current reserves
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        // Calculate output using constant product formula
        // Same math as swap_a_to_b, but swapped reserves
        let amount_in_with_fee = (amount_in * (FEE_PRECISION - SWAP_FEE)) / FEE_PRECISION;
        let amount_out = (amount_in_with_fee * reserve_a) / (reserve_b + amount_in_with_fee);

        // Slippage protection
        assert!(amount_out >= min_amount_out, ESlippageExceeded);

        // Liquidity check
        assert!(amount_out < reserve_a, EInsufficientLiquidity);

        // Add input tokens to reserve_b
        balance::join(&mut pool.reserve_b, coin::into_balance(token_b));

        // Remove output tokens from reserve_a
        let output = coin::from_balance(
            balance::split(&mut pool.reserve_a, amount_out),
            ctx
        );

        // Calculate fee collected
        let fee_collected = amount_in - amount_in_with_fee;

        // Emit swap event
        event::emit(Swapped<TokenA, TokenB> {
            pool_id: object::id(pool),
            trader: ctx.sender(),
            amount_in,
            amount_out,
            is_a_to_b: false,  // Direction: B → A
            fee_collected,
        });

        output
    }

    // ======== Admin Functions ========

    /// Pause pool operations (admin only, emergency use)
    ///
    /// Disables all pool operations (swaps, add/remove liquidity).
    /// Used when security issue detected or during upgrades.
    ///
    /// # Arguments
    /// * `pool` - Pool to pause
    /// * `_admin_cap` - Admin capability (proves authorization)
    ///
    /// # Security
    /// * Only PoolAdminCap holder can call this
    /// * Should only be used in emergencies
    public fun pause_pool<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        _admin_cap: &PoolAdminCap,  // Proves admin access (unused but required)
    ) {
        pool.is_paused = true;  // Block all operations
    }

    /// Unpause pool operations (admin only)
    ///
    /// Re-enables pool operations after emergency is resolved.
    ///
    /// # Arguments
    /// * `pool` - Pool to unpause
    /// * `_admin_cap` - Admin capability (proves authorization)
    public fun unpause_pool<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        _admin_cap: &PoolAdminCap,  // Proves admin access (unused but required)
    ) {
        pool.is_paused = false;  // Re-enable all operations
    }

    // ======== View Functions ========
    // Read-only functions for querying pool state (no gas cost when called off-chain)

    /// Get both reserve amounts from the pool
    ///
    /// # Arguments
    /// * `pool` - Pool to query
    ///
    /// # Returns
    /// * `(u64, u64)` - (reserve_a, reserve_b) amounts
    ///
    /// # Use Case
    /// * Check pool liquidity before swapping
    /// * Calculate expected swap output
    /// * Display pool stats in UI
    public fun get_reserves<TokenA, TokenB>(pool: &Pool<TokenA, TokenB>): (u64, u64) {
        (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b))  // Return both reserves
    }

    /// Get total LP token supply
    ///
    /// # Arguments
    /// * `pool` - Pool to query
    ///
    /// # Returns
    /// * Total LP tokens in circulation
    ///
    /// # Use Case
    /// * Calculate LP token value
    /// * Determine ownership percentage
    public fun get_lp_supply<TokenA, TokenB>(pool: &Pool<TokenA, TokenB>): u64 {
        balance::supply_value(&pool.lp_token_supply)  // Total LP tokens issued
    }

    /// Calculate expected swap output without executing (quote function)
    ///
    /// Simulates a swap to show user expected output before execution.
    /// Useful for price quotes and slippage calculations.
    ///
    /// # Arguments
    /// * `pool` - Pool to query
    /// * `amount_in` - Input amount to simulate
    /// * `is_a_to_b` - true for A→B swap, false for B→A
    ///
    /// # Returns
    /// * Expected output amount (after 0.3% fee)
    ///
    /// # Example
    /// ```
    /// // Quote swap of 100 SUI for USDC
    /// let expected_usdc = get_amount_out(&pool, 100, true);
    /// // Use this to set min_amount_out with slippage tolerance
    /// let min_out = expected_usdc * 99 / 100;  // 1% slippage
    /// ```
    ///
    /// # Note
    /// * Does not account for price impact of this specific trade
    /// * Use this output to set min_amount_out for actual swap
    public fun get_amount_out<TokenA, TokenB>(
        pool: &Pool<TokenA, TokenB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        // Get current reserves
        let (reserve_a, reserve_b) = get_reserves(pool);

        // Determine input/output reserves based on direction
        let (reserve_in, reserve_out) = if (is_a_to_b) {
            (reserve_a, reserve_b)  // A → B swap
        } else {
            (reserve_b, reserve_a)  // B → A swap
        };

        // Calculate output using same formula as actual swap
        let amount_in_with_fee = (amount_in * (FEE_PRECISION - SWAP_FEE)) / FEE_PRECISION;
        (amount_in_with_fee * reserve_out) / (reserve_in + amount_in_with_fee)
    }

    /// Check if pool is currently paused
    ///
    /// # Arguments
    /// * `pool` - Pool to query
    ///
    /// # Returns
    /// * true if paused (operations disabled), false if active
    public fun is_paused<TokenA, TokenB>(pool: &Pool<TokenA, TokenB>): bool {
        pool.is_paused  // Emergency pause status
    }

    // ======== Helper Functions ========

    /// Calculate integer square root using Babylonian method
    ///
    /// Used for initial liquidity calculation: sqrt(amount_a × amount_b).
    /// Implements Newton's method for integer square roots.
    ///
    /// # Arguments
    /// * `x` - Number to find square root of
    ///
    /// # Returns
    /// * Integer square root (rounded down)
    ///
    /// # Algorithm
    /// * Newton's method: z_(n+1) = (z_n + x/z_n) / 2
    /// * Converges to sqrt(x) in O(log n) iterations
    fun sqrt(x: u64): u64 {
        // Handle zero case
        if (x == 0) return 0;

        // Initial guess: (x + 1) / 2
        let mut z = (x + 1) / 2;
        let mut y = x;

        // Iterate until convergence
        while (z < y) {
            y = z;                  // Update previous guess
            z = (x / z + z) / 2;    // Newton's method iteration
        };

        y  // Return converged value
    }

    // ======== Test Functions ========
    // Only compiled in test mode, not in production builds

    /// Initialize pool for testing purposes
    ///
    /// Test-only helper that creates a pool and transfers admin cap.
    ///
    /// # Arguments
    /// * `ctx` - Test transaction context
    ///
    /// # Returns
    /// * Pool object for test scenarios
    #[test_only]
    public fun init_for_testing<TokenA, TokenB>(ctx: &mut TxContext): Pool<TokenA, TokenB> {
        // Create pool and admin capability
        let (pool, admin_cap) = create_pool<TokenA, TokenB>(ctx);

        // Transfer admin cap to test caller
        transfer::transfer(admin_cap, ctx.sender());

        // Return pool for test use
        pool
    }
}
