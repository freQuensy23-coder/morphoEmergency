pragma solidity 0.8.26;

import {IERC4626} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title EmergencyVaultWrapper
/// @notice Wrapper for MetaMorpho vaults with emergency exit capability
/// @dev Owner can trigger emergency mode, but funds always go back to depositors
contract EmergencyVaultWrapper is Ownable2Step {
    using SafeERC20 for IERC20;

    struct VaultState {
        bool emergency;
        uint256 totalShares;  // total wrapper shares (not vault shares)
        uint256 withdrawnAssets;  // assets withdrawn during emergency
    }

    mapping(address vault => VaultState) public vaultStates;
    mapping(address vault => mapping(address user => uint256 shares)) public userShares;

    event Deposit(address indexed vault, address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed vault, address indexed user, uint256 assets, uint256 shares);
    event EmergencyTriggered(address indexed vault, uint256 totalAssets);
    event EmergencyClaim(address indexed vault, address indexed user, uint256 assets);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Deposit assets to MetaMorpho vault via this wrapper
    function deposit(address vault, uint256 assets, address receiver) external returns (uint256 shares) {
        require(!vaultStates[vault].emergency, "emergency");
        IERC20 asset = IERC20(IERC4626(vault).asset());
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(vault, assets);
        shares = IERC4626(vault).deposit(assets, address(this));
        userShares[vault][receiver] += shares;
        vaultStates[vault].totalShares += shares;
        emit Deposit(vault, receiver, assets, shares);
    }

    /// @notice Withdraw assets from MetaMorpho vault
    function withdraw(address vault, uint256 shares, address receiver) external returns (uint256 assets) {
        require(!vaultStates[vault].emergency, "emergency");
        require(userShares[vault][msg.sender] >= shares, "insufficient");
        userShares[vault][msg.sender] -= shares;
        vaultStates[vault].totalShares -= shares;
        assets = IERC4626(vault).redeem(shares, receiver, address(this));
        emit Withdraw(vault, msg.sender, assets, shares);
    }

    /// @notice Trigger emergency mode - withdraws all from vault, users claim their share
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

    /// @notice Claim assets after emergency (proportional to user's shares)
    function emergencyClaim(address vault) external returns (uint256 assets) {
        VaultState storage state = vaultStates[vault];
        require(state.emergency, "not emergency");
        uint256 shares = userShares[vault][msg.sender];
        require(shares > 0, "nothing to claim");
        userShares[vault][msg.sender] = 0;
        assets = (state.withdrawnAssets * shares) / state.totalShares;
        IERC20(IERC4626(vault).asset()).safeTransfer(msg.sender, assets);
        emit EmergencyClaim(vault, msg.sender, assets);
    }

    /// @notice View user's current share value in assets
    function previewUserAssets(address vault, address user) external view returns (uint256) {
        if (vaultStates[vault].emergency) {
            VaultState storage state = vaultStates[vault];
            return (state.withdrawnAssets * userShares[vault][user]) / state.totalShares;
        }
        return IERC4626(vault).previewRedeem(userShares[vault][user]);
    }
}

