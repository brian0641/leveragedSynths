# leveragedSynths
A simple contract for P2P margin lending and leveraged trading in the synthetix ecosystem.
The Lender deposits sUSD to the contract and the trader deposits synths as collateral. The trader
may place trades through a trade() call, which acts as a proxy to Synthetix.exchange().

## Overview and Key Terms
Lender: The party providing the loan by depositing sUSD. <br>
Trader: The party depositing ETH as collateral for the loan.

synth_value (sv) - Total sUSD value of the synths in the contract. <br>
loan_value (lv)  - Value owed to Lender at a given point in time. <br>
maintenance margin (mm) - A buffer amount (e.g., 3%) to allow for slippage in liquidations. <br>

For the trader to remain solvent, the following is enforced:
```
sv - lv * (1+mm) > 0
```

If the solvency equation is false, a liquidation() function may be successfully called by anyone. Doing so 
assigns all the value in the contract to the Lender.

## Example Use Cases
Alice wants to trade with 5X leverage and is willing to pay 8% APR. She creates a smart contract with those parameters and deposits Eth as collateral. Bob sees it, thinks Alice's terms are reasonable, and deposits sUSD to the contract that is used to fund Alice's trading.
			
Alice wants to trade the forex and commodity synths with 15X leverage and is willing to pay 8% APR. Bob thinks that 15X leverage is generally high, but recognizes that Alice has limited herself to low-volatility synths. Bob funds the loan with sUSD after Alice deposits Eth as collateral. 

	



