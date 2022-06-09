pragma solidity ^0.8.13;
pragma experimental ABIEncoderV2;

interface IAuctionHouse {
    struct Auction {
        // ID for the ERC721 token
        uint256 tokenId;
        // The current highest bid amount
        uint256 currentBid;
        // The length of time to run the auction for, after the first bid was made
        uint256 duration;
        // The time of the first bid
        uint256 firstBidTime;
        // The minimum price of the first bid
        uint256 reservePrice;
        uint256[] recipients;
        uint256[] amounts;
        address bidder;
        address initiator;
        uint256 initiatorFee;
    }

    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        uint256 duration,
        uint256 reservePrice
    );

    event AuctionReservePriceUpdated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        uint256 reservePrice
    );

    event AuctionBid(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address sender,
        uint256 value,
        bool firstBid,
        bool extended
    );

    event AuctionDurationExtended(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        uint256 duration
    );

    event AuctionEnded(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address winner,
        uint256 winningBid,
        uint256[] recipients
    );

    event AuctionCanceled(uint256 indexed auctionId, uint256 indexed tokenId);

    function createAuction(
        uint256 tokenId,
        uint256 duration,
        address initiator,
        uint256 initiatorFee
    ) external returns (uint256, uint256);

    function createBid(uint256 auctionId, uint256 amount) external;

    function endAuction(uint256 auctionId) external returns (address);

    function cancelAuction(uint256 auctionId, address canceledBy) external;

    function getClaimableBalance(uint256 _lienId)
        external
        view
        returns (uint256);

    function getAuctionData(uint256 _auctionId)
        external
        view
        returns (
            uint256 tokenId,
            uint256 amount,
            uint256 duration,
            uint256 firstBidTime,
            uint256 reservePrice,
            address bidder
        );
}
