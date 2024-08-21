// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {CoreContract} from "../utils/CoreContract.sol";
import {EventEmitter} from "../utils/EventEmitter.sol";
import {IAuthority} from "../utils/interfaces/IAuthority.sol";
import {GmxPositionUtils} from "./utils/GmxPositionUtils.sol";

contract ExecuteRevertedAdjustmentLogic is CoreContract {
    event ExecuteRevertedAdjustmentLogic__SetConfig(uint timestamp, Config config);

    struct Config {
        string handlehandle;
    }

    Config config;

    constructor(
        IAuthority _authority,
        EventEmitter _eventEmitter,
        Config memory _config
    ) CoreContract("ExecuteRevertedAdjustmentLogic", "1", _authority, _eventEmitter) {
        _setConfig(_config);
    }

    function handleCancelled(bytes32 key, GmxPositionUtils.Props memory order) external auth {
        // TODO: implement
    }
    function handleFrozen(bytes32 key, GmxPositionUtils.Props memory order) external auth {
        // TODO: implement
    }

    // governance

    function setConfig(Config memory _config) external auth {
        _setConfig(_config);
    }

    function _setConfig(Config memory _config) internal {
        config = _config;

        emit ExecuteRevertedAdjustmentLogic__SetConfig(block.timestamp, config);
    }
}
