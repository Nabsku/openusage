import XCTest
@testable import OpenUsage

@MainActor
final class LayoutAccountTests: XCTestCase {
    private func accountLayoutRegistry(_ providers: [Provider], suffixes: [String]) -> WidgetRegistry {
        WidgetRegistry(providers: providers, descriptors: providers.flatMap { provider in
            suffixes.map { suffix in
                let id = "\(provider.id).\(suffix)"
                return WidgetDescriptor(
                    id: id, providerID: provider.id, metricLabel: id,
                    sample: WidgetData(title: id, icon: provider.icon, kind: .percent, used: 0, limit: 100)
                )
            }
        })
    }

    func testProviderReorderPreservesAnAbsentAccountCardSlot() {
        let defaults = makeDefaults("ReorderAbsentAccountCard")
        let storageKey = "layout"
        let hidden = "claude@hidden"
        let persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
        persistence.saveProviderOrder(["claude", hidden, "cursor"])
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: storageKey)

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertEqual(Array(store.providerOrder.prefix(3)), ["cursor", hidden, "claude"])
        XCTAssertEqual(persistence.loadProviderOrder()?.contains(hidden), true)
    }

    func testTranslatedDefaultsSeedAnAccountCardTheFirstTimeItAppears() {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let work = Provider(id: "claude@work", displayName: "Claude — Work", icon: .providerMark("claude"))
        let suffixes = ["session", "weekly", "fable", "sonnet"]
        let registry = accountLayoutRegistry([claude, work], suffixes: suffixes)
        let defaults = makeDefaults("AccountCardSeeding")
        let familyDefaults = suffixes.dropLast().map { "claude.\($0)" }
        saveStored(familyDefaults.map { PlacedWidget(descriptorID: $0) }, forKey: "layout", in: defaults)
        defaults.set(suffixes.map { "claude.\($0)" }, forKey: "layout.seededDefaults")

        let store = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout", defaultMetricIDs: familyDefaults,
            defaultExpandedMetricIDs: ["claude.sonnet"]
        )

        for suffix in suffixes.dropLast() {
            XCTAssertTrue(store.isMetricEnabled("claude@work.\(suffix)"))
        }
        XCTAssertFalse(store.isPinned("claude@work.fable"))
        XCTAssertFalse(store.expandedMetricIDs.contains("claude@work.fable"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude@work").map(\.id), suffixes.map { "claude@work.\($0)" })
        XCTAssertFalse(store.isMetricEnabled("claude.sonnet"))
        XCTAssertTrue(store.defaultExpandedOnEnableIDs.contains("claude@work.sonnet"))
    }

    func testAccountCustomizationSurvivesAbsenceAnUnrelatedEditAndGraphRebuild() {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let work = Provider(id: "claude@ab12cd34", displayName: "Claude — Work", icon: .providerMark("claude"))
        func registry(includingWork: Bool) -> WidgetRegistry {
            self.accountLayoutRegistry(includingWork ? [claude, work] : [claude], suffixes: ["session", "weekly"])
        }
        let defaults = makeDefaults("AccountGraphRebuild")
        func load(includingWork: Bool) -> LayoutStore {
            LayoutStore(
                registry: registry(includingWork: includingWork), defaults: defaults, storageKey: "layout",
                defaultMetricIDs: ["claude.session", "claude.weekly"], defaultPinnedMetricIDs: [],
                defaultExpandedMetricIDs: ["claude.weekly"]
            )
        }

        let first = load(includingWork: true)
        first.setMetricEnabled("claude@ab12cd34.weekly", false)
        first.setPinned(true, for: "claude@ab12cd34.session")
        XCTAssertTrue(first.setProviderExpanded(true, for: "claude@ab12cd34"))
        XCTAssertTrue(first.reorderProvider(dragged: "claude@ab12cd34", target: "claude"))

        let temporarilyAbsent = load(includingWork: false)
        XCTAssertFalse(temporarilyAbsent.isMetricEnabled("claude@ab12cd34.session"))
        XCTAssertTrue(temporarilyAbsent.pinnedMetricIDs.contains("claude@ab12cd34.session"))
        XCTAssertTrue(temporarilyAbsent.expandedProviderIDs.contains("claude@ab12cd34"))
        XCTAssertEqual(temporarilyAbsent.providerOrder.first, "claude@ab12cd34")

        temporarilyAbsent.setMetricEnabled("claude.weekly", false)
        temporarilyAbsent.setPinned(true, for: "claude.session")

        let restored = load(includingWork: true)
        XCTAssertTrue(restored.isMetricEnabled("claude@ab12cd34.session"))
        XCTAssertFalse(restored.isMetricEnabled("claude@ab12cd34.weekly"))
        XCTAssertTrue(restored.isPinned("claude@ab12cd34.session"))
        XCTAssertTrue(restored.isProviderExpanded("claude@ab12cd34"))
        XCTAssertEqual(restored.orderedProviderIDs().first, "claude@ab12cd34")
        XCTAssertFalse(restored.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(restored.isPinned("claude.session"))
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.LayoutAccount.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}
