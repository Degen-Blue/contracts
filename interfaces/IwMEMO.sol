// SPDX-License-Identifier: AGPL-3.0-or-later
// DegenBlue Contracts v0.0.1 (interfaces/IwMEMO.sol)

/**
 *  @title IwMEMO
 *  @author pbnather
 *
 *  This interface is meant to be used to interact with the vault contract
 *  by it's `manager`, wich manages bonding and redeeming operations.
 */
pragma solidity ^0.8.0;

interface IwMEMO {
    function wrap(uint256 _amount) external returns (uint256);

    function unwrap(uint256 _amount) external returns (uint256);
}
