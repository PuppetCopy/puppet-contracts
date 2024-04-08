// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Auth} from "@solmate/contracts/auth/Auth.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Precision} from "./../utils/Precision.sol";
import {Dictator} from "./../utils/Dictator.sol";

/**
 * @title PuppetToken
 * @dev An ERC20 token with a mint rate limit designed to mitigate and provide feedback of a potential critical faults or bugs in the minting process.
 * The limit restricts the quantity of new tokens that can be minted within a given timeframe, proportional to the existing supply.
 */
contract PuppetToken is Auth, ERC20 {
    event PuppetToken__SetMintLimitRate(uint rateLimitFactor, uint timeframeLimit);
    event PuppetToken__ReleaseCore(address to, uint timestamp, uint amount, uint releasedAmount);

    string private constant _NAME = "Muppet Test";
    string private constant _SYMBOL = "MUPPET";

    uint private constant CORE_RELEASE_DURATION = 31540000 * 2; // 2 years
    uint private constant CORE_RELEASE_RATE = 0.35e30; // 35%
    uint private constant CORE_RELEASE_END_SCHEDULE = 1822262400; // Thu Sep 30 2027

    uint private constant GENESIS_MINT_AMOUNT = 100_000e18;

    // Rate limit for minting new tokens in basis points
    uint public limitFactor;
    // Time window for minting new tokens
    uint public durationWindow;
    // Amount minted in the current window
    uint public mintWindowCount;
    // Current epoch for rate limit calculation
    uint public epoch;

    // the  amount of tokens released to the core
    uint public coreReleasedAmount;

    constructor(Dictator _authority) Auth(address(0), _authority) ERC20(_NAME, _SYMBOL) {
        _setMintLimitRate(0.01e30, 1 hours); // init at 1% of circulating supply per hour
        _mint(_authority.owner(), GENESIS_MINT_AMOUNT);
    }

    function getLimitAmount() public view returns (uint) {
        return Precision.applyFactor(limitFactor, totalSupply());
    }

    function getMarginAmount() public view returns (uint) {
        return getLimitAmount() - mintWindowCount;
    }

    /**
     * @dev Mints new tokens with a governance-controlled rate limit.
     * @param _for The address to mint tokens for.
     * @param _amount The amount of tokens to mint.
     * @return The amount of tokens minted.
     */
    function mint(address _for, uint _amount) external requiresAuth returns (uint) {
        uint nextEpoch = block.timestamp / durationWindow;

        // Reset mint count and update epoch at the start of a new window
        if (nextEpoch > epoch) {
            mintWindowCount = 0;
            epoch = nextEpoch;
        }

        // Add the requested mint amount to the window's mint count
        mintWindowCount += _amount;

        // Enforce the mint rate limit based on total emitted tokens
        if (mintWindowCount > getLimitAmount()) {
            revert PuppetToken__ExceededRateLimit(durationWindow, limitFactor, getLimitAmount());
        }

        _mint(_for, _amount);
        return _amount;
    }

    function mintCoreRelease(address _to) external requiresAuth returns (uint) {
        if (block.timestamp > CORE_RELEASE_END_SCHEDULE) revert PuppetToken__CoreReleaseEnded();

        uint timeElapsed = CORE_RELEASE_END_SCHEDULE - block.timestamp;
        uint timeMultiplier = Math.min(Precision.toFactor(timeElapsed, CORE_RELEASE_END_SCHEDULE), Precision.FLOAT_PRECISION);
        uint maxMintableAmount = Precision.applyFactor(CORE_RELEASE_RATE, totalSupply());
        uint maxMintableAmountForPeriod = Precision.applyFactor(timeMultiplier, maxMintableAmount);
        uint mintableAmount = maxMintableAmountForPeriod - coreReleasedAmount;

        _mint(_to, mintableAmount);

        coreReleasedAmount += mintableAmount;

        emit PuppetToken__ReleaseCore(_to, block.timestamp, mintableAmount, coreReleasedAmount);

        return mintableAmount;
    }

    /**
     * @dev Allows governance to adjust the mint rate limit and window.
     * @param _rateLimitFactor The new rate limit as a basis point percentage of total emitted tokens.
     * @param _timeframeLimit The new mint window timeframe in seconds.
     */
    function setMintLimitRate(uint _rateLimitFactor, uint _timeframeLimit) external requiresAuth {
        _setMintLimitRate(_rateLimitFactor, _timeframeLimit);
    }

    function _setMintLimitRate(uint _rateLimitFactor, uint _timeframeLimit) internal {
        limitFactor = _rateLimitFactor;
        durationWindow = _timeframeLimit;
        mintWindowCount = 0; // Reset the mint count window on rate limit change

        emit PuppetToken__SetMintLimitRate(_rateLimitFactor, _timeframeLimit);
    }

    error PuppetToken__InvalidRate();
    error PuppetToken__ExceededRateLimit(uint limitWindow, uint rateLimit, uint maxMintAmount);
    error PuppetToken__CoreReleaseEnded();
}
