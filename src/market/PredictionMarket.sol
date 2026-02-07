// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IPredictionMarket.sol";
import "../interfaces/IOCPVault.sol";

/**
 * @title PredictionMarket
 * @dev 预测市场 MVP：恒定乘积 AMM + 手续费进金库
 *
 * - 二元 YES/NO 市场
 * - 0.3% 交易手续费 donate 到金库
 * - 解析由金库投票决定
 */
contract PredictionMarket is ReentrancyGuard, IPredictionMarket {
    using SafeERC20 for IERC20;

    uint256 private constant FEE_BPS = 30; // 0.3% = 30 bps
    uint256 private constant BPS = 10000;

    IOCPVault public immutable vaultContract;
    IERC20 private immutable _collateral;

    function collateral() external view override returns (address) {
        return address(_collateral);
    }
    address public immutable factory;

    uint8 public immutable override conditionType;
    bytes public override conditionParams;
    uint256 public immutable override resolutionTime;

    bool public override resolved;
    Outcome public override outcome;

    // AMM 恒定乘积：yesReserve * noReserve = k
    uint256 public yesReserve;
    uint256 public noReserve;
    uint256 public poolCollateral; // 池中实际抵押品

    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;
    uint256 public totalYesShares;
    uint256 public totalNoShares;

    event Trade(
        address indexed trader,
        bool indexed isYes,
        uint256 amountIn,
        uint256 amountOut
    );
    event LiquidityAdded(address indexed provider, uint256 amount);
    event Redeemed(
        address indexed user,
        uint256 yesAmount,
        uint256 noAmount,
        uint256 payout
    );

    constructor(
        address _vault,
        address _treasury,
        uint8 _conditionType,
        bytes memory _conditionParams,
        uint256 _resolutionTime
    ) {
        require(_vault != address(0), "Invalid vault");
        require(_resolutionTime > block.timestamp, "Invalid resolutionTime");

        vaultContract = IOCPVault(_vault);
        _collateral = vaultContract.stakeToken();
        factory = msg.sender;
        conditionType = _conditionType;
        conditionParams = _conditionParams;
        resolutionTime = _resolutionTime;
        _treasury; // 预留，MVP 费用进金库
    }

    function vault() external view override returns (address) {
        return address(vaultContract);
    }

    function getYesNoPrice()
        external
        view
        override
        returns (uint256 yesPrice, uint256 noPrice)
    {
        uint256 total = yesReserve + noReserve;
        if (total == 0) return (0.5e18, 0.5e18);
        yesPrice = (yesReserve * 1e18) / total;
        noPrice = (noReserve * 1e18) / total;
    }

    /// @notice 添加初始流动性：金额按 50-50 进入 YES/NO 储备池。可不注入（由创建者或他人后续调用）。当前无 LP 份额、无 LP 分红、无退出路径，注入即视为创建者/提供者策略。
    function addLiquidity(uint256 amount) external nonReentrant {
        require(block.timestamp < resolutionTime, "Market closed");
        require(amount > 0, "Amount must be > 0");
        require(yesReserve == 0 && noReserve == 0, "Already has liquidity");

        _collateral.safeTransferFrom(msg.sender, address(this), amount);
        poolCollateral = amount;
        yesReserve = amount / 2;
        noReserve = amount - (amount / 2);

        emit LiquidityAdded(msg.sender, amount);
    }

    /// @notice 买入 YES
    function buyYes(
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(block.timestamp < resolutionTime, "Market closed");
        require(yesReserve > 0 && noReserve > 0, "No liquidity");

        uint256 fee = (amountIn * FEE_BPS) / BPS;
        uint256 amountInAfterFee = amountIn - fee;

        // 恒定乘积: amountOut = yesReserve * amountInAfterFee / (noReserve + amountInAfterFee)
        amountOut =
            (yesReserve * amountInAfterFee) /
            (noReserve + amountInAfterFee);
        require(amountOut >= minOut, "Slippage");

        _collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        _donateFeeToVault(fee);

        poolCollateral += amountInAfterFee;
        noReserve += amountInAfterFee;
        yesReserve -= amountOut;

        yesShares[msg.sender] += amountOut;
        totalYesShares += amountOut;

        emit Trade(msg.sender, true, amountIn, amountOut);
    }

    /// @notice 买入 NO
    function buyNo(
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(block.timestamp < resolutionTime, "Market closed");
        require(yesReserve > 0 && noReserve > 0, "No liquidity");

        uint256 fee = (amountIn * FEE_BPS) / BPS;
        uint256 amountInAfterFee = amountIn - fee;

        amountOut =
            (noReserve * amountInAfterFee) /
            (yesReserve + amountInAfterFee);
        require(amountOut >= minOut, "Slippage");

        _collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        _donateFeeToVault(fee);

        poolCollateral += amountInAfterFee;
        yesReserve += amountInAfterFee;
        noReserve -= amountOut;

        noShares[msg.sender] += amountOut;
        totalNoShares += amountOut;

        emit Trade(msg.sender, false, amountIn, amountOut);
    }

    /// @notice 卖出 YES
    function sellYes(
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(block.timestamp < resolutionTime, "Market closed");
        require(yesShares[msg.sender] >= amountIn, "Insufficient yes shares");

        uint256 amountOutGross = (noReserve * amountIn) /
            (yesReserve + amountIn);
        uint256 fee = (amountOutGross * FEE_BPS) / BPS;
        amountOut = amountOutGross - fee;
        require(amountOut >= minOut, "Slippage");

        yesShares[msg.sender] -= amountIn;
        totalYesShares -= amountIn;

        yesReserve += amountIn;
        noReserve -= amountOutGross;
        poolCollateral -= amountOutGross;

        _donateFeeToVault(fee);
        _collateral.safeTransfer(msg.sender, amountOut);

        emit Trade(msg.sender, true, amountIn, amountOut);
    }

    /// @notice 卖出 NO
    function sellNo(
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(block.timestamp < resolutionTime, "Market closed");
        require(noShares[msg.sender] >= amountIn, "Insufficient no shares");

        uint256 amountOutGross = (yesReserve * amountIn) /
            (noReserve + amountIn);
        uint256 fee = (amountOutGross * FEE_BPS) / BPS;
        amountOut = amountOutGross - fee;
        require(amountOut >= minOut, "Slippage");

        noShares[msg.sender] -= amountIn;
        totalNoShares -= amountIn;

        noReserve += amountIn;
        yesReserve -= amountOutGross;
        poolCollateral -= amountOutGross;

        _donateFeeToVault(fee);
        _collateral.safeTransfer(msg.sender, amountOut);

        emit Trade(msg.sender, false, amountIn, amountOut);
    }

    /// @notice 解析：读取金库结果
    function resolve() external nonReentrant {
        require(!resolved, "Already resolved");
        if (!vaultContract.resolved()) {
            vaultContract.finalize();
        }
        require(vaultContract.resolved(), "Vault not finalized");
        outcome = Outcome(uint8(vaultContract.outcome()));
        resolved = true;
        emit Resolved(address(this), outcome);
    }

    /// @notice 解析后赎回。终局 INVALID 时按份额比例退还池内抵押品（无人赢，全员按比例退款）
    function redeem(
        uint256 yesAmount,
        uint256 noAmount
    ) external nonReentrant returns (uint256 payout) {
        require(resolved, "Not resolved");
        require(
            yesShares[msg.sender] >= yesAmount &&
                noShares[msg.sender] >= noAmount,
            "Insufficient shares"
        );

        uint256 totalSharesBefore = totalYesShares + totalNoShares;

        yesShares[msg.sender] -= yesAmount;
        noShares[msg.sender] -= noAmount;
        totalYesShares -= yesAmount;
        totalNoShares -= noAmount;

        if (outcome == Outcome.YES) {
            payout = yesAmount;
        } else if (outcome == Outcome.NO) {
            payout = noAmount;
        } else if (outcome == Outcome.INVALID) {
            if (totalSharesBefore > 0) {
                uint256 totalBal = _collateral.balanceOf(address(this));
                payout =
                    (totalBal * (yesAmount + noAmount)) /
                    totalSharesBefore;
            }
        }

        if (payout > 0) {
            _collateral.safeTransfer(msg.sender, payout);
        }

        emit Redeemed(msg.sender, yesAmount, noAmount, payout);
    }

    function _donateFeeToVault(uint256 fee) private {
        if (fee > 0) {
            uint256 current = _collateral.allowance(
                address(this),
                address(vaultContract)
            );
            if (current > 0) {
                _collateral.safeDecreaseAllowance(
                    address(vaultContract),
                    current
                );
            }
            _collateral.safeIncreaseAllowance(address(vaultContract), fee);
            vaultContract.donate(fee);
        }
    }
}
