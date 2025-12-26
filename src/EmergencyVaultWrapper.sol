// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title EmergencyVaultWrapper
/// @notice Wrapper for MetaMorpho vaults with emergency exit and performance fee
contract EmergencyVaultWrapper is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_DENOMINATOR = 1e18;

    struct VaultState {
        bool emergency;
        uint256 totalShares;
        uint256 withdrawnAssets;
    }

    address public feeRecipient;
    uint256 public feeRate; // e.g., 0.02e18 = 2%
    bool public isFeeEnabled;

    mapping(address vault => VaultState) public vaultStates;
    mapping(address vault => mapping(address user => uint256 shares)) public userShares;
    mapping(address vault => mapping(address user => uint256 deposited)) public userDeposited;

    event Deposit(address indexed vault, address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed vault, address indexed user, uint256 assets, uint256 shares, uint256 fee);
    event EmergencyTriggered(address indexed vault, uint256 totalAssets);
    event EmergencyClaim(address indexed vault, address indexed user, uint256 assets, uint256 fee);
    event FeeConfigUpdated(address feeRecipient, uint256 feeRate, bool enabled);

    constructor(address owner_, address feeRecipient_, uint256 feeRate_) Ownable(owner_) {
        feeRecipient = feeRecipient_;
        feeRate = feeRate_;
    }

    function setFeeConfig(address feeRecipient_, uint256 feeRate_, bool enabled) external onlyOwner {
        feeRecipient = feeRecipient_;
        feeRate = feeRate_;
        isFeeEnabled = enabled;
        emit FeeConfigUpdated(feeRecipient_, feeRate_, enabled);
    }

    function deposit(address vault, uint256 assets, address receiver) external returns (uint256 shares) {
        require(!vaultStates[vault].emergency, "emergency");
        IERC20 asset = IERC20(IERC4626(vault).asset());
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(vault, assets);
        shares = IERC4626(vault).deposit(assets, address(this));
        userShares[vault][receiver] += shares;
        userDeposited[vault][receiver] += assets;
        vaultStates[vault].totalShares += shares;
        emit Deposit(vault, receiver, assets, shares);
    }

    function withdraw(address vault, uint256 shares, address receiver) external returns (uint256 assets) {
        require(!vaultStates[vault].emergency, "emergency");
        require(userShares[vault][msg.sender] >= shares, "insufficient");
        
        uint256 userTotalShares = userShares[vault][msg.sender];
        uint256 depositedPortion = (userDeposited[vault][msg.sender] * shares) / userTotalShares;
        
        userShares[vault][msg.sender] -= shares;
        userDeposited[vault][msg.sender] -= depositedPortion;
        vaultStates[vault].totalShares -= shares;
        
        assets = IERC4626(vault).redeem(shares, address(this), address(this));
        uint256 fee = _calculateAndTransferFee(vault, assets, depositedPortion);
        IERC20(IERC4626(vault).asset()).safeTransfer(receiver, assets - fee);
        emit Withdraw(vault, msg.sender, assets - fee, shares, fee);
    }

    function triggerEmergency(address vault) external onlyOwner {
        VaultState storage state = vaultStates[vault];
        require(!state.emergency, "already emergency");
        state.emergency = true;
        uint256 vaultShares = IERC20(vault).balanceOf(address(this));
        if (vaultShares > 0) {
            state.withdrawnAssets = IERC4626(vault).redeem(vaultShares, address(this), address(this));
        }
        emit EmergencyTriggered(vault, state.withdrawnAssets);
    }

    function emergencyClaim(address vault) external returns (uint256 assets) {
        VaultState storage state = vaultStates[vault];
        require(state.emergency, "not emergency");
        uint256 shares = userShares[vault][msg.sender];
        require(shares > 0, "nothing to claim");
        
        uint256 deposited = userDeposited[vault][msg.sender];
        userShares[vault][msg.sender] = 0;
        userDeposited[vault][msg.sender] = 0;
        
        assets = (state.withdrawnAssets * shares) / state.totalShares;
        uint256 fee = _calculateAndTransferFee(vault, assets, deposited);
        IERC20(IERC4626(vault).asset()).safeTransfer(msg.sender, assets - fee);
        emit EmergencyClaim(vault, msg.sender, assets - fee, fee);
    }

    function _calculateAndTransferFee(address vault, uint256 withdrawn, uint256 deposited) internal returns (uint256 fee) {
        if (!isFeeEnabled || withdrawn <= deposited) return 0;
        uint256 profit = withdrawn - deposited;
        fee = (profit * feeRate) / FEE_DENOMINATOR;
        if (fee > 0) IERC20(IERC4626(vault).asset()).safeTransfer(feeRecipient, fee);
    }

    function previewUserAssets(address vault, address user) external view returns (uint256) {
        if (vaultStates[vault].emergency) {
            return (vaultStates[vault].withdrawnAssets * userShares[vault][user]) / vaultStates[vault].totalShares;
        }
        return IERC4626(vault).previewRedeem(userShares[vault][user]);
    }
}
