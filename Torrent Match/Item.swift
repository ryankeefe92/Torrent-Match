//
//  Item.swift
//  Torrent Match
//
//  Created by Ryan Keefe on 5/17/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date = Date()
    
    init(timestamp: Date = Date()) {
        self.timestamp = timestamp
    }
}
