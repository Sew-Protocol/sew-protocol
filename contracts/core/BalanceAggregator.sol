// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMulticall3 } from "../interfaces/IMulticall3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

struct ChainBalance {
    uint256 chainId;
    uint256 balance;
    bool success;
}

struct L2BalanceSnapshot {
    address user;
    ChainBalance[] balances;
    uint256 timestamp;
    bool healthy;
}

contract BalanceAggregator is Ownable {
    IMulticall3 public multicall3;

    event MultiCall3Updated(address indexed newAddress);
    event BalanceQueried(address indexed user, uint256 chainCount);

    error InvalidMulticall3Address();
    error InvalidChainIds();
    error NoResults();

    constructor(address _multicall3) Ownable(msg.sender) {
        if (_multicall3 == address(0)) revert InvalidMulticall3Address();
        multicall3 = IMulticall3(_multicall3);
    }

    function setMulticall3(address _multicall3) external onlyOwner {
        if (_multicall3 == address(0)) revert InvalidMulticall3Address();
        multicall3 = IMulticall3(_multicall3);
        emit MultiCall3Updated(_multicall3);
    }

    function aggregateBalances(
        address user,
        address[] calldata tokens,
        bytes[] calldata calls
    )
        external
        returns (L2BalanceSnapshot memory snapshot)
    {
        if (calls.length == 0) revert NoResults();

        IMulticall3.Call3[] memory mcalls = new IMulticall3.Call3[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            mcalls[i] = IMulticall3.Call3({
                target: tokens[i],
                callData: calls[i],
                allowFailure: true
            });
        }

        IMulticall3.Result[] memory results = multicall3.aggregate3(mcalls);

        snapshot.user = user;
        snapshot.timestamp = block.timestamp;
        snapshot.healthy = true;

        ChainBalance[] memory balances = new ChainBalance[](results.length);

        for (uint256 i = 0; i < results.length; i++) {
            balances[i].success = results[i].success;
            if (results[i].success) {
                balances[i].balance = abi.decode(results[i].returnData, (uint256));
            } else {
                snapshot.healthy = false;
            }
        }

        snapshot.balances = balances;

        emit BalanceQueried(user, results.length);

        return snapshot;
    }

    function encodeBalanceCall(address token, address user)
        external
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature("balanceOf(address)", user);
    }

    function decodeBalanceResult(bytes memory result)
        external
        pure
        returns (uint256)
    {
        return abi.decode(result, (uint256));
    }
}
