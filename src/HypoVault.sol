// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {Math} from "@libraries/Math.sol";
import {Constants} from "@libraries/Constants.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {TokenId} from "@types/TokenId.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {IQuoter} from "univ3-periphery/interfaces/IQuoter.sol";

/// @author dyedm1
contract HypoVault is ERC20Minimal {
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
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // timestamp of the *end* of the current epoch
    uint128 currentEpoch;

    uint256 immutable epochLength;

    int24 immutable width;

    int24 immutable tickSpacing;

    address immutable token0;

    address immutable token1;

    uint24 immutable fee;

    address immutable underlying;

    bool immutable underlyingIsToken0;

    IQuoter immutable quoter;

    PanopticPool immutable pp;

    IUniswapV3Pool immutable univ3pool;

    uint64 immutable poolId;

    CollateralTracker immutable ct0;
    CollateralTracker immutable ct1;

    mapping(uint256 epoch => EpochState) closeState;

    mapping(address user => PendingAction queue) queuedDeposit;
    mapping(address user => PendingAction queue) queuedWithdrawal;

    uint256 sharesPendingWithdrawal;

    uint256 assetsPendingDeposit;

    constructor() {
        epochLength = 7 days;
        underlying = address(0);
        quoter = IQuoter(address(0));
        pp = PanopticPool(address(0));
        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        IUniswapV3Pool _univ3pool = pp.univ3pool();

        poolId = 0;

        // ~6% assuming 30bps pool
        width = 10;
        tickSpacing = _univ3pool.tickSpacing();

        token0 = _univ3pool.token0();
        token1 = _univ3pool.token1();
        fee = _univ3pool.fee();

        univ3pool = _univ3pool;

        underlyingIsToken0 = _univ3pool.token0() == underlying;

        // first "epoch" only lasts 3 days and only accepts deposits - the first trade is executed at the start of the second epoch
        uint256 preDepositPeriod = 3 days;
        currentEpoch = uint128(block.timestamp + preDepositPeriod);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/REDEEM LOGIC
    //////////////////////////////////////////////////////////////*/

    // queues a deposit that becomes active at the beginning of the next epoch
    function editDepositQueue(uint128 updatedDepositAssets) external {
        PendingAction memory pendingDeposit = queuedDeposit[msg.sender];

        uint128 _currentEpoch = currentEpoch;

        int256 depositDelta;
        // if the previous queued deposit has already gone into effect, reset the queued deposit state and mint shares
        if (_currentEpoch > pendingDeposit.epoch) {
            EpochState memory depositEpochState = closeState[_currentEpoch];

            // shares from pending deposits are already added to the supply at the start of every new epoch
            balanceOf[msg.sender] += Math.mulDiv(
                pendingDeposit.amount,
                depositEpochState.totalShares,
                depositEpochState.totalAssets
            );

            queuedDeposit[msg.sender] = PendingAction({
                amount: updatedDepositAssets,
                epoch: _currentEpoch
            });

            depositDelta = int256(uint256(updatedDepositAssets));
        } else {
            depositDelta =
                int256(uint256(updatedDepositAssets)) -
                int256(uint256(pendingDeposit.amount));
            queuedDeposit[msg.sender].amount = updatedDepositAssets;
        }

        assetsPendingDeposit = uint256(int256(assetsPendingDeposit) + depositDelta);

        if (depositDelta > 0)
            SafeTransferLib.safeTransferFrom(
                underlying,
                msg.sender,
                address(this),
                uint256(depositDelta)
            );
        else if (depositDelta < 0)
            SafeTransferLib.safeTransfer(underlying, msg.sender, uint256(-depositDelta));
    }

    // convert an active pending deposit into shares
    function executeDeposit(address user) external {
        PendingAction memory pendingDeposit = queuedDeposit[user];

        require(currentEpoch > pendingDeposit.epoch, "HypoVault: deposit not yet active");

        EpochState memory depositEpochState = closeState[pendingDeposit.epoch];

        // shares from pending deposits are already added to the supply at the start of every new epoch
        balanceOf[user] += Math.mulDiv(
            pendingDeposit.amount,
            depositEpochState.totalShares,
            depositEpochState.totalAssets
        );

        queuedDeposit[user] = PendingAction(0, 0);
    }

    // queues a withdrawal that executes at the beginning of the next epoch
    function editWithdrawalQueue(uint128 updatedWithdrawalShares) external {
        PendingAction memory pendingWithdrawal = queuedWithdrawal[msg.sender];

        uint128 _currentEpoch = currentEpoch;

        // if the previous queued withdrawal has already gone into effect, reset the queued withdrawal state and distribute tokens
        if (_currentEpoch > pendingWithdrawal.epoch) {
            EpochState memory withdrawalEpochState = closeState[_currentEpoch];

            queuedWithdrawal[msg.sender] = PendingAction({
                amount: updatedWithdrawalShares,
                epoch: _currentEpoch
            });

            balanceOf[msg.sender] -= updatedWithdrawalShares;

            sharesPendingWithdrawal = uint256(
                int256(sharesPendingWithdrawal) + int256(uint256(updatedWithdrawalShares))
            );

            SafeTransferLib.safeTransfer(
                underlying,
                msg.sender,
                Math.mulDiv(
                    pendingWithdrawal.amount,
                    withdrawalEpochState.totalAssets,
                    withdrawalEpochState.totalShares
                )
            );
        } else {
            queuedWithdrawal[msg.sender].amount = updatedWithdrawalShares;

            int256 withdrawalDelta = int256(uint256(updatedWithdrawalShares)) -
                int256(uint256(pendingWithdrawal.amount));

            balanceOf[msg.sender] = uint256(int256(balanceOf[msg.sender]) - withdrawalDelta);
            sharesPendingWithdrawal = uint256(int256(sharesPendingWithdrawal) + withdrawalDelta);
        }
    }

    // convert an active pending withdrawal into assets
    function executeWithdrawal(address user) external {
        PendingAction memory pendingWithdrawal = queuedWithdrawal[user];

        require(currentEpoch > pendingWithdrawal.epoch, "HypoVault: withdrawal not yet active");

        EpochState memory withdrawalEpochState = closeState[pendingWithdrawal.epoch];

        sharesPendingWithdrawal = uint256(
            int256(sharesPendingWithdrawal) - int256(uint256(pendingWithdrawal.amount))
        );

        queuedWithdrawal[user] = PendingAction(0, 0);

        SafeTransferLib.safeTransfer(
            underlying,
            user,
            Math.mulDiv(
                pendingWithdrawal.amount,
                withdrawalEpochState.totalAssets,
                withdrawalEpochState.totalShares
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                             STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    function advanceEpoch(TokenId currentPosition) external {
        (int24 currentTick, , int24 slowOracleTick, , ) = pp.getOracleTicks();

        require(
            block.timestamp > currentEpoch || needsRebalance(currentPosition, slowOracleTick),
            "HypoVault: epoch not yet over"
        );

        // just an example -- we can set slippage however we want
        int24 minTick = slowOracleTick - 512;
        int24 maxTick = slowOracleTick + 512;

        closePositions(currentPosition, minTick, maxTick);

        openPositions(currentTick, slowOracleTick, minTick, maxTick);

        currentEpoch = uint128(block.timestamp + epochLength);
    }

    function openPositions(
        int24 currentTick,
        int24 slowOracleTick,
        int24 minTick,
        int24 maxTick
    ) internal {
        if (underlyingIsToken0) {
            uint256 collateralAssets = ct0.convertToAssets(ct0.balanceOf(address(this)));

            // we are going to create a position with:
            // width = width
            // strike ~= slowOracleTick
            // notional value = collateralAssets - zappedUnderlyingEstimate

            TokenId[] memory positionList = new TokenId[](1);
            positionList[0] = TokenId.wrap(0).addPoolId(poolId).addLeg({
                legIndex: 0,
                _optionRatio: 0,
                _asset: 0,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: (slowOracleTick / tickSpacing) * tickSpacing,
                _width: width
            });

            (, uint256 comp1) = Math.getAmountsForLiquidity(
                currentTick,
                PanopticMath.getLiquidityChunk(positionList[0], 0, uint128(collateralAssets - 1))
            );

            // overestimate -- we will mint at this size or below
            uint256 zapQuote = quoter.quoteExactOutputSingle(
                token0,
                token1,
                3000,
                comp1,
                Constants.MIN_V3POOL_SQRT_RATIO
            );

            pp.mintOptions(positionList, uint128(collateralAssets - zapQuote), 0, maxTick, minTick);
        } else {
            // vice versa
        }
    }

    function closePositions(TokenId currentPosition, int24 minTick, int24 maxTick) internal {
        // for our example, we are going to 100% collateralize the notional value of the position we mint in the borrowed token
        // thus, a position will never require more tokens to close (w/o zapping) than collateral we have on hand (unless protocol loss occurs)
        pp.burnOptions(currentPosition, new TokenId[](0), minTick, maxTick);

        // now withdraw any collateral of the *non-underlying* token
        // if this fails, we just delay the next epoch until the withdrawal can go through. any better solution for this is more complicated
        // and would involve distributing collateral shares pro-rata at some point and dissolving the vault
        if (underlyingIsToken0) {
            uint256 assetsToSwap = ct1.redeem(
                ct1.balanceOf(address(this)),
                address(this),
                address(this)
            );

            // pretend this swap works all the time and we implemented the callback
            // ideally this is an asynchronous auction using something like CoWswap or Enso -- so the epoch advancement would be divided into two parts
            // we would also want to do only one swap for both the position close and the position open -- the reason we are doing two
            // in this prototype is so we can easily get a NAV figure to close this epoch's price at
            (int256 amount0, ) = univ3pool.swap(
                address(this),
                !underlyingIsToken0,
                int256(assetsToSwap),
                underlyingIsToken0
                    ? Math.getSqrtRatioAtTick(maxTick)
                    : Math.getSqrtRatioAtTick(minTick),
                ""
            );

            amount0 = -amount0;

            // NAV is the sum of the underlying received from the swap and the collateral balance
            uint256 nav = uint256(amount0) + ct0.convertToAssets(ct0.balanceOf(address(this)));

            uint256 previousTotalSupply = totalSupply;

            uint256 _currentEpoch = currentEpoch;

            closeState[_currentEpoch] = EpochState({
                totalAssets: uint128(nav),
                totalShares: uint128(previousTotalSupply)
            });

            uint256 _sharesPendingWithdrawal = sharesPendingWithdrawal;
            uint256 _assetsPendingDeposit = assetsPendingDeposit;

            // determine how many assets, if any, must be removed from the collateral pool to facilitate withdrawals
            int256 assetsToWithdraw = int256(
                Math.mulDiv(_sharesPendingWithdrawal, nav, previousTotalSupply)
            ) -
                int256(_assetsPendingDeposit) -
                amount0;

            if (assetsToWithdraw > 0)
                ct0.withdraw(uint256(assetsToWithdraw), address(this), address(this));
                // ensure all collateral is deposited -- this initial version of the vault assumes that the tokenType = underlying and deposits extra collateral to remain at 100%
            else if (assetsToWithdraw < 0) ct0.deposit(uint256(-assetsToWithdraw), address(this));

            totalSupply = uint256(
                int256(totalSupply) -
                    int256(_sharesPendingWithdrawal) +
                    int256(Math.mulDiv(_assetsPendingDeposit, previousTotalSupply, nav))
            );
        } else {
            // vice versa
        }
    }

    function needsRebalance(
        TokenId currentPosition,
        int24 oracleTick
    ) internal view returns (bool) {
        // if we were minting <100% collateralized strategies or long options, account health would also be considered
        // but for now, we're just checking whether the position has moved far-out-of-range to determine if it's worth rebalancing
        (int24 tickLower, int24 tickUpper) = currentPosition.asTicks(0);

        return
            oracleTick - tickUpper > width * tickSpacing ||
            tickLower - oracleTick > width * tickSpacing;
    }
}
