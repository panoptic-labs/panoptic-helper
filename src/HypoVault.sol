// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Interfaces
import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultAccountant} from "./interfaces/IVaultAccountant.sol";
// Base
import {Multicall} from "@base/Multicall.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// Libraries
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";

/// @author dyedm1
contract HypoVault is ERC20Minimal, Multicall, Ownable {
    using Address for address;
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct PendingAction {
        uint128 amount; // assets for deposits, shares for withdrawals
        uint128 epoch; // epoch *after* which the withdrawal can be processed
    }

    struct EpochState {
        uint128 totalAssets;
        uint128 totalShares;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Only the vault manager is authorized to call this function
    error NotManager();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public immutable underlyingToken;

    address public manager;

    IVaultAccountant public accountant;

    uint128 depositEpoch = 1;

    uint128 withdrawalEpoch = 1;

    uint256 sharesPendingWithdrawal;

    uint256 assetsPendingDeposit;

    uint256 withdrawableAssets;

    mapping(uint256 epoch => EpochState) depositEpochState;
    mapping(uint256 epoch => EpochState) withdrawalEpochState;

    mapping(address user => PendingAction queue) queuedDeposit;
    mapping(address user => PendingAction queue) queuedWithdrawal;

    constructor(address _underlyingToken, address _manager, IVaultAccountant _accountant) {
        underlyingToken = _underlyingToken;
        manager = _manager;
        accountant = _accountant;
    }

    /*//////////////////////////////////////////////////////////////
                                  AUTH
    //////////////////////////////////////////////////////////////*/

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    function setManager(address _manager) external onlyOwner {
        manager = _manager;
    }

    function setAccountant(address _accountant) external onlyOwner {
        accountant = IVaultAccountant(_accountant);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/REDEEM LOGIC
    //////////////////////////////////////////////////////////////*/

    // queues a deposit that becomes active at the beginning of the next epoch
    function editDepositQueue(uint128 updatedDepositAssets) external {
        PendingAction memory pendingDeposit = queuedDeposit[msg.sender];

        uint128 currentEpoch = depositEpoch;

        int256 depositDelta;
        // if the previous queued deposit has already been processed, reset the queued deposit state and mint shares
        if (pendingDeposit.epoch > 0 && currentEpoch > pendingDeposit.epoch) {
            EpochState memory _depositEpochState = depositEpochState[currentEpoch];

            // shares from pending deposits are already added to the supply at the start of every new epoch
            balanceOf[msg.sender] += Math.mulDiv(
                pendingDeposit.amount,
                _depositEpochState.totalShares,
                _depositEpochState.totalAssets
            );

            queuedDeposit[msg.sender] = PendingAction({
                amount: updatedDepositAssets,
                epoch: currentEpoch
            });

            depositDelta = int256(uint256(updatedDepositAssets));
        } else {
            depositDelta =
                int256(uint256(updatedDepositAssets)) -
                int256(uint256(pendingDeposit.amount));
            queuedDeposit[msg.sender] = PendingAction({
                amount: updatedDepositAssets,
                epoch: currentEpoch
            });
        }

        assetsPendingDeposit = uint256(int256(assetsPendingDeposit) + depositDelta);

        if (depositDelta > 0)
            SafeTransferLib.safeTransferFrom(
                underlyingToken,
                msg.sender,
                address(this),
                uint256(depositDelta)
            );
        else if (depositDelta < 0)
            SafeTransferLib.safeTransfer(underlyingToken, msg.sender, uint256(-depositDelta));
    }

    // convert an active pending deposit into shares
    function executeDeposit(address user) external {
        PendingAction memory pendingDeposit = queuedDeposit[user];

        require(depositEpoch > pendingDeposit.epoch, "HypoVault: deposit not yet processed");

        EpochState memory _depositEpochState = depositEpochState[pendingDeposit.epoch];

        // shares from pending deposits are already added to the supply at the start of every new epoch
        balanceOf[user] += Math.mulDiv(
            pendingDeposit.amount,
            _depositEpochState.totalShares,
            _depositEpochState.totalAssets
        );

        queuedDeposit[user] = PendingAction(0, 0);
    }

    // queues a withdrawal that executes at the beginning of the next epoch
    function editWithdrawalQueue(uint128 updatedWithdrawalShares) external {
        PendingAction memory pendingWithdrawal = queuedWithdrawal[msg.sender];

        uint128 currentEpoch = withdrawalEpoch;

        // if the previous queued withdrawal has already been processed, reset the queued withdrawal state and distribute tokens
        if (pendingWithdrawal.epoch > 0 && currentEpoch > pendingWithdrawal.epoch) {
            EpochState memory _withdrawalEpochState = withdrawalEpochState[currentEpoch];

            queuedWithdrawal[msg.sender] = PendingAction({
                amount: updatedWithdrawalShares,
                epoch: currentEpoch
            });

            balanceOf[msg.sender] -= updatedWithdrawalShares;

            sharesPendingWithdrawal = uint256(
                int256(sharesPendingWithdrawal) + int256(uint256(updatedWithdrawalShares))
            );

            SafeTransferLib.safeTransfer(
                underlyingToken,
                msg.sender,
                Math.mulDiv(
                    pendingWithdrawal.amount,
                    _withdrawalEpochState.totalAssets,
                    _withdrawalEpochState.totalShares
                )
            );
        } else {
            queuedWithdrawal[msg.sender] = PendingAction({
                amount: updatedWithdrawalShares,
                epoch: currentEpoch
            });

            int256 withdrawalDelta = int256(uint256(updatedWithdrawalShares)) -
                int256(uint256(pendingWithdrawal.amount));

            if (withdrawalDelta > 0) balanceOf[msg.sender] -= uint256(withdrawalDelta);
            else balanceOf[msg.sender] = uint256(int256(balanceOf[msg.sender]) - withdrawalDelta);

            sharesPendingWithdrawal = uint256(int256(sharesPendingWithdrawal) + withdrawalDelta);
        }
    }

    // convert an active pending withdrawal into assets
    function executeWithdrawal(address user) external {
        PendingAction memory pendingWithdrawal = queuedWithdrawal[user];

        require(
            withdrawalEpoch > pendingWithdrawal.epoch,
            "HypoVault: withdrawal not yet processed"
        );

        EpochState memory _withdrawalEpochState = withdrawalEpochState[pendingWithdrawal.epoch];

        sharesPendingWithdrawal = uint256(
            int256(sharesPendingWithdrawal) - int256(uint256(pendingWithdrawal.amount))
        );

        queuedWithdrawal[user] = PendingAction(0, 0);

        uint256 assetsToWithdraw = Math.mulDiv(
            pendingWithdrawal.amount,
            _withdrawalEpochState.totalAssets,
            _withdrawalEpochState.totalShares
        );

        withdrawableAssets -= assetsToWithdraw;

        SafeTransferLib.safeTransfer(underlyingToken, user, assetsToWithdraw);
    }

    /*//////////////////////////////////////////////////////////////
                            VAULT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows `manager` to make an arbitrary function call from this contract.
    function manage(
        address target,
        bytes calldata data,
        uint256 value
    ) external onlyManager returns (bytes memory result) {
        result = target.functionCallWithValue(data, value);
    }

    /// @notice Allows `manager` to make arbitrary function calls from this contract.
    function manage(
        address[] calldata targets,
        bytes[] calldata data,
        uint256[] calldata values
    ) external onlyManager returns (bytes[] memory results) {
        uint256 targetsLength = targets.length;
        results = new bytes[](targetsLength);
        for (uint256 i; i < targetsLength; ++i) {
            results[i] = targets[i].functionCallWithValue(data[i], values[i]);
        }
    }

    // assigns a share price for all deposits in the current epoch and increments the deposit epoch
    function fulfillDeposits(bytes memory managerInput) external onlyManager {
        uint256 totalAssets = accountant.computeNAV(address(this), managerInput) -
            assetsPendingDeposit -
            withdrawableAssets;

        uint256 currentEpoch = depositEpoch;

        uint256 _totalSupply = totalSupply;
        depositEpochState[currentEpoch] = EpochState({
            totalAssets: uint128(totalAssets),
            totalShares: uint128(_totalSupply)
        });

        assetsPendingDeposit = 0;

        totalSupply = _totalSupply + Math.mulDiv(assetsPendingDeposit, _totalSupply, totalAssets);

        depositEpoch = uint128(currentEpoch + 1);
    }

    // assigns a share price for all withdrawals in the current epoch and increments the withdrawal epoch
    function fulfillWithdrawals(bytes memory managerInput) external onlyManager {
        uint256 _withdrawableAssets = withdrawableAssets;
        uint256 totalAssets = accountant.computeNAV(address(this), managerInput) -
            assetsPendingDeposit -
            _withdrawableAssets;

        uint256 currentEpoch = withdrawalEpoch;

        uint256 _totalSupply = totalSupply;

        withdrawalEpochState[currentEpoch] = EpochState({
            totalAssets: uint128(totalAssets),
            totalShares: uint128(_totalSupply)
        });

        uint256 _sharesPendingWithdrawal = sharesPendingWithdrawal;
        totalSupply = _totalSupply - sharesPendingWithdrawal;

        withdrawableAssets =
            _withdrawableAssets +
            Math.mulDiv(_sharesPendingWithdrawal, _withdrawableAssets, _totalSupply);

        sharesPendingWithdrawal = 0;

        withdrawalEpoch = uint128(currentEpoch + 1);
    }
}
