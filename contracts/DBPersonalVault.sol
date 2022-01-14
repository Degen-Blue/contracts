// SPDX-License-Identifier: AGPL-3.0-or-later
// DegenBlue Contracts v0.0.2 (contracts/DBPersonalVault.sol)

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/ITimeBondDepository.sol";
import "../interfaces/IJoeRouter01.sol";
import "../interfaces/IBondingHQ.sol";
import "../interfaces/IPersonalVault.sol";
import "../interfaces/IwMEMO.sol";

/**
 *  @title DBPersonalVault
 *  @author pbnather
 *  @dev This contract is an implemention for the proxy personal vaults for (4,4) strategy in ohm-forks.
 *
 *  User, aka `depositor`, deposits TIME or MEMO to the contract, which can be managed by a `manager` address.
 *  If estimated bond 5-day ROI is better than staking 5-day ROI, manager can create a bond.
 *  Estimated 5-day ROI assumes that claimable bond rewards are redeemed close to, but before, each TIME rebase.
 *
 *  Contract has price checks, so that the bond which yields worse estimated 5-day ROI than just staking MEMO
 *  will be reverted (it accounts for the fees and slippage taken).
 *
 *  Manager has only access to functions allowing creating a bond, reedeming a bond, and staking TIME for MEMO.
 *  User has only access to functions allowing depositing, withdrawing, and redeeming a bond.
 *  Contract takes information about bonds depositories from BondingHQ contract
 *
 *  If contract is in MANUAL mode, then only user can make bonds, otherwise, in MANAGED mode, only `manager` can
 *  make bonds. User can also set `minimumBondingDiscount` to only take bonds e.g. above 7% (~11.7% hyperbonding).
 *
 *  Fees are sent to `feeHarvester` on each bond redeem. Admin can change the `feeHarvester` and `manager` addresses.
 *
 *  NOTE: This contract needs to be deployed individually for each user, with `depositor` set for her address.
 */
contract DBPersonalVault is Initializable, Ownable, IPersonalVault {
    using SafeERC20 for IERC20;

    /* ======== STATE VARIABLES ======== */

    IERC20 public asset; // e.g. TIME
    IERC20 public stakedAsset; // e.g. MEMO
    IwMEMO public wrappedAsset; // e.g. wMEMO
    IStaking public stakingContract; // Staking contract
    IBondingHQ public bondingHQ; // Bonding HQ

    address public manager; // Address which can manage bonds
    address public admin; // Admin address
    address public feeHarvester; // Address to send fees to
    uint256 public fee; // Fee taken from each redeem
    uint256 public minimumBondDiscount; // 1% = 100
    bool public isManaged; // If vault is in managed mode

    mapping(address => BondInfo) public bonds;
    address[] public activeBonds;

    /* ======== STRUCTS ======== */

    struct BondInfo {
        uint256 payout; // Time remaining to be paid
        uint256 assetUsed; // Asset amount used
        uint256 vestingEndTime; // Timestamp of bond end
        uint256 maturing; // How much MEMO is maturing
    }

    /* ======== EVENTS ======== */

    event BondCreated(
        uint256 indexed amount,
        address indexed bondedWith,
        uint256 indexed payout
    );
    event BondingDiscountChanged(
        uint256 indexed oldDiscount,
        uint256 indexed newDiscount
    );
    event BondRedeemed(address indexed bondedWith, uint256 indexed payout);
    event AssetsStaked(uint256 indexed amount);
    event AssetsUnstaked(uint256 indexed amount);
    event Withdrawal(uint256 indexed amount);
    event Deposit(uint256 indexed amount);
    event ManagedChanged(bool indexed managed);
    event ManagerChanged(
        address indexed oldManager,
        address indexed newManager
    );
    event FeeHarvesterChanged(
        address indexed oldManager,
        address indexed newManager
    );

    /* ======== INITIALIZATION ======== */

    function init(
        address _bondingHQ,
        address _asset,
        address _stakedAsset,
        address _wrappedAsset,
        address _stakingContract,
        address _manager,
        address _admin,
        address _feeHarvester,
        address _user,
        uint256 _fee,
        uint256 _minimumBondDiscount,
        bool _isManaged
    ) external initializer {
        require(_bondingHQ != address(0));
        bondingHQ = IBondingHQ(_bondingHQ);
        require(_asset != address(0));
        asset = IERC20(_asset);
        require(_stakedAsset != address(0));
        stakedAsset = IERC20(_stakedAsset);
        require(_wrappedAsset != address(0));
        wrappedAsset = IwMEMO(_wrappedAsset);
        require(_stakingContract != address(0));
        stakingContract = IStaking(_stakingContract);
        require(_admin != address(0));
        admin = _admin;
        require(_manager != address(0));
        manager = _manager;
        require(_feeHarvester != address(0));
        feeHarvester = _feeHarvester;
        require(_fee < 10000, "Fee should be less than 100%");
        fee = _fee;
        minimumBondDiscount = _minimumBondDiscount;
        isManaged = _isManaged;
        _transferOwnership(_user);
    }

    /* ======== MODIFIERS ======== */

    modifier managed() {
        if (isManaged) {
            require(
                msg.sender == manager,
                "Only manager can call managed vaults"
            );
        } else {
            require(
                msg.sender == owner(),
                "Only depositor can call manual vaults"
            );
        }
        _;
    }

    /* ======== ADMIN FUNCTIONS ======== */

    function changeManager(address _address) external {
        require(msg.sender == admin);
        require(_address != address(0));
        address old = manager;
        manager = _address;
        emit ManagerChanged(old, _address);
    }

    function changeFeeHarvester(address _address) external {
        require(msg.sender == admin);
        require(_address != address(0));
        address old = feeHarvester;
        feeHarvester = _address;
        emit FeeHarvesterChanged(old, _address);
    }

    /* ======== MANAGER FUNCTIONS ======== */

    function bond(
        address _depository,
        uint256 _amount,
        uint256 _slippage
    ) external override managed returns (uint256) {
        (
            bool usingWrapped,
            bool active,
            bool isLpToken,
            address principle,
            address tokenA,
            ,
            address router
        ) = bondingHQ.getDepositoryInfo(_depository);
        uint256 pathLength = bondingHQ.getDepositoryPathLength(_depository);
        address[] memory path = new address[](pathLength);
        require(
            principle != address(0) && active,
            "Depository doesn't exist or is inactive"
        );
        for (uint256 i = 0; i < pathLength; i++) {
            path[i] = bondingHQ.getDepositoryPathAt(i, _depository);
        }
        if (isLpToken) {
            return
                _bondWithAssetTokenLp(
                    IERC20(tokenA),
                    IERC20(principle),
                    ITimeBondDepository(_depository),
                    IJoeRouter01(router),
                    _amount,
                    _slippage,
                    usingWrapped,
                    path
                );
        } else {
            return
                _bondWithToken(
                    IERC20(principle),
                    ITimeBondDepository(_depository),
                    IJoeRouter01(router),
                    _amount,
                    _slippage,
                    usingWrapped,
                    path
                );
        }
    }

    function stakeAssets(uint256 _amount) public override managed {
        require(asset.balanceOf(address(this)) >= _amount, "Not enough tokens");
        asset.approve(address(stakingContract), _amount);
        stakingContract.stake(_amount, address(this));
        stakingContract.claim(address(this));
        emit AssetsStaked(_amount);
    }

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @dev Set MANAGED mode (true), or MANUAL mode (false).
     */
    function setManaged(bool _managed) external override onlyOwner {
        require(isManaged != _managed, "Cannot set mode to current mode");
        isManaged = _managed;
        emit ManagedChanged(_managed);
    }

    /**
     *  @dev Set minimum bonding discount. If bonded ROI is less than the set minimum discount,
     *  bond won't be created and transcation will revert.
     *
     *  @param _discount bonding discount percentage (1% = 100)
     */
    function setMinimumBondingDiscount(uint256 _discount)
        external
        override
        onlyOwner
    {
        require(
            minimumBondDiscount != _discount,
            "New discount value is the same as current one"
        );
        uint256 old = minimumBondDiscount;
        minimumBondDiscount = _discount;
        emit BondingDiscountChanged(old, _discount);
    }

    function withdraw(uint256 _amount) external override onlyOwner {
        require(
            stakedAsset.balanceOf(address(this)) >= _amount,
            "Not enough tokens"
        );
        stakedAsset.safeTransfer(owner(), _amount);
        emit Withdrawal(_amount);
    }

    /**
     *  @notice Anybody can top up the vault, but only depositor will be able to withdraw.
     *  For personal vaults it's the same as sending stakedAsset to the contract address.
     */
    function deposit(uint256 _amount) external override {
        require(
            stakedAsset.balanceOf(msg.sender) >= _amount,
            "Not enough tokens"
        );
        stakedAsset.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(_amount);
    }

    /**
     *  @notice This function is callable by anyone just in case manager is not working.
     */
    function redeem(address _depository) external override {
        require(
            bondingHQ.depositoryExists(_depository, false),
            "Depository doesn't exist or is inactive"
        );
        _redeemBondFrom(ITimeBondDepository(_depository), true);
    }

    /**
     *  @notice This function is callable by anyone just in case manager is not working.
     */
    function redeemAllBonds() external override {
        for (uint256 i = 0; i < activeBonds.length; i++) {
            _redeemBondFrom(ITimeBondDepository(activeBonds[i]), false);
        }
        _removeAllFinishedBonds();
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @dev This function checks if taken bond is profitable after fees.
     *  It estimates using precomputed magic number what's the minimum viable 5-day ROI
     *  (assmuing redeemeing before all the rebases), versus staking MEMO.
     *  It also checks if minimum bonding discount set by the user is reached.
     */
    function isBondProfitable(uint256 _bonded, uint256 _payout)
        public
        view
        returns (bool _profitable)
    {
        require(_payout > _bonded, "Bond cannot have negative ROI");
        uint256 bondingROI = ((10000 * _payout) / _bonded) - 10000; // 1% = 100
        require(
            bondingROI >= minimumBondDiscount,
            "Bonding discount lower than threshold"
        );
        (, uint256 stakingReward, , ) = stakingContract.epoch();
        IMemories memories = IMemories(address(stakedAsset));
        uint256 circualtingSupply = memories.circulatingSupply();
        uint256 stakingROI = (100000 * stakingReward) / circualtingSupply;
        uint256 magicNumber = 2 * (60 + (stakingROI / 100));
        uint256 minimumBonding = (100 * stakingROI) / magicNumber;
        _profitable = bondingROI >= minimumBonding;
    }

    function getActiveBondsLength() public view override returns (uint256) {
        return activeBonds.length;
    }

    function getBondedFunds() public view override returns (uint256 _funds) {
        for (uint256 i = 0; i < activeBonds.length; i++) {
            _funds += bonds[activeBonds[i]].payout;
        }
    }

    function getAllManagedFunds()
        external
        view
        override
        returns (uint256 _funds)
    {
        _funds += getBondedFunds();
        _funds += stakedAsset.balanceOf(address(this));
        _funds += asset.balanceOf(address(this));
    }

    /* ======== INTERNAL FUNCTIONS ======== */

    function _bondWithToken(
        IERC20 _token,
        ITimeBondDepository _depository,
        IJoeRouter01 _router,
        uint256 _amount,
        uint256 _slippage,
        bool _usingWrapped,
        address[] memory _path
    ) internal returns (uint256) {
        uint256 amount;
        if (_usingWrapped) {
            stakedAsset.approve(address(wrappedAsset), _amount);
            amount = wrappedAsset.wrap(_amount);
        } else {
            _unstakeAssets(_amount);
            amount = _amount;
        }
        uint256 received = _sellAssetFor(
            _usingWrapped ? IERC20(address(wrappedAsset)) : asset,
            _token,
            _router,
            amount,
            _slippage,
            _path
        );
        uint256 payout = _bondWith(_token, received, _depository);
        require(
            isBondProfitable(_amount, payout),
            "Bonding rate worse than staking"
        );
        _addBondInfo(address(_depository), payout, _amount);
        emit BondCreated(_amount, address(_token), payout);
        return payout;
    }

    function _bondWithAssetTokenLp(
        IERC20 _token,
        IERC20 _lpToken,
        ITimeBondDepository _depository,
        IJoeRouter01 _router,
        uint256 _amount,
        uint256 _slippage,
        bool _usingWrapped,
        address[] memory _path
    ) internal returns (uint256) {
        uint256 amount;
        if (_usingWrapped) {
            stakedAsset.approve(address(wrappedAsset), _amount);
            amount = wrappedAsset.wrap(_amount);
        } else {
            _unstakeAssets(_amount);
            amount = _amount;
        }
        uint256 received = _sellAssetFor(
            _usingWrapped ? IERC20(address(wrappedAsset)) : asset,
            _token,
            _router,
            amount / 2,
            _slippage,
            _path
        );
        uint256 remaining = amount - (amount / 2);
        uint256 usedAsset = _addLiquidityFor(
            _token,
            _usingWrapped ? IERC20(address(wrappedAsset)) : asset,
            received,
            remaining,
            _router
        );

        // Stake not used assets
        if (usedAsset < remaining) {
            if (_usingWrapped) {
                usedAsset = wrappedAsset.unwrap(remaining - usedAsset);
            } else {
                stakeAssets(remaining - usedAsset);
                usedAsset = remaining - usedAsset;
            }
        }

        uint256 lpAmount = _lpToken.balanceOf(address(this));
        uint256 payout = _bondWith(_lpToken, lpAmount, _depository);
        require(
            isBondProfitable(_amount - usedAsset, payout),
            "Bonding rate worse than staking"
        );
        _addBondInfo(address(_depository), payout, _amount - usedAsset);
        emit BondCreated(_amount - usedAsset, address(_lpToken), payout);
        return payout;
    }

    /**
     *  @dev This function swaps {@param _asset} for sepcified {@param _token} via {@param _router}.
     */
    function _sellAssetFor(
        IERC20 _asset,
        IERC20 _token,
        IJoeRouter01 _router,
        uint256 _amount,
        uint256 _slippage,
        address[] memory _path
    ) internal returns (uint256) {
        require(_path[0] == address(_asset));
        require(_path[_path.length - 1] == address(_token));
        uint256[] memory amounts = _router.getAmountsOut(_amount, _path);
        uint256 minOutput = (amounts[amounts.length - 1] *
            (10000 - _slippage)) / 10000;
        _asset.approve(address(_router), _amount);
        uint256[] memory results = _router.swapExactTokensForTokens(
            _amount,
            minOutput,
            _path,
            address(this),
            block.timestamp + 60
        );
        return results[results.length - 1];
    }

    /**
     *  @dev This function adds liquidity for specified tokens via dex {@param _router}.
     *  @notice This function tries to maximize usage of first token {@param _tokenA}.
     */
    function _addLiquidityFor(
        IERC20 _tokenA,
        IERC20 _tokenB,
        uint256 _amountA,
        uint256 _amountB,
        IJoeRouter01 _router
    ) internal returns (uint256) {
        _tokenA.approve(address(_router), _amountA);
        _tokenB.approve(address(_router), _amountB);
        (, uint256 assetSent, ) = _router.addLiquidity(
            address(_tokenA),
            address(_tokenB),
            _amountA,
            _amountB,
            (_amountA * 995) / 1000,
            (_amountB * 995) / 1000,
            address(this),
            block.timestamp + 60
        );
        return assetSent;
    }

    /**
     * @dev This function mints a bond with a {@param _token}, using bond {@param _depository}.
     */
    function _bondWith(
        IERC20 _token,
        uint256 _amount,
        ITimeBondDepository _depository
    ) internal returns (uint256 _payout) {
        require(
            _token.balanceOf(address(this)) >= _amount,
            "Not enough tokens"
        );
        _token.approve(address(_depository), _amount);
        uint256 maxBondPrice = _depository.bondPrice();
        _payout = _depository.deposit(_amount, maxBondPrice, address(this));
    }

    function _redeemBondFrom(ITimeBondDepository _depository, bool _delete)
        internal
        returns (uint256)
    {
        if (bonds[address(_depository)].payout == 0) {
            return 0;
        }
        uint256 amount = _depository.redeem(address(this), true);
        uint256 feeValue = (amount * fee) / 10000;
        uint256 redeemed = amount - feeValue;
        bonds[address(_depository)].payout -= amount;
        if (_delete && bonds[address(_depository)].payout == 0) {
            _removeBondInfo(address(_depository));
        }
        stakedAsset.safeTransfer(feeHarvester, feeValue);
        emit BondRedeemed(address(_depository), redeemed);
        return redeemed;
    }

    function _unstakeAssets(uint256 _amount) internal {
        stakedAsset.approve(address(stakingContract), _amount);
        stakingContract.unstake(_amount, false);
        emit AssetsUnstaked(_amount);
    }

    function _addBondInfo(
        address _depository,
        uint256 _payout,
        uint256 _assetsUsed
    ) internal {
        if (bonds[address(_depository)].payout == 0) {
            activeBonds.push(address(_depository));
        }
        bonds[address(_depository)] = BondInfo({
            payout: bonds[address(_depository)].payout + _payout,
            assetUsed: bonds[address(_depository)].assetUsed + _assetsUsed,
            vestingEndTime: block.timestamp + 5 days,
            maturing: bonds[address(_depository)].maturing + _payout
        });
    }

    function _removeBondInfo(address _depository) internal {
        bonds[address(_depository)].payout = 0;
        bonds[address(_depository)].maturing = 0;
        bonds[address(_depository)].assetUsed = 0;
        for (uint256 i = 0; i < activeBonds.length; i++) {
            if (activeBonds[i] == _depository) {
                activeBonds[i] = activeBonds[activeBonds.length - 1];
                activeBonds.pop();
                break;
            }
        }
    }

    function _removeAllFinishedBonds() internal {
        uint256 length = activeBonds.length;
        uint256 checked = 0;
        uint256 index = length - 1;
        while (checked != length) {
            if (bonds[activeBonds[index]].payout == 0) {
                _removeBondInfo(activeBonds[index]);
            }
            checked += 1;
            if (index != 0) {
                index -= 1;
            }
        }
    }

    /* ======== AUXILLIARY ======== */

    /**
     *  @notice allow anyone to send lost tokens (stakedAsset) to the vault owner.
     *  @return bool
     */
    function recoverLostToken(IERC20 _token) external returns (bool) {
        require(_token != stakedAsset, "Use withdraw function");
        uint256 balance = _token.balanceOf(address(this));
        _token.safeTransfer(admin, balance);
        return true;
    }
}
