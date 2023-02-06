// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.17;

import {IERC4626} from "core/interfaces/IERC4626.sol";
import {IERC4626RouterBase} from "gpl/interfaces/IERC4626RouterBase.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Multicall} from "gpl/Multicall.sol";

/// @title ERC4626 Router Base Contract
abstract contract ERC4626RouterBase is IERC4626RouterBase, Multicall {
  using SafeTransferLib for ERC20;

  /// @inheritdoc IERC4626RouterBase
  function mint(
    IERC4626 vault,
    address to,
    uint256 shares,
    uint256 maxAmountIn
  ) public payable virtual override returns (uint256 amountIn) {
    ERC20(vault.asset()).safeApprove(address(vault), shares);
    if ((amountIn = vault.mint(shares, to)) > maxAmountIn) {
      revert MaxAmountError();
    }
  }

  /// @inheritdoc IERC4626RouterBase
  function deposit(
    IERC4626 vault,
    address to,
    uint256 amount,
    uint256 minSharesOut
  ) public payable virtual override returns (uint256 sharesOut) {
    ERC20(vault.asset()).safeApprove(address(vault), amount);
    if ((sharesOut = vault.deposit(amount, to)) < minSharesOut) {
      revert MinSharesError();
    }
  }

  /// @inheritdoc IERC4626RouterBase
  function withdraw(
    IERC4626 vault,
    address to,
    uint256 amount,
    uint256 maxSharesOut
  ) public payable virtual override returns (uint256 sharesOut) {

    ERC20(address(vault)).safeApprove(address(vault), maxSharesOut);
    if ((sharesOut = vault.withdraw(amount, to, msg.sender)) > maxSharesOut) {
      revert MaxSharesError();
    }
  }

  /// @inheritdoc IERC4626RouterBase
  function redeem(
    IERC4626 vault,
    address to,
    uint256 shares,
    uint256 minAmountOut
  ) public payable virtual override returns (uint256 amountOut) {

    ERC20(address(vault)).safeApprove(address(vault), shares);
    if ((amountOut = vault.redeem(shares, to, msg.sender)) < minAmountOut) {
      revert MinAmountError();
    }
  }
}
