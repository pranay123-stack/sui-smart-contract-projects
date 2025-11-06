#[test_only]
module token_vault::vault_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use token_vault::vault::{Self, Vault, VaultReceipt, AdminCap};

    const ADMIN: address = @0xAD;
    const USER1: address = @0x1;
    const USER2: address = @0x2;

    const DEPOSIT_AMOUNT: u64 = 1000;

    #[test]
    fun test_create_vault() {
        let mut scenario = ts::begin(ADMIN);

        {
            vault::create_vault(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            assert!(ts::has_most_recent_shared<Vault>(), 0);
            assert!(ts::has_most_recent_for_address<AdminCap>(ADMIN), 1);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_deposit_and_withdraw() {
        let mut scenario = setup_vault();

        // User1 deposits
        ts::next_tx(&mut scenario, USER1);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let coin = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));

            vault::deposit(&mut vault, coin, ts::ctx(&mut scenario));

            assert!(vault::get_vault_balance(&vault) == DEPOSIT_AMOUNT, 0);
            assert!(vault::get_total_shares(&vault) == DEPOSIT_AMOUNT, 1);

            ts::return_shared(vault);
        };

        // User1 receives receipt
        ts::next_tx(&mut scenario, USER1);
        {
            assert!(ts::has_most_recent_for_address<VaultReceipt>(USER1), 2);
        };

        // User1 withdraws
        ts::next_tx(&mut scenario, USER1);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let receipt = ts::take_from_address<VaultReceipt>(&scenario, USER1);

            vault::withdraw(&mut vault, receipt, ts::ctx(&mut scenario));

            assert!(vault::get_vault_balance(&vault) == 0, 3);
            assert!(vault::get_total_shares(&vault) == 0, 4);

            ts::return_shared(vault);
        };

        // User1 receives withdrawn coins
        ts::next_tx(&mut scenario, USER1);
        {
            let withdrawn = ts::take_from_address<Coin<SUI>>(&scenario, USER1);
            assert!(coin::value(&withdrawn) == DEPOSIT_AMOUNT, 5);
            ts::return_to_address(USER1, withdrawn);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_multiple_deposits() {
        let mut scenario = setup_vault();

        // User1 deposits
        ts::next_tx(&mut scenario, USER1);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let coin = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            vault::deposit(&mut vault, coin, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        // User2 deposits same amount
        ts::next_tx(&mut scenario, USER2);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let coin = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            vault::deposit(&mut vault, coin, ts::ctx(&mut scenario));

            assert!(vault::get_vault_balance(&vault) == DEPOSIT_AMOUNT * 2, 0);
            assert!(vault::get_total_shares(&vault) == DEPOSIT_AMOUNT * 2, 1);

            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_yield_accrual() {
        let mut scenario = setup_vault();

        // User1 deposits
        ts::next_tx(&mut scenario, USER1);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let coin = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            vault::deposit(&mut vault, coin, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        // Admin accrues yield
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
            let yield_coin = coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario));

            vault::accrue_yield(&mut vault, &admin_cap, yield_coin, ts::ctx(&mut scenario));

            assert!(vault::get_vault_balance(&vault) == DEPOSIT_AMOUNT + 100, 0);

            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(vault);
        };

        // User1 withdraws and gets yield
        ts::next_tx(&mut scenario, USER1);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let receipt = ts::take_from_address<VaultReceipt>(&scenario, USER1);

            vault::withdraw(&mut vault, receipt, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        ts::next_tx(&mut scenario, USER1);
        {
            let withdrawn = ts::take_from_address<Coin<SUI>>(&scenario, USER1);
            assert!(coin::value(&withdrawn) == DEPOSIT_AMOUNT + 100, 1);
            ts::return_to_address(USER1, withdrawn);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_pause_and_unpause() {
        let mut scenario = setup_vault();

        // Admin pauses vault
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

            vault::pause_vault(&mut vault, &admin_cap, ts::ctx(&mut scenario));
            assert!(vault::is_paused(&vault), 0);

            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(vault);
        };

        // Admin unpauses vault
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);

            vault::unpause_vault(&mut vault, &admin_cap, ts::ctx(&mut scenario));
            assert!(!vault::is_paused(&vault), 1);

            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = vault::EVaultPaused)]
    fun test_deposit_when_paused() {
        let mut scenario = setup_vault();

        // Admin pauses vault
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
            vault::pause_vault(&mut vault, &admin_cap, ts::ctx(&mut scenario));
            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(vault);
        };

        // User1 tries to deposit (should fail)
        ts::next_tx(&mut scenario, USER1);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let coin = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            vault::deposit(&mut vault, coin, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_share_value_calculation() {
        let mut scenario = setup_vault();

        // User1 deposits
        ts::next_tx(&mut scenario, USER1);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let coin = coin::mint_for_testing<SUI>(DEPOSIT_AMOUNT, ts::ctx(&mut scenario));
            vault::deposit(&mut vault, coin, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        // Add yield
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault = ts::take_shared<Vault>(&scenario);
            let admin_cap = ts::take_from_address<AdminCap>(&scenario, ADMIN);
            let yield_coin = coin::mint_for_testing<SUI>(200, ts::ctx(&mut scenario));
            vault::accrue_yield(&mut vault, &admin_cap, yield_coin, ts::ctx(&mut scenario));
            ts::return_to_address(ADMIN, admin_cap);
            ts::return_shared(vault);
        };

        // Check share value
        ts::next_tx(&mut scenario, USER1);
        {
            let vault = ts::take_shared<Vault>(&scenario);
            let receipt = ts::take_from_address<VaultReceipt>(&scenario, USER1);

            let shares = vault::get_receipt_shares(&receipt);
            let value = vault::calculate_share_value(&vault, shares);

            assert!(value == DEPOSIT_AMOUNT + 200, 0);

            ts::return_to_address(USER1, receipt);
            ts::return_shared(vault);
        };

        ts::end(scenario);
    }

    // Helper function to setup vault
    fun setup_vault(): Scenario {
        let mut scenario = ts::begin(ADMIN);

        {
            vault::create_vault(ts::ctx(&mut scenario));
        };

        scenario
    }
}
