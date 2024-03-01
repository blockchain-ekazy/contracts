// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "../openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "../openzeppelin/contracts/access/Ownable.sol";
import {CCIPReceiver} from "../chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "../chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "../chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "../chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";
import "../chainlink/contracts/src/v0.8/AggregatorV3Interface.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

contract MaterialWorld is  ERC721, ERC721Burnable, Ownable, CCIPReceiver, VRFV2WrapperConsumerBase  {
    using Strings for uint256;

    AggregatorV3Interface internal dataFeed;

    uint totalSupply_ = 0;

    uint64 public CCIP_ChainId;
    uint public CCIP_GAS_LIMIT = 500_000;
    uint32 public VRF_GAS_LIMIT = 500_000;

    string URI = "https://materialworld-backend-dev-sufxks5dra-uc.a.run.app/api/metadata/";

    mapping(uint => address) public Material_addresses;
    mapping(uint => Stat) public stats;
    mapping(uint => Request) public requests;
    mapping(Trait => uint[]) public wealthScores;
    mapping(Trait => uint[]) public rarities;
    mapping(Trait => uint) public totalRarities;

    uint traverseFee = 25; // 25 cents
    uint rerollFee = 25; // 25 cents

    event Material_log(Stat stat, uint nft_id, Trait trait, string log_type, address user);

    enum Trait {
        Character,
        House,
        Boat,
        Vehicle,
        Aircraft
    }
    
    struct Stat {
        uint Character;
        uint House;
        uint Boat;
        uint Vehicle;
        uint Aircraft;
        string Name;
        uint ActiveChain;
        uint Traversals;
        uint Wealth;
    }

    struct Request {
        bool valid;
        string log;
        uint tokenId;
    }

    address DinaraWallet;

    constructor(address dinaraWallet, uint64 CCIP_ChainId_, address router, address wrapper, address LINK, address aggregatorAddress) 
    Ownable(msg.sender) 
    CCIPReceiver(router) 
    ERC721("Material World", "MW") 
    VRFV2WrapperConsumerBase(LINK, wrapper) {
        dataFeed = AggregatorV3Interface(aggregatorAddress);
        CCIP_ChainId = CCIP_ChainId_;
        DinaraWallet = dinaraWallet;
        initRarity();
    }

    function tokenURI(uint _tokenId) public view virtual override returns (string memory) {
        return string(abi.encodePacked(URI, _tokenId.toString()));
    }

    function setURI(string memory uri) public onlyOwner {
        URI = uri;
    }

    function set_CCIP_GAS_LIMIT(uint gas_) public onlyOwner {
        CCIP_GAS_LIMIT = gas_;
    }

    function set_VRF_GAS_LIMIT(uint32 gas_) public onlyOwner {
        VRF_GAS_LIMIT = gas_;
    }

    function traverse(uint64 destinationChainSelector, uint id) external payable{
        require(CCIP_ChainId != destinationChainSelector, "Source and destination chain cannot be same!");

        Stat memory stat = stats[id];
        stat.ActiveChain = destinationChainSelector;
        stat.Traversals++;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(Material_addresses[destinationChainSelector]),
            data: abi.encode(msg.sender, id, CCIP_ChainId, address(this), stat),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: CCIP_GAS_LIMIT})),
            feeToken: address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(
            destinationChainSelector,
            message
        );

        uint traverseFee_ = getUSDPrice(traverseFee);

        require(msg.value >= traverseFee_ + fee, "Insufficient value for traverse");
        require(recoverETH(traverseFee_, DinaraWallet), "Fee transfer failed!");

        burn(id);

        bytes32 messageId;
        messageId = IRouterClient(i_router).ccipSend{value: fee}(
            destinationChainSelector,
            message
        );

        emit Material_log(stat, id, Trait(0), "Traverse", msg.sender);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        (address msgsender_, uint tokenId, uint64 senderChainId, address senderContract, Stat memory data) = abi.decode(message.data, (address, uint, uint64, address, Stat));
        require(Material_addresses[senderChainId] == senderContract, "Tx sender contract address not whitelisted.");

        _safeMint(msgsender_, tokenId);
        stats[tokenId] = data;
        totalSupply_++;

        if(data.Aircraft == 0) {
            reroll_(tokenId);
        }
    }

    function supportsInterface(bytes4 interfaceId) public pure override(CCIPReceiver, ERC721) returns (bool) {
        // Call the supportsInterface function from CCIPReceiver
        return CCIPReceiver.supportsInterface(interfaceId);
    }

    function whitelist_addresses(uint64[] memory chainIds, address[] memory addresses) public onlyOwner{
        for(uint i=0 ; i<chainIds.length; i++) {
            Material_addresses[chainIds[i]] = addresses[i];
        }
    }

    function rerollTrait(uint tokenId) public payable {
        uint rerollFee_ = getUSDPrice(rerollFee);

        require(ownerOf(tokenId) == msg.sender, "Caller is not owner");
        require(msg.value >= rerollFee_, "Insufficient value for reroll");
        require(recoverETH(rerollFee_, DinaraWallet), "Fee transfer failed!");

        reroll_(tokenId);
    }

    function reroll_(uint tokenId) internal {
        uint256 hash_1 = uint(keccak256(abi.encodePacked(block.timestamp + block.prevrandao + block.number + block.gaslimit + tokenId))) % 200_000;
        uint256 hash_2 = uint(keccak256(abi.encodePacked(msg.sender))) % 200_000;
        uint256 _randomWord = (hash_1 + hash_2) % 200_000 + 1;
        
        uint8 rarity = findRarity(_randomWord, Trait.Aircraft); //returns 0-19

        uint newWealth = stats[tokenId].Wealth + wealthScores[Trait.Aircraft][rarity];
        if(stats[tokenId].Aircraft != 0) 
            newWealth -= wealthScores[Trait.Aircraft][stats[tokenId].Aircraft - 1];

        stats[tokenId].Aircraft = rarity + 1; //traits range from 1-20
        stats[tokenId].Wealth = newWealth;

        emit Material_log(stats[tokenId], tokenId, Trait.Aircraft, "Reroll Aircraft", msg.sender);
    }
    
    function rerollTraitVRF(uint tokenId) public payable {
        uint rerollFee_ = getUSDPrice(rerollFee);

        require(ownerOf(tokenId) == msg.sender, "Caller is not owner");
        require(msg.value >= rerollFee_, "Insufficient value for reroll");
        require(recoverETH(rerollFee_, DinaraWallet), "Fee transfer failed!");

        uint requestId = requestRandomness(VRF_GAS_LIMIT, 3, 1);
        requests[requestId] = Request (true, "Reroll Aircraft", tokenId);
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        require(requests[_requestId].valid, "Invalid request id");

        uint8 rarity = findRarity(_randomWords[0], Trait.Aircraft); //returns 0-19

        Stat memory stat = stats[requests[_requestId].tokenId];
        
        uint newWealth = stat.Wealth + wealthScores[Trait.Aircraft][rarity];
        if(stat.Aircraft != 0) 
            newWealth -= wealthScores[Trait.Aircraft][stat.Aircraft - 1];

        stats[requests[_requestId].tokenId].Aircraft = rarity + 1; //traits range from 1-20
        stats[requests[_requestId].tokenId].Wealth = newWealth;
        requests[_requestId].valid = false;

        emit Material_log(stats[requests[_requestId].tokenId], requests[_requestId].tokenId, Trait.Aircraft, requests[_requestId].log, msg.sender);
    }

    function findRarity(uint256 randomNumber, Trait trait) internal view returns (uint8) {
        require(randomNumber > 0 , "Random number should greater than 0");

        uint256 randomIndex = uint256(keccak256(abi.encode(randomNumber))) % totalRarities[trait];
        uint256 cumulativeRarity = 0;

        for (uint8 i = 0; i < 20; i++) {
            cumulativeRarity += rarities[trait][i];
            if (randomIndex < cumulativeRarity) {
                return i;
            }
        }
        return 19;
    }

    function initRarity() internal{
        wealthScores[Trait.Character] = [1,100,3,90,10,84,5,8,52,66,72,12,46,15,16,20,22,26,29,32];
        wealthScores[Trait.Vehicle] = [1,100,94,2,82,78,4,5,7,66,12,56,23,34,40,52,10,31,46,48];
        wealthScores[Trait.House] = [1,100,3,95,89,5,84,18,22,10,28,34,41,77,47,74,51,36,59,62];
        wealthScores[Trait.Boat] = [1,100,3,94,2,88,6,86,10,82,18,22,80,28,32,44,46,55,62,77];
        wealthScores[Trait.Aircraft] = [1,100,3,94,4,92,86,6,12,15,82,22,79,32,62,71,75,52,55,57];

        rarities[Trait.Character] = [32,32,64,64,127,127,318,318,318,318,318,637,637,955,955,955,955,955,955,955];
        rarities[Trait.Vehicle] = [27,27,55,82,82,110,137,164,274,274,548,548,822,822,822,822,1096,1096,1096,1096];
        rarities[Trait.House] = [25,25,51,51,127,152,203,380,380,506,506,506,506,506,633,759,886,1266,1266,1266];
        rarities[Trait.Boat] = [32,32,63,63,127,127,190,190,316,316,633,633,633,949,949,949,949,949,949,949];
        rarities[Trait.Aircraft] = [26,26,78,78,157,157,209,261,392,522,522,653,653,783,783,783,783,1044,1044,1044];

        totalRarities[Trait.Character] = 9995;
        totalRarities[Trait.Vehicle] = 10000;
        totalRarities[Trait.House] = 10000;
        totalRarities[Trait.Boat] = 9998;
        totalRarities[Trait.Aircraft] = 9998;
    }

    function recoverERC20(address a) public onlyOwner {
        IERC20(a).transfer(msg.sender, IERC20(a).balanceOf(address(this)));
    }

    function recoverETH(uint amount, address a) internal returns(bool) {
        require(amount <= address(this).balance, "Amount exceed contract balance");
        (bool hq, ) = payable(a).call{value: amount}("");
        return hq;
    }

    function recoverETH_(uint amount, address a) public onlyOwner returns(bool) {
        require(amount <= address(this).balance, "Amount exceed contract balance");
        (bool hq, ) = payable(a).call{value: amount}("");
        return hq;
    }

    function updatePricing(uint traverseFee_, uint rerollFee_) public onlyOwner {
        traverseFee = traverseFee_;
        rerollFee = rerollFee_;
    }

    function burn(uint256 tokenId) public override {
        _update(address(0), tokenId, _msgSender());
        totalSupply_--;
        emit Transfer(_msgSender(), address(0), tokenId);
    }

    function totalSupply() public view returns (uint) {
        return totalSupply_;
    }

    function getUSDPrice(uint cents) public view returns(uint) {
        (,int256 answer,,,) = dataFeed.latestRoundData();
        uint256 ethInCents = (uint256(answer) / 10**6); //ETH in cents
        return (1 ether / ethInCents) * cents;
    }
}