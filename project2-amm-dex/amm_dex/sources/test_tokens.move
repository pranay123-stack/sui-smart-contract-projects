/// Test tokens for AMM DEX testing
#[test_only]
module amm_dex::test_tokens {
    use sui::coin;

    public struct USDC has drop {}
    public struct USDT has drop {}

    #[test_only]
    public fun init_usdc(ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            USDC {},
            6,
            b"USDC",
            b"USD Coin",
            b"Test USDC token",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury, ctx.sender());
    }

    #[test_only]
    public fun init_usdt(ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            USDT {},
            6,
            b"USDT",
            b"Tether USD",
            b"Test USDT token",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury, ctx.sender());
    }
}
