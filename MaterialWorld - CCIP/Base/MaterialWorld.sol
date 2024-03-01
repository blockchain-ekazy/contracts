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

contract MaterialWorld is  ERC721, ERC721Burnable, Ownable, CCIPReceiver  {
    using Strings for uint256;
    
    AggregatorV3Interface internal dataFeed;
    
    uint current_token_id = 1;
    uint maxSupply = 10_000;
    uint totalSupply_ = 0;
    
    uint64 public CCIP_ChainId;
    uint public CCIP_GAS_LIMIT = 500_000;
    string URI = "https://materialworld-backend-dev-sufxks5dra-uc.a.run.app/api/metadata/";

    uint mintFee = 500; // $5 in cents
    uint traverseFee = 25; // 25 cents
    uint renameFee = 25; // 25 cents

    mapping(uint => Stat) public stats;
    mapping(uint => address) public materialAddresses;
    mapping(string => bool) public usedName;

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

    address DinaraWallet;

    constructor(address dinaraWallet, uint64 CCIP_ChainId_, address router, address aggregatorAddress) Ownable(msg.sender) CCIPReceiver(router) ERC721("Material World", "MW") {
        CCIP_ChainId = CCIP_ChainId_;
        dataFeed = AggregatorV3Interface(aggregatorAddress);
        DinaraWallet = dinaraWallet;
    }

    function basemint(address to, string memory name) public payable {
        require(current_token_id <= maxSupply, "Max supply minted");
        require(!usedName[name], "Name already used");

        uint mintFee_ = getUSDPrice(mintFee);

        require(msg.value >= mintFee_, "Insufficient value for mint");
        require(recoverETH(mintFee_, DinaraWallet), "Fee transfer failed!");
        
        _safeMint(to, current_token_id);

        Stat memory s = Stat(0, 0, 0, 0, 0, name, CCIP_ChainId, 0, 0);
        stats[current_token_id] = s;
        usedName[name] = true;

        current_token_id++;
        totalSupply_++;
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

    function rename(uint tokenId, string memory name) public payable {
        require(ownerOf(tokenId) == msg.sender, "Caller is not owner");
        require(!usedName[name], "Name already used");

        uint renameFee_ = getUSDPrice(renameFee);

        require(msg.value >= renameFee_, "Insufficient value for rename");
        require(recoverETH(renameFee_, DinaraWallet), "Fee transfer failed!");

        usedName[name] = true;
        usedName[stats[tokenId].Name] = false;
        stats[tokenId].Name = name;
        emit Material_log(stats[tokenId], tokenId, Trait(0), "Rename", msg.sender);
    }

    function traverse(uint64 destinationChainSelector, uint id) external payable{
        require(CCIP_ChainId != destinationChainSelector, "Source and destination chain cannot be same!");

        Stat memory stat = stats[id];
        stat.ActiveChain = destinationChainSelector;
        stat.Traversals++;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(materialAddresses[destinationChainSelector]),
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

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override{
        (address msgsender_, uint tokenId, uint64 senderChainId, address senderContract, Stat memory data) = abi.decode(message.data, (address, uint, uint64, address, Stat));
        require(materialAddresses[senderChainId] == senderContract, "Tx sender contract address not whitelisted.");

        _safeMint(msgsender_, tokenId);
        stats[tokenId] = data;
        totalSupply_++;
    }

    function supportsInterface(bytes4 interfaceId) public pure override(CCIPReceiver, ERC721) returns (bool) {
        // Call the supportsInterface function from CCIPReceiver
        return CCIPReceiver.supportsInterface(interfaceId);
    }

    function whitelist_addresses(uint64[] memory chainIds, address[] memory addresses) public onlyOwner {
        for(uint i=0 ; i<chainIds.length; i++) {
            materialAddresses[chainIds[i]] = addresses[i];
        }
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

    function updatePricing(uint mintFee_, uint traverseFee_, uint renameFee_) public onlyOwner {
        mintFee = mintFee_;
        traverseFee = traverseFee_;
        renameFee = renameFee_;
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