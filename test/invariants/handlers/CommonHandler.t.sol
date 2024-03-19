// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Test Contracts
import {BaseHandler} from "../base/BaseHandler.t.sol";

// Interfaces
import {IBigBang} from "tapioca-periph/interfaces/bar/IBigBang.sol";

/// @title CommonHandler
/// @notice Handler test contract for the market common functions
contract CommonHandler is BaseHandler {
    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                      STATE VARIABLES                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                       GHOST VARAIBLES                                     //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           ACTIONS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function accrue() external {
        IBigBang(target).accrue();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                           HELPERS                                         //
    ///////////////////////////////////////////////////////////////////////////////////////////////
}