// SPDX-License-Identifier: AGPL-3.0-or-later
// DegenBlue Contracts v0.0.1 (interfaces/ITimeAutoBondVault01.sol)

/**
 *  @title ITimeAutoBondVault01
 *  @author pbnather
 *
 *  This interface is meant to be used to interact with the vault contract
 *  by it's `manager`, wich manages bonding and redeeming operations.
 */
pragma solidity ^0.8.0;

interface ITimeAutoBondVault01 {
    function bondWithMim(uint256 _amount, uint256 _slippage)
        external
        returns (uint256);

    function bondWithWeth(uint256 _amount, uint256 _slippage)
        external
        returns (uint256);

    function bondWithTimeMimLP(uint256 _amount, uint256 _slippage)
        external
        returns (uint256);

    function stakeAssets(uint256 _amount) external;

    function redeemMimBond() external returns (uint256);

    function redeemWethBond() external returns (uint256);

    function redeemTimeMimLPBond() external returns (uint256);
}
