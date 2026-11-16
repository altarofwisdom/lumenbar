import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var lampController: LampController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        signal(SIGTERM) { _ in
            AppDelegate.shared?.lampController?.shutdown()
            exit(0)
        }
        signal(SIGINT) { _ in
            AppDelegate.shared?.lampController?.shutdown()
            exit(0)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        lampController?.shutdown()
    }
}

@main
struct LumenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var lamp = LampController()
    
    var body: some Scene {
        MenuBarExtra {
            LumenBarMenuView(lamp: lamp)
                .onAppear {
                    appDelegate.lampController = lamp
                }
        } label: {
            Image(systemName: lamp.statusIcon)
                .symbolRenderingMode(.multicolor)
        }
        .menuBarExtraStyle(.window)
    }
}
