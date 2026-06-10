// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IXYYDividend
 * @notice XYYDividend 合约接口 — Contract B
 * @dev Contract A (XYYTokenV2) 通过此接口调用分红系统
 */
interface IXYYDividend {
    // ============ 事件 ============
    event NFTQualificationChanged(address indexed user, bool qualified, uint256 stakeAmount);
    event NFTBMinted(address indexed user, uint256 amount);
    event NFTBClaimed(address indexed user, uint256 amount);
    event NFTBBurned(address indexed user, uint256 amount);
    event BurnDividendClaimed(address indexed user, uint256 amount);
    event BurnExecuted(uint256 burnAmount, uint256 toDead, uint256 toDividend);

    // ============ Contract A → Contract B 状态变更 ============

    /// @notice 设置用户 NFT 分红资格（新获得资格）
    function setNFTQualification(address user, bool qualified, uint256 stakeAmount) external;

    /// @notice 更新已有 NFT 资格用户的质押金额
    function updateNFTStake(address user, uint256 newAmount) external;

    /// @notice 撤销用户 NFT 资格
    function revokeNFTQualification(address user) external;

    /// @notice 累积 NFT 分红奖励（payable，传入 BNB）
    function accumulateNftReward(uint256 amount) external payable;

    /// @notice 更新用户有效质押状态（用于燃烧分红）
    function updateValidStake(address user, uint256 amount, bool isValid) external;

    /// @notice 清理过期 NFT 持有者，返回本次清理数量
    function cleanupExpiredNftHolders() external returns (uint256);

    /// @notice 清理过期有效质押者，返回本次清理数量
    function cleanupExpiredValidStakeHolders() external returns (uint256);

    /// @notice 代用户领取燃烧分红（复投时自动调用）
    function claimBurnDividendFor(address user) external returns (uint256);

    // ============ 用户直接调用 ============

    /// @notice 用户领取 NFT 分红（销毁 NFTB 换 BNB）
    function claimNftDividend(uint256 amount) external;

    /// @notice NFTB 自动兑换回调（NFTB 转入时触发）
    function autoClaimForUser(address user, uint256 amount) external;

    /// @notice 用户领取燃烧分红（XYY 代币）
    function claimBurnDividend() external;

    // ============ 底池燃烧 ============

    /// @notice 执行底池燃烧（由 Contract A 的 triggerDailyProcess 调用）
    function executeDailyBurn() external;

    /// @notice 接收燃烧分红代币并更新账本
    function receiveBurnDividend(uint256 toDividend) external;

    // ============ 视图函数 ============

    function hasNftQualification(address account) external view returns (bool);
    function nftStakeAmount(address account) external view returns (uint256);
    function pendingNftReward(address account) external view returns (uint256);
    function pendingBurnDividend(address account) external view returns (uint256);
    function totalNftStakeAmount() external view returns (uint256);
    function totalValidStakeAmount() external view returns (uint256);
    function nftDividendPool() external view returns (uint256);
    function burnDividendPool() external view returns (uint256);
    function accNftPerShare() external view returns (uint256);
    function accBurnPerShare() external view returns (uint256);
    function lastBurnTime() external view returns (uint256);

    // ============ 迁移函数 ============
    function batchSetNFTQualification(address[] calldata users, uint256[] calldata stakeAmounts) external;
    function batchSetValidStake(address[] calldata users, uint256[] calldata amounts) external;
    function lockMigration() external;
}
