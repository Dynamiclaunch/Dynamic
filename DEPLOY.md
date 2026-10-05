# How to deploy Dynamic to Base mainnet (plain-language guide)

The contract starts **paused**, so deploying it does not let anyone put money in. The only cost is the gas fee.

## What you need first
1. **A few dollars of ETH on the Base network** for gas. This cannot be skipped. Buy ETH on an exchange that
   supports withdrawals to **Base**, and send it to your deployer wallet.
2. **Three wallet addresses** (create new accounts in MetaMask):
   - `DEPLOYER`: only pays the gas. Keep almost no money in it.
   - `OWNER`: already decided: `0x91C2c876F6f6e7319C70635B978cBeb42d873969` (the account created on the Dynamic site). It must be different from the deployer.
   - `TREASURY`: where fees are sent (can be the same as OWNER).
3. **Oracle addresses** (at least 3, different from OWNER). These are the wallets that approve milestones.
   The AI service that will use them is not part of this repo yet.

Never share a seed phrase or private key with anyone, and never put one in a file in the repo.

## About the OWNER wallet (read this once)
- This account lives inside the website: its key is stored encrypted in your browser only. Before deploying, open the
  site wallet, press **Export Key**, and write the key on paper. Keep it somewhere safe and offline. Do not take a
  screenshot, do not store it in the cloud, and do not send it to anyone.
- If you lose that key you lose the admin rights for good. If someone else gets it, they control the admin functions
  (open/close, max goal, fees, treasury, oracle list for new launches). They still cannot move the money that is held
  in escrow for existing launches.
- `admin.html` needs MetaMask or Coinbase Wallet. To use it, import this account into one of those apps with the
  exported key (type the key only into the wallet app). The address stays the same.

## Steps
1. **Tests first.** Push the repo to GitHub, open the **Actions** tab and wait for a green check.
   If it is red, do not deploy; open the failed run and fix or ask for help.
2. **Open a terminal.** On your repo page: Code > Codespaces > Create codespace.
3. **Install the tools** (paste in the terminal, one line at a time):
   ```
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 foundry-rs/forge-std
   forge test -vv
   ```
4. **Create your settings file.** Copy `.env.example` to `.env` and fill in the addresses
   (`ORACLES` is a comma-separated list, `THRESHOLD=2` means 2 approvals are needed).
5. **Save the deployer key safely** (it will ask you to paste the key, nothing is stored in the repo):
   ```
   cast wallet import deployer --interactive
   ```
6. **Practice on the free test network first** (Base Sepolia):
   ```
   source .env
   forge script script/Deploy.s.sol --rpc-url https://sepolia.base.org --account deployer --broadcast
   ```
7. **Deploy to mainnet:**
   ```
   forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --account deployer --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
   ```
   Copy the line `Dynamic deployed at: 0x...`. On basescan.org the contract should show as **verified**.

## Opening the launchpad (only when the website is ready for the new contract)
On basescan.org open your contract > Contract > Write Contract > connect the **OWNER** wallet, then call in this order:
1. `setAllowedPay` with `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` and `true`
   (native USDC on Base, according to Circle's docs; do not use USDbC).
2. `setMaxGoal` with `500000000` (500 USDC per project; USDC has 6 decimals).
3. `setPaused` with `false`. Do this last.

Start with a low `maxGoal` and raise it only after things work well. `setPaused(true)` stops new launches and
contributions; refunds and token claims always stay open.

## Updating the website
In `index.html` change `DEFAULT_RPC` and `DEFAULT_CONTRACT` to the new values. If you use a different RPC URL,
add it to `connect-src` in the `Content-Security-Policy` line at the top of the file, otherwise the browser will block it.
