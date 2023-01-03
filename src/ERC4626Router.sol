// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.17;

import {IERC4626Router} from "gpl/interfaces/IERC4626Router.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626RouterBase} from "gpl/ERC4626RouterBase.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/// @title ERC4626Router contract
abstract contract ERC4626Router is IERC4626Router, ERC4626RouterBase {
  using SafeTransferLib for ERC20;

  // For the below, no approval needed, assumes vault is already max approved

  function pullToken(
    address token,
    uint256 amount,
    address recipient
  ) public payable virtual;

  /// @inheritdoc IERC4626Router
  function depositToVault(
    IERC4626 vault,
    address to,
    uint256 amount,
    uint256 minSharesOut
  ) external payable override returns (uint256 sharesOut) {
    pullToken(vault.asset(), amount, address(this));
    return deposit(vault, to, amount, minSharesOut);
  }

  /// @inheritdoc IERC4626Router
  function depositMax(
    IERC4626 vault,
    address to,
    uint256 minSharesOut
  ) public payable override returns (uint256 sharesOut) {
    ERC20 asset = ERC20(vault.asset());
    uint256 assetBalance = asset.balanceOf(msg.sender);
    uint256 maxDeposit = vault.maxDeposit(to);
    uint256 amount = maxDeposit < assetBalance ? maxDeposit : assetBalance;
    pullToken(address(asset), amount, address(this));
    return deposit(vault, to, amount, minSharesOut);
  }

  /// @inheritdoc IERC4626Router
  function redeemMax(
    IERC4626 vault,
    address to,
    uint256 minAmountOut
  ) public payable override returns (uint256 amountOut) {
    uint256 shareBalance = vault.balanceOf(msg.sender);
    uint256 maxRedeem = vault.maxRedeem(msg.sender);
    uint256 amountShares = maxRedeem < shareBalance ? maxRedeem : shareBalance;
    pullToken(address(vault), amountShares, address(this));
    return redeem(vault, to, amountShares, minAmountOut);
  }
}
