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
            .removeDuplicates()
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
    
    /// Loads local files from the Documents directory for all cases in `jsonType`.
    /// If any file is missing, returns `false`. Otherwise `true`.
    public func loadLocalFiles<Item: DropBoxJSON>(for jsonType: Item.Type) -> Bool {
        for item in Item.allCases {
            let localURL = documentsURL(for: item.fileName)
            
            if fileManager.fileExists(atPath: localURL.path) {
                // Create/update the cache
                let cachedEntry = CachedJSONEntry(item: item,
                                                  filePath: "",  // we’ll fill this later from Dropbox
                                                  fileURL: localURL,
                                                  rev: "")        // we’ll fill this once we poll
                cachedJSONs[item.fileName] = cachedEntry
            } else {
                // As soon as we find one missing file, return false
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
                let dropboxFileName = fileMetadata.name
                guard let item = itemsByFileName[dropboxFileName] else {
                    continue
                }
                
                let pathLower = fileMetadata.pathLower ?? ""
                let rev = fileMetadata.rev
                
                // MARK: CHANGES – pass the actual local filename so we store in Documents (NOT temp!)
                let localURL = try await downloadFile(at: pathLower, localFileName: dropboxFileName)
                
                // Create or update cached entry
                let entry = CachedJSONEntry(item: item,
                                            filePath: pathLower,
                                            fileURL: localURL,
                                            rev: rev)
                cachedJSONs[dropboxFileName] = entry
            }
            
            // 3. Mark as prepared on successful Dropbox fetch
            isPrepared = true
            startPolling()
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
        
        guard let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("DropBoxJSON") else {
            fatalError("No documents directory found.")
        }
        try? fileManager.createDirectory(at: docsDir, withIntermediateDirectories: true)
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
    
    // MARK: CHANGES – This now writes to Documents, using the same filename.
    /// Downloads a file from Dropbox and saves it in Documents directory with a given filename.
    private func downloadFile(at path: String, localFileName: String) async throws -> URL {
        guard let client = client else {
            throw NSError(domain: "DropBoxJSONService",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Client not authorized"])
        }
        
        let response = try await client.files.download(path: path).response()
        let data = response.1
        
        // Create a local URL under Documents with the same fileName
        let localURL = documentsURL(for: localFileName)
        try data.write(to: localURL, options: .atomic)
        
        return localURL
    }
    
    // MARK: - Polling Logic
    
    /// Start polling every 10 seconds, if we have prepared content at least once.
    private func startPolling() {
        guard pollingTimer == nil, isPrepared else { return }
        
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.pollForUpdates()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
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
                    if let currentRev = try await getCurrentRev(for: cachedEntry.filePath),
                       currentRev != cachedEntry.rev {
                        
                        // Rev has changed, download new JSON
                        let newFileURL = try await downloadFile(at: cachedEntry.filePath,
                                                                localFileName: cachedEntry.item.fileName)
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
            throw NSError(domain: "DropBoxJSONService",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Client not authorized"])
        }
        
        let metadata = try await client.files.getMetadata(path: filePath).response()
        if let fileMetadata = metadata as? Files.FileMetadata {
            return fileMetadata.rev
        }
        return nil
    }
}
