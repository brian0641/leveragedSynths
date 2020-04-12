pragma solidity ^0.5.11;

import {marginTrade} from "marginTrade.sol";

contract tradeProxyFactory {
  // index of created contracts
  address[] public marginTradeContracts;

  function getContractCount() 
    public
    view
    returns(uint contractCount)
  {
    return marginTradeContracts.length;
  }
  
    /**
     * @notice Deploy a new tradeProxy contract through the factory.
     * @param  traderAddress The address of the Trader.
     * @param  APR The annual interest rate, paid to the lender. Expressed in units of basis points.
     * @param  maxDurationSecs The max period of the loan.
     * @param  mm   The minimum maintenance margin.
     * @param  approvedSynths Array of synths that can be traded. Must include sUSD.
     */
  function newMarginTradeContract(
                address payable traderAddress,
                uint256 APR,
                uint256 maxDurationSecs,
                uint256 maxLoanAmt,
                uint mm,
                bytes32[] memory approvedSynths
                )
        public
    returns(address newContract)
  {
    address tp = address(new marginTrade(traderAddress, APR, maxDurationSecs,  
                                         maxLoanAmt, mm, approvedSynths
                                         ));
    marginTradeContracts.push(tp);
    
    //emit indication of new contract created
    emit marginTradeCreated(tp);
    
    return tp;
  }
  
  // ========== EVENTS ==========
    event marginTradeCreated(address _newContractAddress);
}
