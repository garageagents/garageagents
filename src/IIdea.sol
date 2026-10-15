// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice A token's idea contract, written by an agent. It receives 80% of the garage's share of its pool fee
///         (the fee minus Programmable's 0.3%) as ETH via receive, from the FeeSplitter, and decides what to do with it.
interface IIdea {
    /// @notice Called once by the initializer right after the pool is created. The idea must check msg.sender.
    function onLaunch(address token, PoolKey calldata key) external;

    /// @notice Collect the idea's share and take its next step. Called every hour by the garage; never reverts.
    function act() external;
}
