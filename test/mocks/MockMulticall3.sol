// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMulticall3 } from "../../interfaces/IMulticall3.sol";

contract MockMulticall3 is IMulticall3 {
    IMulticall3.Result[] public returnData;

    function setReturnData(IMulticall3.Result[] memory _returnData) external {
        delete returnData;
        for (uint256 i = 0; i < _returnData.length; i++) {
            returnData.push(_returnData[i]);
        }
    }

    function aggregate(Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes[] memory)
    {
        blockNumber = block.number;
        bytes[] memory results = new bytes[](calls.length);
        return (blockNumber, results);
    }

    function aggregate3(Call3[] calldata calls)
        external
        payable
        returns (Result[] memory)
    {
        require(returnData.length >= calls.length, "Insufficient mock data");

        Result[] memory results = new Result[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            results[i] = returnData[i];
        }
        return results;
    }

    function aggregate3Value(Call3Value[] calldata calls)
        external
        payable
        returns (Result[] memory)
    {
        require(returnData.length >= calls.length, "Insufficient mock data");

        Result[] memory results = new Result[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            results[i] = returnData[i];
        }
        return results;
    }

    function blockBasefee() external view returns (uint256 basefee) {
        return block.basefee;
    }

    function getBasefee() external view returns (uint256 basefee) {
        return block.basefee;
    }

    function getBlockHash(uint256 blockNumber)
        external
        view
        returns (bytes32 blockHash)
    {
        return blockhash(blockNumber);
    }

    function getBlockNumber() external view returns (uint256 blockNumber) {
        return block.number;
    }

    function getChainId() external view returns (uint256 chainid) {
        return block.chainid;
    }

    function getCurrentBlockCoinbase() external view returns (address coinbase) {
        return block.coinbase;
    }

    function getCurrentBlockDifficulty()
        external
        view
        returns (uint256 difficulty)
    {
        return 0;
    }

    function getCurrentBlockGasLimit() external view returns (uint256 gaslimit) {
        return block.gaslimit;
    }

    function getCurrentBlockTimestamp()
        external
        view
        returns (uint256 timestamp)
    {
        return block.timestamp;
    }

    function getEthBalance(address addr)
        external
        view
        returns (uint256 balance)
    {
        return addr.balance;
    }

    function getLastBlockHash() external view returns (bytes32 blockHash) {
        return blockhash(block.number - 1);
    }
}
