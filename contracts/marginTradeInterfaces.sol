pragma solidity ^0.5.11;

contract SynthetixInterface {
    function exchange(bytes32 sourceCurrencyKey, uint sourceAmount, bytes32 destinationCurrencyKey)
        external 
        returns (uint amountReceived);
    function synths(bytes32) public view returns (SynthInterface); 
}

contract SynthInterface {
    function currencyKey() public view returns (bytes32 _currencyKey);
    function transfer(address to, uint tokens) public returns (bool success);
    function balanceOf(address _owner) public view returns (uint256 balance);
    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool);
}

contract ExchRatesInterface {
    function rateForCurrency(bytes32 currencyKey) external view returns (uint);
    function ratesForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint256[] memory);
}

contract IAddressResolver {
    function requireAndGetAddress(bytes32 name, string memory reason) public view returns (address);
}



