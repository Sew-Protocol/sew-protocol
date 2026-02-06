// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMulticall3 } from "../interfaces/IMulticall3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

struct ChainEndpoint {
    uint256 chainId;
    string rpcUrl;
    uint8 priority;
    bool enabled;
}

struct FallbackConfig {
    address fallbackAggregator;
    uint256 fallbackTimeout;
}

contract MulticallFallbackHandler is Ownable {
    IMulticall3 public primaryMulticall;
    FallbackConfig public fallbackConfig;
    mapping(uint256 => ChainEndpoint) public endpoints;

    event PrimaryMulticallSet(address indexed multicall);
    event FallbackConfigUpdated(address indexed fallbackAggregator, uint256 timeout);
    event EndpointUpdated(uint256 indexed chainId, string rpcUrl);
    event FallbackTriggered(uint256 indexed chainId, string reason);

    error InvalidPrimaryMulticall();
    error InvalidChainId();
    error NoEndpoint();
    error EndpointDisabled();

    constructor(
        address _primaryMulticall,
        address _fallbackAggregator,
        uint256 _fallbackTimeout
    ) Ownable(msg.sender) {
        if (_primaryMulticall == address(0)) revert InvalidPrimaryMulticall();
        primaryMulticall = IMulticall3(_primaryMulticall);
        fallbackConfig = FallbackConfig({
            fallbackAggregator: _fallbackAggregator,
            fallbackTimeout: _fallbackTimeout
        });
    }

    function setPrimaryMulticall(address _multicall) external onlyOwner {
        if (_multicall == address(0)) revert InvalidPrimaryMulticall();
        primaryMulticall = IMulticall3(_multicall);
        emit PrimaryMulticallSet(_multicall);
    }

    function setFallbackConfig(
        address _fallbackAggregator,
        uint256 _timeout
    ) external onlyOwner {
        fallbackConfig = FallbackConfig({
            fallbackAggregator: _fallbackAggregator,
            fallbackTimeout: _timeout
        });
        emit FallbackConfigUpdated(_fallbackAggregator, _timeout);
    }

    function addEndpoint(
        uint256 _chainId,
        string calldata _rpcUrl,
        uint8 _priority
    ) external onlyOwner {
        if (_chainId == 0) revert InvalidChainId();
        endpoints[_chainId] = ChainEndpoint({
            chainId: _chainId,
            rpcUrl: _rpcUrl,
            priority: _priority,
            enabled: true
        });
        emit EndpointUpdated(_chainId, _rpcUrl);
    }

    function disableEndpoint(uint256 _chainId) external onlyOwner {
        if (_chainId == 0) revert InvalidChainId();
        endpoints[_chainId].enabled = false;
    }

    function enableEndpoint(uint256 _chainId) external onlyOwner {
        if (_chainId == 0) revert InvalidChainId();
        endpoints[_chainId].enabled = true;
    }

    function executeWithFallback(
        IMulticall3.Call3[] calldata calls,
        uint256 chainId
    )
        external
        returns (
            IMulticall3.Result[] memory results,
            bool usedFallback
        )
    {
        if (!endpoints[chainId].enabled) revert EndpointDisabled();

        try primaryMulticall.aggregate3(calls) returns (
            IMulticall3.Result[] memory primaryResults
        ) {
            uint256 successCount = 0;
            for (uint256 i = 0; i < primaryResults.length; i++) {
                if (primaryResults[i].success) successCount++;
            }

            if (successCount >= (primaryResults.length / 2)) {
                return (primaryResults, false);
            }
        } catch {
            emit FallbackTriggered(chainId, "primary_multicall_failed");
        }

        emit FallbackTriggered(chainId, "low_success_rate");

        return (new IMulticall3.Result[](0), true);
    }

    function getEndpoint(uint256 _chainId)
        external
        view
        returns (ChainEndpoint memory)
    {
        if (!endpoints[_chainId].enabled) revert EndpointDisabled();
        return endpoints[_chainId];
    }

    function isEndpointHealthy(uint256 _chainId)
        external
        view
        returns (bool)
    {
        return endpoints[_chainId].enabled;
    }
}
