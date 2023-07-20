// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Droplinked is ERC1155 {
    AggregatorV3Interface internal immutable priceFeed;

    // HeartBeat is used to check if the price is updated or not (in seconds)
    uint16 heartBeat = 120;

    error oldPrice();

    // This error will be used when transfering money to an account fails
    error WeiTransferFailed(string message);

    // NotEnoughBalance indicates the msg.value is less than expected
    error NotEnoughBalance();

    // NotEnoughtTokens indicates the amount of tokens you want to purchase is more than actual existing
    error NotEnoughtTokens();

    // AccessDenied indicates you want to do a operation (CancelRequest or Accept) that you are not allowed to do
    error AccessDenied();

    // AlreadyRequested indicates that you have already requested for the token_id you are trying to request to again
    error AlreadyRequested();

    // RequestNotfound is thrown when the caller is not the person that is needed to accept the request
    error RequestNotfound();

    // RequestIsAccepted is thrown when the publisher tries to cancel its request but the request is accepted beforehand
    error RequestIsAccepted();

    // The Mint would be emitted on Minting new product
    event Mint_event(uint token_id, address recipient, uint amount);

    // PublishRequest would be emitted when a new publish request is made
    event PulishRequest(uint token_id, uint request_id);

    // AcceptRequest would be emitted when the `approve_request` function is called
    event AcceptRequest(uint request_id);

    // Cancelequest would be emitted when the `cancel_request` function is called
    event CancelRequest(uint request_id);

    // DisapproveRequest would be emitted when the `disapprove` function is called
    event DisapproveRequest(uint request_id);

    // DirectBuy would be emitted when the `direct_buy` function is called and the transfer is successful
    event DirectBuy(uint price, address from, address to);

    // RecordedBuy would be emitted when the `buy_recorded` function is called and the transfers are successful
    event RecordedBuy(
        address producer,
        uint token_id,
        uint shipping,
        uint tax,
        uint amount,
        address buyer
    );

    // AffiliateBuy would be emitted when the `buy_affiliate` function is called and the transfers are successful
    event AffiliateBuy(
        uint request_id,
        uint amount,
        uint shipping,
        uint tax,
        address buyer
    );

    event HeartBeatUpdated(uint16 newHeartBeat);

    event FeeUpdated(uint newFee);

    // NFTMetadata Struct
    struct NFTMetadata {
        string ipfsUrl;
        uint price;
        uint comission;
    }

    // Request struct
    struct Request {
        uint token_id;
        address producer;
        address publisher;
        bool accepted;
    }

    // TokenID => ItsTotalSupply
    mapping(uint => uint) token_cnts;

    // Keeps the record of the minted tokens
    uint public token_cnt;

    // Keeps the record of the requests made
    uint public request_cnt;

    // Keeps record of the total_supply of the contract
    uint public total_supply;

    // The ratio Verifier for payment methods
    address public immutable owner;

    // The fee (*100) for Droplinked Account (ratioVerifier)
    uint public fee;

    // HolderAddress => ( TokenID => AMOUNT ) Holders
    mapping(address => mapping(uint => uint)) public holders;

    // TokenID => metadata
    mapping(uint => NFTMetadata) public metadatas;

    // RequestID => Request
    mapping(uint => Request) public requests;

    // ProducerAddress => ( TokenID => isRequested )
    mapping(address => mapping(uint => bool)) public isRequested;

    // HashOfMetadata => TokenID
    mapping(bytes32 => uint) public tokenid_by_hash;

    // PublisherAddress => ( RequestID => boolean )
    mapping(address => mapping(uint => bool)) public publishers_requests;

    // ProducerAddress => ( RequestID => boolean )
    mapping(address => mapping(uint => bool)) public producer_requests;

    // TokenID => string URI
    mapping(uint => string) uris;

    modifier onlyOwner() {
        if(msg.sender != owner) revert AccessDenied();
        _;
    }

    constructor(uint _fee) ERC1155("") {
        fee = _fee;
        owner = msg.sender;
        // Using price feed of chainlink to get the price of MATIC/USD without external source or centralization
        // Binance : 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526
        // Polygon : 0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada
        priceFeed = AggregatorV3Interface(
            0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada
        );
    }

    function setHeartBeat(uint16 _heartbeat) public onlyOwner {
        heartBeat = _heartbeat;
        emit HeartBeatUpdated(_heartbeat);
    }

    function setFee(uint _fee) public onlyOwner{
        fee = _fee;
        emit FeeUpdated(_fee);
    }

    // Get the latest price of MATIC/USD with 8 digits shift ( the actual price is 1e-8 times the returned price )
    function getLatestPrice(uint80 roundId) public view returns (uint, uint) {
        (, int256 price, , uint256 timestamp, ) = priceFeed.getRoundData(
            roundId
        );
        return (uint(price), timestamp);
    }

    function uri(
        uint256 token_id
    ) public view virtual override returns (string memory) {
        return uris[token_id];
    }

    function mint(
        string calldata _uri,
        uint _price,
        uint _comission,
        uint amount
    ) public {
        // Calculate the metadataHash using its IPFS uri, price, and comission
        bytes32 metadata_hash = keccak256(abi.encode(_uri, _price, _comission));
        // Get the TokenID from `tokenid_by_hash` by its calculated hash
        uint token_id = tokenid_by_hash[metadata_hash];
        // If NOT FOUND
        if (token_id == 0) {
            // Create a new tokenID
            token_id = token_cnt + 1;
            token_cnt++;
            metadatas[token_id].ipfsUrl = _uri;
            metadatas[token_id].price = _price;
            metadatas[token_id].comission = _comission;
            holders[msg.sender][token_id] = amount;
            tokenid_by_hash[metadata_hash] = token_id;
        }
        // If FOUND
        else {
            // Update the old token_ids amount
            holders[msg.sender][token_id] += amount;
        }
        total_supply += amount;
        token_cnts[token_id] += amount;
        _mint(msg.sender, token_id, amount, "");
        uris[token_id] = _uri;
        emit URI(_uri, token_id);
        emit Mint_event(token_id, msg.sender, amount);
    }

    function publish_request(address producer_account, uint token_id) public {
        if (isRequested[producer_account][token_id]) revert AlreadyRequested();
        // Create a new request_id
        uint request_id = request_cnt + 1;
        // Update the requests_cnt
        request_cnt++;
        // Create the request and add it to producer's incoming reqs, and publishers outgoing reqs
        requests[request_id].token_id = token_id;
        requests[request_id].producer = producer_account;
        requests[request_id].publisher = msg.sender;
        requests[request_id].accepted = false;
        publishers_requests[msg.sender][request_id] = true;
        producer_requests[producer_account][request_id] = true;
        isRequested[producer_account][token_id] = true;
        emit PulishRequest(token_id, request_id);
    }

    // The overloading of the safeBatchTransferFrom from ERC1155 to update contract variables
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public virtual override {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );
        _safeBatchTransferFrom(from, to, ids, amounts, data);
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];
            holders[from][id] -= amount;
            holders[to][id] += amount;
        }
    }

    // ERC1155 overloading to update the contracts state when the safeTrasnferFrom is called
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public virtual override {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );
        _safeTransferFrom(from, to, id, amount, data);
        holders[from][id] -= amount;
        holders[to][id] += amount;
    }

    function approve_request(uint request_id) public {
        if (!producer_requests[msg.sender][request_id])
            revert RequestNotfound();
        requests[request_id].accepted = true;
        emit AcceptRequest(request_id);
    }

    function cancel_request(uint request_id) public {
        if (msg.sender != requests[request_id].publisher) revert AccessDenied();
        if (requests[request_id].accepted) revert RequestIsAccepted();
        // remove the request from producer's incoming requests, and from publisher's outgoing requests
        producer_requests[requests[request_id].producer][request_id] = false;
        publishers_requests[msg.sender][request_id] = false;
        // Also set the isRequested to false since we deleted the request
        isRequested[requests[request_id].producer][
            requests[request_id].token_id
        ] = false;
        emit CancelRequest(request_id);
    }

    function disapprove(uint request_id) public {
        if (msg.sender != requests[request_id].producer) revert AccessDenied();
        // remove the request from producer's incoming requests, and from publisher's outgoing requests
        producer_requests[msg.sender][request_id] = false;
        publishers_requests[requests[request_id].publisher][request_id] = false;
        // Also set the isRequested to false since we deleted the request
        isRequested[requests[request_id].producer][
            requests[request_id].token_id
        ] = false;
        // And set the `accepted` property of the request to false
        requests[request_id].accepted = false;
        emit DisapproveRequest(request_id);
    }

    function direct_buy(
        uint price,
        address recipient,
        uint80 roundId
    ) public payable {
        // Get timestamp from roundId and check if its less than 2 heartbeats passed
        // Calculations
        (uint ratio, uint timestamp) = getLatestPrice(roundId);
        // check the timestamp
        if (
            block.timestamp > timestamp &&
            block.timestamp - timestamp > 2 * heartBeat
        ) revert oldPrice();
        uint totalAmount = (price * 1e24) / ratio;
        uint droplinkedShare = (totalAmount * fee) / 1e4;
        // check if the sended amount is more than the needed
        if (msg.value < totalAmount) revert NotEnoughBalance();
        // Transfer money & checks
        (bool t, ) = payable(owner).call{value: droplinkedShare}("");
        if (!t) revert WeiTransferFailed("droplinked transfer");
        (t, ) = payable(recipient).call{value: (totalAmount)}("");
        if (!t) revert WeiTransferFailed("recipient transfer");
        emit DirectBuy(price, msg.sender, recipient);
    }

    function buy_recorded(
        address producer,
        uint token_id,
        uint shipping,
        uint tax,
        uint amount,
        uint80 roundId
    ) public payable {
        if (holders[producer][token_id] < amount) revert NotEnoughtTokens();
        // Calculations
        (uint ratio, uint timestamp) = getLatestPrice(roundId);
        // check the timestamp
        if (
            block.timestamp > timestamp &&
            block.timestamp - timestamp > 2 * heartBeat
        ) revert oldPrice();
        uint product_price = (amount * metadatas[token_id].price * 1e24) /
            ratio;
        uint totalPrice = product_price + (((shipping + tax) * 1e24) / ratio);
        if (msg.value < totalPrice) revert NotEnoughBalance();
        uint droplinked_share = (product_price * fee) / 1e4;
        uint producer_share = totalPrice - droplinked_share;
        // Transfer the product on the contract state
        holders[msg.sender][token_id] += amount;
        holders[producer][token_id] -= amount;
        emit RecordedBuy(producer, token_id, shipping, tax, amount, msg.sender);
        // Actual money transfers & checks
        (bool result, ) = payable(owner).call{value: droplinked_share}("");
        if (!result) revert WeiTransferFailed("droplinked transfer");
        (result, ) = payable(producer).call{value: producer_share}("");
        if (!result) revert WeiTransferFailed("producer transfer");
    }

    function buy_affiliate(
        uint request_id,
        uint amount,
        uint shipping,
        uint tax,
        uint80 roundId
    ) public payable {
        // checks and calculations
        address prod = requests[request_id].producer;
        address publ = requests[request_id].publisher;
        uint token_id = requests[request_id].token_id;
        (uint ratio, uint timestamp) = getLatestPrice(roundId);
        // check the timestamp
        if (
            block.timestamp > timestamp &&
            block.timestamp - timestamp > 2 * heartBeat
        ) revert oldPrice();
        uint product_price = (amount * metadatas[token_id].price * 1e24) /
            ratio;
        uint total_amount = product_price + (((shipping + tax) * 1e24) / ratio);
        if (msg.value < total_amount) revert NotEnoughBalance();

        if (holders[prod][token_id] < amount) revert NotEnoughtTokens();
        uint droplinked_share = (product_price * fee) / 1e4;
        uint publisher_share = ((product_price - droplinked_share) *
            metadatas[token_id].comission) / 1e4;
        uint producer_share = total_amount -
            (droplinked_share + publisher_share);
        // Transfer on contract
        holders[msg.sender][token_id] += amount;
        holders[prod][token_id] -= amount;
        emit AffiliateBuy(request_id, amount, shipping, tax, msg.sender);
        // Money transfer
        (bool result, ) = payable(owner).call{value: droplinked_share}("");
        if (!result) revert WeiTransferFailed("droplinked transfer");
        (result, ) = payable(prod).call{value: producer_share}("");
        if (!result) revert WeiTransferFailed("producer transfer");
        (result, ) = payable(publ).call{value: publisher_share}("");
        if (!result) revert WeiTransferFailed("publisher transfer");
    }

    // Returns the totalSupply of the contract
    function totalSupply(uint256 id) public view returns (uint256) {
        return token_cnts[id];
    }
}
