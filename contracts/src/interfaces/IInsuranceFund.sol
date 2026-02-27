// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInsuranceFund {
    function receiveFromLiquidation(address token, uint256 amount) external;
    function coverShortfall(address token, uint256 amount) external;
    function fundBalance(address token) external view returns (uint256);
}
