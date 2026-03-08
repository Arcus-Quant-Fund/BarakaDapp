// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVault
 * @notice Central collateral custodian. All tokens flow through here.
 */
interface IVault {
    function deposit(bytes32 subaccount, address token, uint256 amount) external;
    function withdraw(bytes32 subaccount, address token, uint256 amount, address to) external;
    function transferInternal(bytes32 from, bytes32 to, address token, uint256 amount) external;
    function settlePnL(bytes32 subaccount, address token, int256 amount) external returns (int256 actualSettled);
    function chargeFee(bytes32 subaccount, address token, uint256 amount, address recipient) external returns (uint256 charged);
    function balance(bytes32 subaccount, address token) external view returns (uint256);
}
