// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

// External
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Tapioca
import {IMarketLiquidatorReceiver} from "tapioca-periph/interfaces/bar/IMarketLiquidatorReceiver.sol";
import {IZeroXSwapper} from "tapioca-periph/interfaces/periph/IZeroXSwapper.sol";

/*
__/\\\\\\\\\\\\\\\_____/\\\\\\\\\_____/\\\\\\\\\\\\\____/\\\\\\\\\\\_______/\\\\\_____________/\\\\\\\\\_____/\\\\\\\\\____        
 _\///////\\\/////____/\\\\\\\\\\\\\__\/\\\/////////\\\_\/////\\\///______/\\\///\\\________/\\\////////____/\\\\\\\\\\\\\__       
  _______\/\\\________/\\\/////////\\\_\/\\\_______\/\\\_____\/\\\_______/\\\/__\///\\\____/\\\/____________/\\\/////////\\\_      
   _______\/\\\_______\/\\\_______\/\\\_\/\\\\\\\\\\\\\/______\/\\\______/\\\______\//\\\__/\\\_____________\/\\\_______\/\\\_     
    _______\/\\\_______\/\\\\\\\\\\\\\\\_\/\\\/////////________\/\\\_____\/\\\_______\/\\\_\/\\\_____________\/\\\\\\\\\\\\\\\_    
     _______\/\\\_______\/\\\/////////\\\_\/\\\_________________\/\\\_____\//\\\______/\\\__\//\\\____________\/\\\/////////\\\_   
      _______\/\\\_______\/\\\_______\/\\\_\/\\\_________________\/\\\______\///\\\__/\\\_____\///\\\__________\/\\\_______\/\\\_  
       _______\/\\\_______\/\\\_______\/\\\_\/\\\______________/\\\\\\\\\\\____\///\\\\\/________\////\\\\\\\\\_\/\\\_______\/\\\_ 
        _______\///________\///________\///__\///______________\///////////_______\/////_____________\/////////__\///________\///__

*/

contract ExampleMarketLiquidatorReceiver is IMarketLiquidatorReceiver, Ownable {
    using SafeERC20 for IERC20;

    struct OracleInfo {
        bytes data;
        address target;
        uint256 precision;
    }

    mapping(address tokenIn => address swapper) public swappers;

    uint256 private _entered;

    event SwapperAssigned(address indexed tokenIn, address indexed swapper);

    error NotAuthorized();
    error NotEnough();
    error Reentrancy();
    error NoSwapperAssigned();
    error NotValid();
    error SwapFailed();

    constructor() {}

    struct SSwapData {
        uint256 minAmountOut;
        bytes data;
    }

    /// @notice action performed during the liquidation process
    /// @param tokenIn received token
    /// @param tokenOut output token
    /// @param collateralAmount received amount
    /// @param data Expect a ZeroXSwapper swap data
    function onCollateralReceiver(address tokenIn, address tokenOut, uint256 collateralAmount, bytes calldata data)
        external
        returns (bool)
    {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        address swapperTokenIn = swappers[tokenIn];
        if (swapperTokenIn == address(0)) revert NoSwapperAssigned();

        uint256 collateralBalance = IERC20(tokenIn).balanceOf(address(this));
        if (collateralBalance < collateralAmount) revert NotEnough();
        SSwapData memory swapData = abi.decode(data, (SSwapData));

        IERC20(tokenIn).safeApprove(swapperTokenIn, collateralAmount);
        uint256 amountOut = IZeroXSwapper(swapperTokenIn).swap(swapData.data, swapData.minAmountOut);
        IERC20(tokenIn).safeApprove(swapperTokenIn, 0);
        if (amountOut < swapData.minAmountOut) revert SwapFailed();
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        _entered = 0;
        return true;
    }

    /// @notice assigns swapper for token
    /// @param _tokenIn token to assign the swapper for
    /// @param _swapper the swapper address
    function assignSwapper(address _tokenIn, address _swapper) external onlyOwner {
        swappers[_tokenIn] = _swapper;
        emit SwapperAssigned(_tokenIn, _swapper);
    }
}