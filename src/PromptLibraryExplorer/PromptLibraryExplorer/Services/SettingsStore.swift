import Foundation
import SwiftUI

/// Persisted app settings via @AppStorage.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("lastOpenedFolder") var lastOpenedFolder: String = ""
    @AppStorage("thumbnailSize") var thumbnailSize: Double = 5
    @AppStorage("sortField") var sortField: String = "type"
    @AppStorage("sortDirection") var sortDirection: String = "asc"
    @AppStorage("hideOther") var hideOther: Bool = true
    @AppStorage("hideJpg") var hideJpg: Bool = false
    @AppStorage("hidePng") var hidePng: Bool = false
    @AppStorage("showStatusBar") var showStatusBar: Bool = true
    @AppStorage("appearanceMode") var appearanceMode: String = AppAppearanceMode.dark.rawValue

    @AppStorage("filterMinRating") var filterMinRating: Int = 0

    private static let customOrderKey = "promptlibrary.customSortOrder"
    private static let ratingsKey = "promptlibrary.ratings"

    func loadCustomOrders() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: Self.customOrderKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    func saveCustomOrders(_ orders: [String: [String]]) {
        if let data = try? JSONEncoder().encode(orders) {
            UserDefaults.standard.set(data, forKey: Self.customOrderKey)
        }
    }

    func loadRatings() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: Self.ratingsKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }

    func saveRatings(_ ratings: [String: Int]) {
        if let data = try? JSONEncoder().encode(ratings) {
            UserDefaults.standard.set(data, forKey: Self.ratingsKey)
        }
    }
}
