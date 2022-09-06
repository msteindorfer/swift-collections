//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Collections open source project
//
// Copyright (c) 2019 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

public struct PersistentDictionary<Key, Value> where Key: Hashable {
    var rootNode: BitmapIndexedDictionaryNode<Key, Value>

    fileprivate init(_ rootNode: BitmapIndexedDictionaryNode<Key, Value>) {
        self.rootNode = rootNode
    }

    public init() {
        self.init(BitmapIndexedDictionaryNode())
    }

    public init(_ map: PersistentDictionary<Key, Value>) {
        self.init(map.rootNode)
    }

    @inlinable
    @inline(__always)
    public init<S>(uniqueKeysWithValues keysAndValues: S) where S : Sequence, S.Element == (Key, Value) {
        var builder = Self()
        var expectedCount = 0
        keysAndValues.forEach { key, value in
            builder.updateValue(value, forKey: key)
            expectedCount += 1

            guard expectedCount == builder.count else {
                preconditionFailure("Duplicate key: '\(key)'")
            }
        }
        self.init(builder)
    }

    @inlinable
    @inline(__always)
    public init<Keys: Sequence, Values: Sequence>(uniqueKeys keys: Keys, values: Values) where Keys.Element == Key, Values.Element == Value {
        self.init(uniqueKeysWithValues: zip(keys, values))
    }

    ///
    /// Inspecting a Dictionary
    ///

    public var isEmpty: Bool { rootNode.count == 0 }

    public var count: Int { rootNode.count }

    public var underestimatedCount: Int { rootNode.count }

    public var capacity: Int { rootNode.count }

    ///
    /// Accessing Keys and Values
    ///

    public subscript(key: Key) -> Value? {
        get {
            return get(key)
        }
        mutating set(optionalValue) {
            if let value = optionalValue {
                updateValue(value, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    public subscript(key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        get {
            return get(key) ?? defaultValue()
        }
        mutating set(value) {
            updateValue(value, forKey: key)
        }
    }

    public func contains(_ key: Key) -> Bool {
        rootNode.containsKey(key, computeHash(key), 0)
    }

    func get(_ key: Key) -> Value? {
        rootNode.get(key, computeHash(key), 0)
    }

    @discardableResult
    public mutating func updateValue(_ value: Value, forKey key: Key) -> Value? {
        let isStorageKnownUniquelyReferenced = isKnownUniquelyReferenced(&self.rootNode)

        var effect = DictionaryEffect<Value>()
        let keyHash = computeHash(key)
        let newRootNode = rootNode.updateOrUpdating(isStorageKnownUniquelyReferenced, key, value, keyHash, 0, &effect)

        if effect.modified {
            self.rootNode = newRootNode
        }

        // Note, always tracking discardable result negatively impacts batch use cases
        return effect.previousValue
    }

    // fluid/immutable API
    public func updatingValue(_ value: Value, forKey key: Key) -> Self {
        var effect = DictionaryEffect<Value>()
        let keyHash = computeHash(key)
        let newRootNode = rootNode.updateOrUpdating(false, key, value, keyHash, 0, &effect)

        if effect.modified {
            return Self(newRootNode)
        } else { return self }
    }

    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        let isStorageKnownUniquelyReferenced = isKnownUniquelyReferenced(&self.rootNode)

        var effect = DictionaryEffect<Value>()
        let keyHash = computeHash(key)
        let newRootNode = rootNode.removeOrRemoving(isStorageKnownUniquelyReferenced, key, keyHash, 0, &effect)

        if effect.modified {
            self.rootNode = newRootNode
        }

        // Note, always tracking discardable result negatively impacts batch use cases
        return effect.previousValue
    }

    // fluid/immutable API
    public func removingValue(forKey key: Key) -> Self {
        var effect = DictionaryEffect<Value>()
        let keyHash = computeHash(key)
        let newRootNode = rootNode.removeOrRemoving(false, key, keyHash, 0, &effect)

        if effect.modified {
            return Self(newRootNode)
        } else { return self }
    }
}

///
/// Fixed-stack iterator for traversing a hash-trie. The iterator performs a
/// depth-first pre-order traversal, which yields first all payload elements of the current
/// node before traversing sub-nodes (left to right).
///
public struct DictionaryKeyValueTupleIterator<Key: Hashable, Value>: IteratorProtocol {

    private var payloadIterator: UnsafeBufferPointer<(key: Key, value: Value)>.Iterator?

    private var trieIteratorStackTop: UnsafeBufferPointer<BitmapIndexedDictionaryNode<Key, Value>>.Iterator?
    private var trieIteratorStackRemainder: [UnsafeBufferPointer<BitmapIndexedDictionaryNode<Key, Value>>.Iterator]

    init(rootNode: BitmapIndexedDictionaryNode<Key, Value>) {
        trieIteratorStackRemainder = []
        trieIteratorStackRemainder.reserveCapacity(maxDepth)

        if rootNode.hasNodes   { trieIteratorStackTop = rootNode._trieSlice.makeIterator() }
        if rootNode.hasPayload { payloadIterator = rootNode._dataSlice.makeIterator() }
    }

    public mutating func next() -> (key: Key, value: Value)? {
        if let payload = payloadIterator?.next() {
            return payload
        }

        while trieIteratorStackTop != nil {
            if let nextNode = trieIteratorStackTop!.next() {
                if nextNode.hasNodes {
                    trieIteratorStackRemainder.append(trieIteratorStackTop!)
                    trieIteratorStackTop = nextNode._trieSlice.makeIterator()
                }
                if nextNode.hasPayload {
                    payloadIterator = nextNode._dataSlice.makeIterator()
                    return payloadIterator?.next()
                }
            } else {
                trieIteratorStackTop = trieIteratorStackRemainder.popLast()
            }
        }

        // Clean-up state
        payloadIterator = nil

        assert(payloadIterator == nil)
        assert(trieIteratorStackTop == nil)
        assert(trieIteratorStackRemainder.isEmpty)

        return nil
    }
}

// TODO consider reworking similar to `DictionaryKeyValueTupleIterator`
// (would require a reversed variant of `UnsafeBufferPointer<(key: Key, value: Value)>.Iterator`)
public struct DictionaryKeyValueTupleReverseIterator<Key: Hashable, Value> {
    private var baseIterator: BaseReverseIterator<BitmapIndexedDictionaryNode<Key, Value>>

    init(rootNode: BitmapIndexedDictionaryNode<Key, Value>) {
        self.baseIterator = BaseReverseIterator(rootNode: rootNode)
    }
}

extension DictionaryKeyValueTupleReverseIterator: IteratorProtocol {
    public mutating func next() -> (key: Key, value: Value)? {
        guard baseIterator.hasNext() else { return nil }

        let payload = baseIterator.currentValueNode!.getPayload(baseIterator.currentValueCursor)
        baseIterator.currentValueCursor -= 1

        return payload
    }
}