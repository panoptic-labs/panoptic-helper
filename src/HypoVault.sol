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
        uint128 fulfillmentAccumulatorLast; // shares for deposits, assets for withdrawals
    }

    struct EpochState {
        uint128 availableAssets; // assets that have been deposited or can be withdrawn
        uint128 availableShares; // shares that have been withdrawn or can be redeemed
        uint128 amountPending; // assets for deposits, shares for withdrawals
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

    uint256 public performanceFeeBps;

    uint128 withdrawalEpoch;

    uint128 depositEpoch;

    uint256 withdrawableAssets;

    uint256 maxSharePriceX128;

    mapping(uint256 epoch => EpochState) depositEpochState;
    mapping(uint256 epoch => EpochState) withdrawalEpochState;

    mapping(address user => mapping(uint256 epoch => PendingAction queue)) queuedDeposit;
    mapping(address user => mapping(uint256 epoch => PendingAction queue)) queuedWithdrawal;

    constructor(
        address _underlyingToken,
        address _manager,
        IVaultAccountant _accountant,
        uint256 _performanceFeeBps
    ) {
        underlyingToken = _underlyingToken;
        manager = _manager;
        accountant = _accountant;
        performanceFeeBps = _performanceFeeBps;
        totalSupply = 1_000_000;
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

    function requestDeposit(uint128 assets, address receiver) external {
        uint256 currentEpoch = depositEpoch;
        PendingAction memory pendingDeposit = queuedDeposit[receiver][currentEpoch];

        queuedDeposit[receiver][currentEpoch] = PendingAction({
            amount: pendingDeposit.amount + assets,
            fulfillmentAccumulatorLast: 0
        });

        depositEpochState[currentEpoch].availableAssets += assets;

        SafeTransferLib.safeTransferFrom(underlyingToken, msg.sender, address(this), assets);
    }

    // convert an active pending deposit into shares
    // can be called multiple times as more of the deposit becomes fulfilled
    function executeDeposit(address user, uint256 epoch) external {
        require(depositEpoch > epoch, "HypoVault: deposit not yet processed");

        PendingAction memory pendingDeposit = queuedDeposit[user][epoch];
        EpochState memory _depositEpochState = depositEpochState[epoch];

        // shares from pending deposits are already added to the supply at the start of every new epoch
        balanceOf[user] += Math.mulDiv(
            pendingDeposit.amount,
            _depositEpochState.availableShares - pendingDeposit.fulfillmentAccumulatorLast,
            _depositEpochState.availableAssets
        );

        queuedDeposit[user][epoch] = PendingAction({
            amount: pendingDeposit.amount,
            fulfillmentAccumulatorLast: _depositEpochState.availableShares
        });
    }

    // queues a withdrawal that executes at the beginning of the next epoch
    function requestWithdrawal(uint128 shares, address receiver) external {
        PendingAction memory pendingWithdrawal = queuedWithdrawal[receiver][withdrawalEpoch];

        queuedWithdrawal[receiver][withdrawalEpoch] = PendingAction({
            amount: pendingWithdrawal.amount + shares,
            fulfillmentAccumulatorLast: 0
        });

        withdrawalEpochState[withdrawalEpoch].availableShares += shares;

        balanceOf[msg.sender] -= shares;
    }

    // convert an active pending withdrawal into assets
    function executeWithdrawal(address user, uint256 epoch) external {
        require(withdrawalEpoch > epoch, "HypoVault: withdrawal not yet processed");

        PendingAction memory pendingWithdrawal = queuedWithdrawal[user][epoch];

        EpochState memory _withdrawalEpochState = withdrawalEpochState[epoch];

        uint256 assetsToWithdraw = Math.mulDiv(
            pendingWithdrawal.amount,
            _withdrawalEpochState.availableAssets - pendingWithdrawal.fulfillmentAccumulatorLast,
            _withdrawalEpochState.availableShares
        );

        withdrawableAssets -= assetsToWithdraw;

        queuedWithdrawal[user][epoch] = PendingAction({
            amount: pendingWithdrawal.amount,
            fulfillmentAccumulatorLast: _withdrawalEpochState.availableAssets
        });

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
    function fulfillDeposits(
        uint256 assetsToFulfill,
        bytes memory managerInput
    ) external onlyManager {
        uint256 currentEpoch = depositEpoch;

        EpochState memory epochState = depositEpochState[currentEpoch];

        EpochState memory previousEpochState;
        unchecked {
            // for epoch 0, point the previous epoch state to a blank slot (depositEpochState[UINT256_MAX])
            previousEpochState = depositEpochState[currentEpoch - 1];
        }

        uint256 totalAssets = accountant.computeNAV(address(this), managerInput) -
            previousEpochState.amountPending -
            epochState.availableAssets -
            withdrawableAssets;

        if (totalAssets == 0) totalAssets = 1;

        // if the previous epoch has not been fulfilled completely, this operation must occur on the previous epoch
        if (previousEpochState.amountPending > 0) {
            currentEpoch--;
            epochState = previousEpochState;
        } else if (epochState.amountPending == 0) {
            // increment the epoch for new deposits if the previous epoch has been fulfilled completely
            depositEpoch = uint128(currentEpoch + 1);
            epochState.amountPending = epochState.availableAssets;
        }

        uint256 _totalSupply = totalSupply;

        uint256 sharesReceived = Math.mulDiv(assetsToFulfill, _totalSupply, totalAssets);

        depositEpochState[currentEpoch] = EpochState({
            availableAssets: uint128(epochState.availableAssets),
            availableShares: uint128(epochState.availableShares + sharesReceived),
            amountPending: uint128(epochState.amountPending - assetsToFulfill)
        });

        totalSupply = _totalSupply + Math.mulDiv(assetsToFulfill, _totalSupply, totalAssets);
    }

    // assigns a share price for all withdrawals in the current epoch and increments the withdrawal epoch
    function fulfillWithdrawals(
        uint256 sharesToFulfill,
        uint256 maxAssetsReceived,
        bytes memory managerInput
    ) external onlyManager {
        uint256 depositEpochCurrent = depositEpoch;

        uint256 _withdrawableAssets = withdrawableAssets;
        uint256 totalAssets = accountant.computeNAV(address(this), managerInput) -
            depositEpochState[depositEpochCurrent - 1].amountPending -
            depositEpochState[depositEpochCurrent].availableAssets -
            _withdrawableAssets;

        uint256 currentEpoch = withdrawalEpoch;

        EpochState memory epochState = withdrawalEpochState[currentEpoch];

        EpochState memory previousEpochState = withdrawalEpochState[currentEpoch - 1];

        uint256 _totalSupply = totalSupply;

        // if the previous epoch has not been fulfilled completely, this operation must occur on the previous epoch
        if (previousEpochState.amountPending > 0) {
            currentEpoch--;
            epochState = previousEpochState;
        } else if (epochState.amountPending == 0) {
            // increment the epoch for new withdrawals if the previous epoch has been fulfilled completely
            withdrawalEpoch = uint128(currentEpoch + 1);
            epochState.amountPending = epochState.availableShares;
        }

        uint256 assetsReceived = Math.mulDiv(sharesToFulfill, totalAssets, _totalSupply);

        require(
            assetsReceived <= maxAssetsReceived,
            "HypoVault: assets received exceeds max assets received"
        );

        withdrawalEpochState[currentEpoch] = EpochState({
            availableAssets: uint128(epochState.availableAssets + assetsReceived),
            availableShares: uint128(epochState.availableShares),
            amountPending: uint128(epochState.amountPending - sharesToFulfill)
        });

        totalSupply = _totalSupply - sharesToFulfill;

        withdrawableAssets = _withdrawableAssets + assetsReceived;
    }
}
