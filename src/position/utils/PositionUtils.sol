// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library PositionUtils {
    function getMatchKey(IERC20 collateralToken, address trader) internal pure returns (bytes32) {
        return keccak256(abi.encode(collateralToken, trader));
    }

    function getRouteKey(IERC20 collateralToken, address puppet) internal pure returns (bytes32) {
        return keccak256(abi.encode(collateralToken, puppet));
    }

    function getAllocationKey(bytes32 matchKey, uint cursor) internal pure returns (bytes32) {
        return keccak256(abi.encode(matchKey, cursor));
    }

    function getSettlementKey(bytes32 matchKey, uint cursor) internal pure returns (bytes32) {
        return keccak256(abi.encode(matchKey, cursor));
    }
}
