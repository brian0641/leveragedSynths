/*
A simple contract for P2P margin lending and trading in the synthetix ecosystem.
The Lender deposits sUSD to the contract and the trader deposits synths as collateral. The trader
may place trades through a trade() call, which acts as a proxy to Synthetix.exchange().

Key Terms:
Lender: the party providing the loan by depositing sUSD.
Trader: the party depositing ETH as collateral for the loan.

synth_value (sv) - Total sUSD value of the synths in the contract.
loan_value (lv)  - Value owed to Lender at a given point in time.
maintenance margin (mm) - A buffer amount (e.g., 3%) to allow for slippage in liquidations.

For the trader to remain solvent, the following should be enforced:

sv > lv * (1+mm)

If the solvency equation is false, a liquidation() function may be successfully called. Doing so 
assigns the synths to the Lender.

For withdraws while a loan is active, an initial margin (im) factor is used. im is defined
as mm plus a constant (e.g., im = 3% (mm) + 1% = 4%). While a loan is active, a trader may withdraw 
synths only to the extent:

sv > lv * (1+im)

im and mm are stored in units of basis points (i.e., 100 equals 1%).
*/



pragma solidity ^0.5.11;

import {SynthetixInterface, SynthInterface, IAddressResolver, ExchRatesInterface} from "marginTradeInterfaces.sol";

contract marginTrade {
    // ========== SYSTEM CONSTANTS ==========
    
    bytes32 private constant sUSD = "sUSD";
    uint public constant IM_BUFFER_OVER_MM = 200;
    uint constant e18 = 10**18;
    uint constant SECONDS_IN_YEAR = 31557600;
    
    address public SNX_RESOLVER_ADDR = 0xA1D03F7bD3e298DFA9EED24b9028777eC1965B3A; //Ropsten Address
    bytes32 private constant CONTRACT_SYNTHETIX = "Synthetix";                      //for address resolution
    bytes32 private constant CONTRACT_EXCHANGE_RATES = "ExchangeRates";
     
    
    //This is needed in case the snxResolverAddr is changed and needs to be updated.
    address public constant adminAddress = 0xB75Af109Ca1A6dB7c6B708E1292ee8fCc5b0B941;
    
    // ========== PUBLIC STATE VARIABLES ==========
    
    address public lender;
    address public trader;
    uint public APR;                                     // in units of basis points
    uint public maxDurationSecs;                         // loan duration
    uint public maxLoanAmt;                              //the maximum loan amount desired by the Trader
    bytes32[] public approvedSynths;                     //list of synths that can be traded by this contract
    mapping(bytes32 => uint) public lenderSynthBalances; //synths balances allocated to the Lender.
    uint public loanStartTS;                             //loan start timestamp
    uint public mm;                                      //maintenance margin. value is in basis point (e.g., 100 is 1%)
    bool public wasLiquidated = false;
    
    // =========== INTERNAL STATE ==========
    mapping(bytes32 => address) private addressCache;  
    
    //The current loan balance (lv) is equal to loanBalance + the interest accrued between lastLoanTS and now;
    uint private loanBalance;
    uint private lastLoanSettleTS;
    
    // ========== CONSTRUCTOR ==========
    /**
     * @notice Deploy a new tradeProxy contract.
     * @param  _traderAddress The address of the Trader.
     * @param  _APR The annual interest rate, paid to the lender. Expressed in units of basis points.
     * @param  _maxDurationSecs The max period of the loan.
     * @param  _maxLoanAmt The requested amount of sUSD that is to be borrowed by the trader.
     * @param  _mm   The minimum maintenance margin.
     * @param  _approvedSynths Array of synths that can be traded. Must include sUSD.
     */
    
    constructor(
                address _traderAddress,
                uint256 _APR,
                uint256 _maxDurationSecs,
                uint256 _maxLoanAmt,
                uint _mm,
                bytes32[] memory _approvedSynths
                )
        public
    {
        trader = _traderAddress; 
        APR = _APR;
        maxDurationSecs = _maxDurationSecs;
        maxLoanAmt = _maxLoanAmt;
        mm = _mm;
        
        //check to ensure approvedSynths includes sUSD
        bool sUSDFound = false;
        for(uint i = 0; i < _approvedSynths.length; i++) {
            if (_approvedSynths[i] == sUSD) {
                sUSDFound = true;
                break;
            }
        }
        require(sUSDFound, "sUSD must be among the approved synths.");
        approvedSynths = _approvedSynths;
        
        //fetch the initial addresses of the syntetix contracts and store in 
        //addressCache
        _fillAddressCache();
        
    }
    
    // ========== SETTERS ==========
    
    /**
     * @notice The Trader can use this parameter to indicate whether a loan is desired
     * @notice by setting the maxLoanAmt greater than the current loan balance.
     */
    function setMaxLoanAmount(uint256 _maxLoanAmt)
        external
    {
        require(msg.sender == trader, "Only the Trader can change the desired max loan amt");
        maxLoanAmt = _maxLoanAmt;
    }
    
    //This is needed in case the SNX addresses resolver changes
    function setSNXAddressResolver(address _newAddress)
        external
    {
        require(msg.sender == adminAddress, "only the admin can call this");
        SNX_RESOLVER_ADDR = _newAddress;
    }
    
    // ========== FUNCTIONS ==========
    
     /**
     * @notice Lender deposit sUSD into the contract. Must first approve the transfer.
     * @param  token The sUSD contract address. 
     * @param amount The amount of sUSD to deposit.
     */
    function depositFunds(SynthInterface token, uint256 amount)
        public
    {
        require(token.currencyKey() == sUSD, "Loan deposit must be sUSD"); 
        require(amount > 0);
        
        //The first person that funds gets be the Lender for contract
        if (lender != address(0x0)) {
            require(lender == msg.sender, "only the lender can call this");
        }
        else {
            lender = msg.sender;
        }
        
        uint _svPre = traderTotSynthValueUSD();
        uint _newLoanBalance = loanBalUSD() + amount;
        
        require(_newLoanBalance <= maxLoanAmt, "loan amount too high");
        
        //enforce solvency contstraint
        require( isInitialMarginSatisfied(_svPre + amount,
                                           _newLoanBalance, mm), "Not enough collateral in the contract.");
                                           
        require(token.transferFrom(msg.sender, address(this), amount), "token transfer failed");
        
        loanBalance = _newLoanBalance;
        lastLoanSettleTS = now;
        
        if (loanStartTS == 0) {
            loanStartTS = now;
        }
    }
    
    /**
     * @notice Allows the trader to place a trade through synthetix.exchange.
     * @param  sourceCurrencyKey The currency key of the source synth. 
     * @param  sourceAmount       The amount of the source synth to trade.
     * @param  destCurrencyKey  The currency key of the destination synth. 
     */
    function trade(
                   bytes32 sourceCurrencyKey, 
                   uint sourceAmount,
                   bytes32 destCurrencyKey) 
                   public
                   returns (uint)
    {
        require(msg.sender == trader);
        
        //Can't trade lender funds
        require(synthBalanceTrader(sourceCurrencyKey) >= sourceAmount,
                "trader does not have enough balance");
        
        return SynthetixInterface(addressCache[CONTRACT_SYNTHETIX]).exchange(sourceCurrencyKey,
                   sourceAmount, destCurrencyKey);
    }
    
    /**
     * @notice Liquidation may be called by any address and is successful if the solvency
     * @notice equation is false. Liquidation causes the Lender to be assigned the assets
     * @notice of the Trader (all the assets in the contrcat). 
     */
     function liquidate()
        public
        returns (bool)
    {
        require(!wasLiquidated, "already liquidated" );
        
        if (isLiquidationable()) {
            //Liquidation; transfer all assets to the lender
            for (uint i = 0; i < approvedSynths.length; i++) {
                uint _bal = SynthInterface(addressCache[approvedSynths[i]]).balanceOf(address(this));
                lenderSynthBalances[approvedSynths[i]] = _bal;
            }
            wasLiquidated = true;
        } else {
            revert("not liquidation eligible");
        }
        
    }
    
    /**
    * @notice Trader can call this function to withdraw synths from the contract.
    * @notice The synths are withdrawable up to the extent of: sv > lv * (1+im) 
    * @param  amt The amount of the synth to withdraw.
    * @param  currencyKey The currency key of the synth to withdraw.
    */
    function traderWithdrawSynth(uint amt, bytes32 currencyKey) 
        public
        returns (bool)
    {
        require(msg.sender == trader, "Only trader can withdraw synths.");
        require(addressCache[currencyKey] != address(0), "currency key not in approved list");
        
        uint usdAmt = _synthValueUSD(getRate(currencyKey), amt);
        
        if (isInitialMarginSatisfied(traderTotSynthValueUSD() - usdAmt, loanBalUSD(), mm) ) {
            return   SynthInterface(addressCache[currencyKey]).transfer(trader, amt); 
        }
        revert("Cant withdraw that much");
    }
    
    /**
    * @notice Lender can call this function to withdraw synths from the contract.
    * @param  amt The amount of the synth to withdraw.
    * @param  currencyKey The currency key of the synth to withdraw.
    */
    function lenderWithdrawSynth(uint amt, bytes32 currencyKey) 
        public
        returns (bool)
    {
        require(msg.sender == lender, "Only lender can withdraw synths.");
        require(lenderSynthBalances[currencyKey] >= amt, "Withdraw amt is too high.");
        
        bool result =  SynthInterface(addressCache[currencyKey]).transfer(lender, amt); 
        if (result) {
            lenderSynthBalances[currencyKey] = lenderSynthBalances[currencyKey] - amt;
        }
        return result;
    }
    
    /**
     * @notice Trader can call this function to repay some or all of the loan amt.
     * @notice If all of the loan is repayed, maxLoanAmt will be set to zero, effectively closing the loan.
     * @param  amount The amount, of sUSD, to repay.
     */
    function traderRepayLoan(uint amount)
        public
        returns (bool)
    {
        require(msg.sender == trader, "only trader can repay loan");
        
        uint _loanBalance = loanBalUSD();
        uint _amt;
        if (amount > _loanBalance)
            _amt = _loanBalance;
        else
            _amt = amount;
        
        require(synthBalanceTrader(sUSD) >= _amt, "Not enough sUSD to repay.");
        
        //settle loan balance and pay lender
        loanBalance = _loanBalance - _amt;
        lastLoanSettleTS = now;
        
        lenderSynthBalances[sUSD] = lenderSynthBalances[sUSD] + _amt;
        
        //potentially close the loan 
        if (loanBalance == 0) {
            maxLoanAmt = 0;
        }
        
        return true;
    }
    
    /**
     * @notice If the maxLoanDuration has elapsed, either the trader or lender may
     * @notice call this function. Doing so assigns synths to the lender until the 
     * @notice current loan balance is satisfied.
     */
     //TODO - refactor 
    function loanExpired_Close()
        public
        returns (bool)
    {
        require(msg.sender == lender || msg.sender == trader);
        require(isLoanExpired(), "loan has not expired");
        
        maxLoanAmt = 0;  //effectively close further loan deposits
        
        // Iterate through the synths and assign them to the lender until loan balance
        // is satisfied.
        uint totalRemainaingUSD = loanBalUSD();
        uint _usdAssigned; uint _weiAssigned;
        
        //sUSD
        (_usdAssigned, _weiAssigned) = _determineAssignableAmt(totalRemainaingUSD, 
                                                            synthBalanceTrader(sUSD),
                                                            getRate(sUSD) );
        if (_weiAssigned > 0) {
            totalRemainaingUSD = sub(totalRemainaingUSD, _usdAssigned);
            lenderSynthBalances[sUSD] = lenderSynthBalances[sUSD] + _weiAssigned;
        }
        if (totalRemainaingUSD == 0) {
            loanBalance = 0;  
            lastLoanSettleTS = now;
            return true;
        }
        
        //synths other than sUSD
        for (uint i = 0; i < approvedSynths.length; i++) {
            if (approvedSynths[i] != sUSD) {
                bytes32 _synth = approvedSynths[i];
                (_usdAssigned, _weiAssigned) = _determineAssignableAmt(totalRemainaingUSD, 
                                                                    synthBalanceTrader(_synth), 
                                                                    getRate(_synth));
                if (_weiAssigned > 0) {
                    totalRemainaingUSD = sub(totalRemainaingUSD, _usdAssigned);
                    lenderSynthBalances[_synth] = lenderSynthBalances[_synth] + _weiAssigned;
                }
                if (totalRemainaingUSD == 0) {
                    loanBalance = 0;  
                    lastLoanSettleTS = now;
                    return true;
                }       
            }
        }
        
        // This is an error condition and implies that there was not enough 
        // synth balance to cover the loan. How to handle?
        loanBalance = totalRemainaingUSD;  
        lastLoanSettleTS = now;
        return false;
    }
    
    /**
     * @notice This function needs to be called if the Synthetix addresses change. 
     */
    function updateAddressCache() 
        external
    {
        require(msg.sender == trader || 
                msg.sender == lender ||
                msg.sender == adminAddress, "only callable by trader, lender, or admin");
        _fillAddressCache();
    }
    
    
    function _fillAddressCache() 
        internal
    {
        addressCache[CONTRACT_SYNTHETIX] = _getContractAddress(CONTRACT_SYNTHETIX);
        addressCache[CONTRACT_EXCHANGE_RATES] = _getContractAddress(CONTRACT_EXCHANGE_RATES);
        
        for (uint i = 0; i < approvedSynths.length; i++) {
            addressCache[approvedSynths[i]] = address(_getSynthAddress(approvedSynths[i]));
        }
         
    }
    
    // VIEW FUNCTIONS
    
    /**
     * @notice Determine if the account is below the mimimum maintenance margin.
     */
    function isLiquidationable()
        public
        view
        returns (bool)
    {   
        if (wasLiquidated || loanStartTS == 0) {
            return false;
        }
        
        uint sv = traderTotSynthValueUSD();
        uint lv = loanBalUSD();
        uint f = (10**18 + mm * 10*14);
        
        if ( sv > mul(f, lv) / e18 ) 
        {
            //liq not possible
            return false;
        }
        return true;
    }
    
    /**
     * @notice Determine if the account, after deducting some value (in USD), still satisfies the
     * @notice mimimum initial margin requirement. 
     * @param _sv Total trader synth value in USD
     * @param _lv Total trader loan value in USD
     * @param _mm  maintenance margin
     */
    function isInitialMarginSatisfied(uint _sv, uint _lv, uint _mm)
        public
        pure
        returns (bool)
    {
        uint f = (10**18 + (_mm + IM_BUFFER_OVER_MM) * 10**14);
        
        if ( _sv >= mul(f, _lv)/e18 ) 
        {
            return true; //initial margin condition still ok
        }
        return false;
    }
 
    /**
     * @notice Retrieves the exchange rate (sUSD per unit) for a given currency key
     */
     function getRate(bytes32 currencyKey)
        public
        view
        returns (uint)
    {
        return ExchRatesInterface(addressCache[CONTRACT_EXCHANGE_RATES]).rateForCurrency(currencyKey);
    }
    
    
    /**
     * @notice Retrieves the exchange rates (sUSD per unit) for a list of currency keys
     */
     function getRates(bytes32[] memory currencyKeys)
        public
        view
        returns (uint[] memory)
    {
        return ExchRatesInterface(addressCache[CONTRACT_EXCHANGE_RATES]).ratesForCurrencies(currencyKeys);
    }
    
    /**
     * @notice Return total synth value, of the approved synths, in sUSD (for the Trader)
     */
    function traderTotSynthValueUSD()
        public
        view
        returns (uint)
    {
        uint[] memory rates = getRates(approvedSynths);
        uint value = 0;
        for (uint i = 0; i < approvedSynths.length; i++) {
            value = value + _synthValueUSD(rates[i], synthBalanceTrader(approvedSynths[i]));
        }
        
        return value; 
    }

    /**
     * @notice Return the balance for the synth (in synth units) that is held by the contract and assigned 
     * @notice to the Trader. The Trader synth balance is defined as the synth balance of the contract 
     * @notice minus any amt allocated to the Lender.
     */
    function synthBalanceTrader(bytes32 currencyKey)
        public
        view
        returns (uint)
    {
        uint _bal =  SynthInterface(addressCache[currencyKey]).balanceOf(address(this));
        
        return _bal - lenderSynthBalances[currencyKey];
    }
    
    /**
     * @notice Returns the actual current ballance of the loan, including outstanding interest.
     */
    function loanBalUSD() 
        public
        view
        returns (uint)
    {
        uint interest = calcInterest(APR, loanBalance, now - lastLoanSettleTS);
        return loanBalance + interest;
    }
    
    function isLoanExpired()
        public
        view
        returns (bool)
    {
        if (loanStartTS == 0) {
            return false;
        }
        return (now - loanStartTS) > maxDurationSecs;
    }
    
    
    /**
     * @notice Convenience function to get the users Leverage multiplied by 100.
     */
    function levTimes100()
        public
        view
        returns (uint)
    {
        uint sv = traderTotSynthValueUSD();
        uint lv = loanBalUSD();
        return 100 * lv / (sv - lv);
    }
    
    //
    // Helper Functions
    //
    
     /**
     * @notice Calculates the simple interest, given an APR, an amount, 
     * @notice and an elapsed time (in seconds).
     * @param  _APR The APR in basis points (1% == 100)
     * @param  amount The base value for the interest calculation. 
     * @param  elapsedTime The time period, in seconds, for the interest calculation.
     */ 
    function calcInterest(uint256 _APR, uint256 amount, uint256 elapsedTime)
        private
        pure
        returns (uint256)
    {
        uint n = mul(elapsedTime, 1000000);
        n = mul(n, amount);
        n = mul(n, _APR);
        uint d = mul(SECONDS_IN_YEAR, 10000000000);
        return n/d;
    }
    
    // Given a maximimum amount in USD that is to be assigned to the Lender, and given a particular 
    // synth balance and exchange rate, determine the 
    // amount that can be assigned. Returns the assignable amount in USD and synth units. 
    /**
     * @notice Given a maximimum amount in USD that is to be assigned to the Lender, and given a particular 
     * @notice  synth balance and exchange rate, determine the 
     * @notice amount that can be assigned. Returns the assignable amount in USD and synth units. 
     * @param  maxAssignUSD The potential maximum USD amount that is to be assigned to the Lender.
     * @param  balWei  The Trader's synth balance.
     * @param  rate    The current exchange rate of the synth.
     */ 
    function _determineAssignableAmt(uint maxAssignUSD, uint balWei, uint rate)
        private
        pure
        returns (uint amtAssignableUSD, uint amtAssignableSynth)
    {
        if (balWei == 0) {
            return (0, 0);
        }
        
        uint balUSD = _synthValueUSD(rate, balWei);
        
        if (maxAssignUSD >= balUSD) {
            return (balUSD, balWei);
        } else {
            return (maxAssignUSD, mul(balWei, maxAssignUSD) / balUSD) ;
        }
    }
    
    //From openzepplin SafeMath
    /**
    * @dev Multiplies two numbers, throws on overflow.
    */
    function mul(uint256 a, uint256 b) 
        internal
        pure
        returns (uint256 c) {
        if (a == 0) {
            return 0;
        }
        c = a * b;
        assert(c / a == b);
        return c;
    }
    
    //Safe subtract. Returns zero if b > a    
    function sub(uint256 a, uint256 b) 
        internal
        pure
        returns (uint256) 
    {
        if (b > a) {
            return 0;
        }
        uint256 c = a - b;
        return c;
    }

     /**
     * @notice Given a synth amount and exchange rate, return the USD value.
     */ 
    function _synthValueUSD(uint rate, uint balance) 
        public
        pure
        returns (uint)
    {
        return mul(rate, balance) / e18;
    }  
    
    function _getContractAddress(bytes32 contractName) 
        private
        view
        returns (address)
    {
            return IAddressResolver(SNX_RESOLVER_ADDR).requireAndGetAddress(contractName, "bad address resolution");
    }
    
     function _getSynthAddress(bytes32 synthName)
        private
        view
        returns (address)
    {
        address _addr = address(SynthetixInterface(addressCache[CONTRACT_SYNTHETIX]).synths(synthName));
        require(_addr != address(0), "bad synth address resolution");
        return _addr;
    }
    
}
