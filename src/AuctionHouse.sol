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
  uint32 public timeBuffer;
  // The minimum percentage difference between the last bid amount and the current bid.
  uint32 public minBidIncrementNumerator;
  uint32 public minBidIncrementDenominator;

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
    timeBuffer = uint32(15 minutes);
    // extend 15 minutes after every bid made in last 15 minutes
    // 5%

    minBidIncrementNumerator = uint32(50);
    minBidIncrementDenominator = uint32(1000);

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
    uint256 initiatorFeeNumerator,
    uint256 initiatorFeeDenominator,
    uint256 reserve,
    ILienToken.AuctionStack[] memory stack
  ) external requiresAuth {
    require(initiator != address(0));
    require(!auctionExists(tokenId), "Auction already exists");
    Auction storage newAuction = auctions[tokenId];
    newAuction.duration = duration.safeCastTo40();

    for (uint256 i = 0; i < stack.length; i++) {
      newAuction.stack.push(stack[i]);
    }
    newAuction.reservePrice = reserve.safeCastTo88();
    newAuction.initiator = initiator;
    newAuction.initiatorFeeNumerator = uint40(initiatorFeeNumerator);
    newAuction.initiatorFeeDenominator = uint40(initiatorFeeDenominator);
    newAuction.firstBidTime = block.timestamp.safeCastTo40();
    newAuction.maxDuration = (duration + 1 days).safeCastTo40();
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
    require(auctionExists(tokenId));
    address lastBidder = auctions[tokenId].bidder;
    uint256 currentBid = auctions[tokenId].currentBid;
    uint256 duration = auctions[tokenId].duration;
    uint40 firstBidTime = auctions[tokenId].firstBidTime;
    require(block.timestamp < firstBidTime + duration, "Auction expired");
    require(
      amount >=
        currentBid +
          ((currentBid * minBidIncrementNumerator) /
            minBidIncrementDenominator),
      "Must send more than last bid by minBidIncrementPercentage amount"
    );

    // If this is the first valid bid, we should set the starting time now.
    // If it's not, then we should refund the last bidder
    uint256 vaultPayment = (amount - currentBid);

    if (lastBidder != address(0)) {
      uint256 lastBidderRefund = amount - vaultPayment;
      _handleOutGoingPayment(lastBidder, lastBidderRefund, address(msg.sender));
    }
    uint256 initiatorPayment = vaultPayment.mulDivDown(
      auctions[tokenId].initiatorFeeNumerator,
      auctions[tokenId].initiatorFeeDenominator
    );
    _handleOutGoingPayment(
      auctions[tokenId].initiator,
      initiatorPayment,
      address(msg.sender)
    );
    uint256 incomingPayment = vaultPayment - initiatorPayment;
    incomingPayment -= _handleIncomingPayment(
      tokenId,
      incomingPayment,
      address(msg.sender)
    );

    if (incomingPayment > 0) {
      TRANSFER_PROXY.tokenTransferFrom(
        weth,
        address(msg.sender),
        COLLATERAL_TOKEN.ownerOf(tokenId),
        incomingPayment
      );
    }

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

      uint40 newDuration = uint256(block.timestamp + timeBuffer - firstBidTime)
        .safeCastTo40();
      if (newDuration <= auctions[tokenId].maxDuration) {
        auctions[tokenId].duration = newDuration;
      } else {
        auctions[tokenId].duration = auctions[tokenId].maxDuration;
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
    if (auction.stack.length > 0) {
      //TODO: make sure this check doesn't break something
      LIEN_TOKEN.removeLiens(auctionId, auction.stack);
    }
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
    require(auctionExists(auctionId), "Auction does not exist");
    uint256 transferAmount = auctions[auctionId].reservePrice;
    require(
      auctions[auctionId].currentBid < auctions[auctionId].reservePrice &&
        block.timestamp <
        auctions[auctionId].firstBidTime + auctions[auctionId].duration,
      "cancelAuction: Auction is at or above reserve or has expired"
    );
    address lastBidder = auctions[auctionId].bidder;
    if (lastBidder != address(0)) {
      _handleOutGoingPayment(
        lastBidder,
        auctions[auctionId].currentBid,
        canceledBy
      );
      transferAmount -= auctions[auctionId].currentBid;
    }

    transferAmount -= _handleIncomingPayment(
      auctionId,
      transferAmount,
      canceledBy
    );
    _handleOutGoingPayment(
      auctions[auctionId].initiator,
      transferAmount,
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

  /**
   * @dev Given an amount and a currency, transfer the currency to this contract.
   */
  function _handleIncomingPayment(
    uint256 collateralId,
    uint256 transferAmount,
    address payer
  ) internal returns (uint256 spent) {
    require(transferAmount > uint256(0), "cannot send nothing");
    Auction storage auction = auctions[collateralId];

    if (auction.stack.length > 0 && transferAmount > 0) {
      (
        ILienToken.AuctionStack[] memory newStack,
        uint256 outcomeSpent
      ) = LIEN_TOKEN.makePaymentAuctionHouse(
          auction.stack,
          collateralId,
          transferAmount,
          payer
        );
      unchecked {
        spent = outcomeSpent;
        delete auction.stack;
        for (uint256 i = 0; i < newStack.length; i++) {
          auction.stack.push(newStack[i]);
        }
      }
    }
  }

  function _handleOutGoingPayment(
    address to,
    uint256 amount,
    address sender
  ) internal {
    TRANSFER_PROXY.tokenTransferFrom(weth, sender, to, amount);
  }

  function _cancelAuction(uint256 tokenId) internal {
    emit AuctionCanceled(tokenId);
    delete auctions[tokenId];
  }

  function auctionExists(uint256 tokenId) public view returns (bool) {
    return auctions[tokenId].firstBidTime != uint256(0);
  }
}
