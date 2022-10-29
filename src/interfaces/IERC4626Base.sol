pragma solidity ^0.8.16;

import {ITokenBase} from "./ITokenBase.sol";

interface IERC4626Base is ITokenBase {
  function underlying() external view returns (address);
}