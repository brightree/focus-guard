// Focus Guard — 맥 메뉴 막대 뽀모도로 앱.
// 메뉴 막대 표시와 패널, 창 관리, 전역 단축키(⌥⇧L), 로컬 서버와 브라우저 감시 시작을 담당한다.

import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - 창 관리

final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, floating: Bool = false, resizable: Bool = false,
                       @ViewBuilder content: () -> V) {
        let root = content().environmentObject(Store.shared)
        let w: NSWindow
        if let existing = windows[id] {
            w = existing
            w.contentViewController = NSHostingController(rootView: root)
        } else {
            var style: NSWindow.StyleMask = [.titled, .closable]
            if resizable { style.insert(.resizable) }
            w = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: root)
            w.center()
            windows[id] = w
        }
        w.title = title
        w.level = floating ? .floating : .normal
        NSApp.setActivationPolicy(.regular) // 창이 있는 동안은 Dock 과 ⌘Tab 에 보인다
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) { windows[id]?.close() }

    // 닫힌 창의 화면을 놓아준다 (안 그러면 숨은 창도 매초 다시 그려진다).
    // 열린 창이 하나도 없으면 다시 메뉴 막대 전용으로 돌아간다.
    func windowWillClose(_ note: Notification) {
        let closing = note.object as? NSWindow
        closing?.contentViewController = nil
        if !windows.values.contains(where: { $0 !== closing && $0.isVisible }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - 전역 단축키

enum HotKey {
    static var handler: (() -> Void)?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4647_5244), id: 1) // 'FGRD'
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let store = Store.shared
    let server = StateServer()
    let watcher = BrowserWatcher()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var bag = Set<AnyCancellable>()
    private var lastTitle = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self

        store.$now.sink { [weak self] now in
            self?.renderTitle()
            self?.checkNewDay(now)
        }.store(in: &bag)
        store.onPhaseChange = { [weak self] old, new in self?.phaseChanged(from: old, to: new) }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        HotKey.handler = { [weak self] in self?.showQuickCapture() }
        HotKey.register()
        server.start()
        watcher.onWarn = { [weak self] min, site, bid in self?.showWarning(min: min, site: site, bid: bid) }
        store.onSecond = { [weak self] in self?.watcher.tick() }
        if store.isBlocking { watcher.sweepAllTabs() }
        renderTitle()
    }

    func applicationWillTerminate(_ note: Notification) { store.saveNow() }

    // 앱이 앞에 있어도 알림 배너를 보여준다
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // MARK: 메뉴 막대 표시

    func renderTitle() {
        guard let b = item.button else { return }
        let title = store.phase == .idle
            ? "🍅"
            : "\(store.isPaused ? "⏸" : store.phase.icon) \(Int((store.remaining / 60).rounded(.up)))"
        guard title != lastTitle else { return }
        lastTitle = title
        b.title = title
        b.toolTip = store.timer.task.isEmpty ? "Focus Guard" : "📌 \(store.timer.task)"
    }

    // MARK: 메뉴 막대 패널

    @objc func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let host = NSHostingController(rootView: PopoverView(
            primary: { [weak self] in self?.popover.performClose(nil); self?.primaryAction() },
            togglePause: { [weak self] in self?.togglePause() },
            openApp: { [weak self] in self?.popover.performClose(nil); self?.showDashboard() },
            close: { [weak self] in self?.popover.performClose(nil) }
        ).environmentObject(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // 닫힌 패널의 화면을 놓아준다
    func popoverDidClose(_ note: Notification) { popover.contentViewController = nil }

    /// 단계별 시작/중지 버튼 동작
    func primaryAction() {
        switch store.phase {
        case .idle: showStart()
        case .focus: showGiveUp()
        case .wrap: finishWrap()
        case .rest: skipBreak()
        }
    }

    // MARK: 동작

    private var checkedDay = ""

    /// 하루의 첫 순간(앱 시작 또는 자정 이후)에 오늘 할 일이 비어 있으면 계획 창을 한 번 띄운다.
    func checkNewDay(_ now: Date) {
        let k = dayKey(now)
        guard k != checkedDay else { return }
        checkedDay = k
        if store.shouldShowMorningPlan() { showPlan() }
    }

    func showPlan() {
        Windows.shared.show("plan", title: "오늘 할 일") { PlanView() }
    }

    func phaseChanged(from old: Phase, to new: Phase) {
        renderTitle()
        switch new {
        case .focus: watcher.sweepAllTabs() // 미리 열어둔 분산 사이트 탭도 막는다
        case .wrap: showWrap()
        case .rest: Windows.shared.close("wrap")
        case .idle where old == .rest: showStart() // 휴식 끝나면 바로 다음 할 일을 묻는다
        default: break
        }
    }

    func showStart() {
        let last = store.today.log.last?.task ?? ""
        Windows.shared.show("start", title: "집중 시작", floating: true) {
            StartView(task: last) { Windows.shared.close("start") }
        }
    }

    func showWrap() {
        Windows.shared.show("wrap", title: "정리", floating: true) {
            WrapView { Windows.shared.close("wrap") }
        }
    }

    func showQuickCapture() {
        Windows.shared.show("capture", title: "나중에 할 것", floating: true) {
            QuickCaptureView { Windows.shared.close("capture") }
        }
    }

    func showWarning(min: Int, site: String, bid: String) {
        Windows.shared.show("warn", title: "딴짓 경고", floating: true) {
            WarnView(min: min, site: site,
                     closeTab: { [weak self] in self?.watcher.closeFrontTab(bid: bid, ifStillOn: site); Windows.shared.close("warn") },
                     keep: { Windows.shared.close("warn") })
        }
    }

    func showGiveUp() { presentGiveUp(thenQuit: false) }

    func presentGiveUp(thenQuit: Bool) {
        Windows.shared.show("giveup", title: "포기하기", floating: true) {
            GiveUpView(onGiveUp: { [weak self] in
                self?.store.stop()
                if thenQuit { NSApp.terminate(nil) }
            }, close: { Windows.shared.close("giveup") })
        }
    }

    func showDashboard() {
        Windows.shared.show("dashboard", title: "Focus Guard", resizable: true) {
            DashboardView(openPlan: { [weak self] in self?.showPlan() },
                          openSettings: { [weak self] in self?.showSettings() },
                          quit: { [weak self] in self?.quit() })
        }
    }

    func showSettings() {
        Windows.shared.show("settings", title: "Focus Guard 설정") {
            SettingsView(chooseFolder: { [weak self] in self?.chooseFolder() },
                         revealFolder: { [weak self] in self?.revealFolder() },
                         toggleLogin: { [weak self] in self?.toggleLogin() },
                         uninstall: { [weak self] in self?.uninstall() })
        }
    }

    func togglePause() { store.isPaused ? store.resume() : store.pause(); renderTitle() }
    func finishWrap() { store.finishWrap(); Windows.shared.close("wrap") }
    func skipBreak() { store.stop() }

    // 집중·정리 중에 앱을 끄면 차단이 풀리므로 포기 절차를 거치게 한다.
    func quit() {
        if store.isBlocking {
            presentGiveUp(thenQuit: true)
        } else {
            NSApp.terminate(nil)
        }
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("자동 실행 설정에 실패했어요", "시스템 설정 → 일반 → 로그인 항목에서 FocusGuard를 직접 추가할 수 있어요.\n\(error.localizedDescription)")
        }
    }

    /// 앱을 휴지통으로 옮기고 종료한다. 원하면 기록 폴더도 휴지통으로 옮긴다 (되살릴 수 있음).
    func uninstall() {
        guard !store.isBlocking else {
            return alert("지금은 삭제할 수 없어요", "집중·정리 중에는 삭제할 수 없어요. 끝난 뒤에 다시 해주세요.")
        }
        let a = NSAlert()
        a.messageText = "Focus Guard를 삭제할까요?"
        a.informativeText = "앱을 휴지통으로 옮기고 종료해요. 로그인 시 자동 실행도 꺼져요."
        let withData = NSButton(checkboxWithTitle: "기록도 함께 휴지통으로 옮기기\n(\(store.dataDir.path))", target: nil, action: nil)
        a.accessoryView = withData
        a.addButton(withTitle: "삭제")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        try? SMAppService.mainApp.unregister()
        if withData.state == .on {
            store.stopSaving() // 종료하면서 기록을 다시 만들지 않게
            NSWorkspace.shared.recycle([store.dataDir]) { _, _ in }
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        } else {
            store.saveNow()
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            if let error { self.alert("앱을 휴지통으로 옮기지 못했어요", error.localizedDescription) }
            NSApp.terminate(nil)
        }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "이 폴더에 저장"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url, let err = store.changeDataDir(to: url) {
            alert("저장 위치를 바꾸지 않았어요", err)
        }
    }

    func revealFolder() {
        store.saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([store.dataURL])
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Dock에 아이콘 없이 메뉴 막대에만
app.run()
