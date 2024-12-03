// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LibString} from "solmate/src/utils/LibString.sol";

library CasinoLib {
    using LibString for uint256;

    uint8 public constant NUM_COLS_ROWS = 3;
    uint8 public constant NUM_VALUES = 10;
    uint256 private constant SCALAR = 10 ** 9;
    uint256 public constant BASE_MULTIPLIER = 6;
    uint256 public constant JACKPOT_DIGIT = 7;

    struct SlotMachine {
        uint256 minBet;
        uint256 pot;
    }

    function calculateSlotPull(uint256 betAmount, uint8[NUM_COLS_ROWS] memory randomNums)
        internal
        pure
        returns (uint256 payout, uint256 rollValue)
    {
        require(NUM_COLS_ROWS % 2 == 1, "NUM_COLS_ROWS must be odd because the middle row is special.");

        uint256 multiplier = BASE_MULTIPLIER;
        uint8 middleRowIndex = _getMiddleRowIndex();
        rollValue = _extractRowNumber(randomNums, 0);

        uint256 diagonalDownValue = _extractNumberDiagonalDown(rollValue);
        uint256 diagonalUpValue = _extractNumberDiagonalUp(rollValue);
        if (_isNumberRepeating(diagonalDownValue)) {
            multiplier = _applyDiagonalMultiplier(multiplier);
        }
        if (_isNumberRepeating(diagonalUpValue)) {
            multiplier = _applyDiagonalMultiplier(multiplier);
        }
        if (isJackpot(rollValue) || isJackpot(diagonalDownValue) || isJackpot(diagonalUpValue)) {
            multiplier = _applyJackpot(multiplier);
        }

        for (uint8 i = 0; i < NUM_COLS_ROWS; i++) {
            uint256 rowValue = _extractRowNumber(randomNums, i);
            if (_isNumberRepeating(rowValue)) {
                if (i == middleRowIndex) {
                    multiplier = _applyMiddleRowMultiplier(multiplier);
                } else {
                    multiplier = _applyHorizontalMultiplier(multiplier);
                }
                if (i > 0 && isJackpot(rowValue)) {
                    multiplier = _applyJackpot(multiplier);
                }
            }
        }

        if (multiplier == BASE_MULTIPLIER) {
            // multiplier never increased, which means no win
            multiplier = 0;
        }

        payout = (betAmount * multiplier);
    }

    /// Generate slot numbers using external randomness
    /// @param randomWord A single random word from Chainlink VRF
    /// @return randomNums An array of generated numbers for the slot machine
    function generateSlotNumbers(uint256 randomWord) internal pure returns (uint8[NUM_COLS_ROWS] memory randomNums) {
        for (uint8 i = 0; i < NUM_COLS_ROWS; i++) {
            randomNums[i] = uint8(randomWord % NUM_VALUES);
            randomWord >>= 8; // Shift to the next byte
        }
    }

    /**
     * Creates a uint256 comprised of ones.
     * @param numDigits The number of digits to create. Must be > 0 else reverts.
     * @return mask uint256 with `numDigits` ones.
     *
     *  ```
     *  require(_oneMask(3) == 111);
     *  require(_oneMask(8) == 11111111);
     *  ```
     */
    function _oneMask(uint8 numDigits) internal pure returns (uint256 mask) {
        require(numDigits > 0, "numDigits must be > 0");
        for (uint256 i = 0; i < numDigits; i++) {
            mask += (uint256(NUM_VALUES) ** i);
        }
    }

    function _isNumberRepeating(uint256 value) internal pure returns (bool) {
        return value % _oneMask(NUM_COLS_ROWS) == 0;
    }

    /// A jackpot is all JACKPOT_DIGITs in a row.
    function isJackpot(uint256 value) internal pure returns (bool) {
        return value == (_oneMask(NUM_COLS_ROWS) * JACKPOT_DIGIT);
    }

    function _extractRowNumber(uint8[NUM_COLS_ROWS] memory randomNums, uint8 rowIndex)
        internal
        pure
        returns (uint256 number)
    {
        for (uint8 j = 0; j < NUM_COLS_ROWS; j++) {
            number += _shiftDigit(randomNums[j], rowIndex, j);
        }
    }

    function _shiftDigit(uint256 baseNumber, uint8 rowIndex, uint8 columnIndex)
        internal
        pure
        returns (uint256 number)
    {
        if (columnIndex % 2 == 0) {
            // even digits +1 per row
            number += ((baseNumber + rowIndex) % NUM_VALUES) * (NUM_VALUES ** (NUM_COLS_ROWS - columnIndex - 1));
        } else {
            // odd digits -1 per row
            if (baseNumber < (NUM_COLS_ROWS - 1)) {
                // round robin
                baseNumber += NUM_VALUES;
            }
            number += ((baseNumber - rowIndex) % NUM_VALUES) * (NUM_VALUES ** (NUM_COLS_ROWS - columnIndex - 1));
        }
    }

    function _extractNumberDiagonalDown(uint256 baseNumber) internal pure returns (uint256 number) {
        for (uint8 i = 0; i < NUM_COLS_ROWS; i++) {
            uint256 factor = NUM_VALUES ** (NUM_COLS_ROWS - i - 1);
            number += _shiftDigit((baseNumber - (baseNumber % factor)) / factor, i, i);
        }
    }

    function _extractNumberDiagonalUp(uint256 baseNumber) internal pure returns (uint256 number) {
        for (uint8 i = 0; i < NUM_COLS_ROWS; i++) {
            uint256 factor = NUM_VALUES ** (NUM_COLS_ROWS - i - 1);
            number += _shiftDigit((baseNumber - (baseNumber % factor)) / factor, NUM_COLS_ROWS - i - 1, i);
        }
    }

    function _getMiddleRowIndex() internal pure returns (uint8 middleRowIndex) {
        for (uint8 idx = 0; idx < NUM_COLS_ROWS; idx++) {
            if (NUM_COLS_ROWS - idx - 1 == idx) {
                middleRowIndex = idx;
            }
        }
    }

    function _applyJackpot(uint256 multiplier) internal pure returns (uint256) {
        return multiplier * 13;
    }

    function _applyHorizontalMultiplier(uint256 multiplier) internal pure returns (uint256) {
        return multiplier * 2;
    }

    function _applyMiddleRowMultiplier(uint256 multiplier) internal pure returns (uint256) {
        return multiplier * 5;
    }

    function _applyDiagonalMultiplier(uint256 multiplier) internal pure returns (uint256) {
        return ((multiplier * SCALAR * 5) / 2) / SCALAR;
    }

    function boardToString(uint8[NUM_COLS_ROWS] memory randomNums) internal pure returns (string memory result) {
        for (uint8 i = 0; i < NUM_COLS_ROWS; i++) {
            result = string(abi.encodePacked(result, _extractRowNumber(randomNums, i).toString(), "\n"));
        }
    }
}
