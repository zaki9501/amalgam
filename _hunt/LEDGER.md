# Amalgam (Ammalgam DLEX) — hunt ledger

Program: Cantina bug bounty. **Only on-chain LOSS OF FUNDS is eligible** (severity secondary). PoC must use
public/external functions only. Losses from >33% up / >25% down price moves in one block/8s are OOS.
Non-loss issues explicitly OOS.

## Hypothesis H1 — Flash-LP bypass of slippage LTV (`increaseForSlippage` prices debt vs instantaneous `activeLiquidityAssets`)

**Claim:** a third party mints ephemeral LP to inflate ALA (the slippage denominator), letting an oversized
borrow pass solvency, then removes the depth while the debt stays — leaving under-depth debt / bad debt.

### Confirmed (mechanism is real)
- `Validation.checkLtv` (core/contracts/libraries/Validation.sol L315-334): prices D (debt) and C (collateral)
  in L at conservative TWAP min/max ticks, then `D_in = ceil(L*D/(L-D))` via `increaseForSlippage`, requires
  `C*75 >= D_in*100`. Larger L ⇒ less slippage inflation ⇒ oversized borrow passes.
- `L = activeLiquidityAssets` is INSTANTANEOUS: `TokenController.getDepositAndActiveLiquidityAssets` /
  `calculateActiveLiquidityAssets = depletionAdjustedActiveLiquidity ≈ sqrt(reserveX*reserveY)`, and
  `AmmalgamPair.getInputParams` L1148: `_activeLiquidityAssets = totalAssets[DEPOSIT_L] - totalAssets[BORROW_L]`.
  A third-party `mint` raises reserves → raises ALA immediately. **Price is TWAP-protected; depth is not.**
- Both the LTV-slippage check AND `saturationAndGeometricTWAPState.update` (borrow path, L1108-1118) consume
  the SAME inflated ALA, and `lastUsedActiveLiquidityInLAssets` is recorded at the inflated value.
- Docs (`core-concepts/risk-engine.md` L25) confirm slippage-in-LTV IS the intended anti-flash-loan defense
  ("...C.R.E.A.M / Mango become impossible..."). So the hypothesis targets exactly that mechanism.

### Why it does NOT (currently) rise to an eligible loss-of-funds finding
1. **Raw LTV ≤75% is always enforced.** `D_in >= D` for all L, so as L→∞ the check → `D <= 0.75*C`. Flash-LP
   only removes the *slippage safety margin*, never lets you borrow beyond 75% of collateral value at TWAP.
   No direct theft / over-borrow.
2. **Both existing PoCs prove only the differential, not a loss.**
   - `poc/test/FlashLpLtvBypass.t.sol`: 2.5x collateral; asserts only "debt remains + utilization>40%". No bad
     debt, no LP loss, no attacker profit; never checks post-burn solvency.
   - `poc/test/FlashLpFreshPair.t.sol`: 5x collateral; **leaves the flash LP in place (never burns)**, asserts
     only the differential; comment admits burning "can hit MaxTrancheOverSaturated on sat update."
   Program rejects non-loss issues → neither PoC is submittable as-is.
3. **Depth removal while the oversized debt exists is blocked by the saturation invariant.** `Saturation.update`
   (L676-684): `maxLeaf = satToLeaf(activeLiquidityAssets)`; reverts `MaxTrancheOverSaturated()` if
   `maxLeaf < max(highestSetLeaf_X,Y) + SATURATION_MAX_BUFFER_TRANCHES`. Token transfers call
   `pair.validateOnUpdate` → `saturationAndGeometricTWAPState.update`, so removing depth (ALA↓) re-runs the
   global check and reverts once the attacker's tranche exceeds the shrunken maxLeaf. The fresh-pair PoC author
   EMPIRICALLY hit this. ⇒ atomic flash-mint → borrow → flash-burn reverts; the "economically temporary depth"
   premise fails. To keep the debt the attacker must keep REAL depth locked (not flash / not temporary), at
   which point the risk model is satisfied.
4. Even ignoring (3), realizing bad debt needs an adverse in-scope (<25%) price move to make the 75%-LTV
   position liquidatable AND liquidation slippage to exceed collateral — and the attacker LOSES collateral in
   that liquidation (borrowed ≤0.75*collateral), so it's griefing, not profit; saturation penalties are
   designed to bound exactly this concentration.

### VERDICT: NOT a valid Critical/High. Defended by saturation invariant — CONFIRMED EMPIRICALLY on mainnet fork.

`poc/test/FlashLpBurnDecisive.t.sol` (fresh pair via real factory, ethereum.publicnode.com):
1. control (no flash LP): borrow 70% of X reverts at real depth ✓ (AmmalgamLTV).
2. flash-mint 20x depth → same borrow SUCCEEDS (700000e18) ✓ (differential reproduced).
3. Attempt to remove the depth: the DEPOSIT_L transfer step reverts with `0x4ea97c63 = MaxTrancheOverSaturated()`.
   Reserves stay at 21e24 (depth NOT removable); the oversized debt cannot be separated from the depth.

⇒ The "keep the debt while extra depth is economically temporary" premise FAILS: the saturation tree's
`MaxTrancheOverSaturated` invariant reverts any attempt to pull the depth while the oversized borrow sits in the
tree. Atomic flash-mint → borrow → flash-burn is impossible. To keep the borrow the attacker must keep REAL
depth locked (20x genuine capital), which is not temporary and satisfies the risk model. No loss of funds.

Residual (would need MATURE in-scope pair + tight TWAP band, out of reach on a fresh pair): whether organic LP
withdrawal by third parties can drop ALA past the buffer and strand an over-saturated borrower — but that path
is the LPs' own withdrawals reverting/penalized (griefing at most), not attacker profit. Not pursued.

## Broad loss-of-funds sweep (4 surfaces) — all clean/defended/design

Parallel deep review of the four highest-value LP-loss surfaces. Bar: on-chain LP loss via public fns, no
malicious token, excl. >25% down / >33% up single-block moves, non-loss OOS.

- **Interest + saturation penalty accrual** (Interest.sol, Saturation.sol penalties, TokenController): borrow
  interest ↔ lender credits balance; penalties minted then assigned with tree updates AFTER accrual (no dodge);
  third-party force-accrual charges the victim, doesn't let attacker pocket it; util/penalty use TWAP/ALA not
  spot; rounding favors protocol/LP. Only code footgun: L-interest uint112 truncation after ×5 magnification —
  requires BORROW_L near 2^112, NOT reasonably reachable. → NO finding.
- **Swap / K-invariant / missingAssets / fees** (AmmalgamPair swap/mint/burn/skim/sync): virtual reserves +
  physical caps + depletion (95%) scaling are coherent; depletion-boundary asymmetry is the documented dynamic
  swap discount (round-trip ~closed); fees stay in reserves; mint/burn use raw reserves not referenceReserve;
  MINIMUM_LIQUIDITY lock; skim only takes surplus. → NO finding.
- **Convert / share-asset rounding** (Convert.sol, TokenController mint/burn, deposit/withdraw/borrow/repay):
  deposit/withdraw/mint/burn round DOWN (protocol), borrow mints MORE debt (fee+ceil), repay burns FEWER shares
  / needs MORE assets. allAssets is internal (not balanceOf) ⇒ no ERC4626 donation inflation; L min-lock. Only
  user-leaning edge: repayLiquidity L-credit ceil = O(1) wei, dominated by 5-bip lending fee. → NO finding.
- **Liquidation** (Liquidation.sol, PartialLiquidations, AmmalgamPair.liquidate): lead was "hard-liq bad-debt
  uncapped premium" — checkHardPremiums (L157) fed uncapped convertLtvToPremium (rises past MAX_PREMIUM=11111
  for LTV>90%), letting a bad-debt liquidator repay less (R≥C/p, p>1.111) and socialize more to LPs.
  VERDICT: **design-intended, OOS.** liquidations.md L9-13 documents the premium as a growing Dutch auction with
  no 90% cap; MAX_PREMIUM_IN_BIPS is only the bad-debt *detector* (L97). Force-bad-debt-a-solvent-position fails
  (full-seize needs R≥C/p and R≤D ⇒ raw D≳0.87C, i.e. genuinely near-insolvent). Other liq paths (empty-sat full
  slice = amplifier only; leverage zero-repay needs ~11× insolvency = OOS; saturation seize = borrower equity;
  rounding = conservative). → NO submittable finding.

Net: no Critical/High loss-of-funds finding from the broad sweep. Subagents:
[liquidation](3288d88c-3ff3-4bd2-8511-cb15833b6f37), [interest/penalty](47bfd556-93e2-433d-b7c0-984f9786de0c),
[swap/K](2a22237e-8500-4774-af3c-3c13caeef846), [convert/rounding](e7addc51-a692-430f-8f7a-56c6e4001693).

## PoC status notes
- `FlashLpLtvBypass.t.sol` targets PAIR `0x728fD0A9...` which is NOT in the cantina.md in-scope list (listed
  AmmalgamPair impl is `0x1b72e0...`); may be a non-existent/foreign pool. Fork tests need `ETH_RPC_URL`.
- `FlashLpFreshPair.t.sol` uses real FACTORY `0x1a411b0f...` to create a fresh pair (cleaner, state-independent).
