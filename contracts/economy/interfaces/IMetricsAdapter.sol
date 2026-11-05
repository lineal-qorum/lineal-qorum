
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
interface IMetricsAdapter {
    function getMetrics() external view returns (uint256 alpha, uint256 idp);
}