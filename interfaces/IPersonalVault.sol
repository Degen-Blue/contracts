// SPDX-License-Identifier: AGPL-3.0-or-later
// DegenBlue Contracts v0.0.1 (interfaces/IPersonalVault.sol)

/**
 *  @title IPersonalVault
 *  @author pbnather
 *
 *  This interface is meant to be used to interact with the vault contract
 *  by it's `manager`, wich manages bonding and redeeming operations.
 */
pragma solidity ^0.8.0;

interface IPersonalVault {
    function bond(
        address _depository,
        uint256 _amount,
        uint256 _slippage
    ) external returns (uint256);

    function stakeAssets(uint256 _amount) external;

    function setManaged(bool _managed) external;

    function setMinimumBondingDiscount(uint256 _discount) external;

    function withdraw(uint256 _amount) external;

    function deposit(uint256 _amount) external;

    function redeem(address _depository) external;

    function redeemAllBonds() external;

    function getBondedFunds() external view returns (uint256 _funds);

    function getAllManagedFunds() external view returns (uint256 _funds);
}
