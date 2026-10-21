import UIKit
import ReTiCaMsgrCore

extension BackgroundTaskClient {
    /// The real thing: UIKit background time, named for the debugger's task list.
    static let uiKit = BackgroundTaskClient(
        begin: { onExpire in
            await MainActor.run {
                let id = UIApplication.shared.beginBackgroundTask(withName: "Finish sending",
                                                                  expirationHandler: onExpire)
                return id == .invalid ? nil : id.rawValue
            }
        },
        end: { id in
            await MainActor.run {
                UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
            }
        })
}
