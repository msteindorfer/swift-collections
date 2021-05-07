//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Collections open source project
//
// Copyright (c) 2019 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

fileprivate var TupleLength: Int { 2 }

final class BitmapIndexedMapNode<Key, Value> : MapNode where Key : Hashable {
    let bitmap1: Bitmap
    let bitmap2: Bitmap
    var content: [Any]

    var dataMap: Bitmap { bitmap1 ^ collMap }

    var nodeMap: Bitmap { bitmap2 ^ collMap }

    var collMap: Bitmap { bitmap1 & bitmap2 }

    init(_ dataMap: Bitmap, _ nodeMap: Bitmap, _ collMap: Bitmap, _ content: [Any]) {
        self.bitmap1 = dataMap ^ collMap
        self.bitmap2 = nodeMap ^ collMap
        self.content = content
    }

    func get(_ key: Key, _ keyHash: Int, _ shift: Int) -> Value? {
        let mask = maskFrom(keyHash, shift)
        let bitpos = bitposFrom(mask)

        if ((dataMap & bitpos) != 0) {
            let index = indexFrom(dataMap, mask, bitpos)
            let payload = self.getPayload(index)
            if (key == payload.0) { return payload.1 } else { return nil }
        }

        if ((nodeMap & bitpos) != 0) {
            let index = indexFrom(nodeMap, mask, bitpos)

            if (shift + BitPartitionSize >= HashCodeLength) {
                return self.getCollisionNode(index).get(key, keyHash, shift + BitPartitionSize)
            } else {
                return self.getNode(index).get(key, keyHash, shift + BitPartitionSize)
            }
        }

        return nil
    }

    func containsKey(_ key: Key, _ keyHash: Int, _ shift: Int) -> Bool {
        let mask = maskFrom(keyHash, shift)
        let bitpos = bitposFrom(mask)

        if ((dataMap & bitpos) != 0) {
            let index = indexFrom(dataMap, mask, bitpos)
            let payload = self.getPayload(index)
            return key == payload.0
        }

        if ((nodeMap & bitpos) != 0) {
            let index = indexFrom(nodeMap, mask, bitpos)
            if (shift + BitPartitionSize >= HashCodeLength) {
                return self.getCollisionNode(index).containsKey(key, keyHash, shift + BitPartitionSize)
            } else {
                return self.getNode(index).containsKey(key, keyHash, shift + BitPartitionSize)
            }
        }

        return false
    }

    func updated(_ isStorageKnownUniquelyReferenced: Bool, _ key: Key, _ value: Value, _ keyHash: Int, _ shift: Int, _ effect: inout MapEffect) -> BitmapIndexedMapNode<Key, Value> {
        let mask = maskFrom(keyHash, shift)
        let bitpos = bitposFrom(mask)

        if ((dataMap & bitpos) != 0) {
            let index = indexFrom(dataMap, mask, bitpos)
            let (key0, value0) = self.getPayload(index)

            if (key0 == key) {
                effect.setReplacedValue()
                return copyAndSetValue(isStorageKnownUniquelyReferenced, bitpos, value)
            } else {
                let subNodeNew = mergeTwoKeyValPairs(key0, value0, computeHash(key0), key, value, keyHash, shift + BitPartitionSize)
                effect.setModified()
                return copyAndMigrateFromInlineToNode(bitpos, subNodeNew)
            }
        }

        if ((nodeMap & bitpos) != 0) {
            // TODO avoid code duplication and specialization
            if (shift + BitPartitionSize >= HashCodeLength) {
                // hash-collison sub-node

                let index = indexFrom(nodeMap, mask, bitpos)
                let subNodeModifyInPlace = self.isNodeKnownUniquelyReferenced(index, isStorageKnownUniquelyReferenced)
                let subNode = self.getCollisionNode(index) // NOTE difference in callee

                let subNodeNew = subNode.updated(subNodeModifyInPlace, key, value, keyHash, shift + BitPartitionSize, &effect)
                if (!effect.modified) {
                    return self
                } else {
                    return copyAndSetNode(isStorageKnownUniquelyReferenced, bitpos, subNodeNew)
                }
            } else {
                // regular sub-node

                let index = indexFrom(nodeMap, mask, bitpos)
                let subNodeModifyInPlace = self.isNodeKnownUniquelyReferenced(index, isStorageKnownUniquelyReferenced)
                let subNode = self.getNode(index)

                let subNodeNew = subNode.updated(subNodeModifyInPlace, key, value, keyHash, shift + BitPartitionSize, &effect)
                if (!effect.modified) {
                    return self
                } else {
                    return copyAndSetNode(isStorageKnownUniquelyReferenced, bitpos, subNodeNew)
                }
            }
        }

        effect.setModified()
        return copyAndInsertValue(bitpos, key, value)
    }

    func removed(_ isStorageKnownUniquelyReferenced: Bool, _ key: Key, _ keyHash: Int, _ shift: Int, _ effect: inout MapEffect) -> BitmapIndexedMapNode<Key, Value> {
        let mask = maskFrom(keyHash, shift)
        let bitpos = bitposFrom(mask)

        if ((dataMap & bitpos) != 0) {
            let index = indexFrom(dataMap, mask, bitpos)
            let (key0, _) = self.getPayload(index)

            if (key0 == key) {
                effect.setModified()
                if (self.payloadArity == 2 && self.nodeArity == 0) {
                    /*
                     * Create new node with remaining pair. The new node will a) either become the new root
                     * returned, or b) unwrapped and inlined during returning.
                     */
                    let newDataMap: Bitmap
                    if (shift == 0) { newDataMap = (dataMap ^ bitpos) } else { newDataMap = bitposFrom(maskFrom(keyHash, 0)) }
                    if (index == 0) {
                        let (k, v) = getPayload(1)
                        return BitmapIndexedMapNode(newDataMap, 0, 0, Array(arrayLiteral: k, v) )
                    } else {
                        let (k, v) = getPayload(0)
                        return BitmapIndexedMapNode(newDataMap, 0, 0, Array(arrayLiteral: k, v))
                    }
                } else { return copyAndRemoveValue(bitpos) }
            } else { return self }
        }

        if ((nodeMap & bitpos) != 0) {
            // TODO avoid code duplication and specialization
            if (shift + BitPartitionSize >= HashCodeLength) {
                // hash-collison sub-node

                let index = indexFrom(nodeMap, mask, bitpos)
                let subNodeModifyInPlace = self.isNodeKnownUniquelyReferenced(index, isStorageKnownUniquelyReferenced)
                let subNode = self.getCollisionNode(index) // NOTE difference in callee

                let subNodeNew = subNode.removed(subNodeModifyInPlace, key, keyHash, shift + BitPartitionSize, &effect)

                if (!effect.modified) { return self }
                switch subNodeNew.payloadArity {
                case 1:
                    if (self.payloadArity == 0 && self.nodeArity == 1) { // escalate (singleton or empty) result
                        // convert `HashCollisionMapNode` to `BitmapIndexedMapNode` (logic moved/inlined from `HashCollisionMapNode`)
                        let newDataMap: Bitmap = bitposFrom(maskFrom(subNodeNew.hash, 0))
                        let (k, v) = subNodeNew.getPayload(0)

                        return BitmapIndexedMapNode(newDataMap, 0, 0, Array(arrayLiteral: k, v))
                    }
                    else { // inline value (move to front)
                        return copyAndMigrateFromNodeToInline(bitpos, subNodeNew.getPayload(0))
                    }

                default: // equivalent to `case 2...`
                    // modify current node (set replacement node)
                    return copyAndSetNode(isStorageKnownUniquelyReferenced, bitpos, subNodeNew)
                }
            } else {
                // regular sub-node

                let index = indexFrom(nodeMap, mask, bitpos)
                let subNodeModifyInPlace = self.isNodeKnownUniquelyReferenced(index, isStorageKnownUniquelyReferenced)
                let subNode = self.getNode(index)

                let subNodeNew = subNode.removed(subNodeModifyInPlace, key, keyHash, shift + BitPartitionSize, &effect)

                if (!effect.modified) { return self }
                switch subNodeNew.payloadArity {
                case 1:
                    if (self.payloadArity == 0 && self.nodeArity == 1) { // escalate (singleton or empty) result
                        return subNodeNew
                    }
                    else { // inline value (move to front)
                        return copyAndMigrateFromNodeToInline(bitpos, subNodeNew.getPayload(0))
                    }

                default: // equivalent to `case 2...`
                    // modify current node (set replacement node)
                    return copyAndSetNode(isStorageKnownUniquelyReferenced, bitpos, subNodeNew)
                }
            }
        }

        return self
    }

    func mergeTwoKeyValPairs(_ key0: Key, _ value0: Value, _ keyHash0: Int, _ key1: Key, _ value1: Value, _ keyHash1: Int, _ shift: Int) -> BitmapIndexedMapNode<Key, Value> {
        let mask0 = maskFrom(keyHash0, shift)
        let mask1 = maskFrom(keyHash1, shift)

        if (mask0 != mask1) {
            // unique prefixes, payload fits on same level
            let dataMap = bitposFrom(mask0) | bitposFrom(mask1)

            if (mask0 < mask1) {
                return BitmapIndexedMapNode(dataMap, 0, 0, Array(arrayLiteral: key0, value0, key1, value1))
            } else {
                return BitmapIndexedMapNode(dataMap, 0, 0, Array(arrayLiteral: key1, value1, key0, value0))
            }
        } else {
            if (shift + BitPartitionSize >= HashCodeLength) {
                // hash collision: prefix exhausted on next level

                let collMap = bitposFrom(mask0)
                let node = HashCollisionMapNode(keyHash0, [(key0, value0), (key1, value1)])

                return BitmapIndexedMapNode(0, collMap, 0, Array(arrayLiteral: node)) // TODO swap `collMap` <-> `0`
            } else {
                // recurse: identical prefixes, payload must be disambiguated deeper in the trie

                let nodeMap = bitposFrom(mask0)
                let node = mergeTwoKeyValPairs(key0, value0, keyHash0, key1, value1, keyHash1, shift + BitPartitionSize)

                return BitmapIndexedMapNode(0, nodeMap, 0, Array(arrayLiteral: node))
            }
        }
    }

    var hasNodes: Bool { nodeMap != 0 }

    var nodeArity: Int { nodeMap.nonzeroBitCount }

    // TODO rework temporarily duplicated methods for type-safe access (requires changing protocol)
    func getNode(_ index: Int) -> BitmapIndexedMapNode<Key, Value> {
        content[content.count - 1 - index] as! BitmapIndexedMapNode<Key, Value>
    }

    // TODO rework temporarily duplicated methods for type-safe access (requires changing protocol)
    func getCollisionNode(_ index: Int) -> HashCollisionMapNode<Key, Value> {
        content[content.count - 1 - index] as! HashCollisionMapNode<Key, Value>
    }

    // TODO rework temporarily duplicated methods for type-safe access (requires changing protocol)
    func getAnyNode(_ index: Int) -> Any {
        content[content.count - 1 - index]
    }


    // TODO replace 'manual' move semantics with pointer arithmetic for obtaining reference
    // to pass into `isKnownUniquelyReferenced`
    private func isNodeKnownUniquelyReferenced(_ index: Int, _ isParentNodeKnownUniquelyReferenced: Bool) -> Bool {
        let slotIndex = content.count - 1 - index

        let fakeNode = BitmapIndexedMapNode(0, 0, 0, Array())

        var realNode = content[slotIndex] as AnyObject
        content[slotIndex] = fakeNode

        let isKnownUniquelyReferenced = isKnownUniquelyReferenced(&realNode)
        content[slotIndex] = realNode

        return isParentNodeKnownUniquelyReferenced && isKnownUniquelyReferenced
    }

    var hasPayload: Bool { dataMap != 0 }

    var payloadArity: Int { dataMap.nonzeroBitCount }

    func getPayload(_ index: Int) -> (Key, Value) {
        (content[TupleLength * index + 0] as! Key,
         content[TupleLength * index + 1] as! Value)
    }

    func dataIndex(_ bitpos: Bitmap) -> Int { (dataMap & (bitpos &- 1)).nonzeroBitCount }

    func nodeIndex(_ bitpos: Bitmap) -> Int { (nodeMap & (bitpos &- 1)).nonzeroBitCount }

    /// TODO: leverage lazy copy-on-write only when aliased. The pattern required by the current data structure design
    /// isn't expressible in Swift currently (i.e., `isKnownUniquelyReferenced(&self)` isn't supported). Example:
    ///
    /// ```
    /// class Node {
    ///     var src: [Any]
    ///     func updateInlineOrCopy(idx: Int, newValue: Any) {
    ///         if isKnownUniquelyReferenced(&self) { // this isn't supported ...
    ///             src[idx] = newValue
    ///             return self
    ///         } else {
    ///             var dst = self.content
    ///             dst[idx] = newValue
    ///             return Node(dst)
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Some more context:
    /// * Node should be a reference counted data type (i.e., `class`)
    /// * In a optimized version `src` would be gone, and `Node` likely become a subclass of `ManagedBuffer`
    /// * I want to check `isKnownUniquelyReferenced(&self)` since `updateInlineOrCopy` should be recursive call that decides upon returning from recursion if modifications are necessary
    ///
    /// Possible mitigations: transform recursive to loop where `isKnownUniquelyReferenced` could be checked from the outside.
    /// This would be very invasive though and make problem logic hard to understand and maintain.
    func copyAndSetValue(_ isStorageKnownUniquelyReferenced: Bool, _ bitpos: Bitmap, _ newValue: Value) -> BitmapIndexedMapNode<Key, Value> {
        let idx = TupleLength * dataIndex(bitpos) + 1

        if (isStorageKnownUniquelyReferenced) {
            // no copying if already editable
            self.content[idx] = newValue

            return self
        } else {
            var dst = self.content
            dst[idx] = newValue

            return BitmapIndexedMapNode(dataMap, nodeMap, collMap, dst)
        }
    }

    func copyAndSetNode<T: MapNode>(_ isStorageKnownUniquelyReferenced: Bool, _ bitpos: Bitmap, _ newNode: T) -> BitmapIndexedMapNode<Key, Value> {
        let idx = self.content.count - 1 - self.nodeIndex(bitpos)

        if (isStorageKnownUniquelyReferenced) {
            // no copying if already editable
            self.content[idx] = newNode

            return self
        } else {
            var dst = self.content
            dst[idx] = newNode

            return BitmapIndexedMapNode(dataMap, nodeMap, collMap, dst)
        }
    }

    func copyAndInsertValue(_ bitpos: Bitmap, _ key: Key, _ value: Value) -> BitmapIndexedMapNode<Key, Value> {
        let idx = TupleLength * dataIndex(bitpos)

        var dst = self.content
        dst.insert(contentsOf: [key, value], at: idx)

        return BitmapIndexedMapNode(dataMap | bitpos, nodeMap, collMap, dst)
    }

    func copyAndRemoveValue(_ bitpos: Bitmap) -> BitmapIndexedMapNode<Key, Value> {
        let idx = TupleLength * dataIndex(bitpos)

        var dst = self.content
        dst.removeSubrange(idx..<idx+TupleLength)

        return BitmapIndexedMapNode(dataMap ^ bitpos, nodeMap, collMap, dst)
    }

    func copyAndMigrateFromInlineToNode(_ bitpos: Bitmap, _ node: BitmapIndexedMapNode<Key, Value>) -> BitmapIndexedMapNode<Key, Value> {
        let idxOld = TupleLength * dataIndex(bitpos)
        let idxNew = self.content.count - TupleLength - nodeIndex(bitpos)

        var dst = self.content
        dst.removeSubrange(idxOld..<idxOld+TupleLength)
        dst.insert(node, at: idxNew)

        return BitmapIndexedMapNode(dataMap ^ bitpos, nodeMap | bitpos, collMap, dst) // TODO check correctness
    }

    func copyAndMigrateFromNodeToInline(_ bitpos: Bitmap, _ tuple: (key: Key, value: Value)) -> BitmapIndexedMapNode<Key, Value> {
        let idxOld = self.content.count - 1 - nodeIndex(bitpos)
        let idxNew = TupleLength * dataIndex(bitpos)

        var dst = self.content
        dst.remove(at: idxOld)
        dst.insert(contentsOf: [tuple.key, tuple.value], at: idxNew)

        return BitmapIndexedMapNode(dataMap | bitpos, nodeMap ^ bitpos, collMap, dst) // TODO check correctness
    }
}

extension BitmapIndexedMapNode : Equatable where Value : Equatable {
    static func == (lhs: BitmapIndexedMapNode<Key, Value>, rhs: BitmapIndexedMapNode<Key, Value>) -> Bool {
        lhs === rhs ||
            lhs.nodeMap == rhs.nodeMap &&
            lhs.dataMap == rhs.dataMap &&
            deepContentEquality(lhs, rhs)
    }

    private static func deepContentEquality(_ lhs: BitmapIndexedMapNode<Key, Value>, _ rhs: BitmapIndexedMapNode<Key, Value>) -> Bool {
        for index in 0..<lhs.payloadArity {
            if (lhs.getPayload(index) != rhs.getPayload(index)) {
                return false
            }
        }

        /// `==` has no context on how deep the current node is located in the trie. Thus it would be beneficial making it explict
        /// how many regular and hash-collision nodes are stored on the current level.

        for index in 0..<lhs.nodeArity {
            if let lhsNode = lhs.getAnyNode(index) as? BitmapIndexedMapNode<Key, Value>,
               let rhsNode = rhs.getAnyNode(index) as? BitmapIndexedMapNode<Key, Value> {
                if (lhsNode != rhsNode) {
                    return false
                }
            } else if let lhsNode = lhs.getAnyNode(index) as? HashCollisionMapNode<Key, Value>,
                      let rhsNode = rhs.getAnyNode(index) as? HashCollisionMapNode<Key, Value> {
                if (lhsNode != rhsNode) {
                    return false
                }
            } else {
                return false
            }
        }

        return true
    }
}
