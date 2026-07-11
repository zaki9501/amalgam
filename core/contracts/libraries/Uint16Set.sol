// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

/**
 * based on https://github.com/rob-Hitchens/SetTypes/blob/master/contracts/UintSet.sol
 * @notice Key sets with enumeration and delete. Uses mappings for random
 * and existence checks and dynamic arrays for enumeration. Key uniqueness is enforced.
 * @dev Sets are unordered. Delete operations reorder keys. All operations have a
 * fixed gas cost at any scale, O(1).
 * author: Rob Hitchens
 */
library Uint16Set {
    struct Set {
        mapping(uint16 => uint16) keyPointers;
        uint16[] keyList;
    }

    /**
     * @notice insert a key.
     * @dev duplicate keys are not permitted.
     * @param self storage pointer to a Set.
     * @param key value to insert.
     * @return keyAlreadyExists whether the key already existed in the set
     */
    function insert(Set storage self, uint16 key) internal returns (bool keyAlreadyExists) {
        if (exists(self, key)) return true;
        self.keyList.push(key);
        self.keyPointers[key] = uint16(self.keyList.length) - 1;
    }

    /**
     * @notice remove a key.
     * @dev If the key does not exist, this function is a no-op and returns true.
     * @param self storage pointer to a Set.
     * @param key value to remove.
     * @return isSetEmpty whether the key did not exist or the set still has items after removal
     */
    function remove(Set storage self, uint16 key) internal returns (bool isSetEmpty) {
        if (!exists(self, key)) {
            isSetEmpty = true;
        } else {
            uint16 last = count(self) - 1;
            uint16 rowToReplace = self.keyPointers[key];
            if (rowToReplace != last) {
                uint16 keyToMove = self.keyList[last];
                self.keyPointers[keyToMove] = rowToReplace;
                self.keyList[rowToReplace] = keyToMove;
            }
            delete self.keyPointers[key];
            self.keyList.pop();
            isSetEmpty = last > 0;
        }
    }

    /**
     * @notice count the keys.
     * @param self storage pointer to a Set.
     */
    function count(
        Set storage self
    ) internal view returns (uint16) {
        return uint16(self.keyList.length);
    }

    /**
     * @notice check if a key is in the Set.
     * @param self storage pointer to a Set.
     * @param key value to check.
     * @return bool true: Set member, false: not a Set member.
     */
    function exists(Set storage self, uint16 key) internal view returns (bool) {
        if (self.keyList.length == 0) return false;
        return self.keyList[self.keyPointers[key]] == key;
    }
}
