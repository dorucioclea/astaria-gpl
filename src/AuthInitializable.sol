// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;
import {Authority} from "solmate/Auth/Auth.sol";

/// @notice Provides a flexible and updatable auth pattern which is completely separate from application logic.
/// @author Astaria (https://github.com/astariaxyz/astaria-gpl/blob/main/src/auth/AuthInitializable.sol)
/// @author Modified from (https://github.com/transmissions11/solmate/blob/main/src/auth/Auth.sol)
abstract contract AuthInitializable {
  event OwnershipTransferred(address indexed user, address indexed newOwner);

  event AuthorityUpdated(address indexed user, Authority indexed newAuthority);

  bytes32 constant authSlot =
    keccak256("gpl.astaria.xyz.Auth.storage.location");

  struct AuthStorage {
    address owner;
    Authority authority;
  }

  function _getAuthSlot() internal view returns (AuthStorage storage s) {
    bytes32 slot = authSlot;
    assembly {
      s.slot := slot
    }
  }

  function __initAuth(address _owner, address _authority) public {
    AuthStorage storage s = _getAuthSlot();
    require(s.owner == address(0), "Already initialized");
    s.owner = _owner;
    s.authority = Authority(_authority);

    emit OwnershipTransferred(msg.sender, _owner);
    emit AuthorityUpdated(msg.sender, Authority(_authority));
  }

  modifier requiresAuth() virtual {
    require(isAuthorized(msg.sender, msg.sig), "UNAUTHORIZED");

    _;
  }

  function owner() public view returns (address) {
    return _getAuthSlot().owner;
  }

  function authority() public view returns (Authority) {
    return _getAuthSlot().authority;
  }

  function isAuthorized(address user, bytes4 functionSig)
    internal
    view
    virtual
    returns (bool)
  {
    AuthStorage storage s = _getAuthSlot();
    Authority auth = s.authority; // Memoizing authority saves us a warm SLOAD, around 100 gas.

    // Checking if the caller is the owner only after calling the authority saves gas in most cases, but be
    // aware that this makes protected functions uncallable even to the owner if the authority is out of order.
    return
      (address(auth) != address(0) &&
        auth.canCall(user, address(this), functionSig)) || user == s.owner;
  }

  function setAuthority(Authority newAuthority) public virtual {
    // We check if the caller is the owner first because we want to ensure they can
    // always swap out the authority even if it's reverting or using up a lot of gas.
    AuthStorage storage s = _getAuthSlot();
    require(
      msg.sender == s.owner ||
        s.authority.canCall(msg.sender, address(this), msg.sig)
    );

    s.authority = newAuthority;

    emit AuthorityUpdated(msg.sender, newAuthority);
  }

  function transferOwnership(address newOwner) public virtual requiresAuth {
    AuthStorage storage s = _getAuthSlot();
    s.owner = newOwner;

    emit OwnershipTransferred(msg.sender, newOwner);
  }
}
