// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IESH {
    function mintNFT(address recipient, string memory tokenURI, string memory productBarcode) external returns (uint256);
}
