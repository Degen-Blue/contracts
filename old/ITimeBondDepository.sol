// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITreasury {
    function deposit(
        uint256 _amount,
        address _token,
        uint256 _profit
    ) external returns (bool);

    function valueOf(address _token, uint256 _amount)
        external
        view
        returns (uint256 value_);
}

interface IBondCalculator {
    function valuation(address _LP, uint256 _amount)
        external
        view
        returns (uint256);

    function markdown(address _LP) external view returns (uint256);
}

interface IMemories {
    function circulatingSupply() external view returns (uint256);
}

interface IStaking {
    function epoch()
        external
        view
        returns (
            uint256 number,
            uint256 distribute,
            uint32 length,
            uint32 endTime
        );

    function claim(address _recipient) external;

    function stake(uint256 _amount, address _recipient) external returns (bool);

    function unstake(uint256 _amount, bool _trigger) external;
}

interface IStakingHelper {
    function stake(uint256 _amount, address _recipient) external;
}

interface ITimeBondDepository {
    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint256 controlVariable; // scaling variable for price
        uint256 minimumPrice; // vs principle value
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
        uint32 vestingTerm; // in seconds
    }

    // Info for bond holder
    struct Bond {
        uint256 payout; // Time remaining to be paid
        uint256 pricePaid; // In DAI, for front end viewing
        uint32 lastTime; // Last interaction
        uint32 vesting; // Seconds left to vest
    }

    // Info for incremental adjustments to control variable
    struct Adjust {
        bool add; // addition or subtraction
        uint256 rate; // increment
        uint256 target; // BCV when adjustment finished
        uint32 buffer; // minimum length (in seconds) between adjustments
        uint32 lastTime; // time when last adjustment made
    }

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     */
    function deposit(
        uint256 _amount,
        uint256 _maxPrice,
        address _depositor
    ) external returns (uint256);

    /**
     *  @notice redeem bond for user
     *  @param _recipient address
     *  @param _stake bool
     *  @return uint
     */
    function redeem(address _recipient, bool _stake) external returns (uint256);

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() external view returns (uint256);

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor(uint256 _value) external view returns (uint256);

    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() external view returns (uint256 price_);

    /**
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() external view returns (uint256 price_);

    /**
     *  @notice calculate current ratio of debt to Time supply
     *  @return debtRatio_ uint
     */
    function debtRatio() external view returns (uint256 debtRatio_);

    /**
     *  @notice debt ratio in same terms for reserve or liquidity bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns (uint256);

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() external view returns (uint256);

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() external view returns (uint256 decay_);

    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested_ uint
     */
    function percentVestedFor(address _depositor)
        external
        view
        returns (uint256 percentVested_);

    /**
     *  @notice calculate amount of Time available for claim by depositor
     *  @param _depositor address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor(address _depositor)
        external
        view
        returns (uint256 pendingPayout_);

    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or Time) to the DAO
     *  @return bool
     */
    function recoverLostToken(IERC20 _token) external returns (bool);
}
