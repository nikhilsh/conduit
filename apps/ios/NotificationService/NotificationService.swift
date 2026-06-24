import UserNotifications

// Intercepts "ask" category pushes that carry an options[] array and registers
// a dynamic UNNotificationCategory so Watch and lock-screen show actual option
// text as action buttons. mutable-content:1 is set by the relay for this to run.
class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = mutable

        guard let rawOptions = request.content.userInfo["options"] as? [Any],
              !rawOptions.isEmpty
        else {
            contentHandler(mutable)
            return
        }
        let options = rawOptions.compactMap { $0 as? String }.prefix(4)
        guard !options.isEmpty else {
            contentHandler(mutable)
            return
        }

        let categoryID = "ask-dynamic"
        let actions = options.enumerated().map { idx, text in
            UNNotificationAction(
                identifier: "ask_opt_\(idx)",
                title: text,
                options: [.authenticationRequired]
            )
        }
        let dynamic = UNNotificationCategory(
            identifier: categoryID,
            actions: Array(actions),
            intentIdentifiers: [],
            options: []
        )

        // Merge with existing categories so the approval Approve/Deny survive.
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var updated = existing.filter { $0.identifier != categoryID }
            updated.insert(dynamic)
            UNUserNotificationCenter.current().setNotificationCategories(updated)
            mutable.categoryIdentifier = categoryID
            contentHandler(mutable)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let mutable = bestAttemptContent {
            contentHandler?(mutable)
        }
    }
}
