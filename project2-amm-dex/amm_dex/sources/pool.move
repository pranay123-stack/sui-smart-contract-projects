/// AMM DEX - Automated Market Maker Liquidity Pool
/// Implements constant product formula (x * y = k) for token swaps
/// Features: liquidity provision, token swaps, LP tokens, fee collection
module amm_dex::pool {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use sui::sui::SUI;
    use sui::event;

    // ======== Error Codes ========
    const EInsufficientLiquidity: u64 = 1;
    const EInsufficientInputAmount: u64 = 2;
    const EInsufficientOutputAmount: u64 = 3;
    const EInvalidAmount: u64 = 4;
    const ESlippageExceeded: u64 = 5;
    const EPoolPaused: u64 = 6;
    const EInsufficientLPTokens: u64 = 7;
    const ENotAuthorized: u64 = 8;

    // ======== Constants ========
    const FEE_PRECISION: u64 = 10000;
    const SWAP_FEE: u64 = 30; // 0.3% = 30/10000
    const MINIMUM_LIQUIDITY: u64 = 1000;

    // ======== Structs ========

    /// Generic liquidity pool for two token types
    public struct Pool<phantom TokenA, phantom TokenB> has key {
        id: UID,
        reserve_a: Balance<TokenA>,
        reserve_b: Balance<TokenB>,
        lp_token_supply: Supply<LPToken<TokenA, TokenB>>,
        fee_to: address,
        is_paused: bool,
        admin: address,
    }

    /// LP Token represents liquidity provider's share
    public struct LPToken<phantom TokenA, phantom TokenB> has drop {}

    /// Admin capability
    public struct PoolAdminCap has key, store {
        id: UID,
        pool_id: ID,
    }

    // ======== Events ========

    public struct PoolCreated<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,
        admin: address,
    }

    public struct LiquidityAdded<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,
        provider: address,
        amount_a: u64,
        amount_b: u64,
        lp_tokens_minted: u64,
    }

    public struct LiquidityRemoved<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,
        provider: address,
        amount_a: u64,
        amount_b: u64,
        lp_tokens_burned: u64,
    }

    public struct Swapped<phantom TokenA, phantom TokenB> has copy, drop {
        pool_id: ID,
        trader: address,
        amount_in: u64,
        amount_out: u64,
        is_a_to_b: bool,
        fee_collected: u64,
    }

    // ======== Core Functions ========

    /// Create a new liquidity pool
    public fun create_pool<TokenA, TokenB>(
        ctx: &mut TxContext
    ): (Pool<TokenA, TokenB>, PoolAdminCap) {
        let pool_uid = object::new(ctx);
        let pool_id = object::uid_to_inner(&pool_uid);
        let admin = ctx.sender();

        let pool = Pool<TokenA, TokenB> {
            id: pool_uid,
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            lp_token_supply: balance::create_supply(LPToken<TokenA, TokenB> {}),
            fee_to: admin,
            is_paused: false,
            admin,
        };

        let admin_cap = PoolAdminCap {
            id: object::new(ctx),
            pool_id,
        };

        event::emit(PoolCreated<TokenA, TokenB> {
            pool_id,
            admin,
        });

        (pool, admin_cap)
    }

    /// Entry function to create and share pool
    public entry fun create_pool_and_share<TokenA, TokenB>(
        ctx: &mut TxContext
    ) {
        let (pool, admin_cap) = create_pool<TokenA, TokenB>(ctx);
        transfer::share_object(pool);
        transfer::transfer(admin_cap, ctx.sender());
    }

    /// Add liquidity to the pool
    public fun add_liquidity<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        token_a: Coin<TokenA>,
        token_b: Coin<TokenB>,
        ctx: &mut TxContext
    ): Coin<LPToken<TokenA, TokenB>> {
        assert!(!pool.is_paused, EPoolPaused);

        let amount_a = coin::value(&token_a);
        let amount_b = coin::value(&token_b);

        assert!(amount_a > 0 && amount_b > 0, EInvalidAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        // Calculate LP tokens to mint
        let lp_tokens_to_mint = if (reserve_a == 0 && reserve_b == 0) {
            // Initial liquidity
            let initial_liquidity = sqrt(amount_a * amount_b);
            assert!(initial_liquidity > MINIMUM_LIQUIDITY, EInsufficientLiquidity);
            initial_liquidity - MINIMUM_LIQUIDITY // Lock minimum liquidity
        } else {
            // Subsequent liquidity - maintain ratio
            let lp_from_a = (amount_a * balance::supply_value(&pool.lp_token_supply)) / reserve_a;
            let lp_from_b = (amount_b * balance::supply_value(&pool.lp_token_supply)) / reserve_b;
            if (lp_from_a < lp_from_b) { lp_from_a } else { lp_from_b }
        };

        assert!(lp_tokens_to_mint > 0, EInsufficientLiquidity);

        // Add tokens to reserves
        balance::join(&mut pool.reserve_a, coin::into_balance(token_a));
        balance::join(&mut pool.reserve_b, coin::into_balance(token_b));

        // Mint LP tokens
        let lp_balance = balance::increase_supply(&mut pool.lp_token_supply, lp_tokens_to_mint);

        event::emit(LiquidityAdded<TokenA, TokenB> {
            pool_id: object::id(pool),
            provider: ctx.sender(),
            amount_a,
            amount_b,
            lp_tokens_minted: lp_tokens_to_mint,
        });

        coin::from_balance(lp_balance, ctx)
    }

    /// Remove liquidity from the pool
    public fun remove_liquidity<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        lp_token: Coin<LPToken<TokenA, TokenB>>,
        ctx: &mut TxContext
    ): (Coin<TokenA>, Coin<TokenB>) {
        assert!(!pool.is_paused, EPoolPaused);

        let lp_amount = coin::value(&lp_token);
        assert!(lp_amount > 0, EInvalidAmount);

        let total_supply = balance::supply_value(&pool.lp_token_supply);
        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        // Calculate amounts to withdraw
        let amount_a = (lp_amount * reserve_a) / total_supply;
        let amount_b = (lp_amount * reserve_b) / total_supply;

        assert!(amount_a > 0 && amount_b > 0, EInsufficientLiquidity);

        // Burn LP tokens
        balance::decrease_supply(&mut pool.lp_token_supply, coin::into_balance(lp_token));

        // Withdraw tokens
        let withdrawn_a = coin::from_balance(
            balance::split(&mut pool.reserve_a, amount_a),
            ctx
        );
        let withdrawn_b = coin::from_balance(
            balance::split(&mut pool.reserve_b, amount_b),
            ctx
        );

        event::emit(LiquidityRemoved<TokenA, TokenB> {
            pool_id: object::id(pool),
            provider: ctx.sender(),
            amount_a,
            amount_b,
            lp_tokens_burned: lp_amount,
        });

        (withdrawn_a, withdrawn_b)
    }

    /// Swap token A for token B
    public fun swap_a_to_b<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        token_a: Coin<TokenA>,
        min_amount_out: u64,
        ctx: &mut TxContext
    ): Coin<TokenB> {
        assert!(!pool.is_paused, EPoolPaused);

        let amount_in = coin::value(&token_a);
        assert!(amount_in > 0, EInsufficientInputAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        // Calculate output amount using constant product formula
        // amount_out = (amount_in * reserve_b) / (reserve_a + amount_in)
        // With 0.3% fee: amount_in_with_fee = amount_in * (10000 - 30) / 10000
        let amount_in_with_fee = (amount_in * (FEE_PRECISION - SWAP_FEE)) / FEE_PRECISION;
        let amount_out = (amount_in_with_fee * reserve_b) / (reserve_a + amount_in_with_fee);

        assert!(amount_out >= min_amount_out, ESlippageExceeded);
        assert!(amount_out < reserve_b, EInsufficientLiquidity);

        // Add input tokens to reserve
        balance::join(&mut pool.reserve_a, coin::into_balance(token_a));

        // Remove output tokens from reserve
        let output = coin::from_balance(
            balance::split(&mut pool.reserve_b, amount_out),
            ctx
        );

        let fee_collected = amount_in - amount_in_with_fee;

        event::emit(Swapped<TokenA, TokenB> {
            pool_id: object::id(pool),
            trader: ctx.sender(),
            amount_in,
            amount_out,
            is_a_to_b: true,
            fee_collected,
        });

        output
    }

    /// Swap token B for token A
    public fun swap_b_to_a<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        token_b: Coin<TokenB>,
        min_amount_out: u64,
        ctx: &mut TxContext
    ): Coin<TokenA> {
        assert!(!pool.is_paused, EPoolPaused);

        let amount_in = coin::value(&token_b);
        assert!(amount_in > 0, EInsufficientInputAmount);

        let reserve_a = balance::value(&pool.reserve_a);
        let reserve_b = balance::value(&pool.reserve_b);

        let amount_in_with_fee = (amount_in * (FEE_PRECISION - SWAP_FEE)) / FEE_PRECISION;
        let amount_out = (amount_in_with_fee * reserve_a) / (reserve_b + amount_in_with_fee);

        assert!(amount_out >= min_amount_out, ESlippageExceeded);
        assert!(amount_out < reserve_a, EInsufficientLiquidity);

        balance::join(&mut pool.reserve_b, coin::into_balance(token_b));

        let output = coin::from_balance(
            balance::split(&mut pool.reserve_a, amount_out),
            ctx
        );

        let fee_collected = amount_in - amount_in_with_fee;

        event::emit(Swapped<TokenA, TokenB> {
            pool_id: object::id(pool),
            trader: ctx.sender(),
            amount_in,
            amount_out,
            is_a_to_b: false,
            fee_collected,
        });

        output
    }

    // ======== Admin Functions ========

    /// Pause pool operations
    public fun pause_pool<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        _admin_cap: &PoolAdminCap,
    ) {
        pool.is_paused = true;
    }

    /// Unpause pool operations
    public fun unpause_pool<TokenA, TokenB>(
        pool: &mut Pool<TokenA, TokenB>,
        _admin_cap: &PoolAdminCap,
    ) {
        pool.is_paused = false;
    }

    // ======== View Functions ========

    /// Get reserve amounts
    public fun get_reserves<TokenA, TokenB>(pool: &Pool<TokenA, TokenB>): (u64, u64) {
        (balance::value(&pool.reserve_a), balance::value(&pool.reserve_b))
    }

    /// Get total LP token supply
    public fun get_lp_supply<TokenA, TokenB>(pool: &Pool<TokenA, TokenB>): u64 {
        balance::supply_value(&pool.lp_token_supply)
    }

    /// Calculate output amount for a given input (without executing swap)
    public fun get_amount_out<TokenA, TokenB>(
        pool: &Pool<TokenA, TokenB>,
        amount_in: u64,
        is_a_to_b: bool
    ): u64 {
        let (reserve_a, reserve_b) = get_reserves(pool);

        let (reserve_in, reserve_out) = if (is_a_to_b) {
            (reserve_a, reserve_b)
        } else {
            (reserve_b, reserve_a)
        };

        let amount_in_with_fee = (amount_in * (FEE_PRECISION - SWAP_FEE)) / FEE_PRECISION;
        (amount_in_with_fee * reserve_out) / (reserve_in + amount_in_with_fee)
    }

    /// Check if pool is paused
    public fun is_paused<TokenA, TokenB>(pool: &Pool<TokenA, TokenB>): bool {
        pool.is_paused
    }

    // ======== Helper Functions ========

    /// Simple integer square root implementation
    fun sqrt(x: u64): u64 {
        if (x == 0) return 0;
        let mut z = (x + 1) / 2;
        let mut y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        };
        y
    }

    // ======== Test Functions ========

    #[test_only]
    public fun init_for_testing<TokenA, TokenB>(ctx: &mut TxContext): Pool<TokenA, TokenB> {
        let (pool, admin_cap) = create_pool<TokenA, TokenB>(ctx);
        transfer::transfer(admin_cap, ctx.sender());
        pool
    }
}
