// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IPredictionMarket.sol";
import "../interfaces/IOCPVault.sol";

/**
 * @title PredictionMarket
 * @dev 预测市场：恒定乘积 AMM + 手续费进金库；解析由金库（含冷静期/挑战/再质押）终局决定
 *
 * - 二元 YES/NO 市场
 * - 0.3% 交易手续费 donate 到金库
 * - 解析由金库 getOutcome() 决定（金库已实现 POC 一次性挑战与挑战期）
 */
contract PredictionMarket is ReentrancyGuard, IPredictionMarket {
    using SafeERC20 for IERC20;

    /// @notice 交易手续费（bps，0.3% = 30）
    uint256 private constant FEE_BPS = 30;
    /// @notice bps 分母
    uint256 private constant BPS = 10000;

    /// @notice 关联金库
    IOCPVault public immutable vaultContract;
    /// @notice 抵押品（交易币种）
    IERC20 private immutable _collateral;

    /// @notice 返回交易手续费（bps）
    function feeBps() external pure returns (uint256) {
        return FEE_BPS;
    }

    /// @notice 返回抵押品 ERC20 地址
    function collateral() external view override returns (address) {
        return address(_collateral);
    }
    /// @notice 市场工厂地址（部署者）
    address public immutable factory;

    /// @notice 条件类型（协议层定义）
    uint8 public immutable override conditionType;
    /// @notice 条件参数（ABI 编码）
    bytes public override conditionParams;
    /// @notice 解析时间
    uint256 public immutable override resolutionTime;

    /// @notice 是否已解析
    bool public override resolved;
    /// @notice 解析结果
    Outcome public override outcome;

    // AMM 恒定乘积：yesReserve * noReserve = k
    /// @notice YES 池储备（计价单位为 collateral）
    uint256 public yesReserve;
    /// @notice NO 池储备（计价单位为 collateral）
    uint256 public noReserve;
    /// @notice 池中实际抵押品总量（用于 INVALID 退款）
    uint256 public poolCollateral; // 池中实际抵押品

    /// @notice 用户 YES 份额（可赎回）
    mapping(address => uint256) public yesShares;
    /// @notice 用户 NO 份额（可赎回）
    mapping(address => uint256) public noShares;
    /// @notice YES 侧总份额
    uint256 public totalYesShares;
    /// @notice NO 侧总份额
    uint256 public totalNoShares;

    /// @notice 交易事件（买入/卖出都会触发）
    event Trade(
        address indexed trader,
        bool indexed isYes,
        uint256 amountIn,
        uint256 amountOut
    );
    /// @notice 初始流动性添加事件
    event LiquidityAdded(address indexed provider, uint256 amount);
    /// @notice 解析后赎回事件
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
        // 参数校验
        require(_vault != address(0), "Invalid vault");
        require(_resolutionTime > block.timestamp, "Invalid resolutionTime");

        // 绑定金库与抵押品
        vaultContract = IOCPVault(_vault);
        _collateral = vaultContract.stakeToken();
        factory = msg.sender;
        conditionType = _conditionType;
        conditionParams = _conditionParams;
        resolutionTime = _resolutionTime;
        _treasury; // 预留，当前费用进金库
    }

    /// @notice 返回金库地址
    function vault() external view override returns (address) {
        return address(vaultContract);
    }

    function getYesNoPrice()
        external
        view
        override
        returns (uint256 yesPrice, uint256 noPrice)
    {
        // 按储备比例返回隐含价格
        uint256 total = yesReserve + noReserve;
        if (total == 0) return (0.5e18, 0.5e18);
        yesPrice = (yesReserve * 1e18) / total;
        noPrice = (noReserve * 1e18) / total;
    }

    /// @notice 添加初始流动性：金额按 50-50 进入 YES/NO 储备池。可不注入（由创建者或他人后续调用）。当前无 LP 份额、无 LP 分红、无退出路径，注入即视为创建者/提供者策略。
    function addLiquidity(uint256 amount) external nonReentrant {
        // 仅在市场未到期时添加
        require(block.timestamp < resolutionTime, "Market closed");
        require(amount > 0, "Amount must be > 0");
        require(yesReserve == 0 && noReserve == 0, "Already has liquidity");

        // 资金进入池子，按 50/50 划分储备
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
        // 到期后禁止交易，以保证解析一致性
        require(block.timestamp < resolutionTime, "Market closed");
        require(yesReserve > 0 && noReserve > 0, "No liquidity");

        // 计算手续费与净入金
        uint256 fee = (amountIn * FEE_BPS) / BPS;
        uint256 amountInAfterFee = amountIn - fee;

        // 恒定乘积: amountOut = yesReserve * amountInAfterFee / (noReserve + amountInAfterFee)
        amountOut =
            (yesReserve * amountInAfterFee) /
            (noReserve + amountInAfterFee);
        require(amountOut >= minOut, "Slippage");

        // 转入资金并捐赠手续费给金库
        _collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        _donateFeeToVault(fee);

        // 更新池子与用户份额
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
        // 到期后禁止交易，以保证解析一致性
        require(block.timestamp < resolutionTime, "Market closed");
        require(yesReserve > 0 && noReserve > 0, "No liquidity");

        // 计算手续费与净入金
        uint256 fee = (amountIn * FEE_BPS) / BPS;
        uint256 amountInAfterFee = amountIn - fee;

        amountOut =
            (noReserve * amountInAfterFee) /
            (yesReserve + amountInAfterFee);
        require(amountOut >= minOut, "Slippage");

        // 转入资金并捐赠手续费给金库
        _collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        _donateFeeToVault(fee);

        // 更新池子与用户份额
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
        // 到期后禁止交易，以保证解析一致性
        require(block.timestamp < resolutionTime, "Market closed");
        require(yesShares[msg.sender] >= amountIn, "Insufficient yes shares");

        // 先按恒定乘积算出卖出总额，再扣手续费
        uint256 amountOutGross = (noReserve * amountIn) /
            (yesReserve + amountIn);
        uint256 fee = (amountOutGross * FEE_BPS) / BPS;
        amountOut = amountOutGross - fee;
        require(amountOut >= minOut, "Slippage");

        // 更新份额与池子
        yesShares[msg.sender] -= amountIn;
        totalYesShares -= amountIn;

        yesReserve += amountIn;
        noReserve -= amountOutGross;
        poolCollateral -= amountOutGross;

        // 手续费捐赠给金库，净额支付给用户
        _donateFeeToVault(fee);
        _collateral.safeTransfer(msg.sender, amountOut);

        emit Trade(msg.sender, true, amountIn, amountOut);
    }

    /// @notice 卖出 NO
    function sellNo(
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256 amountOut) {
        // 到期后禁止交易，以保证解析一致性
        require(block.timestamp < resolutionTime, "Market closed");
        require(noShares[msg.sender] >= amountIn, "Insufficient no shares");

        // 先按恒定乘积算出卖出总额，再扣手续费
        uint256 amountOutGross = (yesReserve * amountIn) /
            (noReserve + amountIn);
        uint256 fee = (amountOutGross * FEE_BPS) / BPS;
        amountOut = amountOutGross - fee;
        require(amountOut >= minOut, "Slippage");

        // 更新份额与池子
        noShares[msg.sender] -= amountIn;
        totalNoShares -= amountIn;

        noReserve += amountIn;
        yesReserve -= amountOutGross;
        poolCollateral -= amountOutGross;

        // 手续费捐赠给金库，净额支付给用户
        _donateFeeToVault(fee);
        _collateral.safeTransfer(msg.sender, amountOut);

        emit Trade(msg.sender, false, amountIn, amountOut);
    }

    /// @notice 解析：读取金库结果
    function resolve() external nonReentrant {
        // 若金库尚未终局，则尝试触发终局
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

        // 记录赎回前总份额，用于 INVALID 按比例退款
        uint256 totalSharesBefore = totalYesShares + totalNoShares;

        yesShares[msg.sender] -= yesAmount;
        noShares[msg.sender] -= noAmount;
        totalYesShares -= yesAmount;
        totalNoShares -= noAmount;

        // 根据终局结果计算应得金额
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

    /// @dev 将手续费捐赠到金库（通过 approve + donate），避免直接转账
    function _donateFeeToVault(uint256 fee) private {
        // 为避免与旧 allowance 冲突，先归零再设置
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
            // 仅授权本次手续费额度
            _collateral.safeIncreaseAllowance(address(vaultContract), fee);
            vaultContract.donate(fee);
        }
    }
}
