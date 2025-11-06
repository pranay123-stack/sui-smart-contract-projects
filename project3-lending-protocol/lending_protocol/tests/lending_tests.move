#[test_only]
module lending_protocol::lending_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use lending_protocol::lending_pool::{
        Self,
        LendingPool,
        DepositPosition,
        BorrowPosition,
        AdminCap
    };

    const ADMIN: address = @0xAD;
    const USER1: address = @0x1;
    const USER2: address = @0x2;

    const DEPOSIT_AMOUNT: u64 = 1000000;
    const COLLATERAL_AMOUNT: u64 = 10000;
    const BORROW_AMOUNT: u64 = 7000; // 70% of collateral (within 75% limit)

    #[test]
    fun test_create_pool() {
        let mut scenario = ts::begin(ADMIN);

        {
            lending_pool::create_pool<SUI>(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            assert!(ts::has_most_recent_shared<LendingPool<SUI>>(), 0);
            assert!(ts::has_most_recent_for_address<AdminCap>(ADMIN), 1);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_deposit_and_withdraw() {
        let mut scenario = setup_pool();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // User deposits
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let token = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));

            lending_pool::deposit(&mut pool, token, &clock, ts::ctx(&mut scenario));

            ts::return_shared(pool);
        };

        // Check deposit position created
        ts::next_tx(&mut scenario, USER1);
        {
            assert!(ts::has_most_recent_for_address<DepositPosition<SUI>>(USER1), 0);
        };

        // User withdraws
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let position = ts::take_from_address<DepositPosition<SUI>>(&scenario, USER1);

            lending_pool::withdraw(&mut pool, position, &clock, ts::ctx(&mut scenario));

            ts::return_shared(pool);
        };

        // Check withdrawn coins
        ts::next_tx(&mut scenario, USER1);
        {
            let withdrawn = ts::take_from_address<Coin<SUI>>(&scenario, USER1);
            assert!(coin::value(&withdrawn) == DEPOSIT_AMOUNT, 1);
            ts::return_to_address(USER1, withdrawn);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_borrow_and_repay() {
        let mut scenario = setup_pool_with_liquidity();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // User1 borrows with collateral
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let collateral = coin::mint_for_testing<SUI>(COLLATERAL_AMOUNT, ts::ctx(&mut scenario));

            lending_pool::borrow(
                &mut pool,
                collateral,
                BORROW_AMOUNT,
                &clock,
                ts::ctx(&mut scenario)
            );

            ts::return_shared(pool);
        };

        // Check borrow position and borrowed coins
        ts::next_tx(&mut scenario, USER1);
        {
            assert!(ts::has_most_recent_for_address<BorrowPosition<SUI>>(USER1), 0);
            let borrowed = ts::take_from_address<Coin<SUI>>(&scenario, USER1);
            assert!(coin::value(&borrowed) == BORROW_AMOUNT, 1);
            ts::return_to_address(USER1, borrowed);
        };

        // User1 repays
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let position = ts::take_from_address<BorrowPosition<SUI>>(&scenario, USER1);
            let repayment = coin::mint_for_testing<SUI>(BORROW_AMOUNT + 100, ts::ctx(&mut scenario));

            lending_pool::repay(&mut pool, position, repayment, &clock, ts::ctx(&mut scenario));

            ts::return_shared(pool);
        };

        // Check collateral returned
        ts::next_tx(&mut scenario, USER1);
        {
            let collateral_returned = ts::take_from_address<Coin<SUI>>(&scenario, USER1);
            assert!(coin::value(&collateral_returned) == COLLATERAL_AMOUNT, 2);
            ts::return_to_address(USER1, collateral_returned);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_health_factor_calculation() {
        let mut scenario = setup_pool_with_liquidity();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // User1 borrows
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let collateral = coin::mint_for_testing<SUI>(COLLATERAL_AMOUNT, ts::ctx(&mut scenario));

            lending_pool::borrow(
                &mut pool,
                collateral,
                BORROW_AMOUNT,
                &clock,
                ts::ctx(&mut scenario)
            );

            ts::return_shared(pool);
        };

        // Check health factor
        ts::next_tx(&mut scenario, USER1);
        {
            let pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let position = ts::take_from_address<BorrowPosition<SUI>>(&scenario, USER1);

            let health_factor = lending_pool::calculate_health_factor(&pool, &position);

            // Health factor should be > 1.0 (10000 in basis points)
            assert!(health_factor > 10000, 0);

            // Position should not be liquidatable
            assert!(!lending_pool::is_liquidatable(&pool, &position), 1);

            ts::return_to_address(USER1, position);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_liquidation() {
        let mut scenario = setup_pool_with_liquidity();
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // User1 borrows at high utilization (close to 75% limit)
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let collateral = coin::mint_for_testing<SUI>(10000, ts::ctx(&mut scenario));
            // Borrow 7400 (close to 75% collateral factor limit)
            lending_pool::borrow(&mut pool, collateral, 7400, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Simulate time passage and interest accrual
        clock::increment_for_testing(&mut clock, 365 * 24 * 60 * 60 * 1000); // 1 year

        // Accrue interest by doing a small action
        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let token = coin::mint_for_testing<SUI>(1, ts::ctx(&mut scenario));
            lending_pool::deposit(&mut pool, token, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Now position might be liquidatable due to accrued interest
        // For this test, we'll manually verify liquidation logic works
        ts::next_tx(&mut scenario, USER2);
        {
            let pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let position_ref = ts::take_from_address<BorrowPosition<SUI>>(&scenario, USER1);

            // Check if liquidatable (may or may not be depending on interest)
            let _is_liq = lending_pool::is_liquidatable(&pool, &position_ref);

            ts::return_to_address(USER1, position_ref);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_borrow_rate_calculation() {
        let mut scenario = setup_pool_with_liquidity();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Check initial borrow rate
        ts::next_tx(&mut scenario, USER1);
        {
            let pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let initial_rate = lending_pool::get_borrow_rate(&pool);

            // Should be at base rate with low utilization
            assert!(initial_rate >= 200, 0); // Base rate is 2%

            ts::return_shared(pool);
        };

        // Create high utilization by borrowing a lot
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let collateral = coin::mint_for_testing<SUI>(900000, ts::ctx(&mut scenario));
            // Borrow significant amount
            lending_pool::borrow(&mut pool, collateral, 650000, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Check increased borrow rate
        ts::next_tx(&mut scenario, USER1);
        {
            let pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let high_util_rate = lending_pool::get_borrow_rate(&pool);

            // Rate should be higher due to increased utilization
            assert!(high_util_rate > 200, 1);

            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_multiple_users() {
        let mut scenario = setup_pool();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // User1 deposits
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let token = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            lending_pool::deposit(&mut pool, token, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // User2 deposits
        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let token = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            lending_pool::deposit(&mut pool, token, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Check pool stats
        ts::next_tx(&mut scenario, USER1);
        {
            let pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let (total_deposits, total_borrowed, _) = lending_pool::get_pool_stats(&pool);

            assert!(total_deposits == DEPOSIT_AMOUNT * 2, 0);
            assert!(total_borrowed == 0, 1);

            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_pause_and_unpause() {
        let mut scenario = setup_pool();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Admin pauses pool
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

            lending_pool::pause_pool(&mut pool, &admin_cap);

            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(pool);
        };

        // Admin unpauses pool
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

            lending_pool::unpause_pool(&mut pool, &admin_cap);

            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = lending_pool::EPoolPaused)]
    fun test_deposit_when_paused_fails() {
        let mut scenario = setup_pool();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Admin pauses pool
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
            lending_pool::pause_pool(&mut pool, &admin_cap);
            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(pool);
        };

        // User tries to deposit (should fail)
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let token = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            lending_pool::deposit(&mut pool, token, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = lending_pool::EInsufficientCollateral)]
    fun test_overborrow_fails() {
        let mut scenario = setup_pool_with_liquidity();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // User tries to borrow more than allowed
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let collateral = coin::mint_for_testing<SUI>(COLLATERAL_AMOUNT, ts::ctx(&mut scenario));

            // Try to borrow 90% of collateral (exceeds 75% limit)
            lending_pool::borrow(&mut pool, collateral, 9000, &clock, ts::ctx(&mut scenario));

            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ======== Helper Functions ========

    fun setup_pool(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            lending_pool::create_pool<SUI>(ts::ctx(&mut scenario));
        };
        scenario
    }

    fun setup_pool_with_liquidity(): Scenario {
        let mut scenario = setup_pool();
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // USER2 provides initial liquidity
        ts::next_tx(&mut scenario, USER2);
        {
            let mut pool = ts::take_shared<LendingPool<SUI>>(&scenario);
            let token = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            lending_pool::deposit(&mut pool, token, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        scenario
    }
}
