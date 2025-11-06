#[test_only]
module amm_dex::pool_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;
    use amm_dex::pool::{Self, Pool, LPToken, PoolAdminCap};
    use amm_dex::test_tokens::{Self, USDC, USDT};

    const ADMIN: address = @0xAD;
    const USER1: address = @0x1;
    const USER2: address = @0x2;

    const INITIAL_LIQUIDITY: u64 = 1000000; // 1M tokens

    #[test]
    fun test_create_pool() {
        let mut scenario = ts::begin(ADMIN);

        {
            pool::create_pool_and_share<SUI, USDC>(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            assert!(ts::has_most_recent_shared<Pool<SUI, USDC>>(), 0);
            assert!(ts::has_most_recent_for_address<PoolAdminCap>(ADMIN), 1);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_add_initial_liquidity() {
        let mut scenario = setup_pool();

        // User adds initial liquidity
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);

            let token_sui = coin::mint_for_testing<SUI>(INITIAL_LIQUIDITY, ts::ctx(&mut scenario));
            let token_usdc = coin::mint_for_testing<USDC>(INITIAL_LIQUIDITY, ts::ctx(&mut scenario));

            let lp_token = pool::add_liquidity(&mut pool, token_sui, token_usdc, ts::ctx(&mut scenario));

            // Check LP tokens minted
            let lp_amount = coin::value(&lp_token);
            assert!(lp_amount > 0, 0);

            // Check reserves
            let (reserve_sui, reserve_usdc) = pool::get_reserves(&pool);
            assert!(reserve_sui == INITIAL_LIQUIDITY, 1);
            assert!(reserve_usdc == INITIAL_LIQUIDITY, 2);

            transfer::public_transfer(lp_token, USER1);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_add_and_remove_liquidity() {
        let mut scenario = setup_pool();

        // User1 adds liquidity
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let token_sui = coin::mint_for_testing<SUI>(INITIAL_LIQUIDITY, ts::ctx(&mut scenario));
            let token_usdc = coin::mint_for_testing<USDC>(INITIAL_LIQUIDITY, ts::ctx(&mut scenario));
            let lp_token = pool::add_liquidity(&mut pool, token_sui, token_usdc, ts::ctx(&mut scenario));
            transfer::public_transfer(lp_token, USER1);
            ts::return_shared(pool);
        };

        // User1 removes liquidity
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let lp_token = ts::take_from_address<Coin<LPToken<SUI, USDC>>>(&scenario, USER1);

            let (token_sui, token_usdc) = pool::remove_liquidity(&mut pool, lp_token, ts::ctx(&mut scenario));

            // User should get back approximately what they put in (minus minimum liquidity lock)
            assert!(coin::value(&token_sui) > 0, 0);
            assert!(coin::value(&token_usdc) > 0, 1);

            transfer::public_transfer(token_sui, USER1);
            transfer::public_transfer(token_usdc, USER1);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_swap_a_to_b() {
        let mut scenario = setup_pool_with_liquidity();

        // User2 swaps SUI for USDC
        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);

            let swap_amount = 1000;
            let token_sui = coin::mint_for_testing<SUI>(swap_amount, ts::ctx(&mut scenario));

            // Get expected output
            let expected_out = pool::get_amount_out(&pool, swap_amount, true);

            // Execute swap with 1% slippage tolerance
            let min_out = (expected_out * 99) / 100;
            let token_usdc = pool::swap_a_to_b(&mut pool, token_sui, min_out, ts::ctx(&mut scenario));

            assert!(coin::value(&token_usdc) >= min_out, 0);
            assert!(coin::value(&token_usdc) > 0, 1);

            transfer::public_transfer(token_usdc, USER2);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_swap_b_to_a() {
        let mut scenario = setup_pool_with_liquidity();

        // User2 swaps USDC for SUI
        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);

            let swap_amount = 1000;
            let token_usdc = coin::mint_for_testing<USDC>(swap_amount, ts::ctx(&mut scenario));

            let expected_out = pool::get_amount_out(&pool, swap_amount, false);
            let min_out = (expected_out * 99) / 100;

            let token_sui = pool::swap_b_to_a(&mut pool, token_usdc, min_out, ts::ctx(&mut scenario));

            assert!(coin::value(&token_sui) >= min_out, 0);
            assert!(coin::value(&token_sui) > 0, 1);

            transfer::public_transfer(token_sui, USER2);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_multiple_swaps_maintain_k() {
        let mut scenario = setup_pool_with_liquidity();

        // Get initial k value (reserve_a * reserve_b)
        ts::next_tx(&mut scenario, USER2);
        let initial_k;
        {
            let pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let (reserve_a, reserve_b) = pool::get_reserves(&pool);
            initial_k = reserve_a * reserve_b;
            ts::return_shared(pool);
        };

        // Execute multiple swaps
        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);

            // Swap 1: SUI -> USDC
            let token1 = coin::mint_for_testing<SUI>(500, ts::ctx(&mut scenario));
            let out1 = pool::swap_a_to_b(&mut pool, token1, 0, ts::ctx(&mut scenario));

            // Swap 2: USDC -> SUI
            let token2 = coin::mint_for_testing<USDC>(300, ts::ctx(&mut scenario));
            let out2 = pool::swap_b_to_a(&mut pool, token2, 0, ts::ctx(&mut scenario));

            transfer::public_transfer(out1, USER2);
            transfer::public_transfer(out2, USER2);
            ts::return_shared(pool);
        };

        // Check k value increased (due to fees)
        ts::next_tx(&mut scenario, USER2);
        {
            let pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let (reserve_a, reserve_b) = pool::get_reserves(&pool);
            let final_k = reserve_a * reserve_b;

            // K should increase due to collected fees
            assert!(final_k >= initial_k, 0);

            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_price_impact() {
        let mut scenario = setup_pool_with_liquidity();

        // Small swap should have less price impact
        ts::next_tx(&mut scenario, USER2);
        let small_swap_rate;
        {
            let pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let small_amount = 100;
            let small_out = pool::get_amount_out(&pool, small_amount, true);
            small_swap_rate = (small_out * 10000) / small_amount;
            ts::return_shared(pool);
        };

        // Large swap should have more price impact (use much larger amount)
        ts::next_tx(&mut scenario, USER2);
        let large_swap_rate;
        {
            let pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let large_amount = 100000; // 10% of pool
            let large_out = pool::get_amount_out(&pool, large_amount, true);
            large_swap_rate = (large_out * 10000) / large_amount;
            ts::return_shared(pool);
        };

        // Large swap should have worse rate (lower ratio due to slippage)
        assert!(large_swap_rate < small_swap_rate, 0);

        ts::end(scenario);
    }

    #[test]
    fun test_pause_and_unpause() {
        let mut scenario = setup_pool_with_liquidity();

        // Admin pauses pool
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let admin_cap = ts::take_from_address<PoolAdminCap>(&scenario, ADMIN);

            pool::pause_pool(&mut pool, &admin_cap);
            assert!(pool::is_paused(&pool), 0);

            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(pool);
        };

        // Admin unpauses pool
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let admin_cap = ts::take_from_address<PoolAdminCap>(&scenario, ADMIN);

            pool::unpause_pool(&mut pool, &admin_cap);
            assert!(!pool::is_paused(&pool), 1);

            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = pool::EPoolPaused)]
    fun test_swap_when_paused_fails() {
        let mut scenario = setup_pool_with_liquidity();

        // Admin pauses pool
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let admin_cap = ts::take_from_address<PoolAdminCap>(&scenario, ADMIN);
            pool::pause_pool(&mut pool, &admin_cap);
            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(pool);
        };

        // User tries to swap (should fail)
        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let token = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));
            let out = pool::swap_a_to_b(&mut pool, token, 0, ts::ctx(&mut scenario));
            transfer::public_transfer(out, USER2);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = pool::ESlippageExceeded)]
    fun test_slippage_protection() {
        let mut scenario = setup_pool_with_liquidity();

        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let token = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));

            // Set unrealistically high minimum output
            let min_out = 10000000;
            let out = pool::swap_a_to_b(&mut pool, token, min_out, ts::ctx(&mut scenario));

            transfer::public_transfer(out, USER2);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    // ======== Helper Functions ========

    fun setup_pool(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            pool::create_pool_and_share<SUI, USDC>(ts::ctx(&mut scenario));
        };
        scenario
    }

    fun setup_pool_with_liquidity(): Scenario {
        let mut scenario = setup_pool();

        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<Pool<SUI, USDC>>(&scenario);
            let token_sui = coin::mint_for_testing<SUI>(INITIAL_LIQUIDITY, ts::ctx(&mut scenario));
            let token_usdc = coin::mint_for_testing<USDC>(INITIAL_LIQUIDITY, ts::ctx(&mut scenario));
            let lp_token = pool::add_liquidity(&mut pool, token_sui, token_usdc, ts::ctx(&mut scenario));
            transfer::public_transfer(lp_token, USER1);
            ts::return_shared(pool);
        };

        scenario
    }
}
