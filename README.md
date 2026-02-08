# LMSR Sports Betting (Ethereum + Foundry + Vanilla JS)

Simple educational Web3 sports betting app using a binary LMSR AMM.

- Smart contracts: Solidity + Foundry
- Local chain: Anvil
- Frontend: HTML5 + Tailwind CSS CDN + Vanilla JS + ethers + esbuild
- Settlement model: admin resolves outcome
- Collateral: native ETH

## What This MVP Supports

- Create a binary market (`YES` / `NO`) with custom `b` parameter.
- Trade shares against LMSR prices (`buy` and `sell`) before market close.
- Resolve market outcome as contract owner after close time.
- Claim winnings in ETH after resolution.

## Project Layout

- `src/LMSRBetting.sol`: core LMSR betting contract
- `src/utils/FixedPointMathLib.sol`: fixed-point math helpers (`expWad`, `lnWad`, etc.)
- `test/LMSRBetting.t.sol`: unit tests
- `script/Deploy.s.sol`: Foundry deploy script
- `frontend/index.html`: Tailwind UI
- `frontend/src/main.js`: wallet + contract interaction logic
- `frontend/src/abi.js`: frontend ABI

## Prerequisites

- Foundry installed (`forge`, `anvil`, `cast`)
- Node.js 18+
- MetaMask

Foundry install (official):

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Contract Build, Test, and Debug

From repo root:

```bash
forge build
forge test -vvvv
```

Debug a failing test with Foundry debugger:

```bash
forge test --debug --match-test test_ResolveAndClaimWinnerOnce
```

## Run Local Chain (Anvil)

Terminal 1:

```bash
anvil
```

This starts RPC at `http://127.0.0.1:8545` on chain id `31337`.

## Deploy Contract

Terminal 2 (repo root):

```bash
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
```

Optional envs:

- `FEE_RECIPIENT` (defaults to deployer)
- `FEE_BPS` (defaults to `100` = 1%)

After deploy, copy the deployed contract address from broadcast output.

## Run Frontend

Terminal 3:

```bash
cd frontend
npm install
npm run build
python3 -m http.server 5173
```

Open `http://127.0.0.1:5173` and:

1. Connect MetaMask.
2. Ensure MetaMask uses Anvil network (`http://127.0.0.1:8545`, chain `31337`).
3. Paste deployed contract address and click `Save`.
4. Create and trade markets.

## LMSR Notes

For market state `(qYes, qNo)` and liquidity `b`:

- Cost function: `C(q) = b * ln(exp(qYes / b) + exp(qNo / b))`
- Buy cost: `C(new) - C(old)`
- Sell payout: `C(old) - C(new)`

This repo keeps the implementation straightforward for local development and learning.
