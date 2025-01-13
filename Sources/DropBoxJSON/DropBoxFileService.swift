import Foundation
import SwiftyDropbox
import Combine
import ConnectionManager



// MARK: - DropBoxJSONService
public final class DropBoxJSONService: DropBoxFileJSONClient {
    
    // MARK: - Internal types
    
    fileprivate class CachedJSONEntry {
        let item: any DropBoxJSON   // The enum case (e.g., JSONFile.genres)
        var filePath: String        // Dropbox file path (e.g., "/JSONs/genres.json")
        var fileURL: URL            // Local file URL in the Documents directory
        var rev: String             // Dropbox revision ID
        
        init(item: any DropBoxJSON, filePath: String, fileURL: URL, rev: String) {
            self.item = item
            self.filePath = filePath
            self.fileURL = fileURL
            self.rev = rev
        }
    }
    
    // MARK: - Properties
    
    private var client: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }
    
    private let fileManager = FileManager.default
    
    /// In-memory cache: fileName -> cached entry
    private var cachedJSONs: [String: CachedJSONEntry] = [:]
    
    /// Indicates whether we have attempted to load from Dropbox at least once.
    private var isPrepared = false
    
    // MARK: Connection / Polling
    private var connectionCancellable: AnyCancellable?
    private var pollingTimer: Timer?
    
    // Publisher that emits JSON enum cases whenever a file is updated.
    private let updateSubject = PassthroughSubject<any DropBoxJSON, Never>()
    public var updatePublisher: AnyPublisher<any DropBoxJSON, Never> {
        updateSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Init / Deinit
    
    public init() {
        // Observe connectivity & manage polling
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
    
    // MARK: - Public Methods
    
    /// Loads local files from Documents directory for all cases in `jsonType`.
    /// If files exist, creates or updates the `cachedJSONs` so `get...` methods can use them immediately.
    public func loadLocalFiles<Item: DropBoxJSON>(for jsonType: Item.Type) -> Bool {
        for item in Item.allCases {
            let localURL = documentsURL(for: item.fileName)
            if fileManager.fileExists(atPath: localURL.path) {
                // If we already have a file locally, create/update the cache
                let cachedEntry = CachedJSONEntry(item: item,
                                                  filePath: "",  // unknown until we poll Dropbox
                                                  fileURL: localURL,
                                                  rev: "")       // unknown until we poll Dropbox
                cachedJSONs[item.fileName] = cachedEntry
            } else {
                return false
            }
        }
        return true
    }
    
    
    /// 1) Load local files (if any) into the cache so `get...` calls don’t block.
    /// 2) Attempt to download new files from Dropbox (async). If successful, update cache.
    /// 3) After at least one successful Dropbox download, `isPrepared` becomes `true`.
    public func prepareContent<Item: DropBoxJSON>(jsonType: Item.Type) async throws {
       
        // 2. Attempt to load from Dropbox (if authorized). If it fails, we keep using local data.
        guard let client = client else {
            // No authorized client => keep local data
            print("Dropbox client not authorized. Using local cache if available.")
            return
        }
        
        do {
            let folderPath = Item.parentFolderPath
            let files = try await listFiles(inFolder: folderPath, using: client)
            
            // Build a lookup so we know which Dropbox filename corresponds to which enum case
            var itemsByFileName = [String: Item]()
            for item in Item.allCases {
                itemsByFileName[item.fileName] = item
            }
            
            // For each Dropbox file, if it matches an enum case, download & update cache
            for fileMetadata in files {
                guard let dropboxFileName = fileMetadata.name as String?,
                      let item = itemsByFileName[dropboxFileName] else {
                    continue
                }
                let pathLower = fileMetadata.pathLower ?? ""
                let rev = fileMetadata.rev
                let localURL = try await downloadFile(at: pathLower)
                
                // Create or update cached entry
                let entry = CachedJSONEntry(item: item,
                                            filePath: pathLower,
                                            fileURL: localURL,
                                            rev: rev)
                cachedJSONs[dropboxFileName] = entry
            }
            
            // 3. Mark as prepared on successful Dropbox fetch
            self.isPrepared = true
            startPolling()  // might as well ensure polling is active
        } catch {
            // If any network or Dropbox error occurs, do *not* throw away local data
            print("Failed to prepare content from Dropbox: \(error)")
        }
    }
    
    /// Returns a decoded object from the cached JSON.
    public func getJSON<Item: DropBoxJSON, T: Decodable>(json: Item, decodingType: T.Type) throws -> T {
        guard let entry = cachedJSONs[json.fileName] else {
            throw NSError(domain: "DropBoxJSONService",
                          code: 1001,
                          userInfo: [NSLocalizedDescriptionKey: "No cached data for \(json.fileName)"])
        }
        
        let data = try Data(contentsOf: entry.fileURL)
        return try JSONDecoder().decode(decodingType, from: data)
    }
    
    /// Returns raw `Data` from the cached JSON.
    public func getData<Item: DropBoxJSON>(of json: Item) throws -> Data {
        guard let entry = cachedJSONs[json.fileName] else {
            throw NSError(domain: "DropBoxJSONService",
                          code: 1002,
                          userInfo: [NSLocalizedDescriptionKey: "No cached data for \(json.fileName)"])
        }
        return try Data(contentsOf: entry.fileURL)
    }
    
    /// Returns a `[String: Any]` from the cached JSON.
    public func getDictionary<Item: DropBoxJSON>(of json: Item) throws -> [String: Any] {
        let data = try getData(of: json)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        
        guard let dictionary = jsonObject as? [String: Any] else {
            throw NSError(domain: "DropBoxJSONService",
                          code: 1003,
                          userInfo: [NSLocalizedDescriptionKey: "Data cannot be cast to a dictionary"])
        }
        return dictionary
    }
    
    // MARK: - Private Helpers
    
    
    /// Gets a `URL` in the user’s Documents directory for a given filename.
    private func documentsURL(for fileName: String) -> URL {
        guard let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("No documents directory found.")
        }
        return docsDir.appendingPathComponent(fileName)
    }
    
    /// Lists the files (as `Files.FileMetadata`) in the given Dropbox folder.
    private func listFiles(inFolder folderPath: String, using client: DropboxClient) async throws -> [Files.FileMetadata] {
        var allFiles: [Files.FileMetadata] = []
        var cursor: String?
        
        repeat {
            let response: Files.ListFolderResult
            if let existingCursor = cursor {
                response = try await client.files.listFolderContinue(cursor: existingCursor).response()
            } else {
                response = try await client.files.listFolder(path: folderPath).response()
            }
            
            let files = response.entries.compactMap { $0 as? Files.FileMetadata }
            allFiles.append(contentsOf: files)
            cursor = response.hasMore ? response.cursor : nil
        } while cursor != nil
        
        return allFiles
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
    
    // MARK: - Polling Logic
    
    /// Start polling every 10 seconds, if we have prepared content at least once.
    private func startPolling() {
        guard pollingTimer == nil, isPrepared else { return }
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 10.0,
                                            repeats: true) { [weak self] _ in
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
        
        for (_, cachedEntry) in cachedJSONs {
            Task {
                do {
                    if let currentRev = try await getCurrentRev(for: cachedEntry.filePath), currentRev != cachedEntry.rev {
                        // Rev has changed, download new JSON
                        let newFileURL = try await downloadFile(at: cachedEntry.filePath)
                        // Update the cachedEntry
                        cachedEntry.fileURL = newFileURL
                        cachedEntry.rev = currentRev
                        
                        print("Updated JSON file: \(cachedEntry.item.fileName)")
                        updateSubject.send(cachedEntry.item)
                    }
                } catch {
                    print("Error polling Dropbox for updates: \(error)")
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
}
