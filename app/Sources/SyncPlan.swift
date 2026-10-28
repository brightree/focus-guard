import Foundation

// 미리 알림 동기화에서 "무엇을 어느 쪽에 반영할지"만 정한다 (미리 알림 API 와 분리 — 테스트하기 쉽게).
//
// 규칙
// - 지난 동기화 때 양쪽이 같았던 상태(last)와 비교해서, 바뀐 쪽을 반대쪽에 반영한다.
// - 양쪽이 같이 바뀌었으면 미리 알림(폰) 쪽을 따른다.
// - 앱에서 지운 항목은 미리 알림에서도, 미리 알림에서 지운 항목은 앱에서도 지운다.
// - 폰에서 새로 만든 항목은 앱에 추가한다.
// - 할 일은 오늘 · 앞으로의 날짜만 둔다. 지난 날짜가 된 미리 알림은 지운다 (앱의 기록은 그대로).
// - 미리 알림 목록이 통째로 비어 있으면 (목록을 지웠다가 다시 만든 경우 등) 앱 쪽을 지우지 않고 다시 채운다.

/// 양쪽을 비교하는 단위: 제목(종류 표시 포함) · 완료 · 날짜(할 일만)
struct SyncItem: Codable, Equatable {
    var text: String
    var done: Bool
    var day: String?
}

struct LocalSyncItem: Equatable {
    var id: UUID
    var item: SyncItem
}

struct RemoteSyncItem: Equatable {
    var key: String // 미리 알림 쪽 식별자
    var id: UUID? // 이어져 있는 앱 항목
    var item: SyncItem
}

enum SyncAction: Equatable {
    case createRemote(id: UUID, SyncItem)
    case updateRemote(key: String, SyncItem)
    case deleteRemote(key: String)
    case updateLocal(id: UUID, SyncItem)
    case deleteLocal(id: UUID)
    /// 폰에서 만든 항목 → 앱에 추가 (item 이 폰의 원래 값과 다르면 폰도 고친다)
    case createLocal(key: String, SyncItem)
    /// 이어진 기록을 잃었을 때 같은 제목 · 날짜끼리 다시 잇는다
    case link(key: String, id: UUID)
}

struct SyncResult: Equatable {
    var actions: [SyncAction]
    /// 실행 후 양쪽이 같아질 상태 (만들기는 실행한 쪽에서 더한다)
    var settled: [UUID: SyncItem]
}

enum SyncPlan {
    /// - local: 동기화할 앱 항목 (할 일은 오늘 이후)
    /// - today: 할 일 목록이면 오늘 날짜, 나중에 할 것이면 nil
    static func reconcile(local: [LocalSyncItem], remote: [RemoteSyncItem],
                          last lastIn: [UUID: SyncItem], today: String?) -> SyncResult {
        var actions: [SyncAction] = []
        var settled: [UUID: SyncItem] = [:]
        let last = remote.isEmpty ? [:] : lastIn
        var remote = remote

        // 이어진 기록이 없는 미리 알림 ↔ 아직 짝이 없는 앱 항목: 제목 · 날짜가 같으면 다시 잇는다
        var paired = Set(remote.compactMap(\.id))
        for i in remote.indices where remote[i].id == nil {
            let r = remote[i]
            if let l = local.first(where: { !paired.contains($0.id) && $0.item.text == r.item.text && $0.item.day == r.item.day }) {
                remote[i].id = l.id
                paired.insert(l.id)
                actions.append(.link(key: r.key, id: l.id))
            }
        }

        let localByID = Dictionary(local.map { ($0.id, $0.item) }, uniquingKeysWith: { a, _ in a })
        func isPast(_ day: String?) -> Bool { today.map { (day ?? "") < $0 } ?? false }
        var seen = Set<UUID>()

        for r in remote {
            guard let id = r.id else {
                if r.item.done && isPast(r.item.day) { continue } // 지난 날짜에 이미 끝낸 항목은 가져오지 않는다
                var m = r.item
                if let t = today, isPast(m.day) { m.day = t } // 날짜가 없거나 지났으면 오늘로
                actions.append(.createLocal(key: r.key, m))
                continue
            }
            if seen.contains(id) { actions.append(.deleteRemote(key: r.key)); continue } // 같은 항목이 둘이면 하나만 남긴다
            seen.insert(id)
            guard let l = localByID[id] else {
                actions.append(.deleteRemote(key: r.key)) // 앱에서 지웠거나 지난 날짜가 됐다
                continue
            }
            let before = last[id]
            if l == r.item {
                settled[id] = l
            } else if let before, r.item != before {
                var m = r.item // 폰에서 바뀌었다 (같이 바뀌었어도 폰 쪽)
                if isPast(m.day) { m.day = l.day } // 날짜를 지우거나 지난 날로 바꾸면 앱의 날짜를 지킨다
                if m != l { actions.append(.updateLocal(id: id, m)) }
                if m != r.item { actions.append(.updateRemote(key: r.key, m)) }
                settled[id] = m
            } else {
                actions.append(.updateRemote(key: r.key, l))
                settled[id] = l
            }
        }

        for l in local where !seen.contains(l.id) {
            if last[l.id] != nil {
                actions.append(.deleteLocal(id: l.id)) // 폰에서 지웠다
            } else if !l.item.done {
                actions.append(.createRemote(id: l.id, l.item)) // 이미 끝낸 항목은 새로 올리지 않는다
            }
        }
        return SyncResult(actions: actions, settled: settled)
    }

    /// 할 일 제목 앞에 붙이는 표시 (폰에서도 종류가 보이게)
    static func title(_ text: String, kind: TodoKind) -> String {
        switch kind {
        case .must: return "🔥 " + text
        case .nice: return "👍 " + text
        case .other: return text
        }
    }

    /// 폰에서 본 제목 → (글, 종류)
    static func parse(_ title: String) -> (text: String, kind: TodoKind) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, kind) in [("🔥", TodoKind.must), ("👍", .nice)] where t.hasPrefix(prefix) {
            return (String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces), kind)
        }
        return (t, .other)
    }
}
