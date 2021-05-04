//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Collections open source project
//
// Copyright (c) 2019 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// TODO check Dictionary semantics of Equatable (i.e., if it only compares keys or also values)
extension HashMap : Equatable where Value : Equatable {
    public static func == (lhs: HashMap<Key, Value>, rhs: HashMap<Key, Value>) -> Bool {
        lhs.cachedSize == rhs.cachedSize &&
            lhs.cachedKeySetHashCode == rhs.cachedKeySetHashCode &&
            (lhs.rootNode === rhs.rootNode || lhs.rootNode == rhs.rootNode)
    }
}
