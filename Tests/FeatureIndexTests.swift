import Foundation

@main struct FeatureIndexTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        let all = CommandCatalog.all
        let visible = FeatureIndex.entries
        let expected = all.filter { !$0.path.isEmpty && $0.path.first != "help" && $0.path.first != "hook" && $0.path != ["statusline"] }
        let identities = Set(visible.map(FeatureIndex.id))
        check(all.count == 67, "underlying command catalog is preserved")
        check(visible.count == 61, "all existing 61 product operations remain available")
        check(identities == Set(expected.map(FeatureIndex.id)), "new navigation has exactly the original product operations")
        check(identities.count == visible.count, "different operations sharing a command path retain distinct identities")
        check(FeatureIndex.groups.count == 7, "overview stays limited to seven groups")
        check(Set(FeatureIndex.groups.map { $0.id }).count == 7, "group identities are unique")
        let grouped = FeatureIndex.groups.flatMap { FeatureIndex.entries(in: $0.id) }
        check(grouped.count == visible.count && Set(grouped.map(FeatureIndex.id)) == identities, "every operation is reachable in exactly one group")
        check(FeatureIndex.groups.allSatisfy { !FeatureIndex.entries(in: $0.id).isEmpty }, "no empty navigation destinations")
        check(FeatureIndex.entries(in: "missing").isEmpty, "unknown groups cannot accidentally expose hidden operations")
        check(FeatureIndex.common.count == 4, "only four common actions appear on the overview")
        check(Set(FeatureIndex.common.map(FeatureIndex.id)).isSubset(of: identities), "every common shortcut points to a real visible operation")
        check(FeatureIndex.common.allSatisfy { !["remove", "logout", "update"].contains($0.path.first ?? "") }, "overview does not promote destructive actions")
        check(FeatureIndex.entries(in: "accounts").contains { $0.path == ["import"] }, "account import is discoverable with account management")
        check(FeatureIndex.entries(in: "sharing").contains { $0.path == ["share"] }, "shared source inspection is discoverable with shared groups")
        check(FeatureIndex.entries(in: "maintenance").contains { $0.path == ["statusline", "install"] }, "status display installation remains available although internal status input is hidden")
        check(FeatureIndex.search(" \n ").count == 61, "empty search spans all available operations")
        check(Set(FeatureIndex.search("mcp").map(FeatureIndex.id)) == Set(FeatureIndex.search("MCP").map(FeatureIndex.id)), "search ignores case")
        check(FeatureIndex.search("账号 额度").contains { $0.path == ["usage"] }, "multiword search finds an operation across its title and description")
        check(FeatureIndex.search("not-a-real-feature-8925").isEmpty, "unmatched searches return a true empty state")
        let localizedSearch = FeatureIndex.search("共同工作") { $0.path.first == "group" ? "共同工作" : "其他功能" }
        check(!localizedSearch.isEmpty && localizedSearch.allSatisfy { $0.path.first == "group" }, "search uses supplied visible wording instead of depending on command syntax")
        check(FeatureIndex.search("迁移").contains { FeatureIndex.groupID(for: $0) == "projects" }, "global search reaches operations outside the account group")
        print("PASS: \(checks) feature navigation and coverage checks (61 operations / 7 groups)")
    }
}
