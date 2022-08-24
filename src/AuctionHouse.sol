// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.16;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IAuctionHouse} from "./interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "./interfaces/ITransferProxy.sol";

import "./interfaces/IWETH9.sol";
import {ILienToken} from "../../../src/interfaces/ILienToken.sol";
import {ICollateralToken} from "../../../src/interfaces/ICollateralToken.sol";

contract AuctionHouse is Auth, IAuctionHouse {
    // The minimum amount of time left in an auction after a new bid is created
    uint256 timeBuffer;

    using SafeTransferLib for ERC20;

    // The minimum percentage difference between the last bid amount and the current bid.
    uint8 minBidIncrementPercentage;
    uint8 maxActiveAuctionsPerUnderlying;

    // / The address of the WETH contract, so that any ETH transferred can be handled as an ERC-20
    address weth;

    ITransferProxy TRANSFER_PROXY;
    ILienToken LIEN_TOKEN;
    ICollateralToken COLLATERAL_TOKEN;

    // A mapping of all of the auctions currently running.
    mapping(uint256 => IAuctionHouse.Auction) auctions;

    /*
     * Constructor
     */
    constructor(
        address weth_,
        address AUTHORITY_,
        address COLLATERAL_TOKEN_,
        address LIEN_TOKEN_,
        address transferProxy_
    )
        Auth(msg.sender, Authority(address(AUTHORITY_)))
    {
        weth = weth_;
        TRANSFER_PROXY = ITransferProxy(transferProxy_);
        COLLATERAL_TOKEN = ICollateralToken(COLLATERAL_TOKEN_);
        LIEN_TOKEN = ILienToken(LIEN_TOKEN_);
        timeBuffer = 15 * 60;
        // extend 15 minutes after every bid made in last 15 minutes
        minBidIncrementPercentage = 5;
        // 5%
        maxActiveAuctionsPerUnderlying = 3;

        ERC20(weth).safeApprove(address(LIEN_TOKEN), type(uint256).max);
    }

    function setMaxActiveAuctionsPerUnderlying(uint8 newMax) external requiresAuth {
        maxActiveAuctionsPerUnderlying = newMax;
    }

    /**
     * @notice Create an auction.
     * @dev Store the auction details in the auctions mapping and emit an AuctionCreated event.
     * If there is no curator, or if the curator is the auction creator, automatically approve the auction.
     */
    function createAuction(uint256 tokenId, uint256 duration, address initiator, uint256 initiatorFee, uint256 epochCap)
        external
        requiresAuth
        returns (uint256 reserve)
    {
        uint256[] memory amounts;
        (reserve, amounts,) = LIEN_TOKEN.stopLiens(tokenId);

        Auction storage newAuction = auctions[tokenId];
        newAuction.duration = uint64(duration);
        newAuction.reservePrice = reserve;
        newAuction.amounts = amounts;
        newAuction.initiator = initiator;
        newAuction.initiatorFee = initiatorFee;
        newAuction.firstBidTime = uint64(block.timestamp);
        newAuction.maxDuration = uint64(block.timestamp + 3 days);
        newAuction.currentBid = 0;
        newAuction.epochCap = epochCap;

        emit AuctionCreated(tokenId, duration, reserve);
    }

    /**
     * @notice Create a bid on a token, with a given amount.
     * @dev If provided a valid bid, transfers the provided amount to this contract.
     * If the auction is run in native ETH, the ETH is wrapped so it can be identically to other
     * auction currencies in this contract.
     */
    function createBid(uint256 tokenId, uint256 amount) external override {
        address lastBidder = auctions[tokenId].bidder;
        require(
            auctions[tokenId].firstBidTime == 0 || block.timestamp < auctions[tokenId].firstBidTime + auctions[tokenId].duration,
            "Auction expired"
        );
        require(
            amount >= auctions[tokenId].currentBid + ((auctions[tokenId].currentBid * minBidIncrementPercentage) / 100),
            "Must send more than last bid by minBidIncrementPercentage amount"
        );

        // If this is the first valid bid, we should set the starting time now.
        // If it's not, then we should refund the last bidder
        uint256 vaultPayment = (amount - auctions[tokenId].currentBid);

        if (auctions[tokenId].firstBidTime == 0) {
            auctions[tokenId].firstBidTime = uint64(block.timestamp);
        } else if (lastBidder != address(0)) {
            uint256 lastBidderRefund = amount - vaultPayment;
            _handleOutGoingPayment(lastBidder, lastBidderRefund);
        }

        _handleIncomingPayment(tokenId, vaultPayment, address(msg.sender));

        auctions[tokenId].currentBid = amount;
        auctions[tokenId].bidder = address(msg.sender);

        bool extended = false;
        // at this point we know that the timestamp is less than start + duration (since the auction would be over, otherwise)
        // we want to know by how much the timestamp is less than start + duration
        // if the difference is less than the timeBuffer, increase the duration by the timeBuffer
        if (
            (auctions[tokenId].epochCap == 0 || block.timestamp + timeBuffer < auctions[tokenId].epochCap)
                && auctions[tokenId].firstBidTime + auctions[tokenId].duration - block.timestamp < timeBuffer
        ) {
            // Playing code golf for gas optimization:
            // uint256 expectedEnd = auctions[auctionId].firstBidTime.add(auctions[auctionId].duration);
            // uint256 timeRemaining = expectedEnd.sub(block.timestamp);
            // uint256 timeToAdd = timeBuffer.sub(timeRemaining);
            // uint256 newDuration = auctions[auctionId].duration.add(timeToAdd);

            //TODO: add the cap to the duration, do not let it extend beyond 24 hours extra from max duration
            uint256 oldDuration = auctions[tokenId].duration;
            uint64 newDuration =
                uint64(oldDuration + (timeBuffer - auctions[tokenId].firstBidTime + oldDuration - block.timestamp));
            if (newDuration <= auctions[tokenId].maxDuration) {
                auctions[tokenId].duration = newDuration;
                extended = true;
            }
        }

        emit AuctionBid(
            tokenId,
            msg.sender,
            amount,
            lastBidder == address(0), // firstBid boolean
            extended
            );

        if (extended) {
            emit AuctionDurationExtended(tokenId, auctions[tokenId].duration);
        }
    }

    /**
     * @notice End an auction, finalizing the bid on if applicable and paying out the respective parties.
     * @dev If for some reason the auction cannot be finalized (invalid token recipient, for example),
     * The auction is reset and the NFT is transferred back to the auction creator.
     */
    function endAuction(uint256 auctionId) external override requiresAuth returns (address winner) {
        require(
            block.timestamp >= auctions[auctionId].firstBidTime + auctions[auctionId].duration, "Auction hasn't completed"
        );
        Auction storage auction = auctions[auctionId];
        if (auction.bidder == address(0)) {
            winner = auction.initiator;
        } else {
            winner = auction.bidder;
        }

        emit AuctionEnded(auctionId, auction.bidder, auction.currentBid, auction.recipients);
        LIEN_TOKEN.removeLiens(auctionId);
        delete auctions[auctionId];
    }

    /**
     * @notice Cancel an auction.
     * @dev Transfers the NFT back to the auction creator and emits an AuctionCanceled event
     */
    function cancelAuction(uint256 auctionId, address canceledBy) external requiresAuth {
        require(
            auctions[auctionId].currentBid < auctions[auctionId].reservePrice,
            "cancelAuction: Auction is at or above reserve"
        );
        _handleIncomingPayment(auctionId, auctions[auctionId].reservePrice, canceledBy);
        _cancelAuction(auctionId);
    }

    function getAuctionData(uint256 _auctionId)
        public
        view
        returns (uint256 amount, uint256 duration, uint256 firstBidTime, uint256 reservePrice, address bidder)
    {
        IAuctionHouse.Auction memory auction = auctions[_auctionId];
        return (auction.currentBid, auction.duration, auction.firstBidTime, auction.reservePrice, auction.bidder);
    }

    /**
     * @dev Given an amount and a currency, transfer the currency to this contract.
     */
    function _handleIncomingPayment(uint256 tokenId, uint256 transferAmount, address payee) internal {
        require(transferAmount > uint256(0), "cannot send nothing");

        Auction storage auction = auctions[tokenId];

        uint256 initiatorPayment = (transferAmount * auction.initiatorFee) / 100;
        TRANSFER_PROXY.tokenTransferFrom(weth, payee, auction.initiator, initiatorPayment);
        transferAmount -= initiatorPayment;

        if (auction.amounts.length > 0) {
            uint256[] memory liens = LIEN_TOKEN.getLiens(tokenId);
            for (uint256 i = liens.length - auction.amounts.length; i < liens.length; ++i) {
                uint256 payment;
                uint256 lienId = liens[i];

                if (transferAmount >= auction.amounts[i]) {
                    payment = auction.amounts[i];
                    transferAmount -= payment;
                    delete auction.amounts[i];
                } else {
                    payment = transferAmount;
                    transferAmount = 0;
                    auction.amounts[i] -= payment;
                }

                if (payment > 0) {
                    LIEN_TOKEN.makePayment(lienId, payment, payee);
                }
            }
        } else {
            TRANSFER_PROXY.tokenTransferFrom(weth, payee, COLLATERAL_TOKEN.ownerOf(tokenId), transferAmount);
        }
    }

    function _handleOutGoingPayment(address to, uint256 amount) internal {
        TRANSFER_PROXY.tokenTransferFrom(weth, address(msg.sender), to, amount);
    }

    function _cancelAuction(uint256 tokenId) internal {
        emit AuctionCanceled(tokenId);
        delete auctions[tokenId];
    }

    function auctionExists(uint256 tokenId) public view returns (bool) {
        return auctions[tokenId].initiator != address(0);
    }
}
