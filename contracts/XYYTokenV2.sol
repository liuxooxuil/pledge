// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IXYYDividend.sol";

interface IPancakePair {
    function sync() external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function mint(address to) external returns (uint256 liquidity);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakeRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable;
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token, uint liquidity, uint, uint amountETHMin, address to, uint deadline
    ) external returns (uint amountETH);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

contract SwapHelperV2 {
    address public immutable token;
    constructor() { token = msg.sender; }
    receive() external payable {}
}

error ZeroAddress();
error InvalidAmount();
error TradingDisabled();
error Unauthorized();
error InvalidFee();
error InvalidRate();
error NotExpired();
error InsufficientBalance();
error DeadlinePassed();
error NotQualified();
error TransferFailed();
error Blacklisted();
error MigrationLocked();
error ReceiveReentrant();
error EnforcedPause();

/**
 * @title XYYTokenV2
 * @notice XYY代币 V2 — ERC20 + 质押核心 (Contract A)
 */
contract XYYTokenV2 is ERC20, Ownable {

    uint256 public constant MAX_TEAM_DEPTH = 45;
    uint256 public constant MPU_DENOMINATOR = 1_000_000;
    uint256 public constant ZOMBIE_MIN = 5;
    uint256 public constant ZOMBIE_MAX = 8;
    uint256 public constant USER_REWARD_BP = 750_000;
    uint256 public constant TEAM_REWARD_BP = 250_000;
    uint256 public constant DIRECT_REWARD_BP = 50_000;
    uint256 public constant SAME_LEVEL_DEDUCT_BP = 200_000;

    address public immutable mainPair;
    address public immutable swapRouter;
    address public immutable weth;
    address public immutable swapHelper;
    bool public tradingEnabled;
    uint256 public buyFee = 30_000;
    uint256 public sellFee = 30_000;

    mapping(address => address) public inviter;
    mapping(address => address[]) public binders;
    uint256 public binderCondition = 0.5 ether;
    bool public autoBindOnTransferEnabled = true;

    uint256 public cycleDays = 7;
    uint256 public validPeriod = 8 days;
    uint256 public dailyReturnBp = 18_000;
    uint256 public principalReturnBp = 1_000_000;

    uint256 public fundFeeBp = 29_990;
    uint256 public nftFeeBp = 20_000;
    uint256 public zombieFeeBp = 10;
    uint256 public rewardReserveBp = 126_000;
    uint256 public minStakeAmount = 0.1 ether;
    uint256 public maxStake = 3 ether;
    uint256 public nftThreshold = 2 ether;

    struct StakeInfo { uint256 recordedAmount; uint256 retainedAmount; uint256 nextDeadline; }
    mapping(address => StakeInfo) public stakeInfos;

    struct TeamInfo { uint256 totalAmount; uint8 level; uint256 lastUpdateTime; }
    mapping(address => TeamInfo) public teamInfos;

    struct LevelConfig { uint256 threshold; uint256 rewardRate; }
    mapping(uint8 => LevelConfig) public levelConfigs;

    bool public profitTaxEnabled;
    uint256 public profitTaxRate = 250_000;

    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public isBlacklisted;

    bool public zeroExitEnabled;

    mapping(uint256 => uint256) public dailyBuyFees;
    uint256 public pendingSellFees;

    address public fundAddress;
    address public operator;
    address public dividendManager;
    address public nftbToken;
    uint256 private _randomNonce;

    uint256 internal reservedRewardPool;
    uint256 internal rewardPoolThreshold = 1 ether;
    uint256 internal lpWithdrawBatchAmount = 5 ether;
    uint256 internal maxSlippage = 500;

    uint256 public lastBurnTime;
    uint256 public burnDailyRate = 20_000;
    bool public burningEnabled = true;
    uint256 public burnDeadBp = 199_900;
    uint256 public burnDividendBp = 100;
    uint256 public burnInterval = 2 hours;

    bool public migrationLocked;
    bool public paused;
    uint256 private _flowGuard;

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier migrationOpen() {
        if (migrationLocked) revert MigrationLocked();
        _;
    }

    modifier flowGuarded() {
        _enterFlowGuard();
        _;
        _exitFlowGuard();
    }

    modifier whenNotPaused() { _requireNotPaused(); _; }

    event InviterBound(address indexed account, address indexed inviter);
    event Staked(address indexed user, uint256 recordedAmount, uint256 nextDeadline);
    event Compounded(address indexed user, uint256 newRecorded, uint256 nextDeadline);
    event UserReset(address indexed user, uint256 retainedAmount);
    event TeamRewardDistributed(address indexed to, uint256 amount, uint8 rewardType);
    event SameLevelReward(address indexed recipient, uint256 amount);
    event LevelUp(address indexed user, uint8 newLevel);
    event Exited(address indexed user, uint256 principal, uint256 reward);
    event AdminPowerAdded(address indexed user, uint256 newRecorded);
    event ZombieDistributed(uint256 ethAmount, uint256 tokenAmount, uint256 zombieCount);
    event LiquidityAdded(uint256 ethAmount, uint256 tokenAmount, uint256 liquidity);
    event SellFeesProcessed(uint256 tokenAmount, uint256 bnbReceived);
    event DailyTradeFeesProcessed(uint256 indexed day, uint256 tokenAmount, uint256 bnbAmount);
    event DailyProcessTriggered(address indexed trigger);
    event StakingFeesUpdated(uint256 fundFee, uint256 nftFee, uint256 zombieFee);
    event ZeroExitEnabledChanged(bool enabled);
    event RewardPoolLow(uint256 balance, uint256 threshold);
    event LPWithdrawn(uint256 lpAmount, uint256 bnbReceived, uint256 xyyBurned);
    event RewardPoolReplenished(uint256 amount, uint256 newBalance);
    event BurnExecuted(uint256 burnAmount, uint256 toDead, uint256 toDividend);
    event MigrationLockedEvent();

    constructor(
        address _router, address _fund, address _tokenReceiver,
        string memory _name, string memory _symbol,
        uint256 _totalSupply, address _initialOwner, address _operator
    ) ERC20(_name, _symbol) Ownable(_initialOwner) {
        if (_router == address(0) || _fund == address(0) || _tokenReceiver == address(0) || _operator == address(0)) revert ZeroAddress();
        swapRouter = _router;
        fundAddress = _fund;
        operator = _operator;
        weth = IPancakeRouter(_router).WETH();
        mainPair = _createPair(_router);
        _mint(_tokenReceiver, _totalSupply * 10 ** decimals());
        swapHelper = address(new SwapHelperV2());
        isWhitelisted[swapHelper] = true;
        isWhitelisted[address(this)] = true;
        isWhitelisted[_tokenReceiver] = true;
        isWhitelisted[_fund] = true;
        _initLevelConfigs();
    }

    function _createPair(address router) internal returns (address) {
        address factory = IPancakeRouter(router).factory();
        address _weth = IPancakeRouter(router).WETH();
        address pair = IPancakeFactory(factory).getPair(address(this), _weth);
        if (pair == address(0)) pair = IPancakeFactory(factory).createPair(address(this), _weth);
        return pair;
    }

    function _enterFlowGuard() internal {
        if (_flowGuard != 0) revert ReceiveReentrant();
        _flowGuard = 1;
    }

    function _exitFlowGuard() internal {
        _flowGuard = 0;
    }

    function _requireNotPaused() internal view {
        if (paused) revert EnforcedPause();
    }

    function _rescueRecipient() internal view returns (address recipient) {
        recipient = owner();
        if (recipient == address(0)) recipient = operator;
    }

    function _initLevelConfigs() internal {
        levelConfigs[1] = LevelConfig(10 ether, 70_000);
        levelConfigs[2] = LevelConfig(50 ether, 130_000);
        levelConfigs[3] = LevelConfig(200 ether, 160_000);
        levelConfigs[4] = LevelConfig(500 ether, 180_000);
        levelConfigs[5] = LevelConfig(1200 ether, 250_000);
    }

    function _validateRewardReserveConfig(uint256 _fundFee, uint256 _nftFee, uint256 _zombieFee, uint256 _reserveBp) internal pure {
        uint256 afterFeeBp = MPU_DENOMINATOR - _fundFee - _nftFee - _zombieFee;
        if (afterFeeBp == 0 || _reserveBp > afterFeeBp) revert InvalidRate();
    }

    // ============ _update ============
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && isBlacklisted[from]) revert Blacklisted();
        if (to != address(0) && isBlacklisted[to]) revert Blacklisted();

        if (autoBindOnTransferEnabled && from != address(0) && to != address(0) && from == tx.origin && inviter[to] == address(0)
            && amount >= binderCondition && !_isSwapPair(from) && !_isSwapPair(to)) {
            _bindInviter(to, from);
        }

        uint256 fee;
        bool isBuy = (from == mainPair || from == swapRouter);
        bool isSell = (to == mainPair || to == swapRouter);

        if ((isBuy || isSell) && !tradingEnabled) {
            bool fw = isWhitelisted[from] || from == mainPair || from == swapRouter;
            bool tw = isWhitelisted[to] || to == mainPair || to == swapRouter;
            if (!(fw && tw)) revert TradingDisabled();
        }

        if (!(isWhitelisted[from] || isWhitelisted[to])) {
            if (isBuy && buyFee > 0) fee = (amount * buyFee) / MPU_DENOMINATOR;
            else if (isSell && sellFee > 0) fee = (amount * sellFee) / MPU_DENOMINATOR;
        }

        if (fee > 0) {
            super._update(from, address(this), fee);
            if (isSell) pendingSellFees += fee;
            else dailyBuyFees[block.timestamp / 1 days] += fee;
        }

        uint256 transferAmt = amount - fee;
        if (isSell && profitTaxEnabled && from != address(0) && !isWhitelisted[from]) {
            uint256 pt = (transferAmt * profitTaxRate) / MPU_DENOMINATOR;
            if (pt > 0) { transferAmt -= pt; super._update(from, fundAddress, pt); }
        }
        if (transferAmt > 0) super._update(from, to, transferAmt);
    }

    function _isSwapPair(address a) internal view returns (bool) { return a == mainPair || a == swapRouter; }
    function _bindInviter(address account, address inv) internal {
        if (inviter[account] == address(0) && inv != address(0) && account != address(0) && inv != account) {
            inviter[account] = inv; binders[inv].push(account);
        }
    }

    // ============ Dividend Manager helpers ============
    function _dm() internal view returns (IXYYDividend) { return IXYYDividend(dividendManager); }
    function _hasDM() internal view returns (bool) { return dividendManager != address(0); }

    function _syncExpiredDividendState() internal {
        if (!_hasDM()) return;
        _dm().cleanupExpiredNftHolders();
        _dm().cleanupExpiredValidStakeHolders();
    }

    function _dmSetNFT(address user, uint256 amt) internal {
        if (!_hasDM()) return;
        if (_dm().hasNftQualification(user)) _dm().updateNFTStake(user, amt);
        else _dm().setNFTQualification(user, true, amt);
    }

    // ============ Staking ============
    function _stakeInternal(address user, uint256 amount) internal {
        if (isBlacklisted[user]) revert Blacklisted();
        if (amount < minStakeAmount || amount > maxStake) revert InvalidAmount();
        if (inviter[user] == address(0)) revert ZeroAddress();

        StakeInfo storage info = stakeInfos[user];
        if (info.nextDeadline > 0) {
            if (block.timestamp <= info.nextDeadline) revert NotExpired();
            if (info.recordedAmount > 0) {
                if (amount < info.recordedAmount) revert InvalidAmount();
                _compoundShared(user, amount, true);
                return;
            }
            _resetUserState(user);
        }

        _distributeEntryFee(amount);
        uint256 afterFeeBp = MPU_DENOMINATOR - fundFeeBp - nftFeeBp - zombieFeeBp;
        uint256 rr = amount * rewardReserveBp / MPU_DENOMINATOR;
        reservedRewardPool += rr;
        _addLiquidityWithBNB(amount * (afterFeeBp - rewardReserveBp) / MPU_DENOMINATOR);

        info.recordedAmount = amount;
        info.nextDeadline = block.timestamp + validPeriod;
        _updateTeamAmount(user, amount);

        if (_hasDM()) {
            if (amount >= nftThreshold) _dm().setNFTQualification(user, true, amount);
            _dm().updateValidStake(user, amount, true);
        }
    }

    /**
     * @notice 统一的复投逻辑（合并 _expiredCompound 和 _compoundInternal）
     * @param isExpired true = 过期复投, false = 期内复投
     */
    function _compoundShared(address user, uint256 amount, bool isExpired) internal {
        if (isBlacklisted[user]) revert Blacklisted();
        StakeInfo storage info = stakeInfos[user];

        if (!isExpired) {
            if (info.nextDeadline == 0) revert InvalidAmount();
            if (block.timestamp > info.nextDeadline) revert DeadlinePassed();
            if (amount < info.recordedAmount) revert InvalidAmount();
            // 必须等到周期结束才能复投（cycleEnd = deadline - grace）
            uint256 grace = validPeriod - cycleDays * 1 days;
            if (info.nextDeadline > grace && block.timestamp < info.nextDeadline - grace) revert NotExpired();
        }

        uint256 oldRecorded = info.recordedAmount;
        uint256 staticReward = oldRecorded * dailyReturnBp * cycleDays / MPU_DENOMINATOR;

        _distributeEntryFee(amount);
        // 返还本金，避开 reservedRewardPool 对应的余额
        uint256 principalReturn = oldRecorded * principalReturnBp / MPU_DENOMINATOR;
        uint256 principalPaid = _payPrincipalWithFallback(user, principalReturn);
        if (principalPaid < principalReturn) revert TransferFailed();
        // 收益 75%
        _payRewardWithFallback(user, staticReward * USER_REWARD_BP / MPU_DENOMINATOR);

        // 团队奖励 25% — 基于总收益计算各级奖励
        _distributeTeamRewards(user, staticReward);

        // 增量部分 → LP
        if (amount > oldRecorded) {
            uint256 afterFeeBp = MPU_DENOMINATOR - fundFeeBp - nftFeeBp - zombieFeeBp;
            uint256 rem = (amount - oldRecorded) * afterFeeBp / MPU_DENOMINATOR;
            uint256 rr = rem * rewardReserveBp / afterFeeBp;
            reservedRewardPool += rr;
            _addLiquidityWithBNB(rem - rr);
            _updateTeamAmount(user, amount - oldRecorded);
        }

        info.recordedAmount = amount;
        info.nextDeadline = block.timestamp + validPeriod;

        if (_hasDM()) {
            // 复投窗口内 / 超期重开后，都先结算上一单待领取的燃烧分红
            _dm().claimBurnDividendFor(user);
            if (amount >= nftThreshold) _dmSetNFT(user, amount);
            _dm().updateValidStake(user, amount, true);
        }
        _checkAndReplenishPool();
        emit Compounded(user, amount, info.nextDeadline);
    }

    function _exitInternal(address user) internal {
        if (isBlacklisted[user]) revert Blacklisted();
        StakeInfo storage info = stakeInfos[user];
        if (info.nextDeadline == 0 || info.recordedAmount == 0) revert InvalidAmount();
        if (block.timestamp > info.nextDeadline) revert DeadlinePassed();
        // 必须等到周期结束才能退出
        uint256 grace = validPeriod - cycleDays * 1 days;
        if (info.nextDeadline > grace && block.timestamp < info.nextDeadline - grace) revert NotExpired();

        uint256 oldRecorded = info.recordedAmount;
        uint256 staticReward = oldRecorded * dailyReturnBp * cycleDays / MPU_DENOMINATOR;

        uint256 principalReturn = oldRecorded * principalReturnBp / MPU_DENOMINATOR;
        uint256 principalPaid = _payPrincipalWithFallback(user, principalReturn);
        if (principalPaid < principalReturn) revert TransferFailed();

        _payRewardWithFallback(user, staticReward * USER_REWARD_BP / MPU_DENOMINATOR);
        _distributeTeamRewards(user, staticReward);

        if (_hasDM()) _dm().claimBurnDividendFor(user);
        _resetUserState(user);
        _checkAndReplenishPool();
    }

    // ============ Fee Distribution ============
    function _distributeEntryFee(uint256 amount) internal {
        uint256 ff = amount * fundFeeBp / MPU_DENOMINATOR;
        if (ff > 0) _safeTransferETH(fundAddress, ff);

        uint256 nf = amount * nftFeeBp / MPU_DENOMINATOR;
        if (nf > 0 && _hasDM()) {
            _dm().accumulateNftReward{value: nf}(nf);
        } else if (nf > 0) {
            _safeTransferETH(fundAddress, nf);
        }

        uint256 zf = amount * zombieFeeBp / MPU_DENOMINATOR;
        if (zf > 0) _distributeToZombies(zf);
    }

    function _distributeToZombies(uint256 ethAmt) internal {
        if (ethAmt == 0) return;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = address(this);
        uint256 bb = balanceOf(swapHelper);
        uint256 minOut = _getSwapMinOut(ethAmt, false);
        try IPancakeRouter(swapRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmt}(minOut, path, swapHelper, block.timestamp + 300) {
            uint256 bought = balanceOf(swapHelper) - bb;
            if (bought > 0) {
                uint256 zc = ZOMBIE_MIN + (_randomNonce % (ZOMBIE_MAX - ZOMBIE_MIN + 1));
                _randomNonce++;
                uint256 per = bought / zc;
                for (uint256 i = 0; i < zc;) {
                    if (per > 0) super._update(swapHelper, _genAddr(i), per);
                    unchecked { ++i; }
                }
            }
        } catch { _safeTransferETH(fundAddress, ethAmt); }
    }

    function _addLiquidityWithBNB(uint256 ethAmt) internal {
        if (ethAmt == 0) return;
        uint256 half = ethAmt / 2;
        uint256 otherHalf = ethAmt - half;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = address(this);
        uint256 tb = balanceOf(swapHelper);
        uint256 minOut = _getSwapMinOut(half, false);
        try IPancakeRouter(swapRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: half}(minOut, path, swapHelper, block.timestamp + 300) {
            uint256 ts = balanceOf(swapHelper) - tb;
            if (ts > 0 && otherHalf > 0) {
                IWETH(weth).deposit{value: otherHalf}();
                IWETH(weth).transfer(mainPair, otherHalf);
                super._update(swapHelper, mainPair, ts);
                IPancakePair(mainPair).mint(address(this));
            }
        } catch { _safeTransferETH(fundAddress, ethAmt); }
    }

    // ============ LP & Reward Pool ============
    function _getPairReserves() internal view returns (uint256 rToken, uint256 rBNB) {
        (uint112 r0, uint112 r1, ) = IPancakePair(mainPair).getReserves();
        if (weth < address(this)) {
            rBNB = uint256(r0);
            rToken = uint256(r1);
        } else {
            rToken = uint256(r0);
            rBNB = uint256(r1);
        }
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function _availableOperationalBNB() internal view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > reservedRewardPool ? bal - reservedRewardPool : 0;
    }

    function _getSwapMinOut(uint256 amountIn, bool tokenToBnb) internal view returns (uint256) {
        (uint256 rToken, uint256 rBNB) = _getPairReserves();
        uint256 expectedOut = tokenToBnb ? _getAmountOut(amountIn, rToken, rBNB) : _getAmountOut(amountIn, rBNB, rToken);
        if (expectedOut == 0) return 0;
        return expectedOut * (MPU_DENOMINATOR - maxSlippage) / MPU_DENOMINATOR;
    }

    function _calculateLPForBNB(uint256 bnbAmt) internal view returns (uint256) {
        uint256 totalLP = IPancakePair(mainPair).totalSupply();
        if (totalLP == 0) return 0;
        (, uint256 rBNB) = _getPairReserves();
        if (rBNB == 0) return 0;
        return (bnbAmt * totalLP * 110) / (rBNB * 100);
    }

    function _withdrawBNBFromLP(uint256 bnbNeeded) internal returns (uint256 ext) {
        uint256 lpBal = IPancakePair(mainPair).balanceOf(address(this));
        if (lpBal == 0) return 0;
        uint256 lpRem = _calculateLPForBNB(bnbNeeded);
        if (lpRem > lpBal) lpRem = lpBal;
        if (lpRem == 0) return 0;
        uint256 beforeTokenBal = balanceOf(address(this));
        IPancakePair(mainPair).approve(swapRouter, lpRem);
        try IPancakeRouter(swapRouter).removeLiquidityETHSupportingFeeOnTransferTokens(
            address(this), lpRem, 0, bnbNeeded * (MPU_DENOMINATOR - maxSlippage) / MPU_DENOMINATOR, address(this), block.timestamp + 300
        ) returns (uint256 amtETH) {
            ext = amtETH;
            uint256 afterTokenBal = balanceOf(address(this));
            uint256 xb = afterTokenBal > beforeTokenBal ? afterTokenBal - beforeTokenBal : 0;
            if (xb > 0) {
                (uint256 extraBnb, bool ok) = _swapTokensForBNB(xb);
                if (!ok) {
                    super._update(address(this), fundAddress, xb);
                } else {
                    ext += extraBnb;
                }
            }
        } catch { ext = 0; }
    }

    function _payRewardWithFallback(address to, uint256 amt) internal returns (uint256 paid, bool fromLP) {
        if (amt == 0) return (0, false);
        if (reservedRewardPool >= amt) {
            reservedRewardPool -= amt; _safeTransferETH(to, amt); return (amt, false);
        }
        uint256 extracted = _withdrawBNBFromLP(amt - reservedRewardPool);
        uint256 avail = reservedRewardPool + extracted;
        reservedRewardPool = 0;
        paid = avail > amt ? amt : avail;
        if (paid > 0) _safeTransferETH(to, paid);
        return (paid, true);
    }

    function _payPrincipalWithFallback(address to, uint256 amt) internal returns (uint256 paid) {
        if (amt == 0 || to == address(0)) return 0;
        uint256 bal = _availableOperationalBNB();
        if (bal < amt) {
            _withdrawBNBFromLP(amt - bal);
            bal = _availableOperationalBNB();
        }
        paid = bal >= amt ? amt : bal;
        if (paid > 0) { (bool ok, ) = to.call{value: paid}(""); if (!ok) return 0; }
    }

    function _checkAndReplenishPool() internal {
        if (reservedRewardPool < rewardPoolThreshold) {
            uint256 lpBal = IPancakePair(mainPair).balanceOf(address(this));
            if (lpBal > 0) {
                uint256 ext = _withdrawBNBFromLP(lpWithdrawBatchAmount);
                if (ext > 0) reservedRewardPool += ext;
            }
        }
    }

    function _genAddr(uint256 seed) internal returns (address) {
        _randomNonce++;
        return address(uint160(uint256(keccak256(abi.encodePacked(_randomNonce, seed, block.timestamp, block.prevrandao, msg.sender, gasleft())))));
    }

    function _resetUserState(address user) internal {
        StakeInfo storage info = stakeInfos[user];
        uint256 oldRecorded = info.recordedAmount;
        if (_hasDM()) { _dm().revokeNFTQualification(user); _dm().updateValidStake(user, 0, false); }
        info.recordedAmount = 0; info.nextDeadline = 0;
        TeamInfo storage team = teamInfos[user];
        team.totalAmount = 0; team.level = 0;
        // 从上线的 teamInfos.totalAmount 中扣减该用户的贡献
        if (oldRecorded > 0) _reduceTeamAmount(user, oldRecorded);
    }

    // ============ Team ============
    function _updateTeamAmount(address user, uint256 amount) internal {
        address cur = user;
        for (uint256 i = 0; i < MAX_TEAM_DEPTH;) {
            address p = inviter[cur]; if (p == address(0)) break;
            TeamInfo storage pt = teamInfos[p];
            pt.totalAmount += amount;
            _syncTeamLevel(p); cur = p;
            unchecked { ++i; }
        }
    }

    function _reduceTeamAmount(address user, uint256 amount) internal {
        address cur = user;
        for (uint256 i = 0; i < MAX_TEAM_DEPTH;) {
            address p = inviter[cur]; if (p == address(0)) break;
            TeamInfo storage pt = teamInfos[p];
            if (pt.totalAmount >= amount) pt.totalAmount -= amount;
            else pt.totalAmount = 0;
            _syncTeamLevel(p);
            cur = p;
            unchecked { ++i; }
        }
    }

    function _syncTeamLevel(address user) internal {
        TeamInfo storage t = teamInfos[user];
        for (uint8 i = t.level + 1; i <= 5;) {
            if (t.totalAmount >= levelConfigs[i].threshold) t.level = i;
            else break;
            unchecked { ++i; }
        }
    }

    function _distributeTeamRewards(address staker, uint256 rewardPool) internal {
        address cur = staker;
        uint8 lastLvl = 0; bool drGiven = false; uint256 ct = block.timestamp;
        for (uint256 i = 0; i < MAX_TEAM_DEPTH;) {
            address p = inviter[cur]; if (p == address(0)) break;
            if (ct > stakeInfos[p].nextDeadline) {
                cur = p;
                unchecked { ++i; }
                continue;
            }
            uint8 pLvl = teamInfos[p].level;
            uint256 reward;
            if (i == 0 && pLvl == 0) { reward = rewardPool * DIRECT_REWARD_BP / MPU_DENOMINATOR; drGiven = true; }
            else if (pLvl > lastLvl) {
                uint256 pRate = levelConfigs[pLvl].rewardRate;
                uint256 lRate = lastLvl == 0 ? (drGiven ? DIRECT_REWARD_BP : 0) : levelConfigs[lastLvl].rewardRate;
                if (pRate > lRate) reward = rewardPool * (pRate - lRate) / MPU_DENOMINATOR;
            }
            if (reward > 0) {
                uint256 ded;
                address gp = inviter[p];
                if (gp != address(0) && ct <= stakeInfos[gp].nextDeadline && pLvl > 0) {
                    if (teamInfos[gp].level == pLvl) {
                        ded = reward * SAME_LEVEL_DEDUCT_BP / MPU_DENOMINATOR; reward -= ded;
                    }
                }
                lastLvl = pLvl;
                if (ded > 0) _payRewardWithFallback(gp, ded);
                if (reward > 0) _payRewardWithFallback(p, reward);
            }
            cur = p;
            unchecked { ++i; }
        }
    }

    // ============ Burn ============
    function _dailyBurnInternal() internal {
        uint256 ptb = balanceOf(mainPair);
        if (ptb == 0) { lastBurnTime = block.timestamp; return; }
        uint256 ba = (ptb * burnDailyRate) / MPU_DENOMINATOR;
        if (ba == 0) { lastBurnTime = block.timestamp; return; }
        uint256 tr = burnDeadBp + burnDividendBp;
        uint256 td = (ba * burnDeadBp) / tr;
        uint256 tv = ba - td;
        super._update(mainPair, address(0xdead), td);
        if (_hasDM() && _dm().totalValidStakeAmount() > 0) {
            super._update(mainPair, dividendManager, tv);
            _dm().receiveBurnDividend(tv);
        } else super._update(mainPair, address(0xdead), tv);
        try IPancakePair(mainPair).sync() {} catch {}
        emit BurnExecuted(ba, td, tv);
        lastBurnTime = block.timestamp;
    }

    function _dailyBatchProcess() internal {
        _syncExpiredDividendState();
        if (burningEnabled && block.timestamp >= lastBurnTime + burnInterval) _dailyBurnInternal();
        _processDailyTradeFees((block.timestamp / 1 days) - 1);
    }

    function _processDailyTradeFees(uint256 day) internal {
        uint256 fa = dailyBuyFees[day]; if (fa == 0) return;
        (uint256 bnb, bool swapped) = _swapTokensForBNB(fa);
        if (!swapped) {
            uint256 currentDay = block.timestamp / 1 days;
            if (day != currentDay) {
                dailyBuyFees[currentDay] += fa;
                dailyBuyFees[day] = 0;
            }
            return;
        }
        dailyBuyFees[day] = 0;
        if (bnb > 0 && _hasDM()) _dm().accumulateNftReward{value: bnb}(bnb);
    }

    function _swapTokensForBNB(uint256 tAmt) internal returns (uint256 bnbOut, bool swapped) {
        if (tAmt == 0) return (0, false);
        address[] memory path = new address[](2); path[0] = address(this); path[1] = weth;
        uint256 bb = address(this).balance;
        uint256 minOut = _getSwapMinOut(tAmt, true);
        _approve(address(this), swapRouter, tAmt);
        try IPancakeRouter(swapRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tAmt, minOut, path, address(this), block.timestamp + 300
        ) {
            return (address(this).balance - bb, true);
        } catch {
            return (0, false);
        }
    }

    // ============ External Entry ============
    function stake(address referrer) external payable flowGuarded whenNotPaused {
        if (msg.value < minStakeAmount) revert InvalidAmount();
        _dailyBatchProcess();
        if (referrer != address(0) && inviter[msg.sender] == address(0) && referrer != msg.sender) {
            inviter[msg.sender] = referrer; binders[referrer].push(msg.sender);
        }
        _stakeInternal(msg.sender, msg.value);
    }

    function compound() external payable flowGuarded whenNotPaused {
        if (msg.value < minStakeAmount) revert InvalidAmount();
        _dailyBatchProcess();
        _compoundShared(msg.sender, msg.value, false);
    }

    function triggerDailyProcess() external onlyOperator { _dailyBatchProcess(); }

    function processSellFees() external flowGuarded {
        uint256 amt = pendingSellFees; if (amt == 0) revert InvalidAmount();
        _syncExpiredDividendState();
        (uint256 bnb, bool swapped) = _swapTokensForBNB(amt);
        if (!swapped) revert TransferFailed();
        pendingSellFees = 0;
        if (bnb > 0 && _hasDM()) _dm().accumulateNftReward{value: bnb}(bnb);
    }

    receive() external payable {
        if (msg.sender == weth || msg.sender == swapRouter || msg.sender == mainPair) return;
        _requireNotPaused();
        _enterFlowGuard();
        _dailyBatchProcess();
        StakeInfo storage info = stakeInfos[msg.sender];
        bool active = (info.nextDeadline > 0 && block.timestamp <= info.nextDeadline);
        if (msg.value == 0 && zeroExitEnabled && active) { _exitInternal(msg.sender); _exitFlowGuard(); return; }
        if (active) _compoundShared(msg.sender, msg.value, false);
        else _stakeInternal(msg.sender, msg.value);
        _exitFlowGuard();
    }

    // ============ View ============
    function getReservedRewardPool() external view returns (uint256) { return reservedRewardPool; }
    function getBinderLength(address account) external view returns (uint256) { return binders[account].length; }

    function autoClaimForUser(address user, uint256 amount) external flowGuarded {
        if (msg.sender != nftbToken || !_hasDM()) revert Unauthorized();
        _dm().autoClaimForUser(user, amount);
    }

    // ============ Admin ============
    function adminAddPower(address user, uint256 amount) external onlyOperator flowGuarded {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (inviter[user] == address(0)) revert ZeroAddress();
        _syncExpiredDividendState();
        StakeInfo storage info = stakeInfos[user];
        if (info.nextDeadline == 0 || info.recordedAmount == 0) {
            info.recordedAmount = amount; info.nextDeadline = block.timestamp + validPeriod;
            _updateTeamAmount(user, amount);
            if (_hasDM()) {
                if (amount >= nftThreshold) _dm().setNFTQualification(user, true, amount);
                _dm().updateValidStake(user, amount, true);
            }
        } else {
            uint256 nr = info.recordedAmount + amount;
            info.recordedAmount = nr; info.nextDeadline = block.timestamp + validPeriod;
            _updateTeamAmount(user, amount);
            if (_hasDM()) {
                _dm().claimBurnDividendFor(user);
                if (nr >= nftThreshold) _dmSetNFT(user, nr);
                _dm().updateValidStake(user, nr, true);
            }
        }
    }

    function setOperator(address _op) external onlyOperator { if (_op == address(0)) revert ZeroAddress(); operator = _op; }
    function setDividendManager(address dm_) external onlyOperator { if (dm_ == address(0)) revert ZeroAddress(); dividendManager = dm_; }
    function setNftbToken(address nftb_) external onlyOperator { if (nftb_ == address(0)) revert ZeroAddress(); nftbToken = nftb_; }
    function setFundAddress(address _f) external onlyOperator { if (_f == address(0)) revert ZeroAddress(); fundAddress = _f; }

    function setWhitelisted(address a, bool s) external onlyOperator { isWhitelisted[a] = s; }
    function setBlacklisted(address a, bool s) external onlyOperator { isBlacklisted[a] = s; }
    function adminFundOperationalBNB() external payable onlyOperator {
        if (msg.value == 0) revert InvalidAmount();
    }
    function adminFundRewardPool() external payable onlyOperator {
        if (msg.value == 0) revert InvalidAmount();
        reservedRewardPool += msg.value;
    }

    function setTradingEnabled(bool e) external onlyOperator { tradingEnabled = e; }
    function setTradingFees(uint256 _b, uint256 _s) external onlyOperator { if (_b > MPU_DENOMINATOR || _s > MPU_DENOMINATOR) revert InvalidFee(); buyFee = _b; sellFee = _s; }
    function setProfitTaxConfig(bool _e, uint256 _r) external onlyOperator { if (_r > MPU_DENOMINATOR) revert InvalidRate(); profitTaxEnabled = _e; profitTaxRate = _r; }
    function setStakingFees(uint256 _f, uint256 _n, uint256 _z) external onlyOperator {
        if (_f + _n + _z > 1_000_000) revert InvalidFee();
        _validateRewardReserveConfig(_f, _n, _z, rewardReserveBp);
        fundFeeBp = _f; nftFeeBp = _n; zombieFeeBp = _z;
    }
    function setRewardReserveBp(uint256 _r) external onlyOperator {
        if (_r > MPU_DENOMINATOR) revert InvalidRate();
        _validateRewardReserveConfig(fundFeeBp, nftFeeBp, zombieFeeBp, _r);
        rewardReserveBp = _r;
    }
    function setStakeAmountLimits(uint256 _min, uint256 _max) external onlyOperator { if (_min > _max) revert InvalidAmount(); minStakeAmount = _min; maxStake = _max; }
    function setCompoundConfig(uint256 _cd, uint256 _vp) external onlyOperator {
        if (_cd == 0 || _vp == 0 || _vp < _cd * 1 days) revert InvalidAmount();
        cycleDays = _cd; validPeriod = _vp;
    }
    function setDailyReturnBp(uint256 _d) external onlyOperator { if (_d > MPU_DENOMINATOR) revert InvalidRate(); dailyReturnBp = _d; }
    function setPrincipalReturnBp(uint256 _p) external onlyOperator { if (_p > 1_000_000) revert InvalidRate(); principalReturnBp = _p; }
    function setUserLevel(address u, uint8 l) external onlyOperator {
        if (l > 5) revert InvalidAmount();
        teamInfos[u].level = l;
    }
    function setNftbConfig(uint256 _t) external onlyOperator { nftThreshold = _t; }
    function setBurnConfig(uint256 _r, bool _e, uint256 _db, uint256 _dvb, uint256 _i) external onlyOperator {
        if (_r > MPU_DENOMINATOR) revert InvalidRate(); if (_db + _dvb == 0) revert InvalidRate(); if (_i < 1 hours || _i > 7 days) revert InvalidAmount();
        burnDailyRate = _r; burningEnabled = _e; burnDeadBp = _db; burnDividendBp = _dvb; burnInterval = _i;
    }
    function setZeroExitEnabled(bool e) external onlyOperator { zeroExitEnabled = e; }
    function setRewardPoolConfig(uint256 _t, uint256 _b, uint256 _s) external onlyOperator { rewardPoolThreshold = _t; lpWithdrawBatchAmount = _b; if (_s > MPU_DENOMINATOR) revert InvalidRate(); maxSlippage = _s; }
    function setLevelConfig(uint8 _l, uint256 _th, uint256 _r) external onlyOperator { if (_l == 0 || _l > 5) revert InvalidAmount(); if (_r > MPU_DENOMINATOR) revert InvalidRate(); levelConfigs[_l] = LevelConfig(_th, _r); }

    function withdrawRewardPool(uint256 amt) external onlyOperator {
        if (amt > reservedRewardPool) revert InsufficientBalance();
        reservedRewardPool -= amt; _safeTransferETH(fundAddress, amt);
    }

    function setPaused(bool _p) external onlyOperator { paused = _p; }

    function rescueBNB(uint256 amt) external onlyOperator {
        if (amt > address(this).balance) revert InsufficientBalance();
        address recipient = _rescueRecipient();
        (bool ok, ) = recipient.call{value: amt}(""); if (!ok) revert TransferFailed();
    }
    function rescueToken(address tok, uint256 amt) external onlyOperator {
        if (tok == address(0)) revert ZeroAddress();
        address recipient = _rescueRecipient();
        if (tok == address(this)) super._update(address(this), recipient, amt);
        else { bool ok = IERC20(tok).transfer(recipient, amt); if (!ok) revert TransferFailed(); }
    }

    // ============ Migration ============
    function batchSetInviter(address[] calldata users, address[] calldata inviters) external onlyOwner migrationOpen {
        if (users.length != inviters.length) revert InvalidAmount();
        uint256 len = users.length;
        for (uint256 i = 0; i < len;) {
            if (inviter[users[i]] == address(0) && inviters[i] != address(0)) {
                inviter[users[i]] = inviters[i]; binders[inviters[i]].push(users[i]);
            }
            unchecked { ++i; }
        }
    }
    function batchSetStakeInfo(address[] calldata users, uint256[] calldata amounts, uint256[] calldata deadlines) external onlyOwner migrationOpen {
        if (users.length != amounts.length || users.length != deadlines.length) revert InvalidAmount();
        uint256 len = users.length;
        for (uint256 i = 0; i < len;) {
            StakeInfo storage info = stakeInfos[users[i]];
            info.recordedAmount = amounts[i]; info.nextDeadline = deadlines[i];
            unchecked { ++i; }
        }
    }
    function batchSetTeamInfo(address[] calldata users, uint256[] calldata totals, uint8[] calldata levels) external onlyOwner migrationOpen {
        if (users.length != totals.length || users.length != levels.length) revert InvalidAmount();
        uint256 len = users.length;
        for (uint256 i = 0; i < len;) {
            TeamInfo storage t = teamInfos[users[i]]; t.totalAmount = totals[i]; t.level = levels[i];
            unchecked { ++i; }
        }
    }
    function batchMintTokens(address[] calldata users, uint256[] calldata amounts) external onlyOwner migrationOpen {
        if (users.length != amounts.length) revert InvalidAmount();
        uint256 len = users.length;
        for (uint256 i = 0; i < len;) {
            _mint(users[i], amounts[i]);
            unchecked { ++i; }
        }
    }
    function lockMigration() external onlyOwner { migrationLocked = true; }

    // ============ Utility ============
    function _safeTransferETH(address to, uint256 amt) internal {
        if (amt == 0 || to == address(0)) return;
        (bool ok, ) = to.call{value: amt}(""); if (!ok) revert TransferFailed();
    }

}
