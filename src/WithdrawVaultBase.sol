pragma solidity ^0.8.17;
import {ERC4626Base} from "./ERC4626Base.sol";

abstract contract WithdrawVaultBase is ERC4626Base {
  function name() public view virtual returns (string memory);

  function symbol() public view virtual returns (string memory);

  function owner() public pure returns (address) {
    return _getArgAddress(0);
  }

  function underlying()
    public
    pure
    virtual
    override(ERC4626Base)
    returns (address)
  {
    return _getArgAddress(20);
  }
}
