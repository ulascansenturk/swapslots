pragma solidity ^0.8.26;

import "./CasinoLib.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {VRFCoordinatorV2Interface} from "foundry-chainlink-toolkit/src/interfaces/vrf/VRFCoordinatorV2Interface.sol";
import "foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract SlotsSwapHook is BaseHook, VRFConsumerBaseV2 {
    using PoolIdLibrary for PoolKey;
    using CasinoLib for CasinoLib.SlotMachine;

    VRFCoordinatorV2Interface private immutable COORDINATOR;
    uint64 private immutable subscriptionId;
    bytes32 private immutable keyHash;
    uint32 private immutable callbackGasLimit;

    mapping(PoolId => CasinoLib.SlotMachine) public slotMachines; // Slot machines by pool
    mapping(address => uint256) public winnings; // User winnings
    mapping(address => uint256) public userLosses; // User losses
    mapping(uint256 => address) public vrfRequests; // Map VRF requestId to user
    mapping(uint256 => PoolId) public requestToPoolId; // Map VRF requestId to PoolId
    mapping(uint256 => bool) public requestIdResultFulfilled;

    uint256 public lastRequestId;

    event RandomnessRequested(uint256 indexed requestId, address indexed user, uint256 betAmount);
    event RandomnessFulfilled(uint256 indexed requestId, address indexed user, uint256 payout);
    event UserWinnings(address indexed user, uint256 amount);
    event UserLosses(address indexed user, uint256 amount);

    constructor(
        IPoolManager _manager,
        address vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit
    ) BaseHook(_manager) VRFConsumerBaseV2(vrfCoordinator) {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        callbackGasLimit = _callbackGasLimit;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        if (slotMachines[poolId].minBet == 0) {
            slotMachines[poolId] = CasinoLib.SlotMachine({minBet: 0.001 ether, pot: 10e6});
        }
        return this.beforeInitialize.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        require(slotMachines[poolId].minBet > 0, "Slot machine not initialized");

        uint256 betAmount = uint256(params.amountSpecified);
        require(betAmount >= slotMachines[poolId].minBet, "Bet amount too small");

        uint256 potContribution = (betAmount * 70) / 100; // 70% to pot
        uint256 providerCompensation = (betAmount * 20) / 100; // 20% to providers
        uint256 casinoFee = (betAmount * 10) / 100; // 10% fee

        slotMachines[poolId].pot += potContribution;

        uint256 requestId = COORDINATOR.requestRandomWords(keyHash, subscriptionId, 3, callbackGasLimit, 1);
        vrfRequests[requestId] = sender; // Map requestId to user
        requestToPoolId[requestId] = poolId;
        lastRequestId = requestId;

        emit RandomnessRequested(requestId, sender, betAmount);

        return (this.afterSwap.selector, 0);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        address user = vrfRequests[requestId];
        PoolId poolId = requestToPoolId[requestId];
        require(user != address(0), "Invalid VRF request");

        uint8[3] memory slotNumbers = CasinoLib.generateSlotNumbers(randomWords[0]);
        (uint256 payout,) = CasinoLib.calculateSlotPull(slotMachines[poolId].minBet, slotNumbers);

        if (payout == 0) {
            uint256 lostAmount = slotMachines[poolId].minBet;
            slotMachines[poolId].pot += lostAmount;
            userLosses[user] += lostAmount;
            emit UserLosses(user, lostAmount);
        } else {
            winnings[user] += payout;
            emit UserWinnings(user, payout);
        }

        emit RandomnessFulfilled(requestId, user, payout);
        requestIdResultFulfilled[requestId] = true;
        delete vrfRequests[requestId];
    }

    function claimWinnings() external {
        uint256 amount = winnings[msg.sender];
        require(amount > 0, "No winnings to claim");

        winnings[msg.sender] = 0;

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Winnings transfer failed");

        emit UserWinnings(msg.sender, 0); // Emit event indicating winnings claimed
    }

    function getSlotMachine(PoolId poolId) external view returns (uint256 minBet, uint256 pot) {
        CasinoLib.SlotMachine storage machine = slotMachines[poolId];
        return (machine.minBet, machine.pot);
    }
}
