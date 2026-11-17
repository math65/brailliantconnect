import Foundation

/// Where an item lives on the display: its storage, and its path there.
public struct ItemLocation: Hashable, Codable, Sendable {
    public let storageID: UInt32
    public let path: String

    public init(storageID: UInt32, path: String) {
        self.storageID = storageID
        self.path = path
    }

    /// The folder holding this item; "/" for the top level of its storage.
    public var parent: ItemLocation {
        ItemLocation(storageID: storageID, path: RemotePath.split(path).parent)
    }

    /// True for this item and for everything below it, on the same storage.
    ///
    /// Compared on whole segments, and on the paths as the display spelled
    /// them: normalising would fold a name such as ".." into its parent.
    public func contains(_ other: ItemLocation) -> Bool {
        guard other.storageID == storageID else { return false }
        if path == "/" || other.path == path { return true }
        return other.path.hasPrefix(path + "/")
    }
}

/// Identifiers that outlive an MTP session.
///
/// The display's object handles do not: each session numbers objects from a
/// counter, in the order their folders are listed, so the same file is 16 in
/// one session and 9 in the next, one file added shifts every number after it,
/// and two storages hand out the same ones (measured 17 Nov 2026 on a BI 40X).
/// The system keeps the identifiers it was given for as long as the location
/// is published, across every reconnection — so a handle used as one ends up
/// designating another object: a folder answered as a file, a deletion applied
/// to the wrong item.
///
/// So the extension numbers items itself, and ties each number to a location.
/// A number never designates anything but the path it was given for, or the
/// path that item was renamed or moved to through this extension. An item
/// renamed on the display itself gets a new number, which is right: nothing
/// told us it was the same one.
///
/// Pure and `Codable`, so it can be tested without a display and kept in the
/// extension's container between processes.
public struct ItemIdentities: Codable, Equatable, Sendable {

    private var next: UInt64 = 1
    private var locations: [UInt64: ItemLocation] = [:]
    private var numbers: [ItemLocation: UInt64] = [:]

    public init() {}

    public var count: Int { locations.count }

    /// The number of the item at `location`, given one if it has none yet.
    public mutating func number(for location: ItemLocation) -> UInt64 {
        if let known = numbers[location] { return known }
        let assigned = next
        next += 1
        locations[assigned] = location
        numbers[location] = assigned
        return assigned
    }

    /// The number of the item at `location`, without assigning one.
    public func existingNumber(for location: ItemLocation) -> UInt64? {
        numbers[location]
    }

    /// Where the item with this number is, or nil for a number never given or
    /// since forgotten.
    public func location(of number: UInt64) -> ItemLocation? {
        locations[number]
    }

    /// An item, and everything below it, moved or was renamed: each keeps its
    /// number at its new location.
    ///
    /// Whatever held a number at the destination is forgotten first. It was
    /// not there any more — the display just accepted something at that path
    /// — and keeping it would leave two numbers for one location.
    public mutating func move(from origin: ItemLocation, to destination: ItemLocation) {
        guard origin != destination else { return }
        let moving = locations.filter { origin.contains($0.value) }
        for (number, held) in locations
        where destination.contains(held) && !origin.contains(held) {
            locations.removeValue(forKey: number)
            numbers.removeValue(forKey: held)
        }
        for (number, location) in moving {
            numbers.removeValue(forKey: location)
            let rest = String(location.path.dropFirst(origin.path.count))
            let moved = ItemLocation(
                storageID: destination.storageID,
                path: origin.path == "/"
                    ? RemotePath.join(destination.path, rest) : destination.path + rest)
            locations[number] = moved
            numbers[moved] = number
        }
    }

    /// An item is gone: its number, and every number below it, are retired.
    ///
    /// - Returns: the numbers retired, for whatever was cached under them.
    @discardableResult
    public mutating func forget(_ location: ItemLocation) -> [UInt64] {
        var retired: [UInt64] = []
        for (number, held) in locations where location.contains(held) {
            locations.removeValue(forKey: number)
            numbers.removeValue(forKey: held)
            retired.append(number)
        }
        return retired
    }

    /// A folder was just listed: what it no longer holds is gone, along with
    /// everything that was below it.
    ///
    /// Without this the table would only grow, by every file ever deleted from
    /// the display itself.
    ///
    /// - Returns: the numbers retired.
    @discardableResult
    public mutating func keepOnly(_ names: Set<String>, in folder: ItemLocation) -> [UInt64] {
        let gone = locations.values.filter {
            $0.storageID == folder.storageID && $0.path != "/"
                && $0.parent == folder
                && !names.contains(RemotePath.split($0.path).name)
        }
        return gone.flatMap { forget($0) }
    }

    // MARK: - Codable

    /// Kept as a list: a dictionary keyed by a structure does not encode as a
    /// JSON object, and the reverse map is derived anyway.
    private struct Record: Codable {
        let number: UInt64
        let storage: UInt32
        let path: String
    }

    private enum CodingKeys: String, CodingKey { case next, items }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        next = try container.decode(UInt64.self, forKey: .next)
        for record in try container.decode([Record].self, forKey: .items) {
            let location = ItemLocation(storageID: record.storage, path: record.path)
            // A corrupt file must not give one location two numbers.
            guard numbers[location] == nil, record.number < next else { continue }
            locations[record.number] = location
            numbers[location] = record.number
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(next, forKey: .next)
        let records = locations.sorted { $0.key < $1.key }.map {
            Record(number: $0.key, storage: $0.value.storageID, path: $0.value.path)
        }
        try container.encode(records, forKey: .items)
    }
}
