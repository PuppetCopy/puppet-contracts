// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CoreContract} from "../utils/CoreContract.sol";
import {EventEmitter} from "../utils/EventEmitter.sol";
import {IAuthority} from "../utils/interfaces/IAuthority.sol";
import {PuppetStore} from "./../puppet/store/PuppetStore.sol";
import {Error} from "./../shared/Error.sol";
import {Subaccount} from "./../shared/Subaccount.sol";
import {ErrorUtils} from "./../utils/ErrorUtils.sol";
import {Precision} from "./../utils/Precision.sol";
import {IGmxDatastore} from "./interface/IGmxDatastore.sol";
import {IGmxExchangeRouter} from "./interface/IGmxExchangeRouter.sol";
import {MirrorPositionStore} from "./store/MirrorPositionStore.sol";
import {GmxPositionUtils} from "./utils/GmxPositionUtils.sol";
import {PositionUtils} from "./utils/PositionUtils.sol";

contract RequestPositionLogic is CoreContract {
    bytes32 constant GMX_DATASTORE_SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 constant GMX_DATASTORE_COLLATERAL_AMOUNT = keccak256(abi.encode("COLLATERAL_AMOUNT"));

    struct Config {
        IGmxExchangeRouter gmxExchangeRouter;
        IGmxDatastore gmxDatastore;
        address callbackHandler;
        address gmxFundsReciever;
        address gmxOrderVault;
        bytes32 referralCode;
        uint callbackGasLimit;
        uint limitPuppetList;
        uint minimumMatchAmount;
    }

    struct RequestMirrorPosition {
        IERC20 collateralToken;
        bytes32 originRequestKey;
        bytes32 routeKey;
        address trader;
        address market;
        bool isIncrease;
        bool isLong;
        GmxPositionUtils.OrderType orderType;
        uint executionFee;
        uint collateralDelta;
        uint sizeDeltaInUsd;
        uint acceptablePrice;
        uint triggerPrice;
    }

    PuppetStore puppetStore;
    MirrorPositionStore positionStore;
    Config public config;

    constructor(
        IAuthority _authority,
        EventEmitter _eventEmitter,
        PuppetStore _puppetStore,
        MirrorPositionStore _positionStore
    ) CoreContract("RequestPositionLogic", "1", _authority, _eventEmitter) {
        puppetStore = _puppetStore;
        positionStore = _positionStore;
    }

    function submitOrder(
        RequestMirrorPosition calldata order,
        Subaccount subaccount,
        MirrorPositionStore.RequestAdjustment memory request,
        GmxPositionUtils.OrderType orderType,
        uint collateralDelta
    ) internal returns (bytes32 requestKey) {
        (bool orderSuccess, bytes memory orderReturnData) = subaccount.execute(
            address(config.gmxExchangeRouter),
            abi.encodeWithSelector(
                config.gmxExchangeRouter.createOrder.selector,
                GmxPositionUtils.CreateOrderParams({
                    addresses: GmxPositionUtils.CreateOrderParamsAddresses({
                        receiver: config.gmxFundsReciever,
                        callbackContract: config.callbackHandler,
                        uiFeeReceiver: address(0),
                        market: order.market,
                        initialCollateralToken: order.collateralToken,
                        swapPath: new address[](0)
                    }),
                    numbers: GmxPositionUtils.CreateOrderParamsNumbers({
                        sizeDeltaUsd: request.sizeDelta,
                        initialCollateralDeltaAmount: collateralDelta,
                        triggerPrice: order.triggerPrice,
                        acceptablePrice: order.acceptablePrice,
                        executionFee: order.executionFee,
                        callbackGasLimit: config.callbackGasLimit,
                        minOutputAmount: 0
                    }),
                    orderType: orderType,
                    decreasePositionSwapType: GmxPositionUtils.DecreasePositionSwapType.NoSwap,
                    isLong: order.isLong,
                    shouldUnwrapNativeToken: false,
                    referralCode: config.referralCode
                })
            )
        );

        if (!orderSuccess) {
            ErrorUtils.revertWithParsedMessage(orderReturnData);
        }

        requestKey = abi.decode(orderReturnData, (bytes32));

        request.transactionCost = (request.transactionCost - gasleft()) * tx.gasprice + order.executionFee;
        positionStore.setRequestAdjustment(requestKey, request);
    }

    function adjust(
        RequestMirrorPosition calldata order,
        MirrorPositionStore.RequestAdjustment memory request,
        Subaccount subaccount
    ) internal returns (bytes32 requestKey) {
        uint traderSize = getDatstoreValue(request.traderPositionKey, GMX_DATASTORE_SIZE_IN_USD);
        uint traderCollateral = getDatstoreValue(request.traderPositionKey, GMX_DATASTORE_COLLATERAL_AMOUNT);
        uint leverage = Precision.toBasisPoints(traderSize, traderCollateral);
        uint targetLeverage = order.isIncrease
            ? Precision.toBasisPoints(traderSize + order.sizeDeltaInUsd, traderCollateral + order.collateralDelta)
            : order.sizeDeltaInUsd < traderSize
                ? Precision.toBasisPoints(traderSize - order.sizeDeltaInUsd, traderCollateral - order.collateralDelta)
                : 0;

        if (targetLeverage > leverage) {
            uint deltaLeverage = targetLeverage - leverage;
            request.sizeDelta = traderSize * deltaLeverage / targetLeverage;

            requestKey = submitOrder(order, subaccount, request, GmxPositionUtils.OrderType.MarketIncrease, 0);

            logEvent(
                "RequestIncrease",
                abi.encode(
                    order.originRequestKey,
                    requestKey,
                    request.traderPositionKey,
                    request.positionKey,
                    request.sizeDelta,
                    request.transactionCost,
                    deltaLeverage
                )
            );
        } else {
            uint deltaLeverage = leverage - targetLeverage;
            request.sizeDelta = traderSize * deltaLeverage / leverage;

            requestKey = submitOrder(order, subaccount, request, GmxPositionUtils.OrderType.MarketDecrease, 0);

            logEvent(
                "RequestDecrease",
                abi.encode(
                    order.originRequestKey,
                    requestKey,
                    request.traderPositionKey,
                    request.positionKey,
                    request.sizeDelta,
                    request.transactionCost,
                    deltaLeverage
                )
            );
        }
    }

    function mirror(RequestMirrorPosition calldata order) external payable auth returns (bytes32 requestKey) {
        uint startGas = gasleft();

        Subaccount subaccount = positionStore.getSubaccount(order.routeKey);
        address subaccountAddress = address(subaccount);

        if (subaccountAddress == address(0)) {
            subaccount = positionStore.createSubaccount(order.routeKey, order.trader);
        }

        MirrorPositionStore.RequestAdjustment memory request = MirrorPositionStore.RequestAdjustment({
            routeKey: order.routeKey,
            positionKey: GmxPositionUtils.getPositionKey(
                subaccountAddress, order.market, order.collateralToken, order.isLong
                ),
            traderPositionKey: GmxPositionUtils.getPositionKey(
                order.trader, order.market, order.collateralToken, order.isLong
                ),
            sizeDelta: 0,
            transactionCost: startGas
        });

        MirrorPositionStore.Position memory mirrorPosition = positionStore.getPosition(request.positionKey);

        if (mirrorPosition.size == 0) {
            PuppetStore.AllocationMatch memory allocation = puppetStore.getAllocationMatch(order.routeKey);

            if (allocation.amountOut > 0) {
                revert Error.RequestPositionLogic__PendingAllocation();
            }

            puppetStore.transferOutAllocation(
                order.collateralToken, order.routeKey, config.gmxOrderVault, allocation.totalAllocated
            );
            requestKey =
                submitOrder(order, subaccount, request, GmxPositionUtils.OrderType.MarketIncrease, allocation.amountOut);

            logEvent(
                "RequestIncrease",
                abi.encode(
                    order.originRequestKey,
                    requestKey,
                    request.traderPositionKey,
                    request.positionKey,
                    request.sizeDelta,
                    request.transactionCost,
                    0
                )
            );
        } else {
            requestKey = adjust(order, request, subaccount);
        }
    }

    function allocate(
        IERC20 collateralToken,
        bytes32 originRequestKey,
        bytes32 routeKey,
        uint fromIndex,
        uint toIndex
    ) external auth {
        uint startGas = gasleft();
        (uint totalAllocated, PuppetStore.RouteAllocation[] memory _matchedAllocations) =
            puppetStore.allocateList(collateralToken, routeKey, fromIndex, toIndex);
        uint transactionCost = (startGas - gasleft()) * tx.gasprice;

        logEvent(
            "AllocateMatch",
            abi.encode(
                collateralToken, originRequestKey, routeKey, transactionCost, totalAllocated, _matchedAllocations
            )
        );
    }

    function getDatstoreValue(bytes32 positionKey, bytes32 prop) internal view returns (uint) {
        return config.gmxDatastore.getUint(keccak256(abi.encode(positionKey, prop)));
    }

    // governance

    /// @notice Set the mint rate limit for the token.
    /// @param _config The new rate limit configuration.
    function setConfig(Config calldata _config) external auth {
        config = _config;
        logEvent("SetConfig", abi.encode(_config));
    }
}
