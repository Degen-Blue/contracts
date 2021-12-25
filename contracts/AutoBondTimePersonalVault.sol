// SPDX-License-Identifier: AGPL-3.0-or-later
// DegenBlue Contracts v0.0.1 (contracts/AutoBondTimePersonalVault.sol)

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ITimeBondDepository.sol";
import "../interfaces/IJoeRouter01.sol";
import "../interfaces/ITimeAutoBondVault01.sol";

/**
 *  @title AutoBondPersonalVault
 *  @author pbnather
 *  @dev This contract allows for managing bonds in Wonderland.money for a single user.
 *
 *  User, aka `depositor`, sends TIME or MEMO to the contract, which can be managed by `manager` address.
 *  If estimated bond 5-day ROI is better than staking 5-day ROI, manager can create a bond.
 *  Estimated 5-day ROI assumes that claimable bond rewards are redeemed close to, but before, each TIME rebase.
 *
 *  Contract has price checks, so that the bond which yields worse estimated 5-day ROI than just staking MEMO
 *  will be reverted (it accounts for the fees and slippage taken).
 *  Manager has only access to functions allowing creating a bond, reedeming a bond, and staking TIME for MEMO.
 *  User has only access to functions allowing depositing, withdrawing, and redeeming a bond.
 *
 *  Fees are sent to `admin` on each bond redeem. Admin can also change the `manager` address.
 *
 *  NOTE: This contract needs to be deployed individually for each user, with `depositor` set for her address.
 */
contract AutoBondTimePersonalVault is ITimeAutoBondVault01 {
    using SafeERC20 for IERC20;

    /* ======== EVENTS ======== */

    event BondCreated(
        uint256 indexed amount,
        address indexed bondedWith,
        uint256 indexed payout
    );
    event BondRedeemed(address indexed bondedWith, uint256 indexed payout);
    event BondingAllowed(bool indexed allowed);
    event AssetsStaked(uint256 indexed amount);
    event AssetsUnstaked(uint256 indexed amount);
    event ManagerChanged(
        address indexed oldManager,
        address indexed newManager
    );

    /* ======== STATE VARIABLES ======== */

    ITimeBondDepository public immutable mimBondDepository;
    ITimeBondDepository public immutable wethBondDepository;
    ITimeBondDepository public immutable timeMimLpBondDepository;
    IJoeRouter01 public immutable joeRouter;
    IStaking public immutable staking;
    IERC20 public immutable asset; // e.g. TIME
    IERC20 public immutable stakedAsset; // e.g. MEMO
    IERC20 public immutable mim;
    IERC20 public immutable weth;
    IERC20 public immutable timeMimJLP;
    address public immutable depositor; // address allowed to withdraw funds
    address public immutable admin; // address to send fees
    uint256 public immutable fee; // fee taken from each redeem
    address public manager; // address which can manage bonds
    bool public isBondingAllowed;
    uint256 constant UINT_MAX = 2**256 - 1;

    /* ======== INITIALIZATION ======== */

    /**
     *  @dev `_argsIndex`:
     *  0 - asset
     *  1 - stakedAsset
     *  2 - mim
     *  3 - weth
     *  4 - timeMimJLP
     *  5 - depositor
     *  6 - admin
     *  7 - manager
     *  8 - joeRouter
     *  9 - staking
     *  10 - mimBondDepository
     *  11 - wethBondDepository
     *  12 - timeMimLpBondDepository
     */
    constructor(address[] memory _args, uint256 _fee) public {
        require(_args[0] != address(0));
        asset = IERC20(_args[0]);
        require(_args[1] != address(0));
        stakedAsset = IERC20(_args[1]);
        require(_args[2] != address(0));
        mim = IERC20(_args[2]);
        require(_args[3] != address(0));
        weth = IERC20(_args[3]);
        require(_args[4] != address(0));
        timeMimJLP = IERC20(_args[4]);
        require(_args[5] != address(0));
        depositor = _args[5];
        require(_args[6] != address(0));
        admin = _args[6];
        require(_args[7] != address(0));
        manager = _args[7];
        require(_args[8] != address(0));
        joeRouter = IJoeRouter01(_args[8]);
        require(_args[9] != address(0));
        staking = IStaking(_args[9]);
        require(_args[10] != address(0));
        mimBondDepository = ITimeBondDepository(_args[10]);
        require(_args[11] != address(0));
        wethBondDepository = ITimeBondDepository(_args[11]);
        require(_args[12] != address(0));
        timeMimLpBondDepository = ITimeBondDepository(_args[12]);
        require(_fee <= 50, "Fee cannot be greater than 0.5%");
        fee = _fee;
        isBondingAllowed = true;
    }

    modifier only(address _address) {
        require(msg.sender == _address);
        _;
    }

    /* ======== ADMIN FUNCTIONS ======== */

    function changeManager(address _address) external only(admin) {
        require(_address != address(0));
        address old = manager;
        manager = _address;
        emit ManagerChanged(old, _address);
    }

    /* ======== MANAGER FUNCTIONS ======== */

    function bondWithMim(uint256 _amount, uint256 _slippage)
        external
        override
        only(manager)
        returns (uint256)
    {
        return _bondWithToken(mim, mimBondDepository, _amount, _slippage);
    }

    function bondWithWeth(uint256 _amount, uint256 _slippage)
        external
        override
        only(manager)
        returns (uint256)
    {
        return _bondWithToken(weth, wethBondDepository, _amount, _slippage);
    }

    function bondWithTimeMimLP(uint256 _amount, uint256 _slippage)
        external
        override
        only(manager)
        returns (uint256)
    {
        require(
            isBondingAllowed,
            "Bonding not allowed, depositor action required"
        );
        _unstakeAssets(_amount);
        // Sell half TIME for MIM
        uint256 received = _sellAssetFor(mim, _amount / 2, _slippage);
        uint256 remaining = _amount - (_amount / 2);
        // Add liquidity
        uint256 usedAsset = _addLiquidityFor(mim, asset, received, remaining);
        // Bond with TIME-MIM LP
        uint256 lpAmount = timeMimJLP.balanceOf(address(this));
        uint256 payout = _bondWith(
            timeMimJLP,
            lpAmount,
            timeMimLpBondDepository
        );
        // Stake not used assets
        if (usedAsset < remaining) {
            stakeAssets(remaining - usedAsset);
        }

        require(
            isBondProfitable(_amount - remaining + usedAsset, payout),
            "Bonding rate worse than staking"
        );
        emit BondCreated(
            _amount - remaining + usedAsset,
            address(timeMimJLP),
            payout
        );
        return payout;
    }

    function stakeAssets(uint256 _amount) public override only(manager) {
        require(asset.balanceOf(address(this)) >= _amount, "Not enough tokens");
        asset.approve(address(staking), _amount);
        staking.stake(_amount, address(this));
        staking.claim(address(this));
        emit AssetsStaked(_amount);
    }

    /* ======== USER FUNCTIONS ======== */

    function allowBonding(bool _allow) external only(depositor) {
        require(isBondingAllowed != _allow, "State is the same");
        isBondingAllowed = _allow;
        emit BondingAllowed(_allow);
    }

    function withdraw(uint256 _amount, bool _staked) external only(depositor) {
        if (_staked) {
            require(
                stakedAsset.balanceOf(address(this)) >= _amount,
                "Not enough tokens"
            );
            stakedAsset.safeTransfer(depositor, _amount);
        } else {
            require(
                asset.balanceOf(address(this)) >= _amount,
                "Not enough tokens"
            );
            asset.safeTransfer(depositor, _amount);
        }
    }

    /**
     *  @notice Anybody can top up the vault, but only depositor will be able to withdraw.
     *  For personal vaults it's the same as sending stakedAsset to the contract address.
     */
    function deposit(uint256 _amount) external {
        require(
            stakedAsset.balanceOf(msg.sender) >= _amount,
            "Not enough tokens"
        );
        stakedAsset.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     *  @notice This function is callable by anyone just in case manager is not working.
     */
    function redeemMimBond() external override returns (uint256) {
        return _redeemBondFrom(mimBondDepository);
    }

    /**
     *  @notice This function is callable by anyone just in case manager is not working.
     */
    function redeemTimeMimLPBond() external override returns (uint256) {
        return _redeemBondFrom(timeMimLpBondDepository);
    }

    /**
     *  @notice This function is callable by anyone just in case manager is not working.
     */
    function redeemWethBond() external override returns (uint256) {
        return _redeemBondFrom(wethBondDepository);
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @dev this function checks if taken bond is profitable after fees.
     *  It estimates using precomputed magic number what's the minimum viable 5-day ROI
     *  (assmuing redeemeing before all the rebases), versus staking MEMO.
     */
    function isBondProfitable(uint256 _bonded, uint256 _payout)
        public
        view
        returns (bool _profitable)
    {
        uint256 bondingROI = ((10000 * _payout) / _bonded) - 10000; // 1% = 100
        (, uint256 stakingReward, , ) = staking.epoch();
        IMemories memories = IMemories(address(stakedAsset));
        uint256 circualtingSupply = memories.circulatingSupply();
        uint256 stakingROI = (100000 * stakingReward) / circualtingSupply;
        uint256 magicNumber = 2 * (60 + (stakingROI / 100));
        uint256 minimumBonding = (100 * stakingROI) / magicNumber;
        _profitable = bondingROI >= minimumBonding;
    }

    function PendingBondFor(ITimeBondDepository _depository)
        external
        view
        returns (uint256)
    {
        return _depository.pendingPayoutFor(address(this));
    }

    /* ======== INTERNAL FUNCTIONS ======== */

    function _bondWithToken(
        IERC20 _token,
        ITimeBondDepository _depository,
        uint256 _amount,
        uint256 _slippage
    ) internal returns (uint256) {
        require(
            isBondingAllowed,
            "Bonding not allowed, depositor action required"
        );
        _unstakeAssets(_amount);
        uint256 received = _sellAssetFor(_token, _amount, _slippage);
        uint256 payout = _bondWith(_token, received, _depository);
        require(
            isBondProfitable(_amount, payout),
            "Bonding rate worse than staking"
        );
        emit BondCreated(_amount, address(_token), payout);
        return payout;
    }

    /**
     *  @dev This function swaps assets for sepcified token via TraderJoe.
     *  @notice Slippage cannot exceed 1.5%.
     */
    function _sellAssetFor(
        IERC20 _token,
        uint256 _amount,
        uint256 _slippage
    ) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(asset);
        path[1] = address(_token);
        uint256[] memory amounts = joeRouter.getAmountsOut(_amount, path);
        require(_slippage <= 150, "Slippage greater than 1.5%");
        uint256 minOutput = (amounts[1] * (10000 - _slippage)) / 10000;
        asset.approve(address(joeRouter), _amount);
        uint256[] memory results = joeRouter.swapExactTokensForTokens(
            _amount,
            minOutput,
            path,
            address(this),
            block.timestamp + 60
        );
        return results[1];
    }

    /**
     *  @dev This function adds liquidity for specified tokens on TraderJoe.
     *  @notice This function tries to maximize usage of first token {_tokenA}.
     */
    function _addLiquidityFor(
        IERC20 _tokenA,
        IERC20 _tokenB,
        uint256 _amountA,
        uint256 _amountB
    ) internal returns (uint256) {
        _tokenA.approve(address(joeRouter), _amountA);
        _tokenB.approve(address(joeRouter), _amountB);
        (, uint256 assetSent, ) = joeRouter.addLiquidity(
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
     * @dev This function adds liquidity for specified tokens on TraderJoe.
     */
    function _bondWith(
        IERC20 _token,
        uint256 _amount,
        ITimeBondDepository _depository
    ) internal returns (uint256 _payout) {
        _token.approve(address(_depository), _amount);
        uint256 maxBondPrice = _depository.bondPrice();
        _payout = _depository.deposit(_amount, maxBondPrice, address(this));
    }

    function _redeemBondFrom(ITimeBondDepository _depository)
        internal
        returns (uint256)
    {
        uint256 amount = _depository.redeem(address(this), true);
        uint256 feeValue = (amount * fee) / 10000;
        stakedAsset.safeTransfer(admin, feeValue);
        uint256 redeemed = amount - feeValue;
        emit BondRedeemed(address(_depository), redeemed);
        return redeemed;
    }

    function _unstakeAssets(uint256 _amount) internal {
        require(
            stakedAsset.balanceOf(address(this)) >= _amount,
            "Not enough tokens"
        );
        stakedAsset.approve(address(staking), _amount);
        staking.unstake(_amount, false);
        emit AssetsUnstaked(_amount);
    }

    /* ======== AUXILLIARY ======== */

    /**
     *  @notice allow anyone to send lost tokens (excluding asset and stakedAsset) to the admin
     *  @return bool
     */
    function recoverLostToken(IERC20 _token) external returns (bool) {
        require(_token != asset, "NAT");
        require(_token != stakedAsset, "NAP");
        uint256 balance = _token.balanceOf(address(this));
        _token.safeTransfer(admin, balance);
        return true;
    }
}
