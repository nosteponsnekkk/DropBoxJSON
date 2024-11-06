//
//  JSONClient.swift
//  DropBoxJSON-iOS
//
//  Created by Oleg on 06.11.2024.
//

import Foundation
import Combine
import Dependencies

// MARK: - DropBoxFileJSONClient Protocol

public protocol DropBoxFileJSONClient {
    func prepareContent<Item: DropBoxJSON>(jsonType: Item.Type) async throws
    func getJSON<Item: DropBoxJSON, T: Decodable>(json: Item, decodingType: T.Type) throws -> T
    var updatePublisher: AnyPublisher<any DropBoxJSON, Never> { get }
}
// MARK: - DropBoxJSON Protocol

public protocol DropBoxJSON: Hashable, CaseIterable {
    /// The path to the folder containing all the JSON files.
    static var parentFolderPath: String { get }
    
    /// The file name of the JSON file associated with each enum case.
    var fileName: String { get }
}

// MARK: - Dependency Key

public extension DependencyValues {
    var dropBoxJsonClient: DropBoxFileJSONClient {
        get { self[DropBoxJsonKey.self] }
        set { self[DropBoxJsonKey.self] = newValue }
    }
    struct DropBoxJsonKey: DependencyKey {
        public static let liveValue: DropBoxFileJSONClient = DropBoxJSONService()
        public init() {}
    }
}
