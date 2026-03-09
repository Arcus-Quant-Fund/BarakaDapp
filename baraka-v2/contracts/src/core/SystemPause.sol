// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SystemPause — Global Kill Switch
/// @notice AUDIT FIX (P16-UP-H2): Atomic pause/unpause for all registered protocol contracts.
/// @dev The owner (multisig) or guardian can call pauseAll() to pause every registered contract
///      in a single transaction. Individual contracts retain their own pause() for granular control.
interface IPausable {
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

contract SystemPause is Ownable2Step {
    address public guardian;
    address[] public targets;
    mapping(address => bool) public isRegistered;

    event TargetRegistered(address indexed target);
    event TargetRemoved(address indexed target);
    event GlobalPause(address indexed caller);
    event GlobalUnpause(address indexed caller);
    event GuardianSet(address indexed guardian);

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian, "SP: not owner or guardian");
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function renounceOwnership() public pure override {
        revert("SP: cannot renounce");
    }

    function setGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "SP: zero address");
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    function registerTarget(address target) external onlyOwner {
        require(target != address(0), "SP: zero address");
        require(!isRegistered[target], "SP: already registered");
        targets.push(target);
        isRegistered[target] = true;
        emit TargetRegistered(target);
    }

    function removeTarget(address target) external onlyOwner {
        require(isRegistered[target], "SP: not registered");
        isRegistered[target] = false;
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == target) {
                targets[i] = targets[targets.length - 1];
                targets.pop();
                break;
            }
        }
        emit TargetRemoved(target);
    }

    function pauseAll() external onlyOwnerOrGuardian {
        for (uint256 i = 0; i < targets.length; i++) {
            try IPausable(targets[i]).pause() {} catch {}
        }
        emit GlobalPause(msg.sender);
    }

    function unpauseAll() external onlyOwner {
        for (uint256 i = 0; i < targets.length; i++) {
            try IPausable(targets[i]).unpause() {} catch {}
        }
        emit GlobalUnpause(msg.sender);
    }

    function targetCount() external view returns (uint256) {
        return targets.length;
    }

    function allPaused() external view returns (bool) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (!IPausable(targets[i]).paused()) return false;
        }
        return targets.length > 0;
    }
}
