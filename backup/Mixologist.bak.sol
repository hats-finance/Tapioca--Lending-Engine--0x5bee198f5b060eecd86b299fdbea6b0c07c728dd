// SPDX-License-Identifier: UNLICENSED

// Copyright (c) 2021 BoringCrypto - All rights reserved
// Twitter: @Boring_Crypto

pragma solidity ^0.8.0;
import '@boringcrypto/boring-solidity/contracts/BoringOwnable.sol';
import '@boringcrypto/boring-solidity/contracts/ERC20.sol';
import '@boringcrypto/boring-solidity/contracts/libraries/BoringRebase.sol';
import '@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol';
import '../bar/YieldBox.sol';
import '../swappers/MultiSwapper.sol';
import './interfaces/IOracle.sol';
import './interfaces/IFlashLoan.sol';
import '../liquidationQueue/ILiquidationQueue.sol';

// solhint-disable avoid-low-level-calls
// solhint-disable no-inline-assembly
// solhint-disable max-line-length

/// @title Mixologist
/// @dev This contract allows contract calls to any contract (except yieldBox)
/// from arbitrary callers thus, don't trust calls from this contract in any circumstances.
contract Mixologist is ERC20, BoringOwnable {
    using RebaseLibrary for Rebase;
    using BoringERC20 for IERC20;

    event LogExchangeRate(uint256 rate);
    event LogAccrue(
        uint256 accruedAmount,
        uint256 feeFraction,
        uint64 rate,
        uint256 utilization
    );
    event LogAddCollateral(
        address indexed from,
        address indexed to,
        uint256 share
    );
    event LogAddAsset(
        address indexed from,
        address indexed to,
        uint256 share,
        uint256 fraction
    );
    event LogRemoveCollateral(
        address indexed from,
        address indexed to,
        uint256 share
    );
    event LogRemoveAsset(
        address indexed from,
        address indexed to,
        uint256 share,
        uint256 fraction
    );
    event LogBorrow(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 feeAmount,
        uint256 part
    );
    event LogRepay(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 part
    );
    event LogWithdrawFees(address indexed feeTo, uint256 feesEarnedFraction);
    event LogFlashLoan(
        address indexed borrower,
        uint256 amount,
        uint256 feeAmount,
        address indexed receiver
    );
    event LogYieldBoxFeesDeposit(uint256 feeShares, uint256 tapAmount);
    event LogApprovalForAll(
        address indexed _from,
        address indexed _operator,
        bool _approved
    );

    //errors
    error NotApproved(address _from, address _operator);

    // Constructor settings
    BeachBar public beachBar;
    YieldBox public yieldBox;
    IERC20 public collateral;
    IERC20 public asset;
    uint256 public collateralId;
    uint256 public assetId;
    IOracle oracle;
    bytes oracleData;
    address[] collateralSwapPath; // Collateral -> Asset
    address[] tapSwapPath; // Asset -> Tap

    // Total amounts
    uint256 public totalCollateralShare; // Total collateral supplied
    Rebase public totalAsset; // elastic = yieldBox shares held by the Mixologist, base = Total fractions held by asset suppliers
    Rebase public totalBorrow; // elastic = Total token amount to be repayed by borrowers, base = Total parts of the debt held by borrowers

    // User balances
    mapping(address => uint256) public userCollateralShare;
    // userAssetFraction is called balanceOf for ERC20 compatibility (it's in ERC20.sol)
    mapping(address => uint256) public userBorrowPart;
    // map of operator approval
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @notice Exchange and interest rate tracking.
    /// This is 'cached' here because calls to Oracles can be very expensive.
    /// Asset -> collateral = assetAmount * exchangeRate.
    uint256 public exchangeRate;

    ILiquidationQueue public liquidationQueue;

    struct AccrueInfo {
        uint64 interestPerSecond;
        uint64 lastAccrued;
        uint128 feesEarnedFraction;
    }

    AccrueInfo public accrueInfo;

    bool private initialized;
    modifier onlyOnce() {
        require(!initialized, 'Singularity: initialized');
        _;
        initialized = true;
    }

    /// Modifier to check if the msg.sender is allowed to use funds belonging to the 'from' address.
    /// If 'from' is msg.sender, it's allowed.
    /// If 'msg.sender' is an address (an operator) that is approved by 'from', it's allowed.
    modifier allowed(address from) virtual {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) {
            revert NotApproved(from, msg.sender);
        }
        _;
    }

    /**
     * @notice Sets approval status for an `operator` to manage user account.
     * @param operator Address of Operator.
     * @param approved Status of approval.
     */
    function setApprovalForAll(address operator, bool approved) external {
        // Effects
        isApprovedForAll[msg.sender][operator] = approved;

        emit LogApprovalForAll(msg.sender, operator, approved);
    }

    // ERC20 'variables'
    function symbol() external view returns (string memory) {
        return
            string(
                abi.encodePacked(
                    'tm',
                    collateral.safeSymbol(),
                    '/',
                    asset.safeSymbol(),
                    '-',
                    oracle.symbol(oracleData)
                )
            );
    }

    function name() external view returns (string memory) {
        return
            string(
                abi.encodePacked(
                    'Tapioca Mixologist ',
                    collateral.safeName(),
                    '/',
                    asset.safeName(),
                    '-',
                    oracle.name(oracleData)
                )
            );
    }

    function decimals() external view returns (uint8) {
        return asset.safeDecimals();
    }

    // totalSupply for ERC20 compatibility
    // BalanceOf[user] represent a fraction
    function totalSupply() public view override returns (uint256) {
        return totalAsset.base;
    }

    // Settings for the Medium Risk Mixologist
    uint256 private constant CLOSED_COLLATERIZATION_RATE = 75000; // 75%
    uint256 private constant LQ_COLLATERIZATION_RATE = 25000; // 25%
    uint256 private constant COLLATERIZATION_RATE_PRECISION = 1e5; // Must be less than EXCHANGE_RATE_PRECISION (due to optimization in math)
    uint256 private constant MINIMUM_TARGET_UTILIZATION = 7e17; // 70%
    uint256 private constant MAXIMUM_TARGET_UTILIZATION = 8e17; // 80%
    uint256 private constant UTILIZATION_PRECISION = 1e18;
    uint256 private constant FULL_UTILIZATION = 1e18;
    uint256 private constant FULL_UTILIZATION_MINUS_MAX =
        FULL_UTILIZATION - MAXIMUM_TARGET_UTILIZATION;
    uint256 private constant FACTOR_PRECISION = 1e18;

    uint64 private constant STARTING_INTEREST_PER_SECOND = 317097920; // approx 1% APR
    uint64 private constant MINIMUM_INTEREST_PER_SECOND = 79274480; // approx 0.25% APR
    uint64 private constant MAXIMUM_INTEREST_PER_SECOND = 317097920000; // approx 1000% APR
    uint256 private constant INTEREST_ELASTICITY = 28800e36; // Half or double in 28800 seconds (8 hours) if linear

    uint256 private constant EXCHANGE_RATE_PRECISION = 1e18;

    uint256 private constant ORDER_BOOK_LIQUIDATION_MULTIPLIER = 127000; // add 27%
    uint256 private constant LIQUIDATION_MULTIPLIER = 112000; // add 12%
    uint256 private constant LIQUIDATION_MULTIPLIER_PRECISION = 1e5;

    // Fees
    uint256 private constant CALLER_FEE = 1000; // 1%
    uint256 private constant CALLER_FEE_DIVISOR = 1e5;
    uint256 private constant PROTOCOL_FEE = 10000; // 10%
    uint256 private constant PROTOCOL_FEE_DIVISOR = 1e5;
    uint256 private constant BORROW_OPENING_FEE = 50; // 0.05%
    uint256 private constant BORROW_OPENING_FEE_PRECISION = 1e5;
    uint256 private constant FLASHLOAN_FEE = 90; // 0.09%
    uint256 private constant FLASHLOAN_FEE_PRECISION = 1e5;

    /// @notice The init function that acts as a constructor
    function init(bytes calldata data) external onlyOnce {
        (
            BeachBar tapiocaBar_,
            IERC20 _asset,
            uint256 _assetId,
            IERC20 _collateral,
            uint256 _collateralId,
            IOracle _oracle,
            address[] memory _collateralSwapPath,
            address[] memory _tapSwapPath
        ) = abi.decode(
                data,
                (
                    BeachBar,
                    IERC20,
                    uint256,
                    IERC20,
                    uint256,
                    IOracle,
                    address[],
                    address[]
                )
            );

        beachBar = tapiocaBar_;
        yieldBox = tapiocaBar_.yieldBox();
        owner = address(beachBar);

        require(
            address(_collateral) != address(0) &&
                address(_asset) != address(0) &&
                address(_oracle) != address(0),
            'Mx: bad pair'
        );
        asset = _asset;
        collateral = _collateral;
        assetId = _assetId;
        collateralId = _collateralId;
        oracle = _oracle;
        collateralSwapPath = _collateralSwapPath;
        tapSwapPath = _tapSwapPath;

        accrueInfo.interestPerSecond = uint64(STARTING_INTEREST_PER_SECOND); // 1% APR, with 1e18 being 100%

        updateExchangeRate();
    }

    /// @notice Allows batched call to Mixologist.
    /// @param calls An array encoded call data.
    /// @param revertOnFail If True then reverts after a failed call and stops doing further calls.
    function execute(bytes[] calldata calls, bool revertOnFail)
        external
        returns (bool[] memory successes, string[] memory results)
    {
        successes = new bool[](calls.length);
        results = new string[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(
                calls[i]
            );
            require(success || !revertOnFail, _getRevertMsg(result));
            successes[i] = success;
            results[i] = _getRevertMsg(result);
        }
    }

    function _getRevertMsg(bytes memory _returnData)
        private
        pure
        returns (string memory)
    {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return 'no-data';
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }

    /// @notice Accrues the interest on the borrowed tokens and handles the accumulation of fees.
    function accrue() public {
        AccrueInfo memory _accrueInfo = accrueInfo;
        // Number of seconds since accrue was called
        uint256 elapsedTime = block.timestamp - _accrueInfo.lastAccrued;
        if (elapsedTime == 0) {
            return;
        }
        _accrueInfo.lastAccrued = uint64(block.timestamp);

        Rebase memory _totalBorrow = totalBorrow;
        if (_totalBorrow.base == 0) {
            // If there are no borrows, reset the interest rate
            if (_accrueInfo.interestPerSecond != STARTING_INTEREST_PER_SECOND) {
                _accrueInfo.interestPerSecond = STARTING_INTEREST_PER_SECOND;
                emit LogAccrue(0, 0, STARTING_INTEREST_PER_SECOND, 0);
            }
            accrueInfo = _accrueInfo;
            return;
        }

        uint256 extraAmount = 0;
        uint256 feeFraction = 0;
        Rebase memory _totalAsset = totalAsset;

        // Accrue interest
        extraAmount =
            (uint256(_totalBorrow.elastic) *
                _accrueInfo.interestPerSecond *
                elapsedTime) /
            1e18;
        _totalBorrow.elastic += uint128(extraAmount);
        uint256 fullAssetAmount = yieldBox.toAmount(
            assetId,
            _totalAsset.elastic,
            false
        ) + _totalBorrow.elastic;

        uint256 feeAmount = (extraAmount * PROTOCOL_FEE) / PROTOCOL_FEE_DIVISOR; // % of interest paid goes to fee
        feeFraction = (feeAmount * _totalAsset.base) / fullAssetAmount;
        _accrueInfo.feesEarnedFraction += uint128(feeFraction);
        totalAsset.base = _totalAsset.base + uint128(feeFraction);
        totalBorrow = _totalBorrow;

        // Update interest rate
        uint256 utilization = (uint256(_totalBorrow.elastic) *
            UTILIZATION_PRECISION) / fullAssetAmount;
        if (utilization < MINIMUM_TARGET_UTILIZATION) {
            uint256 underFactor = ((MINIMUM_TARGET_UTILIZATION - utilization) *
                FACTOR_PRECISION) / MINIMUM_TARGET_UTILIZATION;
            uint256 scale = INTEREST_ELASTICITY +
                (underFactor * underFactor * elapsedTime);
            _accrueInfo.interestPerSecond = uint64(
                (uint256(_accrueInfo.interestPerSecond) * INTEREST_ELASTICITY) /
                    scale
            );

            if (_accrueInfo.interestPerSecond < MINIMUM_INTEREST_PER_SECOND) {
                _accrueInfo.interestPerSecond = MINIMUM_INTEREST_PER_SECOND; // 0.25% APR minimum
            }
        } else if (utilization > MAXIMUM_TARGET_UTILIZATION) {
            uint256 overFactor = ((utilization - MAXIMUM_TARGET_UTILIZATION) *
                FACTOR_PRECISION) / FULL_UTILIZATION_MINUS_MAX;
            uint256 scale = INTEREST_ELASTICITY +
                (overFactor * overFactor * elapsedTime);
            uint256 newInterestPerSecond = (uint256(
                _accrueInfo.interestPerSecond
            ) * scale) / INTEREST_ELASTICITY;
            if (newInterestPerSecond > MAXIMUM_INTEREST_PER_SECOND) {
                newInterestPerSecond = MAXIMUM_INTEREST_PER_SECOND; // 1000% APR maximum
            }
            _accrueInfo.interestPerSecond = uint64(newInterestPerSecond);
        }

        emit LogAccrue(
            extraAmount,
            feeFraction,
            _accrueInfo.interestPerSecond,
            utilization
        );
        accrueInfo = _accrueInfo;
    }

    /// @notice Concrete implementation of `isSolvent`. Includes a parameter to allow caching `exchangeRate`.
    /// @param _exchangeRate The exchange rate. Used to cache the `exchangeRate` between calls.
    function _isSolvent(address user, uint256 _exchangeRate)
        internal
        view
        returns (bool)
    {
        // accrue must have already been called!
        uint256 borrowPart = userBorrowPart[user];
        if (borrowPart == 0) return true;
        uint256 collateralShare = userCollateralShare[user];
        if (collateralShare == 0) return false;

        Rebase memory _totalBorrow = totalBorrow;

        return
            yieldBox.toAmount(
                collateralId,
                collateralShare *
                    (EXCHANGE_RATE_PRECISION / COLLATERIZATION_RATE_PRECISION) *
                    CLOSED_COLLATERIZATION_RATE,
                false
            ) >=
            // Moved exchangeRate here instead of dividing the other side to preserve more precision
            (borrowPart * _totalBorrow.elastic * _exchangeRate) /
                _totalBorrow.base;
    }

    /// @notice Return the amount of collateral for a `user` to be solvent. Returns 0 if user already solvent.
    /// @dev We use a `CLOSED_COLLATERIZATION_RATE` that is a safety buffer when making the user solvent again,
    ///      To prevent from being liquidated. This function is valid only if user is not solvent by `_isSolvent()`.
    /// @param user The user to check solvency.
    /// @param _exchangeRate The exchange rate asset/collateral.
    /// @return The amount of collateral to be solvent.
    function computeAssetAmountToSolvency(address user, uint256 _exchangeRate)
        public
        view
        returns (uint256)
    {
        // accrue must have already been called!
        uint256 borrowPart = userBorrowPart[user];
        if (borrowPart == 0) return 0;
        uint256 collateralShare = userCollateralShare[user];

        Rebase memory _totalBorrow = totalBorrow;

        uint256 collateralAmountInAsset = yieldBox.toAmount(
            collateralId,
            (collateralShare *
                (EXCHANGE_RATE_PRECISION / COLLATERIZATION_RATE_PRECISION) *
                LQ_COLLATERIZATION_RATE),
            false
        ) / _exchangeRate;
        // Obviously it's not `borrowPart` anymore but `borrowAmount`
        borrowPart = (borrowPart * _totalBorrow.elastic) / _totalBorrow.base;

        return
            borrowPart >= collateralAmountInAsset
                ? borrowPart - collateralAmountInAsset
                : 0;
    }

    /// @dev Checks if the user is solvent in the closed liquidation case at the end of the function body.
    modifier solvent() {
        _;
        require(_isSolvent(msg.sender, exchangeRate), 'Mx: insolvent');
    }

    /// @notice Gets the exchange rate. I.e how much collateral to buy 1e18 asset.
    /// This function is supposed to be invoked if needed because Oracle queries can be expensive.
    /// @return updated True if `exchangeRate` was updated.
    /// @return rate The new exchange rate.
    function updateExchangeRate() public returns (bool updated, uint256 rate) {
        (updated, rate) = oracle.get(oracleData);

        if (updated) {
            exchangeRate = rate;
            emit LogExchangeRate(rate);
        } else {
            // Return the old rate if fetching wasn't successful
            rate = exchangeRate;
        }
    }

    /// @dev Helper function to move tokens.
    /// @param from Account to debit tokens from, in `yieldBox`.
    /// @param _assetId The ERC-20 token asset ID in yieldBox.
    /// @param share The amount in shares to add.
    /// @param total Grand total amount to deduct from this contract's balance. Only applicable if `skim` is True.
    /// Only used for accounting checks.
    /// @param skim If True, only does a balance check on this contract.
    /// False if tokens from msg.sender in `yieldBox` should be transferred.
    function _addTokens(
        address from,
        uint256 _assetId,
        uint256 share,
        uint256 total,
        bool skim
    ) internal {
        if (skim) {
            require(
                share <= yieldBox.balanceOf(address(this), _assetId) - total,
                'Mx: too much'
            );
        } else {
            yieldBox.transfer(from, address(this), _assetId, share); // added a 'from' instead of 'msg.sender' -0xGAB
        }
    }

    /// @notice Adds `collateral` from msg.sender to the account `to`.
    /// @param from Account to transfer shares from.
    /// @param to The receiver of the tokens.
    /// @param skim True if the amount should be skimmed from the deposit balance of msg.sender.
    /// False if tokens from msg.sender in `yieldBox` should be transferred.
    /// @param share The amount of shares to add for `to`.
    function addCollateral(
        address from,
        address to,
        bool skim,
        uint256 share
    ) public allowed(from) {
        userCollateralShare[to] += share;
        uint256 oldTotalCollateralShare = totalCollateralShare;
        totalCollateralShare = oldTotalCollateralShare + share;
        _addTokens(from, collateralId, share, oldTotalCollateralShare, skim);
        emit LogAddCollateral(skim ? address(yieldBox) : from, to, share);
    }

    /// @dev Concrete implementation of `removeCollateral`.
    function _removeCollateral(
        address from,
        address to,
        uint256 share
    ) internal {
        userCollateralShare[from] -= share;
        totalCollateralShare -= share;
        emit LogRemoveCollateral(from, to, share);
        yieldBox.transfer(address(this), to, collateralId, share);
    }

    /// @notice Removes `share` amount of collateral and transfers it to `to`.
    /// @param from Account to debit collateral from.
    /// @param to The receiver of the shares.
    /// @param share Amount of shares to remove.
    function removeCollateral(
        address from,
        address to,
        uint256 share
    ) public solvent allowed(from) {
        // accrue must be called because we check solvency
        accrue();

        _removeCollateral(from, to, share);
    }

    /// @dev Concrete implementation of `addAsset`.
    function _addAsset(
        address from,
        address to,
        bool skim,
        uint256 share
    ) internal returns (uint256 fraction) {
        Rebase memory _totalAsset = totalAsset;
        uint256 totalAssetShare = _totalAsset.elastic;
        uint256 allShare = _totalAsset.elastic +
            yieldBox.toShare(assetId, totalBorrow.elastic, true);
        fraction = allShare == 0
            ? share
            : (share * _totalAsset.base) / allShare;
        if (_totalAsset.base + uint128(fraction) < 1000) {
            return 0;
        }
        totalAsset = _totalAsset.add(share, fraction);
        balanceOf[to] += fraction;
        emit Transfer(address(0), to, fraction);
        _addTokens(from, assetId, share, totalAssetShare, skim);
        emit LogAddAsset(skim ? address(yieldBox) : from, to, share, fraction);
    }

    /// @notice Adds assets to the lending pair.
    /// @param from Address to add asset from.
    /// @param to The address of the user to receive the assets.
    /// @param skim True if the amount should be skimmed from the deposit balance of msg.sender.
    /// False if tokens from msg.sender in `yieldBox` should be transferred.
    /// @param share The amount of shares to add.
    /// @return fraction Total fractions added.
    function addAsset(
        address from,
        address to,
        bool skim,
        uint256 share
    ) public allowed(from) returns (uint256 fraction) {
        accrue();
        fraction = _addAsset(from, to, skim, share);
    }

    /// @dev Concrete implementation of `removeAsset`.
    /// @param from The account to remove from. Should always be msg.sender except for `depositFeesToyieldBox()`.
    function _removeAsset(
        address from,
        address to,
        uint256 fraction
    ) internal returns (uint256 share) {
        Rebase memory _totalAsset = totalAsset;
        uint256 allShare = _totalAsset.elastic +
            yieldBox.toShare(assetId, totalBorrow.elastic, true);
        share = (fraction * allShare) / _totalAsset.base;
        balanceOf[from] -= fraction;
        emit Transfer(from, address(0), fraction);
        _totalAsset.elastic -= uint128(share);
        _totalAsset.base -= uint128(fraction);
        require(_totalAsset.base >= 1000, 'Mx: min limit');
        totalAsset = _totalAsset;
        emit LogRemoveAsset(from, to, share, fraction);
        yieldBox.transfer(address(this), to, assetId, share);
    }

    /// @notice Removes an asset from msg.sender and transfers it to `to`.
    /// @param from Account to debit Assets from.
    /// @param to The user that receives the removed assets.
    /// @param fraction The amount/fraction of assets held to remove.
    /// @return share The amount of shares transferred to `to`.
    function removeAsset(
        address from,
        address to,
        uint256 fraction
    ) public allowed(from) returns (uint256 share) {
        accrue();

        share = _removeAsset(from, to, fraction);
    }

    /// @dev Concrete implementation of `borrow`.
    function _borrow(
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 part, uint256 share) {
        uint256 feeAmount = (amount * BORROW_OPENING_FEE) /
            BORROW_OPENING_FEE_PRECISION; // A flat % fee is charged for any borrow

        (totalBorrow, part) = totalBorrow.add(amount + feeAmount, true);
        userBorrowPart[from] += part;
        emit LogBorrow(from, to, amount, feeAmount, part);

        share = yieldBox.toShare(assetId, amount, false);
        Rebase memory _totalAsset = totalAsset;
        require(_totalAsset.base >= 1000, 'Mx: min limit');
        _totalAsset.elastic -= uint128(share);
        totalAsset = _totalAsset;
        yieldBox.transfer(address(this), to, assetId, share);
    }

    /// @notice Sender borrows `amount` and transfers it to `to`.
    /// @param from Account to borrow for.
    /// @param to The receiver of borrowed tokens.
    /// @param amount Amount to borrow.
    /// @return part Total part of the debt held by borrowers.
    /// @return share Total amount in shares borrowed.
    function borrow(
        address from,
        address to,
        uint256 amount
    ) public solvent allowed(from) returns (uint256 part, uint256 share) {
        accrue();

        (part, share) = _borrow(from, to, amount);
    }

    /// @dev Concrete implementation of `repay`.
    function _repay(
        address from,
        address to,
        bool skim,
        uint256 part
    ) internal returns (uint256 amount) {
        (totalBorrow, amount) = totalBorrow.sub(part, true);
        userBorrowPart[to] -= part;

        uint256 share = yieldBox.toShare(assetId, amount, true);
        uint128 totalShare = totalAsset.elastic;
        _addTokens(from, assetId, share, uint256(totalShare), skim);
        totalAsset.elastic = totalShare + uint128(share);
        emit LogRepay(skim ? address(yieldBox) : from, to, amount, part);
    }

    /// @notice Repays a loan.
    /// @param from Address to repay from.
    /// @param to Address of the user this payment should go.
    /// @param skim True if the amount should be skimmed from the deposit balance of msg.sender.
    /// False if tokens from msg.sender in `yieldBox` should be transferred.
    /// @param part The amount to repay. See `userBorrowPart`.
    /// @return amount The total amount repayed.
    function repay(
        address from,
        address to,
        bool skim,
        uint256 part
    ) public allowed(from) returns (uint256 amount) {
        accrue();

        amount = _repay(from, to, skim, part);
    }

    /// @notice Entry point for liquidations.
    /// @dev Will call `closedLiquidation()` if not LQ exists or no LQ bid avail exists. Otherwise use LQ.
    /// @param users An array of user addresses.
    /// @param maxBorrowParts A one-to-one mapping to `users`, contains maximum (partial) borrow amounts (to liquidate) of the respective user.
    ///        Ignore for `orderBookLiquidation()`
    /// @param swapper Contract address of the `MultiSwapper` implementation. See `setSwapper`.
    ///        Ignore for `orderBookLiquidation()`
    /// @param collateralToAssetSwapData Extra swap data
    ///        Ignore for `orderBookLiquidation()`
    /// @param usdoToBorrowedSwapData Extra swap data
    ///        Ignore for `closedLiquidation()`
    function liquidate(
        address[] calldata users,
        uint256[] calldata maxBorrowParts,
        MultiSwapper swapper,
        bytes calldata collateralToAssetSwapData,
        bytes calldata usdoToBorrowedSwapData
    ) external {
        // Oracle can fail but we still need to allow liquidations
        (, uint256 _exchangeRate) = updateExchangeRate();
        accrue();

        if (address(liquidationQueue) != address(0)) {
            (, bool bidAvail) = liquidationQueue.getNextAvailBidPool();
            if (bidAvail) {
                orderBookLiquidation(
                    users,
                    _exchangeRate,
                    usdoToBorrowedSwapData
                );
                return;
            }
        }
        closedLiquidation(
            users,
            maxBorrowParts,
            swapper,
            _exchangeRate,
            collateralToAssetSwapData
        );
    }

    function orderBookLiquidation(
        address[] calldata users,
        uint256 _exchangeRate,
        bytes memory swapData
    ) internal {
        uint256 allCollateralShare;
        uint256 allBorrowAmount;
        uint256 allBorrowPart;
        Rebase memory _totalBorrow = totalBorrow;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (!_isSolvent(user, _exchangeRate)) {
                uint256 borrowAmount = computeAssetAmountToSolvency(
                    user,
                    _exchangeRate
                );
                if (borrowAmount == 0) {
                    continue;
                }

                uint256 borrowPart;
                {
                    uint256 availableBorrowPart = userBorrowPart[user];
                    borrowPart = _totalBorrow.toBase(borrowAmount, false);
                    userBorrowPart[user] = availableBorrowPart - borrowPart;
                }
                uint256 collateralShare = yieldBox.toShare(
                    collateralId,
                    (borrowAmount * _exchangeRate * LIQUIDATION_MULTIPLIER) /
                        (EXCHANGE_RATE_PRECISION *
                            LIQUIDATION_MULTIPLIER_PRECISION),
                    false
                );
                userCollateralShare[user] -= collateralShare;
                emit LogRemoveCollateral(
                    user,
                    address(liquidationQueue),
                    collateralShare
                );
                emit LogRepay(
                    address(liquidationQueue),
                    user,
                    borrowAmount,
                    borrowPart
                );

                // Keep totals
                allCollateralShare += collateralShare;
                allBorrowAmount += borrowAmount;
                allBorrowPart += borrowPart;
            }
        }
        require(allBorrowAmount != 0, 'Mx: solvent');

        _totalBorrow.elastic -= uint128(allBorrowAmount);
        _totalBorrow.base -= uint128(allBorrowPart);
        totalBorrow = _totalBorrow;
        totalCollateralShare -= allCollateralShare;

        uint256 allBorrowShare = yieldBox.toShare(
            assetId,
            allBorrowAmount,
            true
        );

        // Transfer collateral to be liquidated
        yieldBox.transfer(
            address(this),
            address(liquidationQueue),
            collateralId,
            allCollateralShare
        );

        // LiquidationQueue pay debt
        liquidationQueue.executeBids(
            yieldBox.toAmount(collateralId, allCollateralShare, true),
            swapData
        );

        uint256 returnedShare = yieldBox.balanceOf(address(this), assetId) -
            uint256(totalAsset.elastic);
        uint256 extraShare = returnedShare - allBorrowShare;
        uint256 callerShare = (extraShare * CALLER_FEE) / CALLER_FEE_DIVISOR; // 1% goes to caller

        yieldBox.transfer(address(this), msg.sender, assetId, callerShare);

        totalAsset.elastic += uint128(returnedShare - callerShare);
        emit LogAddAsset(
            address(liquidationQueue),
            address(this),
            returnedShare - callerShare,
            0
        );
    }

    /// @notice Handles the liquidation of users' balances, once the users' amount of collateral is too low.
    /// @dev Closed liquidations Only, 90% of extra shares goes to caller and 10% to protocol
    /// @param users An array of user addresses.
    /// @param maxBorrowParts A one-to-one mapping to `users`, contains maximum (partial) borrow amounts (to liquidate) of the respective user.
    /// @param swapper Contract address of the `MultiSwapper` implementation. See `setSwapper`.
    /// @param swapData Swap necessar data
    function closedLiquidation(
        address[] calldata users,
        uint256[] calldata maxBorrowParts,
        MultiSwapper swapper,
        uint256 _exchangeRate,
        bytes calldata swapData
    ) internal {
        uint256 allCollateralShare;
        uint256 allBorrowAmount;
        uint256 allBorrowPart;
        Rebase memory _totalBorrow = totalBorrow;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (!_isSolvent(user, _exchangeRate)) {
                uint256 borrowPart;
                {
                    uint256 availableBorrowPart = userBorrowPart[user];
                    borrowPart = maxBorrowParts[i] > availableBorrowPart
                        ? availableBorrowPart
                        : maxBorrowParts[i];
                    userBorrowPart[user] = availableBorrowPart - borrowPart;
                }
                uint256 borrowAmount = _totalBorrow.toElastic(
                    borrowPart,
                    false
                );
                uint256 collateralShare = yieldBox.toShare(
                    collateralId,
                    (borrowAmount * LIQUIDATION_MULTIPLIER * _exchangeRate) /
                        (LIQUIDATION_MULTIPLIER_PRECISION *
                            EXCHANGE_RATE_PRECISION),
                    false
                );
                userCollateralShare[user] -= collateralShare;
                emit LogRemoveCollateral(
                    user,
                    address(swapper),
                    collateralShare
                );
                emit LogRepay(address(swapper), user, borrowAmount, borrowPart);

                // Keep totals
                allCollateralShare += collateralShare;
                allBorrowAmount += borrowAmount;
                allBorrowPart += borrowPart;
            }
        }
        require(allBorrowAmount != 0, 'Mx: solvent');
        _totalBorrow.elastic -= uint128(allBorrowAmount);
        _totalBorrow.base -= uint128(allBorrowPart);
        totalBorrow = _totalBorrow;
        totalCollateralShare -= allCollateralShare;

        uint256 allBorrowShare = yieldBox.toShare(
            assetId,
            allBorrowAmount,
            true
        );

        // Closed liquidation using a pre-approved swapper
        require(beachBar.swappers(swapper), 'Mx: Invalid swapper');

        // Swaps the users collateral for the borrowed asset
        yieldBox.transfer(
            address(this),
            address(swapper),
            collateralId,
            allCollateralShare
        );

        uint256 minAssetMount = 0;
        if (swapData.length > 0) {
            minAssetMount = abi.decode(swapData, (uint256));
        }
        swapper.swap(
            collateralId,
            assetId,
            minAssetMount,
            address(this),
            collateralSwapPath,
            allCollateralShare
        );

        uint256 returnedShare = yieldBox.balanceOf(address(this), assetId) -
            uint256(totalAsset.elastic);
        uint256 extraShare = returnedShare - allBorrowShare;
        uint256 feeShare = (extraShare * PROTOCOL_FEE) / PROTOCOL_FEE_DIVISOR; // 10% of profit goes to fee.
        uint256 callerShare = (extraShare * CALLER_FEE) / CALLER_FEE_DIVISOR; //  1%  of profit goes to caller.

        yieldBox.transfer(address(this), beachBar.feeTo(), assetId, feeShare);
        yieldBox.transfer(address(this), msg.sender, assetId, callerShare);

        totalAsset.elastic += uint128(returnedShare - feeShare - callerShare);
        emit LogAddAsset(
            address(swapper),
            address(this),
            extraShare - feeShare - callerShare,
            0
        );
    }

    /// @notice Flashloan ability.
    /// @dev The contract expect the `borrower` to have at the end of `onFlashLoan` `amount` + the incurred fees.
    /// The borrower is expected to `approve()` yieldBox for this number at the end of its `onFlashLoan()`.
    /// @param borrower The address of the contract that implements and conforms to `IFlashBorrower` and handles the flashloan.
    /// @param receiver Address of the token receiver.
    /// @param amount of the tokens to receive.
    /// @param data The calldata to pass to the `borrower` contract.
    function flashLoan(
        IFlashBorrower borrower,
        address receiver,
        uint256 amount,
        bytes memory data
    ) public {
        Rebase memory _totalAsset = totalAsset;
        uint256 feeAmount = (amount * FLASHLOAN_FEE) / FLASHLOAN_FEE_PRECISION;
        uint256 feeFraction = (yieldBox.toShare(assetId, feeAmount, false) *
            _totalAsset.base) / _totalAsset.elastic;

        yieldBox.withdraw(assetId, address(this), receiver, amount, 0);

        borrower.onFlashLoan(msg.sender, asset, amount, feeAmount, data);

        require(
            yieldBox.amountOf(address(this), assetId) >= amount + feeAmount,
            'Mx: insufficient funds'
        );

        totalAsset.base = _totalAsset.base + uint128(feeFraction);
        accrueInfo.feesEarnedFraction += uint128(feeFraction);

        emit LogFlashLoan(address(borrower), amount, feeAmount, receiver);
    }

    /// @notice Withdraw the fees accumulated in `accrueInfo.feesEarnedFraction` to the balance of `feeTo`.
    function withdrawFeesEarned() public {
        accrue();
        address _feeTo = beachBar.feeTo();
        uint256 _feesEarnedFraction = accrueInfo.feesEarnedFraction;
        balanceOf[_feeTo] += _feesEarnedFraction;
        emit Transfer(address(0), _feeTo, _feesEarnedFraction);
        accrueInfo.feesEarnedFraction = 0;
        emit LogWithdrawFees(_feeTo, _feesEarnedFraction);
    }

    /// @notice Withdraw the balance of `feeTo`, swap asset into TAP and deposit it to yieldBox of `feeTo`
    function depositFeesToYieldBox(
        MultiSwapper swapper,
        SwapData calldata swapData
    ) public {
        if (accrueInfo.feesEarnedFraction > 0) {
            withdrawFeesEarned();
        }
        require(beachBar.swappers(swapper), 'Mx: Invalid swapper');
        address _feeTo = beachBar.feeTo();
        address _feeVeTap = beachBar.feeVeTap();

        uint256 feeShares = _removeAsset(
            _feeTo,
            address(this),
            balanceOf[_feeTo]
        );

        yieldBox.transfer(address(this), address(swapper), assetId, feeShares);

        (uint256 tapAmount, ) = swapper.swap(
            assetId,
            beachBar.tapAssetId(),
            swapData.minAssetAmount,
            _feeVeTap,
            tapSwapPath,
            feeShares
        );

        emit LogYieldBoxFeesDeposit(feeShares, tapAmount);
    }

    /// @notice Used to set the swap path of closed liquidations
    /// @param _collateralSwapPath The Uniswap path .
    function setCollateralSwapPath(address[] calldata _collateralSwapPath)
        public
        onlyOwner
    {
        collateralSwapPath = _collateralSwapPath;
    }

    /// @notice Used to set the swap path of Asset -> TAP
    /// @param _tapSwapPath The Uniswap path .
    function setTapSwapPath(address[] calldata _tapSwapPath) public onlyOwner {
        tapSwapPath = _tapSwapPath;
    }

    /// @notice Set a new LiquidationQueue.
    /// @param _liquidationQueue The address of the new LiquidationQueue contract.
    /// It should be a new contract as `init()` can be called only one time.
    /// @param _liquidationQueueMeta The liquidation queue info.
    function setLiquidationQueue(
        ILiquidationQueue _liquidationQueue,
        LiquidationQueueMeta calldata _liquidationQueueMeta
    ) public onlyOwner {
        _liquidationQueue.init(_liquidationQueueMeta);
        liquidationQueue = _liquidationQueue;
    }

    /// @notice Execute an only owner function inside of the LiquidationQueue
    function updateLQExecutionSwapper(address _swapper) external onlyOwner {
        liquidationQueue.setBidExecutionSwapper(_swapper);
    }

    /// @notice Execute an only owner function inside of the LiquidationQueue
    function updateLQUsdoSwapper(address _swapper) external onlyOwner {
        liquidationQueue.setUsdoSwapper(_swapper);
    }
}