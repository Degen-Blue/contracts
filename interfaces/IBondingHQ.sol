// SPDX-License-Identifier: AGPL-3.0-or-later
// DegenBlue Contracts v0.0.1 (interfaces/IBondingHQ.sol)

/**
 *  @title IBondingHQ
 *  @author pbnather
 *
 *  This interface is meant to be used to interact with the vault contract
 *  by it's `manager`, wich manages bonding and redeeming operations.
 */
pragma solidity ^0.8.0;

interface IBondingHQ {
    function getDepositoryPathLength(address _depository)
        external
        view
        returns (uint256);

    function getDepositoryPathAt(uint256 _index, address _depository)
        external
        view
        returns (address path);

    function getDepositoryInfo(address _depository)
        external
        view
        returns (
            bool _usingWrapped,
            bool _active,
            bool _isLpToken,
            address _principle,
            address _tokenA,
            address _tokenB,
            address _router
        );

    function depositoryExists(address _depository, bool _onlyActive)
        external
        view
        returns (bool);
}
