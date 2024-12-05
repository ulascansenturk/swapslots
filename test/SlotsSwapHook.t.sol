pragma solidity ^0.8.26;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

import {LibString} from "solmate/src/utils/LibString.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {console} from "forge-std/console.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {SlotsSwapHook} from "../src/SlotsSwapHook.sol";

import {VRFCoordinatorV2Mock} from
    "foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract SlotsSwapHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    using LibString for uint256;

    VRFCoordinatorV2Mock vrfCoordinator;
    uint64 subId;
    bytes32 keyHash = "";
    uint32 numWords = 1;
    uint32 callbackGasLimit = 400000;
    uint16 requestConfirmations = 3;

    Currency token0;
    Currency token1;

    SlotsSwapHook hook;

    function setUp() public {
        vrfCoordinator = new VRFCoordinatorV2Mock(100, 100);

        // Create a subscription
        subId = vrfCoordinator.createSubscription();
        assertGt(subId, 0, "Subscription creation failed");

        // Set up manager and tokens
        deployFreshManagerAndRouters();
        (token0, token1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);

        // Deploy the SlotsSwapHook contract
        deployCodeTo(
            "SlotsSwapHook.sol",
            abi.encode(manager, address(vrfCoordinator), subId, keyHash, callbackGasLimit),
            hookAddress
        );

        hook = SlotsSwapHook(hookAddress);
        require(address(hook) != address(0), "Hook contract deployment failed");

        // Add the hook as a consumer for the VRF subscription
        vrfCoordinator.addConsumer(subId, address(hook));
        require(vrfCoordinator.consumerIsAdded(subId, address(hook)), "Hook not added as a consumer");

        // Approve the hook to spend tokens
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize the pool
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize() public {
        console.logString("Testing beforeInitialize");

        // Check if slot machine was initialized
        PoolId poolId = key.toId();
        (uint256 minBet, uint256 pot) = hook.getSlotMachine(poolId);

        assertEq(minBet, 0.001 ether, "Slot machine not initialized correctly");
        assertEq(pot, 10e6, "Initial pot is not 0");
    }

    function test_afterSwapTriggersVRFRequest() public {
        // Simulate a swap triggering a bet
        int256 amount = 1e18; // User bets 1 token
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amount,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Testing afterSwap");

        // Perform the swap, which triggers the afterSwap hook
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 requestId = hook.lastRequestId();

        // Since VRF request was triggered in afterSwap, fetch it manually
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 51273812312123;

        vrfCoordinator.fundSubscription(subId, 10000000000);
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(hook), randomWords);
        assertEq(hook.requestIdResultFulfilled(requestId), true);
    }

    function test_potUpdatesCorrectly() public {
        // Get initial pot value
        (, uint256 initialPot) = hook.getSlotMachine(key.toId());

        // Perform two swaps with valid bets
        int256 betAmount = 1 ether;

        uint160 sqrtPrice = SQRT_PRICE_1_1;
        uint160 priceLowerBound = sqrtPrice / 2;
        uint160 priceUpperBound = sqrtPrice * 2;

        for (uint256 i = 0; i < 2; i++) {
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: i % 2 == 0, // Alternate swap direction
                amountSpecified: betAmount,
                sqrtPriceLimitX96: i % 2 == 0 ? priceLowerBound : priceUpperBound
            });

            PoolSwapTest.TestSettings memory testSettings =
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

            swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        }

        // Get final pot value
        (, uint256 finalPot) = hook.getSlotMachine(key.toId());

        // Calculate expected pot
        uint256 expectedPot = initialPot + (2 * uint256(betAmount) * 70) / 100;

        // Assert final pot matches expectation
        assertEq(
            finalPot,
            expectedPot,
            string(abi.encodePacked("Pot not updated correctly: ", finalPot.toString(), " != ", expectedPot.toString()))
        );
    }
}
