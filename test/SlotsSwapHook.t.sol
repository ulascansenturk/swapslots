pragma solidity ^0.8.26;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

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

        subId = vrfCoordinator.createSubscription();

        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo(
            "SlotsSwapHook.sol",
            abi.encode(manager, address(vrfCoordinator), subId, keyHash, callbackGasLimit),
            hookAddress
        );

        hook = SlotsSwapHook(hookAddress);

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize a pool with these two tokens
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        (,, address subOwner,) = vrfCoordinator.getSubscription(subId);
        require(subOwner == address(this), "Subscription owner is not this contract");
        vrfCoordinator.addConsumer(subId, address(hook));
        assertEq(vrfCoordinator.consumerIsAdded(subId, address(hook)), true);
    }

    // function test_beforeInitialize() public {
    //     // Test the `beforeInitialize` hook
    //     console.logString("Testing beforeInitialize");

    //     manager.initialize(key, SQRT_PRICE_1_1);

    //     // Check if slot machine was initialized
    //     PoolId poolId = key.toId();
    //     (uint256 minBet, uint256 pot) = hook.getSlotMachine(poolId);

    //     assertEq(minBet, 1e6, "Slot machine not initialized correctly");
    //     assertEq(pot, 0, "Initial pot is not 0");
    // }

    // function test_afterSwapTriggersVRFRequest() public {
    //     // Simulate a swap triggering a bet
    //     int256 amount = 1e18; // User bets 1 token
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: amount,
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //     console.log("Testing afterSwap");

    //     // Perform the swap, which triggers the afterSwap hook
    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);

    //     // Since VRF request was triggered in afterSwap, fetch it manually
    //     uint256 requestId =
    //         vrfCoordinator.requestRandomWords(keyHash, subId, requestConfirmations, callbackGasLimit, numWords);

    //     // Check if the VRF request was initiated
    //     assertTrue(requestId > 0, "VRF request not initiated");

    //     // Check if the user and pool are linked to the requestId
    //     PoolId poolId = key.toId();
    //     address user = hook.vrfRequests(requestId);
    //     address swapper = address(this);

    //     assertEq(user, swapper, "User not linked to VRF request");
    // }

    // function test_fulfillRandomWordsRewardsUser() public {
    //     // Simulate a bet and a VRF request
    //     uint256 betAmount = 1e18;
    //     uint256 mockRandomNumber = 123456789;

    //     uint256 requestId = vrfCoordinator.requestRandomWords(keyHash, subId, 3, callbackGasLimit, numWords);
    //     vrfCoordinator.fulfillRandomWords(requestId, address(hook));

    //     // Check if user winnings were updated
    //     address user = address(this);
    //     uint256 winnings = hook.winnings(user);
    //     assertTrue(winnings > 0, "User winnings not updated");
    // }

    // function test_potUpdatesCorrectly() public {
    //     // Simulate multiple bets and check pot updates
    //     (, uint256 initialPot) = hook.getSlotMachine(key.toId());

    //     // Perform two bets
    //     int256 betAmount = 10 ether;

    //     for (uint256 i = 0; i < 2; i++) {
    //         IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: betAmount,
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         });

    //         PoolSwapTest.TestSettings memory testSettings =
    //             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    //         swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    //     }

    //     (, uint256 finalPot) = hook.getSlotMachine(key.toId());

    //     // Ensure betAmount is non-negative and cast to uint256
    //     uint256 absoluteBetAmount = betAmount >= 0 ? uint256(betAmount) : uint256(-betAmount);

    //     uint256 expectedPot = initialPot + 2 * absoluteBetAmount;
    //     assertEq(finalPot, expectedPot, "Pot not updated correctly");
    // }
}