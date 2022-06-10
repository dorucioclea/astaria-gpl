// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.13;
pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IAuctionHouse} from "./interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "./interfaces/ITransferProxy.sol";

import "./interfaces/IWETH9.sol";
import {ILienToken} from "../../../src/interfaces/ILienToken.sol";
import {ICollateralVault} from "../../../src/interfaces/ICollateralVault.sol";

contract AuctionHouse is Auth, IAuctionHouse {
    // The minimum amount of time left in an auction after a new bid is created
    uint256 timeBuffer;

    // The minimum percentage difference between the last bid amount and the current bid.
    uint8 minBidIncrementPercentage;

    // / The address of the WETH contract, so that any ETH transferred can be handled as an ERC-20
    address weth;

    ITransferProxy TRANSFER_PROXY;
    ILienToken LIEN_TOKEN;
    ICollateralVault COLLATERAL_VAULT;

    // A mapping of all of the auctions currently running.
    mapping(uint256 => IAuctionHouse.Auction) auctions;

    uint256 private _auctionIdTracker;

    /**
     * @notice Require that the specified auction exists
     */
    modifier auctionExists(uint256 auctionId) {
        require(_auctionExists(auctionId), "Auction doesn't exist");
        _;
    }

    /*
     * Constructor
     */
    constructor(
        address weth_,
        address AUTHORITY_,
        address COLLATERAL_VAULT_,
        address LIEN_TOKEN_,
        address transferProxy_
    ) Auth(msg.sender, Authority(address(AUTHORITY_))) {
        weth = weth_;
        TRANSFER_PROXY = ITransferProxy(transferProxy_);
        COLLATERAL_VAULT = ICollateralVault(COLLATERAL_VAULT_);
        LIEN_TOKEN = ILienToken(LIEN_TOKEN_);
        timeBuffer = 15 * 60;
        // extend 15 minutes after every bid made in last 15 minutes
        minBidIncrementPercentage = 5;
        // 5%
    }

    /**
     * @notice Create an auction.
     * @dev Store the auction details in the auctions mapping and emit an AuctionCreated event.
     * If there is no curator, or if the curator is the auction creator, automatically approve the auction.
     */
    function createAuction(
        uint256 tokenId,
        uint256 duration,
        //        uint256 reservePrice,
        //        uint256[] calldata lienIds,
        //        uint256[] calldata amounts,
        address initiator,
        uint256 initiatorFee
    ) external requiresAuth returns (uint256, uint256) {
        //        unchecked {
        //            ++_auctionIdTracker;
        //        }
        //        uint256 auctionId = _auctionIdTracker;

        (
            uint256 reserve,
            uint256[] memory amounts, //            uint256[] memory lienIds

        ) = LIEN_TOKEN.stopLiens(tokenId);

        Auction storage newAuction = auctions[tokenId];
        newAuction.currentBid = 0;
        newAuction.duration = duration;
        newAuction.firstBidTime = 0;
        newAuction.reservePrice = reserve;
        newAuction.bidder = address(0);
        newAuction.amounts = amounts;
        newAuction.initiator = initiator;
        newAuction.initiatorFee = initiatorFee;

        emit AuctionCreated(tokenId, duration, reserve);

        return (tokenId, reserve);
    }

    /**
     * @notice Create a bid on a token, with a given amount.
     * @dev If provided a valid bid, transfers the provided amount to this contract.
     * If the auction is run in native ETH, the ETH is wrapped so it can be identically to other
     * auction currencies in this contract.
     */
    function createBid(uint256 auctionId, uint256 amount)
        external
        override
        auctionExists(auctionId)
    {
        address lastBidder = auctions[auctionId].bidder;
        require(
            auctions[auctionId].firstBidTime == 0 ||
                block.timestamp <
                auctions[auctionId].firstBidTime + auctions[auctionId].duration,
            "Auction expired"
        );
        require(
            amount >=
                auctions[auctionId].currentBid +
                    ((auctions[auctionId].currentBid *
                        minBidIncrementPercentage) / 100),
            "Must send more than last bid by minBidIncrementPercentage amount"
        );

        // If this is the first valid bid, we should set the starting time now.
        // If it's not, then we should refund the last bidder
        uint256 vaultPayment = (amount - auctions[auctionId].currentBid);

        if (auctions[auctionId].firstBidTime == 0) {
            auctions[auctionId].firstBidTime = block.timestamp;
        } else if (lastBidder != address(0)) {
            uint256 lastBidderRefund = amount - vaultPayment;
            _handleOutGoingPayment(lastBidder, lastBidderRefund);
        }

        _handleIncomingPayment(auctionId, vaultPayment, address(msg.sender));

        auctions[auctionId].currentBid = amount;
        auctions[auctionId].bidder = address(msg.sender);

        bool extended = false;
        // at this point we know that the timestamp is less than start + duration (since the auction would be over, otherwise)
        // we want to know by how much the timestamp is less than start + duration
        // if the difference is less than the timeBuffer, increase the duration by the timeBuffer
        if (
            auctions[auctionId].firstBidTime +
                auctions[auctionId].duration -
                block.timestamp <
            timeBuffer
        ) {
            // Playing code golf for gas optimization:
            // uint256 expectedEnd = auctions[auctionId].firstBidTime.add(auctions[auctionId].duration);
            // uint256 timeRemaining = expectedEnd.sub(block.timestamp);
            // uint256 timeToAdd = timeBuffer.sub(timeRemaining);
            // uint256 newDuration = auctions[auctionId].duration.add(timeToAdd);
            uint256 oldDuration = auctions[auctionId].duration;
            auctions[auctionId].duration =
                oldDuration +
                (timeBuffer -
                    auctions[auctionId].firstBidTime +
                    oldDuration -
                    block.timestamp);
            extended = true;
        }

        emit AuctionBid(
            auctionId,
            msg.sender,
            amount,
            lastBidder == address(0), // firstBid boolean
            extended
        );

        if (extended) {
            emit AuctionDurationExtended(
                auctionId,
                auctions[auctionId].duration
            );
        }
    }

    /**
     * @notice End an auction, finalizing the bid on if applicable and paying out the respective parties.
     * @dev If for some reason the auction cannot be finalized (invalid token recipient, for example),
     * The auction is reset and the NFT is transferred back to the auction creator.
     */
    function endAuction(uint256 auctionId)
        external
        override
        requiresAuth
        auctionExists(auctionId)
        returns (address winner)
    {
        require(
            uint256(auctions[auctionId].firstBidTime) != 0,
            "Auction hasn't begun"
        );
        require(
            block.timestamp >=
                auctions[auctionId].firstBidTime + auctions[auctionId].duration,
            "Auction hasn't completed"
        );
        Auction storage auction = auctions[auctionId];
        winner = auction.bidder;

        //        for (uint256 i = 0; i < auction.recipients.length; ++i) {
        //            _processLienPayout(auction.recipients[i]);
        //        }
        emit AuctionEnded(
            auctionId,
            auction.bidder,
            auction.currentBid,
            auction.recipients
        );
        LIEN_TOKEN.removeLiens(auctionId);
        delete auctions[auctionId];
    }

    /**
     * @notice Cancel an auction.
     * @dev Transfers the NFT back to the auction creator and emits an AuctionCanceled event
     */
    function cancelAuction(uint256 auctionId, address canceledBy)
        external
        auctionExists(auctionId)
        requiresAuth
    {
        require(
            auctions[auctionId].currentBid < auctions[auctionId].reservePrice,
            "cancelAuction: Auction is at or above reserve"
        );
        if (auctions[auctionId].bidder == address(0)) {
            _handleIncomingPayment(
                auctionId,
                auctions[auctionId].reservePrice,
                canceledBy
            );
        }
        _cancelAuction(auctionId);
    }

    function getAuctionData(uint256 _auctionId)
        public
        view
        returns (
            uint256 tokenId,
            uint256 amount,
            uint256 duration,
            uint256 firstBidTime,
            uint256 reservePrice,
            address bidder
        )
    {
        IAuctionHouse.Auction memory auction = auctions[_auctionId];
        return (
            _auctionId,
            auction.currentBid,
            auction.duration,
            auction.firstBidTime,
            auction.reservePrice,
            auction.bidder
        );
    }

    /**
     * @dev Given an amount and a currency, transfer the currency to this contract.
     * If the currency is ETH (0x0), attempt to wrap the amount as WETH
     */
    function _handleIncomingPayment(
        uint256 tokenId,
        uint256 transferAmount,
        address payee
    ) internal {
        require(transferAmount > uint256(0), "cannot send nothing");

        Auction storage auction = auctions[tokenId];

        uint256 initiatorPayment = (transferAmount * auction.initiatorFee) /
            100;
        TRANSFER_PROXY.tokenTransferFrom(
            weth,
            payee,
            auction.initiator,
            initiatorPayment
        );
        transferAmount -= initiatorPayment;

        if (auction.amounts.length > 0) {
            uint256[] memory liens = LIEN_TOKEN.getLiens(tokenId);
            for (
                uint256 i = liens.length - auction.amounts.length;
                i < liens.length;
                ++i
            ) {
                uint256 payment;
                uint256 recipient = liens[i];

                if (transferAmount >= auction.amounts[i]) {
                    payment = auction.amounts[i];
                    transferAmount -= payment;
                    //                    delete auction.recipients[i];
                    delete auction.amounts[i];
                } else {
                    payment = transferAmount;
                    transferAmount = 0;
                    auction.amounts[i] -= payment;
                }

                if (payment > 0) {
                    TRANSFER_PROXY.tokenTransferFrom(
                        weth,
                        payee,
                        LIEN_TOKEN.ownerOf(recipient),
                        payment
                    );
                }
            }
        } else {
            TRANSFER_PROXY.tokenTransferFrom(
                weth,
                payee,
                COLLATERAL_VAULT.ownerOf(tokenId),
                transferAmount
            );
        }
    }

    function _handleOutGoingPayment(address to, uint256 amount) internal {
        //        weth.transferFrom(address(msg.sender), to, amount);
        TRANSFER_PROXY.tokenTransferFrom(weth, address(msg.sender), to, amount);
    }

    function _cancelAuction(uint256 tokenId) internal {
        emit AuctionCanceled(tokenId, tokenId);
        delete auctions[tokenId];
    }

    function _auctionExists(uint256 tokenId) internal view returns (bool) {
        return auctions[tokenId].initiator != address(0);
    }
}
