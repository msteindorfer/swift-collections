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

extension HashMap : ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (Key, Value)...) {
        let map = elements.reduce(Self()) { (map, element) in let (key, value) = element
            var tmp = map
            tmp.insert(key: key, value: value)
            return tmp
        }
        self.init(map)
    }
}
