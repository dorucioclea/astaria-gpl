// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.16;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IAuctionHouse} from "./interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

import {ILienToken} from "core/interfaces/ILienToken.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "./utils/SafeCastLib.sol";
import {PublicVault, IPublicVault} from "core/PublicVault.sol";

contract AuctionHouse is Auth, IAuctionHouse {
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using FixedPointMathLib for uint256;
  // The minimum amount of time left in an auction after a new bid is created
  uint256 public timeBuffer;
  // The minimum percentage difference between the last bid amount and the current bid.
  uint256 public minBidIncrementPercentage;

  // / The address of the WETH contract, so that any ETH transferred can be handled as an ERC-20
  address public weth;

  ITransferProxy TRANSFER_PROXY;
  IAstariaRouter ASTARIA_ROUTER;
  ILienToken LIEN_TOKEN;
  ICollateralToken COLLATERAL_TOKEN;

  // A mapping of all of the auctions currently running.
  // collateralToken ID => auction
  mapping(uint256 => IAuctionHouse.Auction) auctions;

  /*
   * Constructor
   */
  constructor(
    address weth_,
    Authority AUTHORITY_,
    ICollateralToken COLLATERAL_TOKEN_,
    ILienToken LIEN_TOKEN_,
    ITransferProxy TRANSFER_PROXY_,
    IAstariaRouter ASTARIA_ROUTER_
  ) Auth(msg.sender, Authority(address(AUTHORITY_))) {
    weth = weth_;
    TRANSFER_PROXY = TRANSFER_PROXY_;
    COLLATERAL_TOKEN = COLLATERAL_TOKEN_;
    LIEN_TOKEN = LIEN_TOKEN_;
    ASTARIA_ROUTER = ASTARIA_ROUTER_;
    timeBuffer = 15 minutes;
    // extend 15 minutes after every bid made in last 15 minutes
    minBidIncrementPercentage = 5;
    // 5%

    ERC20(weth).safeApprove(address(LIEN_TOKEN), type(uint256).max);
  }

  /**
   * @notice Create an auction.
   * @dev Store the auction details in the auctions mapping and emit an AuctionCreated event.
   * If there is no curator, or if the curator is the auction creator, automatically approve the auction.
   */
  function createAuction(
    uint256 tokenId,
    uint256 duration,
    address initiator,
    uint256 reserve,
    uint256[] calldata stack
  ) external requiresAuth {
    require(!auctionExists(tokenId), "Auction already exists");
    Auction storage newAuction = auctions[tokenId];
    newAuction.duration = duration.safeCastTo64();
    newAuction.stack = stack;
    newAuction.reservePrice = reserve;
    newAuction.initiator = initiator;
    newAuction.firstBidTime = block.timestamp.safeCastTo64();
    newAuction.maxDuration = (duration + 1 days).safeCastTo64();
    newAuction.currentBid = 0;

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
    uint256 currentBid = auctions[tokenId].currentBid;
    uint256 duration = auctions[tokenId].duration;
    uint64 firstBidTime = auctions[tokenId].firstBidTime;
    require(
      firstBidTime == 0 || block.timestamp < firstBidTime + duration,
      "Auction expired"
    );
    require(
      amount > currentBid + ((currentBid * minBidIncrementPercentage) / 100),
      "Must send more than last bid by minBidIncrementPercentage amount"
    );

    // If this is the first valid bid, we should set the starting time now.
    // If it's not, then we should refund the last bidder
    uint256 vaultPayment = (amount - currentBid);

    if (firstBidTime == 0) {
      auctions[tokenId].firstBidTime = block.timestamp.safeCastTo64();
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
    if (firstBidTime + duration - block.timestamp < timeBuffer) {
      // Playing code golf for gas optimization:
      // uint256 expectedEnd = auctions[auctionId].firstBidTime.add(auctions[auctionId].duration);
      // uint256 timeRemaining = expectedEnd.sub(block.timestamp);
      // uint256 timeToAdd = timeBuffer.sub(timeRemaining);
      // uint256 newDuration = auctions[auctionId].duration.add(timeToAdd);

      //TODO: add the cap to the duration, do not let it extend beyond 24 hours extra from max duration
      uint64 newDuration = uint256(
        duration + (block.timestamp + timeBuffer - firstBidTime)
      ).safeCastTo64();
      if (newDuration <= auctions[tokenId].maxDuration) {
        auctions[tokenId].duration = newDuration;
      } else {
        auctions[tokenId].duration =
          auctions[tokenId].maxDuration -
          firstBidTime;
      }
      extended = true;
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
  function endAuction(uint256 auctionId)
    external
    override
    requiresAuth
    returns (address winner)
  {
    require(
      block.timestamp >=
        auctions[auctionId].firstBidTime + auctions[auctionId].duration,
      "Auction hasn't completed"
    );
    Auction storage auction = auctions[auctionId];
    if (auction.bidder == address(0)) {
      winner = auction.initiator;
    } else {
      winner = auction.bidder;
    }

    emit AuctionEnded(auctionId, winner, auction.currentBid);

    for (uint256 i = 0; i < auction.stack.length; i++) {
      ILienToken.LienDataPoint memory point = LIEN_TOKEN.getPoint(
        auction.stack[i]
      );
      if (
        PublicVault(LIEN_TOKEN.ownerOf(i)).supportsInterface(
          type(IPublicVault).interfaceId
        )
      ) {
        PublicVault(LIEN_TOKEN.ownerOf(i)).decreaseYIntercept(point.amount);
      }
    }
    LIEN_TOKEN.removeLiens(auctionId, auction.stack);
    delete auctions[auctionId];
  }

  /**
   * @notice Cancel an auction.
   * @dev Transfers the NFT back to the auction creator and emits an AuctionCanceled event
   */
  function cancelAuction(uint256 auctionId, address canceledBy)
    external
    requiresAuth
  {
    require(
      auctions[auctionId].currentBid < auctions[auctionId].reservePrice,
      "cancelAuction: Auction is at or above reserve"
    );
    _handleIncomingPayment(
      auctionId,
      auctions[auctionId].reservePrice,
      canceledBy
    );
    _cancelAuction(auctionId);
  }

  function getAuctionData(uint256 _auctionId)
    public
    view
    returns (
      uint256 amount,
      uint256 duration,
      uint256 firstBidTime,
      uint256 reservePrice,
      address bidder
    )
  {
    IAuctionHouse.Auction memory auction = auctions[_auctionId];
    return (
      auction.currentBid,
      auction.duration,
      auction.firstBidTime,
      auction.reservePrice,
      auction.bidder
    );
  }

  event PaymentMade(address, uint256);
  event PaymentAmount(uint256);

  /**
   * @dev Given an amount and a currency, transfer the currency to this contract.
   */
  function _handleIncomingPayment(
    uint256 collateralId,
    uint256 incomingPaymentAmount,
    address payer
  ) internal {
    require(incomingPaymentAmount > uint256(0), "cannot send nothing");
    uint256 transferAmount = incomingPaymentAmount;
    Auction storage auction = auctions[collateralId];

    //fee is in percent
    //muldiv?
    uint256 initiatorPayment = ASTARIA_ROUTER.getLiquidatorFee(transferAmount);

    TRANSFER_PROXY.tokenTransferFrom(
      weth,
      payer,
      auction.initiator,
      initiatorPayment
    );
    transferAmount -= initiatorPayment;

    uint256 totalLienAmount = 0;
    if (auction.stack.length > 0) {
      for (uint256 i = 0; i < auction.stack.length; ++i) {
        uint256 payment;

        ILienToken.LienDataPoint memory point = LIEN_TOKEN.getPoint(
          auction.stack[i]
        );

        if (transferAmount >= point.amount) {
          payment = point.amount;
          transferAmount -= payment;
        } else {
          payment = transferAmount;
          transferAmount = 0;
        }

        if (payment > 0) {
          LIEN_TOKEN.makePaymentAuctionHouse(
            auction.stack[i],
            collateralId,
            payment,
            uint8(i),
            payer
          );
        }
      }
    }
    if (transferAmount > 0) {
      TRANSFER_PROXY.tokenTransferFrom(
        weth,
        payer,
        COLLATERAL_TOKEN.ownerOf(collateralId),
        transferAmount
      );
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
