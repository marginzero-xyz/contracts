// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract PerpOTMPricing is Ownable {
    // Fees are stored as basis points (1/10000)
    uint256 public openFees = 5;
    uint256 public closeFees = 0;
    uint256 public fundingFeeRate = 5; // 0.05% daily rate

    constructor() Ownable(msg.sender) {}

    function onOpenPositionPrice(uint256 totalSize, bool isLong) external view returns (uint256) {
        if (openFees == 0) return 0;
        return (totalSize * openFees) / 10000;
    }

    function onClosePositionPrice(uint256 totalSize, bool isLong) external view returns (uint256) {
        if (closeFees == 0) return 0;
        return (totalSize * closeFees) / 10000;
    }

    function setOpenFees(uint256 _openFees) external onlyOwner {
        openFees = _openFees;
    }

    function setCloseFees(uint256 _closeFees) external onlyOwner {
        closeFees = _closeFees;
    }

    function setFundingFeeRate(uint256 _fundingFeeRate) external onlyOwner {
        fundingFeeRate = _fundingFeeRate;
    }

    function getFundingFee(uint256 totalSize, bool isLong, uint64 lastFeeAccrued) external view returns (uint256) {
        if (fundingFeeRate == 0) return 0;
        uint256 timeElapsed = block.timestamp - lastFeeAccrued;
        // Calculate the fee based on the daily rate, adjusted for the time elapsed
        return (totalSize * fundingFeeRate * timeElapsed) / (1 days * 10000);
    }
}
