  // SPDX-License-Identifier: MIT
pragma solidity ^0.8.5;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract Auction is IERC721Receiver {
    address payable public contractOwner;
    uint256 cancelFee = 1 ether;

    struct Item {
        IERC721 nftContract;
        address payable seller;
        address payable owner;
        uint256 tokenId;
        uint256 auctionEndTime;
        uint256 price;
        address highestBidder;
        uint256 highestBid;
        bool sold;
    }

    using Counters for Counters.Counter;

    Counters.Counter public currentItemCount;
    mapping(uint256 => Item) public items;
    mapping(uint256 => mapping(address => uint256)) public bids;
    // keeps track of auctions that are over
    mapping(uint256 => bool) public ended;

    // Events that will be emitted on changes.
    event HighestBidIncreased(address bidder, uint256 amount);
    event AuctionEnded(address winner, uint256 amount);

    /// Bid price is less than floor price.
    error BidPriceLessThanFloorPrice();
    /// The auction has already ended.
    error AuctionAlreadyEnded();
    /// There is already a higher or equal bid.
    error BidNotHighEnough(uint256 highestBid);
    /// The auction has not ended yet.
    error AuctionNotYetEnded();
    /// The function auctionEnd has already been called.
    error AuctionEndAlreadyCalled();

    /// Create a simple auction with `biddingTime`
    /// seconds bidding time on behalf of the
    /// beneficiary address `beneficiaryAddress`.
    constructor() {
        contractOwner = payable(msg.sender);
    }

    uint256 public auctionEndTime;

    function createItem(
        address _nftContract,
        uint256 _tokenId,
        uint256 _auctionDays,
        uint256 _price
    ) public payable {
        require(_nftContract != address(0), "Invalid NFT address");
        require(_auctionDays >= 1, "Invalid auction days");
        require(_price > 0, "Invalid price");
        uint256 id = currentItemCount.current();
        currentItemCount.increment();
        ended[id] = false;
        items[id] = Item(
            IERC721(_nftContract),
            payable(msg.sender),
            payable(address(this)),
            _tokenId,
            (block.timestamp + (_auctionDays * 1 days)),
            _price,
            address(0),
            0,
            false
        );
        require(
            items[id].nftContract.getApproved(_tokenId) == address(this),
            "You have to approve the contract first for transfer of token"
        );
        items[id].nftContract.transferFrom(msg.sender, address(this), _tokenId);
    }

    /// Bid on the auction with the value sent
    /// together with this transaction.
    /// The value will only be refunded if the
    /// auction is not won.
    function bid(uint256 _itemId) external payable {
        Item storage currentItem = items[_itemId];
        require(
            currentItem.seller != msg.sender,
            "You can't bid on your own token"
        );
        require(!currentItem.sold, "Auction is over");
        require(
            currentItem.highestBidder != msg.sender,
            "You can't outbid yourself"
        );
        require(
            bids[_itemId][msg.sender] == 0,
            "Use increase Bid to increase your existing bid"
        );
        if (block.timestamp > currentItem.auctionEndTime)
            revert AuctionAlreadyEnded();

        if (msg.value < currentItem.price) revert BidPriceLessThanFloorPrice();

        if (msg.value <= currentItem.highestBid)
            revert BidNotHighEnough(currentItem.highestBid);

        if (currentItem.highestBid != 0) {
            bids[_itemId][currentItem.highestBidder] += currentItem.highestBid;
        }

        currentItem.highestBidder = msg.sender;
        currentItem.highestBid = msg.value;
        emit HighestBidIncreased(msg.sender, msg.value);
    }

    function increaseBid(uint256 _itemId)
        external
        payable
        eligibleOnly(_itemId)
    {
        if (block.timestamp > items[_itemId].auctionEndTime)
            revert AuctionAlreadyEnded();

        if (
            (msg.value + bids[_itemId][msg.sender]) <= items[_itemId].highestBid
        ) revert BidNotHighEnough(items[_itemId].highestBid);

        bids[_itemId][items[_itemId].highestBidder] += items[_itemId]
            .highestBid;
        items[_itemId].highestBidder = msg.sender;
        items[_itemId].highestBid = msg.value + bids[_itemId][msg.sender];
        bids[_itemId][msg.sender] = 0;
        emit HighestBidIncreased(msg.sender, msg.value);
    }

    function cancelAuction(uint256 _itemId) public payable {
        Item storage currentItem = items[_itemId];
        if (ended[_itemId]) revert AuctionEndAlreadyCalled();
        require(currentItem.seller == msg.sender, "Unauthorized user");
        require(
            block.timestamp < currentItem.auctionEndTime && !currentItem.sold,
            "Auction is over"
        );
        require(
            msg.value == cancelFee,
            "You need to pay a fee to cancel auction"
        );
        currentItem.auctionEndTime = 0;
        currentItem.owner = payable(msg.sender);
        bids[_itemId][currentItem.highestBidder] += currentItem.highestBid;
        currentItem.highestBidder = address(0);
        currentItem.highestBid = 0;
        currentItem.sold = true;
        (bool success, ) = contractOwner.call{value: cancelFee}("");
        require(success, "Payment for cancel fee failed");
        currentItem.nftContract.transferFrom(
            address(this),
            msg.sender,
            currentItem.tokenId
        );
    }

    function withdrawlEligibility(uint256 _itemId)
        public
        view
        returns (bool eligible)
    {
        eligible = msg.sender != items[_itemId].highestBidder &&
            (bids[_itemId][msg.sender] > 0)
            ? true
            : false;
    }

    /// Withdraw a bid that was overbid.
    function withdraw(uint256 _itemId)
        external
        eligibleOnly(_itemId)
        returns (bool)
    {
        uint256 amount = bids[_itemId][msg.sender];
        if (amount > 0) {
            bids[_itemId][msg.sender] = 0;
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            require(success, "Withdrawal failed");
            return true;
        }
        return false;
    }

    /// End the auction and send the highest bid
    /// to the beneficiary.
    function auctionEnd(uint256 _itemId) external sellerOnly(_itemId) {
        if (ended[_itemId]) revert AuctionEndAlreadyCalled();

        ended[_itemId] = true;
        Item storage currentItem = items[_itemId];
        address payable seller = currentItem.seller;
        currentItem.seller = payable(msg.sender);
        currentItem.owner = payable(msg.sender);
        uint256 amount = currentItem.highestBid;
        currentItem.highestBid = 0;
        (bool success, ) = seller.call{value: amount}("");
        require(success, "Payment failed");
        currentItem.nftContract.transferFrom(
            address(this),
            msg.sender,
            currentItem.tokenId
        );
        emit AuctionEnded(
            items[_itemId].highestBidder,
            items[_itemId].highestBid
        );
    }

    modifier eligibleOnly(uint256 _itemId) {
        require(
            msg.sender != items[_itemId].highestBidder,
            "The highest bid can not be withdrawn."
        );
        require(bids[_itemId][msg.sender] > 0, "You do not have a bid placed.");
        _;
    }

    modifier sellerOnly(uint256 _itemId) {
        require(
            msg.sender == items[_itemId].seller,
            "Only seller can end the auction."
        );
        _;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return bytes4(this.onERC721Received.selector);
    }
}