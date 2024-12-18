// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPerpOTMPricing {
    function onOpenPositionPrice(uint256 totalSize, bool isLong) external view returns (uint256);
    function onClosePositionPrice(uint256 totalSize, bool isLong) external view returns (uint256);

    function setOpenFees(uint256 _openFees) external;
    function setCloseFees(uint256 _closeFees) external;
    function setFundingFee(uint256 _fundingFee) external;

    function getFundingFee(uint256 totalSize, bool isLong, uint64 lastFeeAccrued) external view returns (uint256);
}
