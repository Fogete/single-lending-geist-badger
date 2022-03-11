// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IRewardsContract} from "../interfaces/aave/IRewardsContract.sol";
import {IRouter} from "../interfaces/IRouter.sol";

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    event Debug(string name, uint256 value);

    // address public want; // Inherited from BaseStrategy 0x321162cd933e2be498cd2267a90534a804051b11
    // address public lpComponent; // Token that represents ownership in a pool, not always used
    // address public reward; // Token we farm

    address public constant REWARD = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7; // Geist

    // Representing balance of deposits
    address public constant aToken = 0x38aca5484b8603373acc6961ecd57a6a594510a3;

    // Representing balance of debt
    address public constant dToken = 0x38aca5484b8603373acc6961ecd57a6a594510a3;

    // wftm
    address private constant weth = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;

    // Spooky Router
    IRouter public constant ROUTER = IRouter(0xf491e7b69e4244ad4002bc14e878a34207e38c29);

    uint256 private constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 private constant LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;

    uint256 public maxBorrowCollatRatio; // The maximum the protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk

    uint256 public minWant;
    uint256 public minRatio;
    uint256 public rewardsDust;

    uint8 public maxIterations;

    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant BPS_WAD_RATIO = 1e14;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1 ether;
    uint256 private constant PESSIMISM_FACTOR = 1000;
    uint256 private DECIMALS;

    address[] public rewardToWantRoute;
    address[] public gTokens;

    uint256 internal constant MAX = type(uint256).max;

    // We hardcode the address as we need to keep track of funds
    // If lending pool were to change, we would migrate and retire the strategy
    // https://docs.aave.com/developers/the-core-protocol/addresses-provider
    ILendingPool public constant LENDING_POOL = ILendingPool(0x9fad24f572045c7869117160a571b2e50b10d068);
    IRewardsContract public constant REWARDS_CONTRACT = IRewardsContract(0x297fddc5c33ef988dd03bd13e162ae084ea1fe57);
    IGeistIncentivesController private constant INCENTIVES_CONTROLLER = IGeistIncentivesController(0x297FddC5c33Ef988dd03bd13e162aE084ea1fE57);
    IProtocolDataProvider private constant PROTOCOL_DATA_PROVIDER = IProtocolDataProvider(0xf3B0611e2E4D2cd6aB4bb3e01aDe211c3f42A8C3);

    /// @dev Initialize the Strategy with security settings as well as tokens
    /// @notice Proxies will set any non constant variable you declare as default value
    /// @dev add any extra changeable variable at end of initializer as shown
    function initialize(address _vault, address[1] memory _wantConfig) public initializer {
        __BaseStrategy_init(_vault);
        /// @dev Add config here
        want = _wantConfig[0];

        maxIterations = 10;

        minWant = 1000; // Roundabout $0.4
        minRatio = 0.005 ether;
        rewardsDust = 1e18; // Roundabout $0.2

        rewardToWantRoute = [address(REWARD), address(weth), address(want)];

        (address _aToken, , address _dToken) = protocolDataProvider.getReserveTokensAddresses(address(want));
        require(_aToken != address(0));
        aToken = IAToken(_aToken);
        dToken = IVariableDebtToken(_dToken);
        gTokens = [address(aToken), address(dToken)];

        // Approve want & aToken for earning interest
        IERC20Upgradeable(want).safeApprove(address(LENDING_POOL), type(uint256).max);
        IERC20Upgradeable(aToken).safeApprove(address(LENDING_POOL), type(uint256).max);

        // Approve Reward so we can sell it
        IERC20Upgradeable(REWARD).safeApprove(address(ROUTER), type(uint256).max);
    }

    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "fantom-wbtc-geist-leverage";
    }

    /// @dev Return a list of protected tokens
    /// @notice It's very important all tokens that are meant to be in the strategy to be marked as protected
    /// @notice this provides security guarantees to the depositors they can't be swept away
    function getProtectedTokens() public view virtual override returns (address[] memory) {
        address[] memory protectedTokens = new address[](4);
        protectedTokens[0] = want;
        protectedTokens[1] = aToken;
        protectedTokens[2] = dToken;
        protectedTokens[3] = REWARD;
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        emit Debug("_amount", _amount);
        LENDING_POOL.deposit(want, _amount, address(this), 0);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        _withdrawSome(MAX);
    }

    /// @dev Withdraw `_amount` of want, so that it can be sent to the vault / depositor
    /// @notice just unlock the funds and return the amount you could unlock
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {
        uint256 balBefore = balanceOfWant();
        // Check if we can cover with want available
        if (balBefore > _amount) return 0;

        // We need to free funds
        uint256 amountNeeded = _amount.sub(balBefore);
        _releaseWant(amountNeeded);

        uint256 balAfter = balanceOfWant();
        return balAfter.sub(balBefore);
    }

    function _releaseWant(uint256 amountToRelease) internal returns (uint256) {
        if (amountToRelease == 0) return 0;

        uint256 balanceOfPool = balanceOfPool();
        uint256 amountRequired = Math.min(amountToRelease, balanceOfPool);
        uint256 newSupply = balanceOfPool.sub(amountRequired);
        uint256 newBorrow = getBorrowFromSupply(newSupply, targetCollatRatio);

        // Repay required amount
        _reduceLeverage(newBorrow, borrows);

        return balanceOfWant();
    }

    /// @dev Does this function require `tend` to be called?
    function _isTendable() internal pure override returns (bool) {
        return false; // Instead of tending, we re-deposit in harvest
    }

    function _harvest() internal override returns (TokenAmount[] memory harvested) {
        address[] memory tokens = new address[](1);
        tokens[0] = aToken;

        uint256 beforeWant = balanceOfWant();

        // Claim all rewards
        _claimRewards();

        uint256 amountToSell = IERC20(REWARD).balanceOf(address(this)).div(2);

        // Sell 50% of the rewards for more want
        _sellRewards(amountToSell);

        uint256 afterWant = balanceOfWant();

        // Report profit for the want increase (NOTE: We are not getting perf fee on AAVE APY with this code)
        uint256 wantHarvested = afterWant.sub(beforeWant);
        _reportToVault(wantHarvested);

        // Remaining balance to emit to tree
        uint256 rewardEmitted = IERC20(REWARD).balanceOf(address(this));
        _processExtraToken(REWARD, rewardEmitted);

        // Return the same value for APY and offChain automation
        harvested = new TokenAmount[](2);
        harvested[0] = TokenAmount(want, wantHarvested);
        harvested[1] = TokenAmount(REWARD, rewardEmitted);
        return harvested;
    }

    // Example tend is a no-op which returns the values, could also just revert
    function _tend() internal override returns (TokenAmount[] memory tended) {
        uint256 balanceToTend = balanceOfWant();
        _deposit(balanceToTend);

        // Return all tokens involved for offChain tracking and automation
        tended = new TokenAmount[](4);
        tended[0] = TokenAmount(want, balanceToTend);
        tended[1] = TokenAmount(aToken, 0);
        tended[2] = TokenAmount(dToken, 0);
        tended[3] = TokenAmount(REWARD, 0);
        return tended;
    }

    /// @dev Return the balance (in want) that the strategy has invested somewhere
    function balanceOfPool() public view override returns (uint256) {
        uint256 deposits = aToken.balanceOf(address(this));
        uint256 borrows = dToken.balanceOf(address(this));
        return deposits.sub(borrows);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    /// @dev Return the balance of rewards that the strategy has accrued
    /// @notice Used for offChain APY and Harvest Health monitoring
    function balanceOfRewards() external view override returns (uint256) {
        uint256 rewardBal = 0;

        uint256[] memory rewards = incentivesController.claimableReward(address(this), gTokens);
        for (uint8 i = 0; i < rewards.length; i++) {
            rewardBal += rewards[i];
        }

        // Geist takes 50% for early claims
        rewardBal = rewardBal.div(2).add(IERC20(REWARD).balanceOf(address(this)));

        uint256[] memory amounts = router.getAmountsOut(rewardBal, rewardToWantRoute);

        return amounts[amounts.length - 1];
    }

    function _claimRewards() internal {
        INCENTIVES_CONTROLLER.claim(address(this), gTokens);

        // Exit with 50% penalty
        IMultiFeeDistribution(INCENTIVES_CONTROLLER.rewardMinter()).exit();
    }

    function _sellRewards(uint256 _amount) internal {
        // Sell reward for want
        if (_amount >= rewardsDust) {
            router.swapExactTokensForTokens(_amount, 0, rewardToWantRoute, address(this), block.timestamp);
        }
    }
}
