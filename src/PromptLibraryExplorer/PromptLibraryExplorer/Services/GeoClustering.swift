import Foundation

// MARK: - Map clustering (deterministic grid clustering per zoom level)
//
// Points are projected to Web Mercator (0…1 on both axes, like map tiles) and
// dropped into square cells whose size halves with every zoom level. Each
// non-empty cell is one cluster. The same points and zoom always give the same
// clusters in the same order, so annotations don't jump while panning.

/// One geotagged file for clustering.
struct GeoPoint: Sendable, Hashable, Identifiable {
    let id: String
    let coordinate: GeoCoordinate
    let date: Date
}

struct GeoCluster: Sendable, Hashable, Identifiable {
    /// "zoom/x/y": stable for a zoom level.
    let id: String
    /// Mean position of the members.
    let center: GeoCoordinate
    /// Member ids, newest first (ties by id).
    let memberIDs: [String]
    /// Bounding box of the members (for zooming to the cluster).
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var count: Int { memberIDs.count }
    /// The newest member (its thumbnail is the cluster's badge).
    var newestID: String { memberIDs[0] }
}

enum GeoClustering {
    /// Cells per 256-pt map tile edge: 4 → cells of about 64 pt on screen.
    static let defaultCellsPerTile = 4
    static let zoomRange = 0...21

    /// Web Mercator, 0…1 (x east, y south). Latitude is clamped to ±85.05113°.
    static func mercator(_ coordinate: GeoCoordinate) -> (x: Double, y: Double) {
        let latitude = min(max(coordinate.latitude, -85.05112878), 85.05112878)
        let x = (coordinate.longitude + 180) / 360
        let radians = latitude * .pi / 180
        let y = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// The zoom level at which a view `viewWidth` points wide shows `longitudeDelta`
    /// degrees (256-pt tiles, as MapKit uses).
    static func zoomLevel(longitudeDelta: Double, viewWidth: Double) -> Int {
        guard longitudeDelta > 0, viewWidth > 0 else { return zoomRange.lowerBound }
        let zoom = log2(360 * viewWidth / (256 * longitudeDelta))
        guard zoom.isFinite else { return zoomRange.lowerBound }
        return min(max(Int(zoom.rounded(.down)), zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// Grid cell index of a point at `zoom`.
    static func cell(for coordinate: GeoCoordinate, zoom: Int, cellsPerTile: Int = defaultCellsPerTile) -> (x: Int, y: Int) {
        let cellsPerAxis = Double(1 << min(max(zoom, 0), 24)) * Double(max(1, cellsPerTile))
        let point = mercator(coordinate)
        let x = min(Int(point.x * cellsPerAxis), Int(cellsPerAxis) - 1)
        let y = min(Int(point.y * cellsPerAxis), Int(cellsPerAxis) - 1)
        return (x, y)
    }

    /// Clusters `points` for `zoom`. Order: largest cluster first, then by cell
    /// (row, column), so the result is fully deterministic.
    static func cluster(_ points: [GeoPoint], zoom: Int, cellsPerTile: Int = defaultCellsPerTile) -> [GeoCluster] {
        struct Accumulator {
            var members: [GeoPoint] = []
            var latitudeSum = 0.0
            var longitudeSum = 0.0
            var minLatitude = Double.infinity
            var maxLatitude = -Double.infinity
            var minLongitude = Double.infinity
            var maxLongitude = -Double.infinity
        }
        struct CellKey: Hashable { let x: Int; let y: Int }

        var cells: [CellKey: Accumulator] = [:]
        for point in points where point.coordinate.isPlausible {
            let index = cell(for: point.coordinate, zoom: zoom, cellsPerTile: cellsPerTile)
            let key = CellKey(x: index.x, y: index.y)
            var accumulator = cells[key] ?? Accumulator()
            accumulator.members.append(point)
            accumulator.latitudeSum += point.coordinate.latitude
            accumulator.longitudeSum += point.coordinate.longitude
            accumulator.minLatitude = min(accumulator.minLatitude, point.coordinate.latitude)
            accumulator.maxLatitude = max(accumulator.maxLatitude, point.coordinate.latitude)
            accumulator.minLongitude = min(accumulator.minLongitude, point.coordinate.longitude)
            accumulator.maxLongitude = max(accumulator.maxLongitude, point.coordinate.longitude)
            cells[key] = accumulator
        }

        let clusters = cells.map { key, accumulator -> (CellKey, GeoCluster) in
            let count = Double(accumulator.members.count)
            let members = accumulator.members.sorted { lhs, rhs in
                lhs.date != rhs.date ? lhs.date > rhs.date : lhs.id < rhs.id
            }
            return (key, GeoCluster(
                id: "\(zoom)/\(key.x)/\(key.y)",
                center: GeoCoordinate(latitude: accumulator.latitudeSum / count, longitude: accumulator.longitudeSum / count),
                memberIDs: members.map(\.id),
                minLatitude: accumulator.minLatitude,
                maxLatitude: accumulator.maxLatitude,
                minLongitude: accumulator.minLongitude,
                maxLongitude: accumulator.maxLongitude
            ))
        }
        return clusters.sorted { lhs, rhs in
            if lhs.1.count != rhs.1.count { return lhs.1.count > rhs.1.count }
            if lhs.0.y != rhs.0.y { return lhs.0.y < rhs.0.y }
            return lhs.0.x < rhs.0.x
        }.map(\.1)
    }

    /// Whether `coordinate` lies in a region (center ± span/2, with `margin` as a
    /// fraction of the span on each side). Handles regions across the antimeridian.
    static func region(
        centerLatitude: Double, centerLongitude: Double,
        latitudeDelta: Double, longitudeDelta: Double,
        margin: Double = 0.25,
        contains coordinate: GeoCoordinate
    ) -> Bool {
        let halfLat = latitudeDelta * (0.5 + margin)
        let halfLon = longitudeDelta * (0.5 + margin)
        guard abs(coordinate.latitude - centerLatitude) <= halfLat else { return false }
        if halfLon >= 180 { return true }
        var delta = abs(coordinate.longitude - centerLongitude).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta <= halfLon
    }
}
