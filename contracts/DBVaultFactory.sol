// SPDX-License-Identifier: AGPL-3.0-or-later
// DegenBlue Contracts v0.0.1 (contracts/DBVaultFactory.sol)

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./DBPersonalVault.sol";
import "../interfaces/IBondingHQ.sol";

/**
 *  @title DBVaultFactory
 *  @author pbnather
 *  @dev This contract is a factory for Degen Blue Personal Vaults.
 *  It also stores bond depositories information and can update vaults'
 *  underlying implementation to the new vault contract.
 *
 *  @notice Owner should be set to a timelocked contract, controlled by the multisig.
 *  Otherwise owner is able to steal users' funds by changing vault implementation or
 *  adding a fake bond depository.
 */
contract DBVaultFactory is UpgradeableBeacon, IBondingHQ {
    /* ======== STATE VARIABLES ======== */
    address public immutable asset;
    address public immutable stakedAsset;
    address public immutable wrappedAsset;
    address public immutable stakingContract;
    address public manager;
    address public feeHarvester;
    address[] public users;
    address[] public depositories;
    mapping(address => address) public userVaults;
    mapping(address => Depository) public depositoryInfo;
    uint256 public fee;
    uint256 public vaultLimit;

    /* ======== STRUCTS ======== */

    struct Depository {
        address principle; // Principle token used for bonding
        address router; // AMM Router to use
        address tokenA; // If LP, token A
        address tokenB; // If LP, token B
        address[] path; // best trade path
        bool isLpToken; // If token is LP
        bool usingWrapped; // If using wrapped token
        bool active; // If depository is active
    }

    /* ======== EVENTS ======== */

    event DepositoryAdded(address indexed depository, Depository info);
    event DepositoryRemoved(address indexed depository);
    event DepositoryDisabled(address indexed depository);
    event DepositoryEnabled(address indexed depository);
    event DepositoryPathUpdated(address indexed depository, address[] path);
    event FeeChanged(uint256 indexed old, uint256 indexed manager);
    event FeeHarvesterChanged(address indexed old, address indexed harvester);
    event ManagerChanged(address indexed old, address indexed manager);
    event VaultCreated(address indexed user, address indexed vault);
    event VaultLimitChanged(uint256 old, uint256 limit);

    /* ======== INITIALIZATION ======== */

    constructor(
        address _implementation,
        address _manager,
        address _asset,
        address _stakedAsset,
        address _wrappedAsset,
        address _stakingContract,
        address _feeHarvester,
        uint256 _fee,
        uint256 _vaultLimit
    ) UpgradeableBeacon(_implementation) {
        require(_manager != address(0));
        manager = _manager;
        require(_asset != address(0));
        asset = _asset;
        require(_stakedAsset != address(0));
        stakedAsset = _stakedAsset;
        require(_wrappedAsset != address(0));
        wrappedAsset = _wrappedAsset;
        require(_stakingContract != address(0));
        stakingContract = _stakingContract;
        require(_feeHarvester != address(0));
        feeHarvester = _feeHarvester;
        require(_fee <= 100, "Fee cannot be greater than 1%");
        fee = _fee;
        vaultLimit = _vaultLimit;
    }

    /* ======== ADMIN FUNCTIONS ======== */

    function addDepository(
        address _depository,
        address _principle,
        address _router,
        address _tokenA,
        address _tokenB,
        address[] memory _path,
        bool _isLPToken,
        bool _usingWrapped,
        bool _active
    ) external onlyOwner {
        require(_depository != address(0));
        require(_principle != address(0));
        require(_router != address(0));
        require(_tokenA != address(0));
        require(_tokenB != address(0));
        require(depositoryInfo[_depository].principle == address(0));
        depositoryInfo[_depository] = Depository({
            principle: _principle,
            router: _router,
            tokenA: _tokenA,
            tokenB: _tokenB,
            path: _path,
            isLpToken: _isLPToken,
            usingWrapped: _usingWrapped,
            active: _active
        });
        depositories.push(_depository);
        emit DepositoryAdded(_depository, depositoryInfo[_depository]);
    }

    function RemoveDepository(address _depository) external onlyOwner {
        require(
            depositoryInfo[_depository].principle != address(0) &&
                !depositoryInfo[_depository].active
        );
        depositoryInfo[_depository].principle = address(0);
        for (uint256 i = 0; i < depositories.length; i++) {
            if (depositories[i] == _depository) {
                depositories[i] = depositories[depositories.length - 1];
                depositories.pop();
                break;
            }
        }
        emit DepositoryRemoved(_depository);
    }

    function EnableDepository(address _depository) external onlyOwner {
        require(
            depositoryInfo[_depository].principle != address(0) &&
                !depositoryInfo[_depository].active
        );
        depositoryInfo[_depository].active = true;
        emit DepositoryEnabled(_depository);
    }

    function DisableDepository(address _depository) external onlyOwner {
        require(
            depositoryInfo[_depository].principle != address(0) &&
                depositoryInfo[_depository].active
        );
        depositoryInfo[_depository].active = false;
        emit DepositoryDisabled(_depository);
    }

    function UpdateDepositoryPath(address _depository, address[] memory _path)
        external
        onlyOwner
    {
        require(depositoryInfo[_depository].principle != address(0));
        depositoryInfo[_depository].path = _path;
        emit DepositoryPathUpdated(_depository, _path);
    }

    function setVaultLimit(uint256 _limit) external onlyOwner {
        uint256 old = vaultLimit;
        vaultLimit = _limit;
        emit VaultLimitChanged(old, _limit);
    }

    /**
     *  @notice Changing fees only affects new vaults.
     *  All exisitng vaults retain their fee.
     */
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee < 10000, "Fee should be less than 100%");
        uint256 old = fee;
        fee = _fee;
        emit FeeChanged(old, _fee);
    }

    function changeManager(address _manager) external onlyOwner {
        require(_manager != address(0));
        address old = manager;
        manager = _manager;
        emit ManagerChanged(old, _manager);
    }

    function changeFeeHarvester(address _feeHarvester) external onlyOwner {
        require(_feeHarvester != address(0));
        address old = feeHarvester;
        manager = _feeHarvester;
        emit FeeHarvesterChanged(old, _feeHarvester);
    }

    function batchChangeManager(address[] memory _users) external onlyOwner {
        for (uint256 i = 0; i < _users.length; i++) {
            require(userVaults[_users[i]] != address(0));
            DBPersonalVault(userVaults[_users[i]]).changeManager(manager);
        }
    }

    function batchChangeFeeHarvester(address[] memory _users)
        external
        onlyOwner
    {
        for (uint256 i = 0; i < _users.length; i++) {
            require(userVaults[_users[i]] != address(0));
            DBPersonalVault(userVaults[_users[i]]).changeFeeHarvester(
                feeHarvester
            );
        }
    }

    /* ======== USER FUNCTIONS ======== */

    function createVault(uint256 _minimumBondDiscount, bool _isManaged)
        external
        returns (address)
    {
        require(userVaults[msg.sender] == address(0));
        BeaconProxy vault = new BeaconProxy(
            address(this),
            abi.encodeWithSelector(
                DBPersonalVault(address(0)).init.selector,
                address(this),
                asset,
                stakedAsset,
                wrappedAsset,
                stakingContract,
                manager,
                address(this),
                feeHarvester,
                msg.sender,
                fee,
                _minimumBondDiscount,
                _isManaged
            )
        );
        users.push(msg.sender);
        userVaults[msg.sender] = address(vault);
        emit VaultCreated(msg.sender, address(vault));
        return address(vault);
    }

    /* ======== MANAGER FUNCTIONS ======== */

    function batchRedeemVaultBonds(address[] memory _users) external {
        for (uint256 i = 0; i < _users.length; i++) {
            require(userVaults[_users[i]] != address(0));
            DBPersonalVault(userVaults[_users[i]]).redeemAllBonds();
        }
    }

    /* ======== VIEW FUNCTIONS ======== */

    function getDepositoriesLength() external view returns (uint256) {
        return depositories.length;
    }

    function getUsersLength() external view returns (uint256) {
        return users.length;
    }

    function getDepositoryPathLength(address _depository)
        external
        view
        override
        returns (uint256)
    {
        return depositoryInfo[_depository].path.length;
    }

    function getDepositoryPathAt(uint256 _index, address _depository)
        external
        view
        override
        returns (address)
    {
        return depositoryInfo[_depository].path[_index];
    }

    function getDepositoryInfo(address _depository)
        external
        view
        override
        returns (
            bool _usingWrapped,
            bool _active,
            bool _isLpToken,
            address _principle,
            address _tokenA,
            address _tokenB,
            address _router
        )
    {
        _usingWrapped = depositoryInfo[_depository].usingWrapped;
        _isLpToken = depositoryInfo[_depository].isLpToken;
        _active = depositoryInfo[_depository].active;
        _principle = depositoryInfo[_depository].principle;
        _tokenA = depositoryInfo[_depository].tokenA;
        _tokenB = depositoryInfo[_depository].tokenB;
        _router = depositoryInfo[_depository].router;
    }

    function depositoryExists(address _depository, bool _onlyActive)
        external
        view
        override
        returns (bool)
    {
        if (depositoryInfo[_depository].principle == address(0)) {
            return false;
        }
        if (_onlyActive) {
            if (!depositoryInfo[_depository].active) {
                return false;
            }
        }
        return true;
    }

    function getAllBondedFunds() external view returns (uint256 _funds) {
        _funds = 0;
        for (uint256 i = 0; i < users.length; i++) {
            _funds += DBPersonalVault(userVaults[users[i]]).getBondedFunds();
        }
    }

    function getAllManagedFunds() external view returns (uint256 _funds) {
        _funds = 0;
        for (uint256 i = 0; i < users.length; i++) {
            _funds += DBPersonalVault(userVaults[users[i]]).getAllManagedFunds();
        }
    }
}
