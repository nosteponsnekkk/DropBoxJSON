//
//  DropBoxJSONService.swift
//  DropBoxJSON
//
//  Created by Oleg on 31.10.2024.
//

import Foundation
import SwiftyDropbox
import Combine
import ConnectionManager

// MARK: - DropBoxJSONService Class

public final class DropBoxJSONService: DropBoxFileJSONClient {
    
    private var client: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }
    
    // Map to store cached JSON entries; keys are file names (String)
    private var cachedJSONs: [String: CachedJSONEntry] = [:]
    
    // Connection monitoring
    private var connectionCancellable: AnyCancellable?
    private var pollingTimer: Timer?
    private var isPrepared = false
    
    // Publisher to notify updates
    private let updateSubject = PassthroughSubject<any DropBoxJSON, Never>()
    public var updatePublisher: AnyPublisher<any DropBoxJSON, Never> {
        updateSubject.eraseToAnyPublisher()
    }
    
    public init() {
        // Set up connection monitoring
        connectionCancellable = ConnectionManager.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                if isConnected {
                    self?.startPolling()
                } else {
                    self?.stopPolling()
                }
            }
    }
    
    deinit {
        connectionCancellable?.cancel()
        stopPolling()
    }
    
    /// Prepares content by downloading JSON files from Dropbox and storing them locally.
    /// - Parameter jsonType: An enum type conforming to `DropBoxJSON`.
    public func prepareContent<Item: DropBoxJSON>(jsonType: Item.Type) async throws {
        // List files in the folder
        let folderPath = Item.parentFolderPath
        let files = try await listFiles(inFolder: folderPath)
        
        // Map file names to items
        var itemsByFileName = [String: Item]()
        for item in Item.allCases {
            itemsByFileName[item.fileName] = item
        }
        
        // For each file, download it and store it
        for file in files {
            // Check if it's one of the JSON files we care about
            if let item = itemsByFileName[file.name] {
                // Download the file
                let localURL = try await downloadFile(at: file.pathLower ?? "")
                // Create a cached entry
                let cachedEntry = CachedJSONEntry(item: item, filePath: file.pathLower ?? "", fileURL: localURL, rev: file.rev)
                cachedJSONs[item.fileName] = cachedEntry
            }
        }
        
        self.isPrepared = true
    }
    
    /// Retrieves decoded JSON data from the cached JSON entries.
    /// - Parameters:
    ///   - json: An enum case conforming to `DropBoxJSON`.
    ///   - decodingType: The type to decode the JSON data into.
    /// - Returns: An object of type `T` decoded from the JSON data.
    public func getJSON<Item: DropBoxJSON, T: Decodable>(json: Item, decodingType: T.Type) throws -> T {
        // Get the cached entry
        guard let cachedEntry = cachedJSONs[json.fileName] else {
            throw NSError(domain: "DropBoxJSONService", code: 2, userInfo: [NSLocalizedDescriptionKey: "No cached data for \(json.fileName)"])
        }
        // Read data from the file URL
        let data = try Data(contentsOf: cachedEntry.fileURL)
        // Decode the data
        let decodedData = try JSONDecoder().decode(decodingType, from: data)
        return decodedData
    }
    
    /// Retrieves decoded JSON data from the cached JSON entries.
    /// - Parameters:
    ///   - json: An enum case conforming to `DropBoxJSON`.
    /// - Returns: JSON data.
    public func getData<Item: DropBoxJSON>(of json: Item) throws -> Data {
        // Get the cached entry
        guard let cachedEntry = cachedJSONs[json.fileName] else {
            throw NSError(domain: "DropBoxJSONService", code: 2, userInfo: [NSLocalizedDescriptionKey: "No cached data for \(json.fileName)"])
        }        
        return try Data(contentsOf: cachedEntry.fileURL)
    }
    /// Retrieves decoded JSON data from the cached JSON entries.
    /// - Parameters:
    ///   - json: An enum case conforming to `DropBoxJSON`.
    /// - Returns: Dictionary representation of JSON.
    public func getDictionary<Item: DropBoxJSON>(of json: Item) throws -> [String: Any] {
        // Get the cached entry
        guard let cachedEntry = cachedJSONs[json.fileName] else {
            throw NSError(domain: "DropBoxJSONService", code: 2, userInfo: [NSLocalizedDescriptionKey: "No cached data for \(json.fileName)"])
        }
        let data = try Data(contentsOf: cachedEntry.fileURL)
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let dict = decoded as? [String : Any] else {
            throw NSError(
                domain: "DropBoxJSONService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Can't trnaslate data: \(data) of \(json.fileName) in dictionary"])
        }
        return dict
    }
    
    // MARK: - Private Methods
    
    /// Lists files in a Dropbox folder.
    /// - Parameter folderPath: The path of the folder in Dropbox.
    /// - Returns: An array of `Files.FileMetadata`.
    private func listFiles(inFolder folderPath: String) async throws -> [Files.FileMetadata] {
        guard let client = client else {
            throw NSError(domain: "DropBoxJSONService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Client not authorized"])
        }
        
        var result: [Files.FileMetadata] = []
        var cursor: String?
        
        repeat {
            let response: Files.ListFolderResult
            if let cursor = cursor {
                response = try await client.files.listFolderContinue(cursor: cursor).response()
            } else {
                response = try await client.files.listFolder(path: folderPath).response()
            }
            
            let files = response.entries.compactMap { $0 as? Files.FileMetadata }
            result.append(contentsOf: files)
            cursor = response.hasMore ? response.cursor : nil
        } while cursor != nil
        
        return result
    }
    
    /// Downloads a file from Dropbox.
    /// - Parameter path: The Dropbox path of the file.
    /// - Returns: The local URL where the file was saved.
    private func downloadFile(at path: String) async throws -> URL {
        guard let client = client else {
            throw NSError(domain: "DropBoxJSONService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Client not authorized"])
        }
        
        let response = try await client.files.download(path: path).response()
        let data = response.1
        // Save data to a local file
        let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: tempFileURL)
        return tempFileURL
    }
    
    /// Starts polling for updates every 10 seconds.
    private func startPolling() {
        // Ensure we don't start multiple timers
        guard pollingTimer == nil, isPrepared else { return }
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.pollForUpdates()
        }
    }
    
    /// Stops polling for updates.
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    /// Polls for updates to the cached JSON files.
    private func pollForUpdates() {
        // For each cached JSON, check if the rev has changed
        for (fileName, cachedEntry) in cachedJSONs {
            Task {
                do {
                    if let currentRev = try await getCurrentRev(for: cachedEntry.filePath), currentRev != cachedEntry.rev {
                        // Rev has changed, download new JSON
                        let newFileURL = try await downloadFile(at: cachedEntry.filePath)
                        // Update the cachedEntry
                        cachedEntry.fileURL = newFileURL
                        cachedEntry.rev = currentRev
                        print("Updated JSON file: \(fileName)")
                        // Publish update
                        self.updateSubject.send(cachedEntry.item)
                    }
                } catch {
                    print("Error polling for updates: \(error)")
                }
            }
        }
    }
    
    /// Fetches the current rev of a file from Dropbox.
    /// - Parameter filePath: The Dropbox file path.
    /// - Returns: The current rev string or `nil` if failed.
    private func getCurrentRev(for filePath: String) async throws -> String? {
        guard let client = client else {
            throw NSError(domain: "DropBoxJSONService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Client not authorized"])
        }
        
        let metadata = try await client.files.getMetadata(path: filePath).response()
        if let fileMetadata = metadata as? Files.FileMetadata {
            return fileMetadata.rev
        }
        return nil
    }
    
    /// Cached JSON entry containing the file path, local file URL, and rev.
    fileprivate class CachedJSONEntry {
        let item: any DropBoxJSON // The enum case
        let filePath: String // Dropbox file path
        var fileURL: URL // Local file URL
        var rev: String // The rev from Dropbox
        init(item: any DropBoxJSON, filePath: String, fileURL: URL, rev: String) {
            self.item = item
            self.filePath = filePath
            self.fileURL = fileURL
            self.rev = rev
        }
    }
}
// MARK: - Usage Examples

/*
 Example of a JSON enum to be operated via this library:
 
 enum JSONFile: DropBoxJSON {
     case genres
     
     // Specify the parent folder path in Dropbox
     static var parentFolderPath: String {
         return "/JSONs"
     }
     
     // Provide the file name for each case
     var fileName: String {
         switch self {
         case .genres:
             return "genres.json"
         }
     }
 }
 
 Example of usage via The Composable Architecture (TCA):
 
 // Preparing JSONs
 return .run { send in
     do {
         // Prepare the content by downloading JSON files
         try await jsonClient.prepareContent(jsonType: JSONFile.self)
     } catch {
         // Handle any errors during preparation
         print(error.localizedDescription)
     }
 }
 
 // Handling JSONs on view appearance
 func handleOnAppear(_ state: inout State) -> Effect<Action> {
     do {
         // Retrieve and decode the 'genres' JSON data
         let genres = try jsonClient.getJSON(
             json: JSONFile.genres,
             decodingType: [Genre].self
         )
         // Update state with the fetched genres
         state.genres = genres
     } catch {
         // Handle any errors during data retrieval
         print("Error retrieving genres: \(error.localizedDescription)")
     }
     // Subscribe to updates from the jsonClient's updatePublisher
     return .publisher {
         jsonClient.updatePublisher
             .compactMap { update -> Action? in
                 guard let jsonFile = update as? JSONFile else {
                     return nil
                 }
                 return .didReceiveNewJSON(jsonFile)
             }
             .eraseToAnyPublisher()
     }
 }
 
 // Reloading content when JSON files are updated
 func reloadContent(updatedJSON: JSONFile, _ state: inout State) -> Effect<Action> {
     switch updatedJSON {
     case .genres:
         do {
             // Fetch the updated 'genres' JSON data
             let genres = try jsonClient.getJSON(
                 json: JSONFile.genres,
                 decodingType: [Genre].self
             )
             // Update state with the new data
             state.genres = genres
         } catch {
             // Handle any errors during the reload
             print("Error reloading genres: \(error.localizedDescription)")
         }
     }
     
     return .none
 }
*/
