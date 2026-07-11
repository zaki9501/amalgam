Ammalgam introduces a new primitive in decentralized finance: the Decentralized Lending Exchange (DLEX). By combining trading and lending into a single protocol, DLEX unlocks a level of capital efficiency that traditional platforms can't match, offering up to a 60% increase in yield for liquidity providers.

Protocol and security documentation is available in the Ammalgam security docs.

Severity Definitions
Only vulnerabilities that result in an on-chain loss of funds are eligible for a reward. Severity classification is secondary to this requirement: a finding must be reproducible in a proof-of-concept that demonstrates a loss of funds to the protocol's liquidity providers, using reasonably likely scenarios that are achievable without a malicious token or other conditions that would not be expected to occur on-chain.

POC requirements: All POCs must demonstrate the issue using public or external functions only. Findings that rely on calling library, internal, or private functions directly will be automatically rejected.

Critical

Direct theft of user funds, whether at-rest or in-motion, other than unclaimed yield
Permanent freezing of funds
Protocol insolvency that cannot be recovered from through the protocol's bad debt handling logic
High

A loss of funds that requires a specific precondition or a lower-likelihood scenario, but that can still occur under certain conditions
Bypass of authorized-user (trusted address) functionality, for example an untrusted address invoking logic restricted to trusted addresses, resulting in a loss of funds
Theft of unclaimed yield
Permanent freezing of unclaimed yield
Temporary freezing of funds for more than one week
Issues that do not result in a loss of funds are not eligible for a reward (see the Out of Scope group for examples).

In addition to the above definitions, we will also use the Cantina Bug Bounty Severity Classification Framework to determine severity.

Prohibited Actions
No live testing on public chains: Live testing on public or mainnet chains is explicitly prohibited to prevent unintended disruptions.
No public disclosure of bugs: Do not publicly disclose any vulnerability before it has been addressed.
Conflict of interest: Avoid any conflict of interest, including attempting to exploit the program itself or testing outside of defined hours or environments.

In scope
Smart Contracts
Severity

Min and Max Reward

Critical
Up to $25,000

High
Up to $10,000

The Ammalgam DLEX core protocol smart contracts, deployed on Ethereum mainnet. All contract-level vulnerabilities in the deployed contracts listed below are in scope.

Name
Description
Asset
Interest	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xe6cecf8b6593a7decf232bd2ccd444c4a09980b1

Validation	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xe61a70f7ad7ce007e6119663ba334884e193f72e

Liquidation	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xeaae9d222f16d0142eb3102788cecbe0c3e3ba1f

TimelockController	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x59ecf5e9bb7865baac4ce01948d5892ba01aeef8

SaturationAndGeometricTWAPState	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x126d9fca996192bcfcbd98c1763a8fa73469dc88

TransparentUpgradeableProxy	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xaac0fa3c48d70683650184a80313a998ca48d9fc

AmmalgamPair	
Ammalgam DLEX contract deployed on Ethereum mainnet.
https://etherscan.io/address/0x1b72e08c51e00660e78378158c406f3bfc906b67

PairLockedLoans	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x06dcc1f447929687bcde9553479918183948521c

PairBlockLendingFundRemoval	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xe8242c040ae9500b8f44b8975b0fecbcec1e6856

PairFrozen	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xbae04a75ed1d34995db84799b97b68848db9445e

BeaconController	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x7cca80b20e103924eeaa9785109b51e8345027dd

HookRegistry	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xf5190f2e5ecdf5cc825257aadc39e49f4185e329

ERC20LiquidityTokenFactory	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0xbc5f08075fd27187d8f14efd54a515e9ddf48e64

ERC4626DepositTokenFactory	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x67c021047196f040c940dffbb91342bd2ba7a937

ERC4626DebtTokenFactory	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x9293f3f59482fe557176829f62773e4f3e70c08e

ERC20DebtLiquidityTokenFactory	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x2ce8171ce1b39901c457f503e461d7738ff7698c

AmmalgamFactory	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x1a411b0fd1f368d2f413a8cbb6aad425c923015b

PeripheralLending	
Ammalgam DLEX contract deployed on Ethereum mainnet.

https://etherscan.io/address/0x4be3df5bd57ab5849b9da1941bac297ce5fa4bc2

Out of scope
Out of Scope
The following are considered known issues and are not eligible for rewards. For generic exclusions, see the Cantina Bug Bounty Out-of-Scope Policy.

Any issue that does not result in an on-chain loss of funds
Informational findings and design choices related to the protocol
Issues that are ultimately user errors and can easily be caught in the frontend (for example, transfers to address(0))
Rounding errors and off-by-one behavior in the ERC-4626 helper interfaces that do not result in a loss of funds
Relatively high gas consumption
Loss of funds resulting from violent market price movements, specifically any price increase greater than 33% or price decrease greater than 25% within a single block or 8-second period
Default Out of Scope
Standard out-of-scope items per the Cantina Bug Bounty Out-of-Scope Policy.
