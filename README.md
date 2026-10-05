# Dynamic

Milestone-based launchpad. Funds stay in escrow and each tranche is released only when the launch's oracle set
approves a milestone and the community does not veto it.

- `src/Dynamic.sol`: the contract (UNAUDITED)
- `test/Dynamic.t.sol`: Foundry tests (`forge test -vv`)
- `script/Deploy.s.sol`: deploy script (see `DEPLOY.md`)
- `index.html`: the web app (GitHub Pages, domain in `CNAME`)

Note: `index.html` still targets the previous (ETH-based) contract version. It must be updated for this
version (USDC payments, `approve` flow, milestone/challenge/vote screens) before it can use the new contract.
