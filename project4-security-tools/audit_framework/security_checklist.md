# Sui Move Smart Contract Security Audit Checklist

A comprehensive security checklist for auditing Sui Move smart contracts, with focus on DeFi protocols.

## 1. Access Control & Authorization

### 1.1 Capability-based Access Control
- [ ] All admin functions protected by capability objects?
- [ ] Capabilities stored securely (not in public storage)?
- [ ] No hardcoded addresses for authorization?
- [ ] Capability transfers properly restricted?
- [ ] Multi-signature requirements for critical operations?

**Example Issues:**
```move
// ❌ Bad: Hardcoded admin
public fun admin_function(ctx: &TxContext) {
    assert!(ctx.sender() == @0xADMIN, 1);
}

// ✅ Good: Capability-based
public fun admin_function(_cap: &AdminCap) {
    // Only holders of AdminCap can call
}
```

### 1.2 Object Ownership
- [ ] Proper use of `key`, `store`, `copy`, `drop` abilities?
- [ ] Objects transferred to correct addresses?
- [ ] No accidental public exposure of internal objects?
- [ ] Proper use of `transfer::transfer` vs `transfer::public_transfer`?

## 2. Arithmetic & Numeric Safety

### 2.1 Integer Overflow/Underflow
- [ ] All arithmetic operations checked for overflow?
- [ ] Use of Sui Move's built-in overflow protection verified?
- [ ] Large number multiplications done carefully?
- [ ] Division by zero checks present?

**Example Issues:**
```move
// ❌ Potential overflow
let result = amount * large_multiplier;

// ✅ Better: Check bounds
assert!(amount <= MAX_SAFE_AMOUNT, EOverflow);
let result = amount * large_multiplier;
```

### 2.2 Precision & Rounding
- [ ] Consistent use of precision constants?
- [ ] Rounding errors minimized in financial calculations?
- [ ] Division performed after multiplication to avoid precision loss?
- [ ] No accumulation of dust amounts?

```move
// ❌ Bad: Precision loss
let result = (amount / price) * decimals;

// ✅ Good: Multiply first
let result = (amount * decimals) / price;
```

## 3. Asset Handling

### 3.1 Coin & Balance Management
- [ ] All coins properly handled (no orphaned coins)?
- [ ] Balance arithmetic matches coin transfers?
- [ ] No double-counting of assets?
- [ ] Proper use of `coin::value()`, `coin::into_balance()`, `coin::from_balance()`?

### 3.2 Deposit & Withdrawal Logic
- [ ] Deposit amounts correctly credited?
- [ ] Withdrawal amounts correctly debited?
- [ ] Sufficient balance checks before withdrawals?
- [ ] No re-entrancy vulnerabilities in withdrawal flows?

**Example Issues:**
```move
// ❌ Bad: No balance check
public fun withdraw(pool: &mut Pool, amount: u64) {
    let coin = coin::from_balance(
        balance::split(&mut pool.balance, amount),
        ctx
    );
}

// ✅ Good: Check first
public fun withdraw(pool: &mut Pool, amount: u64) {
    let available = balance::value(&pool.balance);
    assert!(amount <= available, EInsufficientBalance);
    // ... proceed with withdrawal
}
```

## 4. DeFi-Specific Vulnerabilities

### 4.1 Flash Loan Attacks
- [ ] State changes finalized before external calls?
- [ ] No reliance on spot prices for critical decisions?
- [ ] Proper use of time-weighted averages where applicable?

### 4.2 Price Manipulation
- [ ] Oracle integration secure and tamper-resistant?
- [ ] No circular price dependencies?
- [ ] Slippage protection in place for swaps?
- [ ] TWAP or median prices used instead of spot prices?

### 4.3 Liquidity Pool Security
- [ ] First depositor inflation attack prevented?
- [ ] Minimum liquidity locked permanently?
- [ ] Fair LP token minting calculations?
- [ ] No donation attack vectors?

**Example Mitigation:**
```move
// ✅ Prevent first depositor inflation
let lp_tokens = if (total_supply == 0) {
    let initial = sqrt(amount_a * amount_b);
    assert!(initial > MINIMUM_LIQUIDITY, ETooSmall);
    initial - MINIMUM_LIQUIDITY // Lock minimum liquidity
} else {
    calculate_proportional_shares(...)
};
```

### 4.4 Lending Protocol Risks
- [ ] Health factor calculations accurate?
- [ ] Liquidation thresholds properly set?
- [ ] Interest rate models economically sound?
- [ ] No over-collateralization bypass vulnerabilities?
- [ ] Liquidation incentives sufficient but not excessive?

## 5. Re-entrancy

### 5.1 State Consistency
- [ ] State updates before external calls?
- [ ] No callback vulnerabilities?
- [ ] Proper use of checks-effects-interactions pattern?

**Example:**
```move
// ✅ Good: Update state before transfer
pool.total_borrowed = pool.total_borrowed - amount;
position.shares = 0;
// Now safe to transfer
transfer::public_transfer(coin, recipient);
```

## 6. Time & Oracle Dependencies

### 6.1 Timestamp Usage
- [ ] Timestamp manipulation considered?
- [ ] Time-based logic uses block timestamps correctly?
- [ ] No reliance on precise timing for critical operations?

### 6.2 Oracle Security
- [ ] Multiple oracle sources used?
- [ ] Oracle data validated before use?
- [ ] Stale price detection implemented?
- [ ] Oracle failure modes handled gracefully?

## 7. Denial of Service (DoS)

### 7.1 Gas Limits
- [ ] No unbounded loops?
- [ ] Batch operations limited in size?
- [ ] No operations that can run out of gas?

### 7.2 Resource Exhaustion
- [ ] Storage growth bounded?
- [ ] No vector/table bloat vulnerabilities?
- [ ] Cleanup mechanisms for old data?

**Example Issues:**
```move
// ❌ Bad: Unbounded iteration
public fun process_all(items: &vector<Item>) {
    let mut i = 0;
    while (i < vector::length(items)) { // Could be huge!
        process(vector::borrow(items, i));
        i = i + 1;
    };
}

// ✅ Good: Bounded operations
public fun process_batch(items: &vector<Item>, start: u64, count: u64) {
    assert!(count <= MAX_BATCH_SIZE, ETooLarge);
    // Process limited batch
}
```

## 8. Event Emission

### 8.1 Event Completeness
- [ ] All state changes emit events?
- [ ] Events contain sufficient information for off-chain tracking?
- [ ] No sensitive data in events?
- [ ] Event ordering consistent?

## 9. Testing & Verification

### 9.1 Test Coverage
- [ ] Unit tests for all public functions?
- [ ] Edge case testing (zero amounts, max values)?
- [ ] Negative tests for error conditions?
- [ ] Multi-user interaction scenarios tested?
- [ ] Gas consumption profiling done?

### 9.2 Formal Verification
- [ ] Critical invariants documented?
- [ ] Mathematical proofs for financial calculations?
- [ ] State machine verified?

## 10. Economic Security

### 10.1 Incentive Alignment
- [ ] Economic incentives properly aligned?
- [ ] No perverse incentives for malicious behavior?
- [ ] Fee structures sustainable?
- [ ] Liquidation economics sound?

### 10.2 Front-running
- [ ] Transaction ordering attacks considered?
- [ ] Slippage limits protect users?
- [ ] No MEV extraction vulnerabilities?

## 11. Emergency Controls

### 11.1 Circuit Breakers
- [ ] Pause/emergency stop functionality?
- [ ] Gradual activation/deactivation of features?
- [ ] Admin privileges clearly limited?
- [ ] Time-locks on critical parameter changes?

### 11.2 Upgradeability
- [ ] Upgrade mechanisms secure?
- [ ] Migration paths tested?
- [ ] No proxy pattern vulnerabilities?

## 12. Documentation & Comments

- [ ] Complex logic well-commented?
- [ ] Security assumptions documented?
- [ ] Known limitations listed?
- [ ] API documentation complete?

## Critical Risk Ratings

| Risk Level | Description | Examples |
|------------|-------------|----------|
| 🔴 Critical | Can lead to fund loss | Overflow in withdrawal, Missing access control |
| 🟠 High | Protocol can be exploited | Price oracle manipulation, Liquidation bypass |
| 🟡 Medium | Affects availability or UX | DoS vectors, Gas inefficiency |
| 🟢 Low | Minor issues | Missing events, Suboptimal code structure |

## Audit Report Template

```markdown
# Smart Contract Audit Report

## Project: [Name]
## Date: [Date]
## Auditor: [Name]

### Executive Summary
- Total Issues Found: X
- Critical: X | High: X | Medium: X | Low: X

### Findings

#### [CRITICAL-001] Integer Overflow in Withdrawal Function
**Severity:** Critical
**Location:** module::function, line X
**Description:** [Detailed description]
**Impact:** Users could withdraw more than deposited
**Recommendation:** Add overflow checks
**Status:** [ ] Pending [ ] Fixed [ ] Acknowledged

[Continue for each finding...]

### Positive Observations
- Well-tested codebase
- Good use of capability patterns
- Clear code structure

### Recommendations
1. Implement multi-sig for admin functions
2. Add formal verification for critical math
3. Integrate multiple oracle sources
```

## Automated Check Scripts

See `scripts/` directory for automated checking tools:
- `check_capabilities.sh` - Verify capability usage
- `check_arithmetic.sh` - Find potential overflow issues
- `check_access_control.sh` - Audit access patterns
- `gas_profiler.sh` - Profile gas consumption

## References

1. [Sui Move Security Best Practices](https://docs.sui.io/build/move/security)
2. [Move Prover Documentation](https://github.com/move-language/move/tree/main/language/move-prover)
3. [DeFi Security Standards](https://github.com/securing/SCSVS)
4. [Smart Contract Weakness Classification](https://swcregistry.io/)

## Version History

- v1.0.0 - Initial checklist
- Focus areas: DeFi, Sui Move, Access Control, Arithmetic Safety
