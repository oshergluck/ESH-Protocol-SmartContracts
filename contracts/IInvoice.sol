// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IInvoice {
    function mintNFT(address recipient, string memory tokenURI, string memory productBarcode) external returns (uint256);
    function burnNFT(uint256 tokenId) external;
    function verifyOwnership(address owner, uint256 tokenId, string memory productBarcode) external view returns (bool);
}
