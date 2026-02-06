// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMulticall3 } from "../interfaces/IMulticall3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

struct EscrowQuery {
    uint256 chainId;
    address escrowAddress;
}

struct EscrowBalanceData {
    uint256 chainId;
    address escrowAddress;
    uint256 escrowBalance;
    uint256 userBalance;
    bool active;
    bool success;
}

struct MultiL2EscrowSnapshot {
    address user;
    EscrowBalanceData[] escrows;
    uint256 totalLocked;
    uint256 timestamp;
    uint8 healthyChains;
}

contract MultiL2EscrowAggregator is Ownable {
    IMulticall3 public multicall3;
    address public usdcAddress;

    event QueryExecuted(address indexed user, uint256 escrowCount);
    event MulticallAddressUpdated(address indexed newAddress);
    event USDCAddressUpdated(address indexed newAddress);

    error InvalidMulticallAddress();
    error InvalidUSDCAddress();
    error EmptyEscrowList();
    error CallFailures(uint256 failureCount);

    constructor(address _multicall3, address _usdc) Ownable(msg.sender) {
        if (_multicall3 == address(0)) revert InvalidMulticallAddress();
        if (_usdc == address(0)) revert InvalidUSDCAddress();
        multicall3 = IMulticall3(_multicall3);
        usdcAddress = _usdc;
    }

    function setMulticall3(address _multicall3) external onlyOwner {
        if (_multicall3 == address(0)) revert InvalidMulticallAddress();
        multicall3 = IMulticall3(_multicall3);
        emit MulticallAddressUpdated(_multicall3);
    }

    function setUSDCAddress(address _usdc) external onlyOwner {
        if (_usdc == address(0)) revert InvalidUSDCAddress();
        usdcAddress = _usdc;
        emit USDCAddressUpdated(_usdc);
    }

    function queryEscrows(
        address user,
        EscrowQuery[] calldata escrows
    )
        external
        returns (MultiL2EscrowSnapshot memory snapshot)
    {
        if (escrows.length == 0) revert EmptyEscrowList();

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](
            escrows.length * 2
        );

        for (uint256 i = 0; i < escrows.length; i++) {
            uint256 baseIdx = i * 2;

            calls[baseIdx] = IMulticall3.Call3({
                target: escrows[i].escrowAddress,
                callData: abi.encodeWithSignature("balanceOf(address)", user),
                allowFailure: true
            });

            calls[baseIdx + 1] = IMulticall3.Call3({
                target: escrows[i].escrowAddress,
                callData: abi.encodeWithSignature("isActive()"),
                allowFailure: true
            });
        }

        IMulticall3.Result[] memory results = multicall3.aggregate3(calls);

        snapshot.user = user;
        snapshot.timestamp = block.timestamp;
        snapshot.healthyChains = 0;

        EscrowBalanceData[] memory data = new EscrowBalanceData[](
            escrows.length
        );

        for (uint256 i = 0; i < escrows.length; i++) {
            uint256 balanceIdx = i * 2;
            uint256 activeIdx = i * 2 + 1;

            data[i].chainId = escrows[i].chainId;
            data[i].escrowAddress = escrows[i].escrowAddress;
            data[i].success = results[balanceIdx].success && results[activeIdx].success;

            if (data[i].success) {
                data[i].userBalance = abi.decode(results[balanceIdx].returnData, (uint256));
                data[i].active = abi.decode(results[activeIdx].returnData, (bool));

                snapshot.totalLocked += data[i].userBalance;
                snapshot.healthyChains++;
            }
        }

        snapshot.escrows = data;

        emit QueryExecuted(user, escrows.length);

        return snapshot;
    }

    function queryEscrowsWithUSDC(
        address user,
        EscrowQuery[] calldata escrows
    )
        external
        returns (MultiL2EscrowSnapshot memory snapshot)
    {
        if (escrows.length == 0) revert EmptyEscrowList();

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](
            escrows.length * 3
        );

        for (uint256 i = 0; i < escrows.length; i++) {
            uint256 baseIdx = i * 3;

            calls[baseIdx] = IMulticall3.Call3({
                target: escrows[i].escrowAddress,
                callData: abi.encodeWithSignature("balanceOf(address)", user),
                allowFailure: true
            });

            calls[baseIdx + 1] = IMulticall3.Call3({
                target: escrows[i].escrowAddress,
                callData: abi.encodeWithSignature("isActive()"),
                allowFailure: true
            });

            calls[baseIdx + 2] = IMulticall3.Call3({
                target: usdcAddress,
                callData: abi.encodeWithSignature("balanceOf(address)", user),
                allowFailure: true
            });
        }

        IMulticall3.Result[] memory results = multicall3.aggregate3(calls);

        snapshot.user = user;
        snapshot.timestamp = block.timestamp;
        snapshot.healthyChains = 0;

        EscrowBalanceData[] memory data = new EscrowBalanceData[](
            escrows.length
        );

        for (uint256 i = 0; i < escrows.length; i++) {
            uint256 balanceIdx = i * 3;
            uint256 activeIdx = i * 3 + 1;

            data[i].chainId = escrows[i].chainId;
            data[i].escrowAddress = escrows[i].escrowAddress;
            data[i].success = results[balanceIdx].success && results[activeIdx].success;

            if (data[i].success) {
                data[i].userBalance = abi.decode(results[balanceIdx].returnData, (uint256));
                data[i].active = abi.decode(results[activeIdx].returnData, (bool));

                snapshot.totalLocked += data[i].userBalance;
                snapshot.healthyChains++;
            }
        }

        snapshot.escrows = data;

        emit QueryExecuted(user, escrows.length);

        return snapshot;
    }
}
