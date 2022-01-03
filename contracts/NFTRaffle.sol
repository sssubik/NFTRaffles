// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;
import "../interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol"; 
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol"; 

contract Raffle is Ownable, ERC721, VRFConsumerBase{
    struct Metadata {
        uint256 startIndex;
        uint256 endIndex;
        uint256 entropy;
    }

    IERC20 public immutable LINK_TOKEN;
    bytes32 internal immutable KEY_HASH;
    uint256 public immutable  MINT_COST;
    uint256 public immutable RAFFLE_START_TIME;
    uint256 public immutable RAFFLE_END_TIME;
    uint256 public immutable AVAILABLE_SUPPLY;
    uint256 public immutable MAX_PER_ADDRESS;

    uint256 public entropy;
    uint256 public nftCount = 0;
    uint256 public shuffledCount = 0;
    uint256 public nftRevealedCount = 0;
    Metadata[] public metadatas;
    bool public clearingEntropySet = false;
    bool public proceedsClaimed = false;
    address[] public raffleEntries;
    mapping(address => uint256) public entriesPerAddress;
    mapping(uint256 => bool) public ticketClaimed;

    
    event RaffleEntered(address indexed user, uint256 entries);
    event RaffleShuffled(address indexed user, uint256 numShuffled);
    event RaffleProceedsClaimed(address indexed owner, uint256 amount);
    event RaffleClaimed(address indexed user, uint256 winningTickets, uint256 losingTickets);

    constructor(
        string memory _NFT_NAME,
        string memory _NFT_SYMBOL,
        bytes32 _LINK_KEY_HASH,
        address _LINK_ADDRESS,
        address _LINK_VRF_COORDINATOR_ADDRESS,
        uint256 _MINT_COST,
        uint256 _RAFFLE_START_TIME,
        uint256 _RAFFLE_END_TIME,
        uint256 _AVAILABLE_SUPPLY,
        uint256 _MAX_PER_ADDRESS
    )   VRFConsumerBase(_LINK_VRF_COORDINATOR_ADDRESS, _LINK_ADDRESS)
        ERC721(_NFT_NAME,_NFT_SYMBOL)
    {
        LINK_TOKEN = IERC20(_LINK_ADDRESS);
        KEY_HASH = _LINK_KEY_HASH;
        MINT_COST = _MINT_COST;
        RAFFLE_START_TIME = _RAFFLE_START_TIME;
        RAFFLE_END_TIME = _RAFFLE_END_TIME;
        AVAILABLE_SUPPLY = _AVAILABLE_SUPPLY;
        MAX_PER_ADDRESS = _MAX_PER_ADDRESS;

    }

    function enterRaffle(uint256 numTickets) external payable{
        require(block.timestamp > RAFFLE_START_TIME, "Raffle not active");
        require(block.timestamp <= RAFFLE_END_TIME,"Raffle has ended");

        require(entriesPerAddress[msg.sender] + numTickets <= MAX_PER_ADDRESS, 'Max slots reached');
        require(msg.value == numTickets * MINT_COST, "Incorrect payment");

        entriesPerAddress[msg.sender] += numTickets;

        for (uint256 i = 0; i < numTickets;i++){
            raffleEntries.push(msg.sender);
        }
        emit RaffleEntered(msg.sender, numTickets);
    }

    function clearRaffle(uint256 numShuffles) external {
        require(block.timestamp > RAFFLE_END_TIME, 'Raffle has not ended');
        require(raffleEntries.length > AVAILABLE_SUPPLY, 'Raffle does not need clearing');
        require(shuffledCount != AVAILABLE_SUPPLY, "Raffle has already been cleared");
        require(numShuffles + shuffledCount <= AVAILABLE_SUPPLY, "Excess indices to shuffle");
        require(clearingEntropySet);

        for (uint256 i = shuffledCount; i < shuffledCount + numShuffles; i++){
            uint256 randomIndex = i + entropy % (raffleEntries.length - i);
            address randomTmp = raffleEntries[randomIndex];
            raffleEntries[randomIndex] = raffleEntries[i];
            raffleEntries[i] = randomTmp;
        }

        shuffledCount += numShuffles;
        emit RaffleShuffled(msg.sender, numShuffles);
    }

    function claimRaffle(uint256[] calldata tickets) external {
        require(block.timestamp > RAFFLE_END_TIME, "Raffle has not ended");

        require(
            (raffleEntries.length < AVAILABLE_SUPPLY) || (shuffledCount == AVAILABLE_SUPPLY),"Raffle has not been cleared"
        );

        uint256 tmpCount = nftCount;
        for (uint256 i = 0; i < tickets.length; i++){
            require(tickets[i] < raffleEntries.length,"Ticket is not in raffle range");
            require(!ticketClaimed[tickets[i]]);
            require(raffleEntries[tickets[i]] == msg.sender);
            ticketClaimed[tickets[i]] = true;

            if(tickets[i] +1 <= AVAILABLE_SUPPLY){
                _safeMint(msg.sender,nftCount + 1);
                nftCount++;
            }
        }
        uint256 winningTickets = nftCount - tmpCount;

        if(winningTickets != tickets.length){
            (bool sent,) = payable(msg.sender).call{value: (tickets.length - winningTickets) * MINT_COST
            
            }("");
            require(sent,'unsuccessful refund');
        }
        
        
    }

    function setClearingEntropy() external returns (bytes32 requestId){
        require(block.timestamp > RAFFLE_END_TIME, 'Raffle Sticll active');
        require(LINK_TOKEN.balanceOf(address(this))== 2e18, "Insufficient Link");
        require(raffleEntries.length > AVAILABLE_SUPPLY,"Raffle does not need entropy");
        require(!clearingEntropySet,'Clearing entropy already set');

        return requestRandomness(KEY_HASH, 2e18);
    }

    function revealPendingMetadata() external returns (bytes32 requestId) {
        require(nftCount - nftRevealedCount > 0, "No NFTs pending metadata reveal");
        require(LINK_TOKEN.balanceOf(address(this)) >= 2e18, "Insufficient LINK");

        return requestRandomness(KEY_HASH, 2e18);
    }

    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override{
        if(clearingEntropySet || raffleEntries.length < AVAILABLE_SUPPLY){
            metadatas.push(Metadata(
                {
                    startIndex: nftRevealedCount+1,
                    endIndex: nftCount + 1,
                    entropy: randomness

                })

            );
            nftRevealedCount = nftCount;
            return;
        }
        
        entropy = randomness;
        clearingEntropySet = true;
    }

    function withdrawRaffleProceeds() external onlyOwner {
        require(block.timestamp > RAFFLE_END_TIME, "Raffle has not ended");
        require(!proceedsClaimed, "Proceeds already claimed");

        proceedsClaimed = true;

        uint256 proceeds = MINT_COST * (
            raffleEntries.length > AVAILABLE_SUPPLY ? AVAILABLE_SUPPLY: raffleEntries.length
        );

        (bool sent,) = payable(address(this)).call{value: proceeds}("");
        require(sent,'Unsuccessful');

         emit RaffleProceedsClaimed(msg.sender, proceeds);
    }

    function tokenURI(uint256 tokenId) override public view returns (string memory){
        uint256 randomness;
        bool metadataCleared;
        string[3] memory parts;

        for(uint256 i = 0; i < metadatas.length;i++){
            if(tokenId > metadatas[i].startIndex && tokenId < metadatas[i].endIndex){
                randomness = metadatas[i].entropy;
                metadataCleared = true;
            }
        }

        parts[0] = '<svg xmlns="http://www.w3.org/2000/svg" preserveAspectRatio="xMinYMin meet" viewBox="0 0 350 350"><style>.base { fill: white; font-family: serif; font-size: 14px; }</style><rect width="100%" height="100%" fill="black" /><text x="10" y="20" class="base">';

        if (metadataCleared) {
            parts[1] = string(abi.encodePacked('Randomness: ', _toString(randomness)));
        } else {
            parts[1] = 'No randomness assigned';
        }

        parts[2] = '</text></svg>';
        string memory output = string(abi.encodePacked(parts[0], parts[1], parts[2]));

        return output;
    }
    /// @notice Converts a uint256 to its string representation
    /// @dev Inspired by OraclizeAPI's implementation
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}