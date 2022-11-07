pragma solidity ^0.8.13;

pragma experimental ABIEncoderV2;

interface IAuctionHouse {
  struct Auction {
    uint256 currentBid;
    // The current highest bid amount
    address token; //20
    address initiator; //20
    address bidder;
    uint40 initiatorFeeNumerator;
    uint40 initiatorFeeDenominator;
    uint40 duration; // 5
    uint40 maxDuration; // 5
    uint40 firstBidTime; //5
    uint88 reservePrice; //11
    // The length of time to run the auction for, after the first bid was made
    uint256[] stack;
    // The time of the first bid
  }

  event AuctionCreated(
    uint256 indexed tokenId,
    uint256 duration,
    uint256 reservePrice
  );

  event AuctionBid(
    uint256 indexed tokenId,
    address sender,
    uint256 value,
    bool firstBid,
    bool extended
  );

  event AuctionDurationExtended(uint256 indexed tokenId, uint256 duration);

  event AuctionEnded(
    uint256 indexed tokenId,
    address winner,
    uint256 winningBid
  );

  event AuctionCanceled(uint256 indexed tokenId);

  function createAuction(
    uint256 tokenId,
    uint256 duration,
    address initiator,
    uint256 initiatorFeeNumerator,
    uint256 initiatorFeeDenominator,
    uint256 reserve,
    uint256[] calldata stack
  ) external;

  function createBid(uint256 tokenId, uint256 amount) external;

  function endAuction(uint256 tokenId) external returns (address);

  function cancelAuction(uint256 tokenId, address canceledBy) external;

  function auctionExists(uint256 tokenId) external returns (bool);

  function getAuctionData(
    uint256 tokenId
  )
    external
    view
    returns (
      uint256 amount,
      uint256 duration,
      uint256 firstBidTime,
      uint256 reservePrice,
      address bidder
    );
}
