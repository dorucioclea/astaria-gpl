// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.16;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

/// @notice Minimal ERC4626 tokenized Vault implementation.
/// @author Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/mixins/ERC4626.sol)
// owner (20) -> underlying (ERC20 address) ,

interface IBase {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function owner() external view returns (address);

    function underlying() external view returns (address);
}

abstract contract Base is Clone, IBase {
    function owner() public view returns (address) {
        return _getArgAddress(0);
    }

    function underlying() public view returns (address) {
        return _getArgAddress(20);
    }
}

abstract contract VaultBase is Base {
    function COLLATERAL_TOKEN() public view returns (address) {
        return _getArgAddress(40);
    }

    function ROUTER() public view returns (address) {
        return _getArgAddress(60);
    }

    function AUCTION_HOUSE() public view returns (address) {
        return _getArgAddress(80);
    }

    function START() public view returns (uint256) {
        return _getArgUint256(100);
    }

    function EPOCH_LENGTH() public view returns (uint256) {
        return _getArgUint256(132);
    }

    function BROKER_TYPE() public view returns (uint256) {
        return _getArgUint256(164);
    }
}

//abstract contract Base is Clone {
//    function COLLATERAL_VAULT() public pure returns (address) {
//        return _getArgAddress(0);
//    }
//
//    function underlying() public pure returns (address) {
//        return _getArgAddress(20);
//    }
//
//    function router() public pure returns (address) {
//        return _getArgAddress(40);
//    }
//
//    function vaultHash() public pure returns (bytes32) {
//        return _getArgBytes32(60);
//    }
//
//    function expiration() public pure returns (uint256) {
//        return _getArgUint256(92);
//    }
//
//    function buyout() public pure returns (uint256) {
//        return _getArgUint256(124);
//    }
//
//    function appraiser() public pure returns (address) {
//        return _getArgAddress(156);
//    }
//
//    function AUCTION_HOUSE() public pure returns (address) {
//        return _getArgAddress(188);
//    }
//
//    function BROKER_TYPE() public pure returns (uint256) {
//        return _getArgUint256(220);
//    }
//
//    function start() public pure returns (uint256) {
//        return _getArgUint256(252);
//    }
//
//    function epoch_length() public pure returns (uint256) {
//        return _getArgUint256(284);
//    }
//
//    function decimals() public pure returns (uint8) {
//        return 18;
//    }
//
//    function _getArgBytes32(uint256 argOffset)
//        internal
//        pure
//        returns (bytes32 arg)
//    {
//        uint256 offset = _getImmutableArgsOffset();
//        // solhint-disable-next-line no-inline-assembly
//        assembly {
//            arg := calldataload(add(offset, argOffset))
//        }
//    }
//
//    //    string constant name = string(abi.encodePacked("Astaria BondVault-", vaultHash()));
//    string constant name = string("Astaria BondVault");
//
//    //    function name() public view returns (string memory) {
//    //        return string("Astaria BondVault-", vaultHash());
//    //    }
//
//    function symbol() public view returns (string memory) {
//        return string(
//            abi.encodePacked("AST-", ERC20(underlying()).symbol(), "-", vaultHash())
//        );
//    }
//}

/// @notice Modern and gas efficient ERC20 + EIP-2612 implementation.
/// @author Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/tokens/ERC20.sol)
/// @author Modified from Uniswap (https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/UniswapV2ERC20.sol)
/// @dev Do not manually set balances without updating totalSupply, as the sum of all user balances must not exceed it.

abstract contract ERC20Cloned is Base {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    uint256 internal INITIAL_CHAIN_ID;

    bytes32 internal INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    //    constructor(
    //        string memory _name,
    //        string memory _symbol,
    //        uint8 _decimals
    //    ) {
    //        name = _name;
    //        symbol = _symbol;
    //        decimals = _decimals;
    //
    //        INITIAL_CHAIN_ID = block.chainid;
    //        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    //    }

    function approve(address spender, uint256 amount)
        public
        virtual
        returns (bool)
    {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transfer(address to, uint256 amount)
        public
        virtual
        returns (bool)
    {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(
                recoveredAddress != address(0) && recoveredAddress == owner,
                "INVALID_SIGNER"
            );

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes(IBase(address(this)).name())),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    function _mint(address to, uint256 amount) internal virtual {
        totalSupply += amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal virtual {
        balanceOf[from] -= amount;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}

interface IVault {
    function deposit(uint256, address) external returns (uint256);
}

abstract contract ERC4626Cloned is ERC20Cloned, VaultBase, IVault {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(IVault)
        returns (uint256 shares)
    {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        ERC20(underlying()).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function mint(uint256 shares, address receiver)
        public
        virtual
        returns (uint256 assets)
    {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        ERC20(underlying()).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual returns (uint256 shares) {
        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) {
                allowance[owner][msg.sender] = allowed - shares;
            }
        }

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        ERC20(underlying()).safeTransfer(receiver, assets);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) {
                allowance[owner][msg.sender] = allowed - shares;
            }
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        ERC20(underlying()).safeTransfer(receiver, assets);
    }

    function totalAssets() public view virtual returns (uint256);

    function convertToShares(uint256 assets)
        public
        view
        virtual
        returns (uint256)
    {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint256 shares)
        public
        view
        virtual
        returns (uint256)
    {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    function previewDeposit(uint256 assets)
        public
        view
        virtual
        returns (uint256)
    {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        returns (uint256)
    {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivUp(supply, totalAssets());
    }

    function previewRedeem(uint256 shares)
        public
        view
        virtual
        returns (uint256)
    {
        return convertToAssets(shares);
    }

    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf[owner];
    }

    function beforeWithdraw(uint256 assets, uint256 shares) internal virtual {}

    function afterDeposit(uint256 assets, uint256 shares) internal virtual {}
}
