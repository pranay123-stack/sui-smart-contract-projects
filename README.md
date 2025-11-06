# 🚀 Sui Smart Contract Projects - Production DeFi Protocols

[![Sui](https://img.shields.io/badge/Sui-1.60.0-blue)](https://sui.io/)
[![Tests](https://img.shields.io/badge/tests-27%2F27%20passing-brightgreen)](https://github.com/pranay123-stack/sui-smart-contract-projects)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Deploy](https://img.shields.io/badge/deploy-testnet-orange)](https://testnet.suivision.xyz/)

A comprehensive portfolio of production-ready DeFi smart contracts built on Sui blockchain, featuring a lending protocol, AMM DEX, token vault, and security audit framework. All contracts are deployed to Sui Testnet with 100% test coverage.

> **Built by [Pranay](https://github.com/pranay123-stack)** - Web3 Smart Contract Engineer specializing in DeFi protocols

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Deployed Contracts](#-deployed-contracts-live-on-sui-testnet)
- [Projects](#-projects)
- [Installation](#-installation)
- [Testing](#-testing)
- [Deployment](#-deployment)
- [Features](#-features)
- [Architecture](#-architecture)
- [Security](#-security)
- [Contributing](#-contributing)
- [Support](#-support-the-project)
- [Contact & Hire Me](#-contact--hire-me)
- [License](#-license)

---

## 🌟 Overview

This repository contains **4 production-ready projects** demonstrating expertise in:
- ✅ **DeFi Protocol Development** - Lending, AMM, Vaults
- ✅ **Sui Move** - Native blockchain development
- ✅ **Security Best Practices** - Audit frameworks & analysis
- ✅ **Professional Standards** - 100% test coverage, comprehensive docs

### 🎯 Key Achievements
- **27/27 Tests Passing** ✅
- **3 Contracts Deployed** to Sui Testnet ✅
- **3,500+ Lines of Code** ✅
- **Security Analyzed** ✅
- **Production Ready** ✅

---

## 🚀 Deployed Contracts (Live on Sui Testnet)

All contracts are **live and verified** on Sui Testnet:

### 1️⃣ Token Vault Package
- **Package ID:** `0x790083d44489c1e1a8373a470b48b9b64d9e43c451e3d3917e37e5e13ba4f47b`
- **Contains:** `token_vault::vault` module
- **Explorer:** [View on Sui Explorer](https://testnet.suivision.xyz/package/0x790083d44489c1e1a8373a470b48b9b64d9e43c451e3d3917e37e5e13ba4f47b)
- **Status:** 🟢 Live

### 2️⃣ AMM DEX Package
- **Package ID:** `0x32e887df4e3a2ca0b104f39336994442c092de453f71fd0eaf065df0ee9e1840`
- **Contains:** `amm_dex::pool` module
- **Explorer:** [View on Sui Explorer](https://testnet.suivision.xyz/package/0x32e887df4e3a2ca0b104f39336994442c092de453f71fd0eaf065df0ee9e1840)
- **Status:** 🟢 Live

### 3️⃣ Lending Protocol Package ⭐ **FLAGSHIP**
- **Package ID:** `0xf7d7820575a71fe7990f3f741ec5bd8be7a8f03aa6d8b23c20aed6f52071972f`
- **Contains:** `lending_protocol::lending_pool` module
- **Explorer:** [View on Sui Explorer](https://testnet.suivision.xyz/package/0xf7d7820575a71fe7990f3f741ec5bd8be7a8f03aa6d8b23c20aed6f52071972f)
- **Status:** 🟢 Live

---

## 📦 Projects

### 1. Token Vault
**Complexity:** ⭐⭐⭐ (Medium)

A secure token vault with yield accrual and emergency controls.

**Features:**
- Share-based deposit/withdrawal system
- Yield accrual mechanism
- Emergency pause functionality
- Capability-based access control

**Tests:** 7/7 ✅

**[📖 Full Documentation →](project1-token-vault/README.md)**

---

### 2. AMM DEX Protocol
**Complexity:** ⭐⭐⭐⭐ (Medium-High)

Automated Market Maker implementing constant product formula (x * y = k).

**Features:**
- Liquidity pool management
- Token swaps with 0.3% fee
- LP token system
- Slippage protection
- Price impact calculations

**Tests:** 10/10 ✅

**[📖 Full Documentation →](project2-amm-dex/README.md)**

---

### 3. Lending Protocol ⭐
**Complexity:** ⭐⭐⭐⭐⭐ (High)

Production-ready overcollateralized lending protocol.

**Features:**
- Overcollateralized borrowing (75% collateral factor)
- Dynamic interest rates based on utilization
- Health factor monitoring
- Liquidation mechanism with 5% bonus
- Time-based interest accrual

**DeFi Concepts:**
- Collateralization ratios
- Liquidation thresholds
- Kinked interest rate curves
- Health factors
- Position management

**Tests:** 10/10 ✅

**[📖 Full Documentation →](project3-lending-protocol/README.md)**

---

### 4. Security Audit Framework
**Complexity:** ⭐⭐⭐⭐ (Medium-High)

Comprehensive security audit tools for Sui Move contracts.

**Features:**
- 80+ point security checklist
- Automated static analyzer (Python)
- Common vulnerability detection
- Best practices documentation

**[📖 Full Documentation →](project4-security-tools/README.md)**

---

## 💻 Installation

### Prerequisites

```bash
# Install Sui CLI (version 1.60.0 or higher)
cargo install --locked --git https://github.com/MystenLabs/sui.git --branch testnet sui

# Verify installation
sui --version
```

### Clone Repository

```bash
git clone https://github.com/pranay123-stack/sui-smart-contract-projects.git
cd sui-smart-contract-projects
```

### Project Structure

```
sui-smart-contract-projects/
├── project1-token-vault/          # Token vault implementation
├── project2-amm-dex/              # AMM DEX protocol
├── project3-lending-protocol/     # Lending protocol (flagship)
├── project4-security-tools/       # Security audit framework
├── README.md                      # This file
├── DEPLOYMENT_INFO.md             # Deployment details
└── LICENSE                        # MIT License
```

---

## 🧪 Testing

### Run All Tests

```bash
# Project 1: Token Vault
cd project1-token-vault/token_vault
sui move test
# Expected: 7/7 tests passing ✅

# Project 2: AMM DEX
cd ../../project2-amm-dex/amm_dex
sui move test
# Expected: 10/10 tests passing ✅

# Project 3: Lending Protocol
cd ../../project3-lending-protocol/lending_protocol
sui move test
# Expected: 10/10 tests passing ✅
```

### Build Contracts

```bash
# Build any project
cd <project-directory>
sui move build
```

### Run Security Analysis

```bash
cd project4-security-tools/scripts
python3 analyze_contract.py ../project3-lending-protocol/lending_protocol/sources
```

---

## 🚀 Deployment

### Deploy to Sui Testnet

#### 1. Get Testnet SUI

```bash
# Request testnet SUI from faucet
curl --location --request POST 'https://faucet.testnet.sui.io/gas' \
  --header 'Content-Type: application/json' \
  --data-raw '{"FixedAmountRequest":{"recipient":"YOUR_ADDRESS"}}'
```

#### 2. Switch to Testnet

```bash
sui client switch --env testnet
```

#### 3. Deploy Contract

```bash
# Example: Deploy Token Vault
cd project1-token-vault/token_vault
sui client publish --gas-budget 100000000

# Example: Deploy AMM DEX
cd ../../project2-amm-dex/amm_dex
sui client publish --gas-budget 100000000

# Example: Deploy Lending Protocol
cd ../../project3-lending-protocol/lending_protocol
sui client publish --gas-budget 100000000
```

#### 4. Verify Deployment

```bash
# Visit Sui Explorer
https://testnet.suivision.xyz/package/<YOUR_PACKAGE_ID>
```

**📖 [Full Deployment Guide →](DEPLOYMENT_GUIDE.md)**

---

## ✨ Features

### Technical Highlights

- **Sui Move 1.60.0** - Latest version
- **100% Test Coverage** - All public functions tested
- **Security Analyzed** - Custom static analyzer included
- **Production Ready** - Deployed to Sui Testnet
- **Comprehensive Docs** - Detailed README for each project

### DeFi Concepts Demonstrated

1. **Lending & Borrowing** - Overcollateralized lending protocol
2. **Automated Market Making** - Constant product formula (x * y = k)
3. **Liquidity Provision** - LP token mechanics
4. **Yield Generation** - Interest accrual mechanisms
5. **Liquidations** - Incentivized position liquidation
6. **Risk Management** - Health factors, collateral ratios

---

## 🏗️ Architecture

### Design Patterns

- **Capability-Based Access Control** - Secure admin functions
- **Share-Based Accounting** - Fair distribution (like cTokens/aTokens)
- **Event-Driven Architecture** - Complete off-chain tracking
- **Generic Type Parameters** - Flexible, reusable code

### Security Features

- ✅ Integer overflow protection
- ✅ Access control enforcement
- ✅ Balance consistency checks
- ✅ Emergency pause mechanisms
- ✅ Static analysis validation

---

## 🔐 Security

### Security Measures

All projects implement:
1. **Access Control** - Capability-based authorization
2. **Arithmetic Safety** - Overflow protection, precision handling
3. **Asset Safety** - Balance verification, proper transfers
4. **Emergency Controls** - Pause mechanisms
5. **Economic Security** - Liquidation incentives, slippage protection

### Security Audit Tools

Run the included security analyzer:

```bash
cd project4-security-tools/scripts
python3 analyze_contract.py <path-to-move-sources>
```

**Features:**
- 80+ point security checklist
- Automated vulnerability detection
- Best practices validation

---

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Follow existing code style
- Add tests for new features
- Update documentation
- Run security analysis

---

## 💰 Support the Project

If you find this project helpful, consider supporting my work:

### 💳 Crypto Payments

**Solana (USDT):**
```
Network: Solana
Token: USDT
Address: FESni41iopVgF1RLLu6YxpWpYCePD4f7zvuCx9xBGLbX
```

### 💵 Fiat Payments

**PayPal:**
- Email: pkumarsaurabh000@gmail.com
- PayPal.me: [https://paypal.me/SBarnwal82](https://paypal.me/SBarnwal82)
- Name: Saurabh Kumar Barnwal

**UPI (India):**
```
UPI ID: pranaygaurav4555@okhdfcbank
```

**Bank Transfer (India - HDFC Bank):**
```
Account Number: 50100254478760
IFSC Code: HDFC0000344
Account Name: PRANAY GAURAV
Account Type: Savings
Branch: Muzaffarpur, Bihar
Bank: HDFC Bank
```

---

## 📞 Contact & Hire Me

### 👨‍💻 About Me

I'm a **Web3 Smart Contract Engineer** specializing in:
- DeFi Protocol Development
- Sui Move & Solidity
- Security Audits
- Smart Contract Architecture

### 🔗 Connect With Me

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/pranay-gaurav-290a30150/)
[![GitHub](https://img.shields.io/badge/GitHub-100000?style=for-the-badge&logo=github&logoColor=white)](https://github.com/pranay123-stack)
[![Email](https://img.shields.io/badge/Email-D14836?style=for-the-badge&logo=gmail&logoColor=white)](mailto:pranaygaurav4555@gmail.com)
[![WhatsApp](https://img.shields.io/badge/WhatsApp-25D366?style=for-the-badge&logo=whatsapp&logoColor=white)](https://wa.me/918235617269)

### 💼 Hire Me for:

- ✅ Smart Contract Development (Sui Move, Solidity)
- ✅ DeFi Protocol Design & Implementation
- ✅ Security Audits & Code Reviews
- ✅ Blockchain Consulting
- ✅ Web3 Full-Stack Development

### 📅 Schedule a Meeting

**Book a 1-on-1 Consultation:**

[![Calendly](https://img.shields.io/badge/Calendly-006BFF?style=for-the-badge&logo=calendly&logoColor=white)](https://calendly.com/pranaygaurav4555)
[![Topmate](https://img.shields.io/badge/Topmate-FF6B6B?style=for-the-badge&logo=topmate&logoColor=white)](https://topmate.io/pranay_gaurav12)

### 📧 Direct Contact

- **Email:** pranaygaurav4555@gmail.com
- **LinkedIn:** [linkedin.com/in/pranay-gaurav-290a30150](https://www.linkedin.com/in/pranay-gaurav-290a30150/)
- **WhatsApp:** [+91-823-561-7269](https://wa.me/918235617269)
- **Calendly:** [calendly.com/pranaygaurav4555](https://calendly.com/pranaygaurav4555)
- **Topmate:** [topmate.io/pranay_gaurav12](https://topmate.io/pranay_gaurav12)

---

## 🎯 For Recruiters & Companies

### Looking for a Smart Contract Engineer?

I'm available for:
- **Full-time positions** - Web3/Blockchain companies
- **Contract work** - DeFi protocols, NFT projects
- **Consulting** - Architecture reviews, security audits
- **Freelance projects** - Smart contract development

### 📊 My Expertise

**Languages & Frameworks:**
- Sui Move, Solidity, Rust
- Web3.js, Ethers.js, Sui SDK
- React, Node.js, TypeScript

**DeFi Experience:**
- Lending protocols (Aave, Compound style)
- AMM DEX (Uniswap style)
- Yield farming & staking
- Token vaults & strategies

**Security & Testing:**
- Comprehensive test coverage
- Security audit experience
- Static analysis tools
- Best practices implementation

### 💼 Portfolio Highlights

This repository showcases:
- ✅ 3 production-ready DeFi protocols
- ✅ All deployed to Sui Testnet
- ✅ 27/27 tests passing
- ✅ Security audit framework
- ✅ Professional documentation

### 📅 Let's Talk

**Quick Contact:**
- 📧 Email: pranaygaurav4555@gmail.com
- 📱 WhatsApp: [Message Me](https://wa.me/918235617269)
- 📞 Calendly: [Book a Call](https://calendly.com/pranaygaurav4555)
- 💬 LinkedIn: [Connect](https://www.linkedin.com/in/pranay-gaurav-290a30150/)
- 🎯 Topmate: [Schedule Session](https://topmate.io/pranay_gaurav12)

---

## 📚 Additional Resources

- **[Deployment Guide](DEPLOYMENT_GUIDE.md)** - Step-by-step deployment instructions
- **[Deployment Info](DEPLOYMENT_INFO.md)** - Live contract addresses
- **[Project Summary](PROJECT_SUMMARY.md)** - Executive summary
- **[Build Results](BUILD_RESULTS.md)** - Test results & metrics

---

## 📊 Statistics

| Metric | Value |
|--------|-------|
| Projects | 4 |
| Smart Contracts | 3 |
| Tests Passing | 27/27 ✅ |
| Lines of Code | 3,500+ |
| Test Coverage | 100% |
| Deployments | 3 (Sui Testnet) |
| Documentation | Comprehensive |

---

## 🌟 Star History

If you find this project useful, please consider giving it a ⭐!

[![Star History Chart](https://api.star-history.com/svg?repos=pranay123-stack/sui-smart-contract-projects&type=Date)](https://star-history.com/#pranay123-stack/sui-smart-contract-projects&Date)

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- **Sui Foundation** - For excellent documentation and tooling
- **Suilend** - Inspiration for lending protocol design
- **Uniswap** - AMM constant product formula
- **Aave & Compound** - Lending protocol architecture

---

## 📈 What's Next?

### Upcoming Features

- [ ] Flash loan functionality
- [ ] Oracle integration
- [ ] Multi-collateral support
- [ ] Governance token
- [ ] Mainnet deployment

### Stay Updated

Watch this repo for updates or follow me:
- GitHub: [@pranay123-stack](https://github.com/pranay123-stack)
- LinkedIn: [Pranay Gaurav](https://www.linkedin.com/in/pranay-gaurav-290a30150/)

---

<div align="center">

## 🚀 **Ready to Build DeFi on Sui?**

**Clone this repo and start building today!**

```bash
git clone https://github.com/pranay123-stack/sui-smart-contract-projects.git
```

### 💬 Questions? Let's Connect!

[![Email](https://img.shields.io/badge/Email-Me-red?style=for-the-badge)](mailto:pranaygaurav4555@gmail.com)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue?style=for-the-badge)](https://www.linkedin.com/in/pranay-gaurav-290a30150/)
[![Calendly](https://img.shields.io/badge/Calendly-Book-orange?style=for-the-badge)](https://calendly.com/pranaygaurav4555)
[![Topmate](https://img.shields.io/badge/Topmate-Schedule-purple?style=for-the-badge)](https://topmate.io/pranay_gaurav12)

---

**Built with ❤️ by [Pranay](https://github.com/pranay123-stack)**

**⭐ Star this repo if you find it useful!**

</div>
