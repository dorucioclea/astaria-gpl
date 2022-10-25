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

  function COLLATERAL_TOKEN() public pure returns (ICollateralToken) {
    return ICollateralToken(_getArgAddress(40));
  }

  function ROUTER() public pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(60));
  }

  function AUCTION_HOUSE() public pure returns (IAuctionHouse) {
    return IAuctionHouse(_getArgAddress(80));
  }

  function START() public pure returns (uint256) {
    return _getArgUint256(100);
  }

  function EPOCH_LENGTH() public pure returns (uint256) {
    return _getArgUint256(132);
  }

  function VAULT_TYPE() public pure returns (uint8) {
    return _getArgUint8(164);
  }

  function VAULT_FEE() public pure returns (uint256) {
    return _getArgUint256(172);
  }
}
