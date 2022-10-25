pragma solidity ^0.8.17;
import {IAstariaVaultBase} from "./interfaces/IAstariaVaultBase.sol";
import {ERC4626Base} from "./ERC4626Base.sol";
import {IERC4626Base} from "./interfaces/IERC4626Base.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

abstract contract AstariaVaultBase is ERC4626Base, IAstariaVaultBase {
  function name() public view virtual returns (string memory);

  function symbol() public view virtual returns (string memory);

  function owner() public pure returns (address) {
    return _getArgAddress(0);
  }

  function underlying()
    public
    pure
    virtual
    override(IERC4626Base, ERC4626Base)
    returns (address)
  {
    return _getArgAddress(20);
  }

  function ROUTER() public pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(40));
  }

  function START() public pure returns (uint256) {
    return _getArgUint256(60);
  }

  function EPOCH_LENGTH() public pure returns (uint256) {
    return _getArgUint256(92);
  }

  function VAULT_TYPE() public pure returns (uint8) {
    return _getArgUint8(124);
  }

  function VAULT_FEE() public pure returns (uint256) {
    return _getArgUint256(132);
  }

  function AUCTION_HOUSE() public view returns (IAuctionHouse) {
    return ROUTER().COLLATERAL_TOKEN().AUCTION_HOUSE();
  }

  function COLLATERAL_TOKEN() public view returns (ICollateralToken) {
    return ROUTER().COLLATERAL_TOKEN();
  }
}
