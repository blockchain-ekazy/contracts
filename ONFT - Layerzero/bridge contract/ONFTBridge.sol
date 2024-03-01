// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma abicoder v2;

import "./lzApp/NonblockingLzApp.sol";
import "./ERC721/IERC721.sol";
import "./EIP712.sol";
import "./AggregatorV3Interface.sol";

contract ONFTBridge is NonblockingLzApp, EIP712("Voucher-Domain", "1") {
    AggregatorV3Interface internal dataFeed;
    address public feeWallet = 0xd64aCEB97B67D41EedB6b40e564f489E3D7746c1;
    address public admin = 0x86fc9DbcE9e909c7AB4D5D94F07e70742E2d144A;
    uint public traverseFee = 25; //cents

    constructor(address _lzEndpoint, address aggregatorAddress) NonblockingLzApp(_lzEndpoint) Ownable(msg.sender) {
        dataFeed = AggregatorV3Interface(aggregatorAddress);
    }

    function setFeeWallet(address _a) public onlyOwner {
        feeWallet = _a;
    }

    function setadmin(address admin_) public onlyOwner {
        admin = admin_;
    }

    function setFee(uint fee) public onlyOwner {
        traverseFee = fee;
    }

    function _nonblockingLzReceive(uint16, bytes memory, uint64, bytes memory _payload) internal override {
        (address toAddr, uint[] memory tokenIds, address _dstToken) = abi.decode(_payload, (address, uint[], address));
        for(uint i=0;i<tokenIds.length;i++)
            IERC721(_dstToken).ONFTMint(toAddr, tokenIds[i]);
    }

    function traverse(uint16 _dstChainId, address _srcToken, address _dstToken, uint[] memory tokenIds, bytes calldata adminSignature) public payable {
        require(recoverOrder(adminSignature, _srcToken, _dstToken) == admin, "Invalid signature!");

        (,int256 answer,,,) = dataFeed.latestRoundData();
        uint256 ethInCents = (uint256(answer) / 10**6); //ETH in cents
        uint256 fee = (1 ether / ethInCents) * traverseFee;

        require(msg.value > fee, "Insufficient value for fee + traverse gas!");

        for(uint i=0;i<tokenIds.length;i++)
            IERC721(_srcToken).burn(tokenIds[i]);

        payable(feeWallet).transfer(fee);

        bytes memory payload = abi.encode(msg.sender, tokenIds, _dstToken);
        _lzSend(_dstChainId, payload, payable(msg.sender), address(0x0), bytes(""), msg.value - fee);
    }

    function traverseV1() public payable{
        (,int256 answer,,,) = dataFeed.latestRoundData();
        uint256 ethInCents = (uint256(answer) / 10**6); //ETH in cents
        uint256 fee = (1 ether / ethInCents) * traverseFee;

        require(msg.value >= fee, "Insufficient value for fee");
        payable(feeWallet).transfer(fee);
    }

    function traverseV2(address _from, uint16 _dstChainId, bytes memory _toAddress, uint _tokenId, address payable _refundAddress, address _zroPaymentAddress, bytes memory _adapterParams, address _srcToken) public payable {
        (,int256 answer,,,) = dataFeed.latestRoundData();
        uint256 ethInCents = (uint256(answer) / 10**6); //ETH in cents
        uint256 fee = (1 ether / ethInCents) * traverseFee;

        require(msg.value > fee, "Insufficient value for fee + traverse gas!");
        
        payable(feeWallet).transfer(fee);
        IERC721(_srcToken).sendFrom{ value: msg.value - fee }(_from, _dstChainId, _toAddress, _tokenId, _refundAddress, _zroPaymentAddress, _adapterParams);
    }

    function traverseV2Batch(address _from, uint16 _dstChainId, bytes memory _toAddress, uint[] memory _tokenIds, address payable _refundAddress, address _zroPaymentAddress, bytes memory _adapterParams, address _srcToken) public payable {
        (,int256 answer,,,) = dataFeed.latestRoundData();
        uint256 ethInCents = (uint256(answer) / 10**6); //ETH in cents
        uint256 fee = (1 ether / ethInCents) * traverseFee;

        require(msg.value > fee, "Insufficient value for fee + traverse gas!");

        payable(feeWallet).transfer(fee);
        IERC721(_srcToken).sendBatchFrom{ value: msg.value - fee }(_from, _dstChainId, _toAddress, _tokenIds, _refundAddress, _zroPaymentAddress, _adapterParams);
    }

    function setOracle(uint16 dstChainId, address oracle) external onlyOwner {
        uint TYPE_ORACLE = 6;
        // set the Oracle
        lzEndpoint.setConfig(lzEndpoint.getSendVersion(address(this)), dstChainId, TYPE_ORACLE, abi.encode(oracle));
    }

    function getOracle(uint16 remoteChainId) external view returns (address _oracle) {
        bytes memory bytesOracle = lzEndpoint.getConfig(lzEndpoint.getSendVersion(address(this)), remoteChainId, address(this), 6);
        assembly {
            _oracle := mload(add(bytesOracle, 32))
        }
    }

    using ECDSA for bytes32;
    function recoverOrder(bytes calldata adminSignature, address _srcToken, address _dstToken) public pure returns (address) {
        bytes32 msgHash = keccak256(abi.encodePacked(_srcToken, _dstToken));
        address signer = msgHash.toEthSignedMessageHash().recover(adminSignature);
        return signer;
    }
    
}