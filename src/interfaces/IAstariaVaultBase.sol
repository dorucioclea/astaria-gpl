pragma solidity ^0.8.16;

import {IERC4626Base} from "./IERC4626Base.sol";

interface IAstariaVaultBase is IERC4626Base {
  function owner() external view returns (address);

  function COLLATERAL_TOKEN() external view returns (address);

  function ROUTER() external view returns (address);

  function AUCTION_HOUSE() external view returns (address);

  function START() external view returns (uint256);

  function EPOCH_LENGTH() external view returns (uint256);

  function VAULT_TYPE() external view returns (uint8);

  function VAULT_FEE() external view returns (uint256);
}
