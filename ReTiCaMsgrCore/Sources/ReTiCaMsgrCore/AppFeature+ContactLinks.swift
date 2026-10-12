import Foundation
import ComposableArchitecture
import GRDB

/// The contact-link arms of `AppFeature` (spec 2026-10-11 §3, §5), composed into
/// `AppFeature.body` after the main and registration reducers; the main reducer treats every
/// action handled here as a no-op. Same state, same actions, same dependencies — split out so
/// `AppFeature.swift` stays readable (backlog 2026-10-11 item 9).
struct ContactLinksReducer: Reducer {
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    @Dependency(\.contactsClient) var contactsClient

    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case let .linkContactTapped(peerHex, source):
                let status = contactsClient.authorizationStatus()
                state.contactsAuthorization = status
                switch status {
                case .full, .limited:
                    state.linkPickerTarget = LinkPickerTarget(peerHex: peerHex, source: source)
                    return .none
                case .denied:
                    state.showingContactsDenied = true
                    return .none
                case .notDetermined:
                    return .run { [contactsClient] send in
                        let granted = await contactsClient.requestAccess()
                        await send(.contactsAccessResolved(granted, peerHex: peerHex, source: source))
                    }
                }

            case let .contactsAccessResolved(status, peerHex, source):
                state.contactsAuthorization = status
                switch status {
                case .full, .limited:
                    state.linkPickerTarget = LinkPickerTarget(peerHex: peerHex, source: source)
                case .denied:
                    state.showingContactsDenied = true
                case .notDetermined:
                    break
                }
                return .none

            case .dismissContactsDenied:
                state.showingContactsDenied = false
                return .none

            case .linkPickerDismissed:
                state.linkPickerTarget = nil
                return .none

            case let .contactPicked(peerHex, identifier, name, source):
                state.linkPickerTarget = nil
                // Re-picking the contact a peer already has changes nothing (Review Focus 2).
                if let existing = state.contactLinks[peerHex], existing.contactIdentifier == identifier {
                    return .none
                }
                if let collision = ContactLinking.collision(peerHex: peerHex, identifier: identifier, name: name,
                                                            source: source, in: state.contactLinks) {
                    state.pendingLinkCollision = collision
                    return .none
                }
                let link = ContactLinking.newLink(peerHex: peerHex, identifier: identifier, name: name,
                                                  source: source, now: date.now)
                return writeLinkEffects(state, link: link, replacing: [], contacts: contactsClient)

            case .replaceLinkConfirmed:
                guard let collision = state.pendingLinkCollision else { return .none }
                state.pendingLinkCollision = nil
                // Every row Replace deletes takes its verify prompt with it (the prompt is derived
                // from the row), so a double collision leaves nothing stale behind (Review Focus F2).
                let link = ContactLinking.newLink(peerHex: collision.peerHex, identifier: collision.identifier,
                                                  name: collision.name, source: collision.source, now: date.now)
                return writeLinkEffects(state, link: link, replacing: collision.existing, contacts: contactsClient)

            case .cancelLinkCollision:
                state.pendingLinkCollision = nil
                return .none

            case let .unlinkContact(peerHex):
                guard let link = state.contactLinks[peerHex] else { return .none }
                return unlinkEffects(state, link: link, contacts: contactsClient)

            case let .markContactVerified(peerHex):
                guard state.contactLinks[peerHex] != nil else { return .none }
                return updateContactLink(database, peerHex: peerHex, now: date.now) { $0.verified = true }

            case let .confirmationReceived(peerHex, confirmation):
                guard state.contactLinks[peerHex] != nil else { return .none }
                // A new confirmation asks again, even after an earlier "Not now".
                return updateContactLink(database, peerHex: peerHex, now: date.now) {
                    $0.confirmations.append(confirmation)
                    $0.promptDismissed = false
                }

            case let .dismissVerifyPrompt(peerHex):
                guard state.contactLinks[peerHex] != nil else { return .none }
                return updateContactLink(database, peerHex: peerHex, now: date.now) { $0.promptDismissed = true }

            case let .conflictReported(peerHex, contactIdentifier, otherPeerHex, at):
                guard let link = state.contactLinks[peerHex], link.contactIdentifier == contactIdentifier else {
                    return .none
                }
                // Re-checked inside the write too: a Replace can land between this guard and the
                // write once the exchange reports from the background (backlog 2026-10-11 item 7).
                return updateContactLink(database, peerHex: peerHex, now: date.now, expectingContact: contactIdentifier) {
                    $0.conflictedAt = at
                    $0.conflictPeerHex = otherPeerHex
                }

            case let .resolveConflict(peerHex):
                guard state.contactLinks[peerHex] != nil else { return .none }
                return updateContactLink(database, peerHex: peerHex, now: date.now) {
                    $0.conflictedAt = nil
                    $0.conflictPeerHex = nil
                }

            case let .contactNameRefreshed(peerHex, name):
                guard let link = state.contactLinks[peerHex], !name.isEmpty, link.cachedName != name else {
                    return .none
                }
                return updateContactLink(database, peerHex: peerHex, now: date.now) { $0.cachedName = name }

            case let .contactRowAppeared(peerHex):
                guard let link = state.contactLinks[peerHex] else { return .none }
                let id = link.contactIdentifier
                let cached = link.cachedName
                return .run { [contactsClient] send in
                    guard let summary = try? await contactsClient.contact(id) else {
                        await send(.contactCardLoaded(contactIdentifier: id, .missing))
                        return
                    }
                    if summary.name != cached { await send(.contactNameRefreshed(peerHex: peerHex, name: summary.name)) }
                    let thumbnail = summary.hasPhoto ? await contactsClient.thumbnail(id) : nil
                    await send(.contactCardLoaded(contactIdentifier: id, .available(thumbnail: thumbnail)))
                }

            case let .contactCardLoaded(id, card):
                state.contactCards[id] = card
                return .none

            case let .contactLinksLoaded(rows):
                state.contactLinks = Dictionary(uniqueKeysWithValues: rows.map { ($0.peerHex, $0) })
                // Cards of contacts that are no longer linked are dropped with their rows.
                let linked = Set(rows.map(\.contactIdentifier))
                state.contactCards = state.contactCards.filter { linked.contains($0.key) }
                return .none

            case let .setContactMirror(on):
                state.$contactMirrorEnabled.withLock { $0 = on }
                // Refresh what Contacts reports so Settings can say why nothing is written when
                // the toggle is on with denied or limited access (backlog 2026-10-11 item 5).
                state.contactsAuthorization = contactsClient.authorizationStatus()
                if on, state.contactsAuthorization == .notDetermined {
                    return .run { [contactsClient] send in
                        _ = await contactsClient.requestAccess()
                        await send(.setContactMirror(true))
                    }
                }
                // Turning on writes every existing link once and scans for imports; turning off
                // leaves the cards as they are (clearing other people's data is a deliberate act).
                guard on, state.contactsAuthorization == .full else { return .none }
                let links = Array(state.contactLinks.values)
                let known = state.contactLinks
                return .run { [contactsClient] send in
                    for link in links {
                        try? await contactsClient.writeAddress(link.contactIdentifier, link.peerHex)
                    }
                    let found = (try? await contactsClient.addressedContacts()) ?? []
                    await send(.importCandidatesFound(ContactLinking.importable(found, links: known)))
                }

            case .contactLinkSheetAppeared:
                // Refresh first (Review Focus F3): the Info sheet can reopen after the user
                // changed Contacts access in Settings, and the row must not show stale access.
                state.contactsAuthorization = contactsClient.authorizationStatus()
                guard state.contactMirrorEnabled else { return .none }
                let known = state.contactLinks
                return .run { [contactsClient] send in
                    let found = (try? await contactsClient.addressedContacts()) ?? []
                    await send(.importCandidatesFound(ContactLinking.importable(found, links: known)))
                }

            case let .importCandidatesFound(candidates):
                state.importCandidates = candidates
                return .none

            case .importContactLinks:
                // Re-filter against the current links: the list may be stale by the time it is tapped.
                let candidates = ContactLinking.importable(state.importCandidates, links: state.contactLinks)
                state.importCandidates = []
                guard !candidates.isEmpty else { return .none }
                let now = date.now
                return .run { [database] send in
                    try await database.write { db in
                        for candidate in candidates {
                            try ContactLink.insertReplacing(
                                ContactLinking.newLink(peerHex: candidate.peerHex, identifier: candidate.identifier,
                                                       name: candidate.name, source: ContactLinkSource.imported, now: now), db)
                        }
                    }
                    try await reloadContactLinks(database, send)
                }

            default:
                return .none
            }
        }
    }
}

// MARK: - Contact links → database (spec 2026-10-11)

/// Reads every link and hands them to the reducer, as a launch and every write do.
func reloadContactLinks(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let rows = try await database.read { try ContactLink.all($0) }
    await send(.contactLinksLoaded(rows))
}

/// Writes a new or replacing link, mirrors it to the card when the mirror is on with full
/// access (clearing every replaced row's card first, except one that is this same contact,
/// since that card is about to be rewritten with the new address instead of lost), reloads.
private func writeLinkEffects(_ state: AppFeature.State, link: ContactLink, replacing: [ContactLink],
                              contacts: ContactsClient) -> Effect<AppFeature.Action> {
    @Dependency(\.defaultDatabase) var database
    let mirror = state.contactMirrorEnabled && contacts.authorizationStatus() == .full
    return .run { send in
        try await database.write { try ContactLink.insertReplacing(link, $0) }
        if mirror {
            for old in replacing where old.contactIdentifier != link.contactIdentifier {
                try? await contacts.clearAddress(old.contactIdentifier)
            }
            try? await contacts.writeAddress(link.contactIdentifier, link.peerHex)
        }
        try await reloadContactLinks(database, send)
    }
}

/// Deletes a link, clears its card when the mirror is on with full access, reloads.
private func unlinkEffects(_ state: AppFeature.State, link: ContactLink,
                           contacts: ContactsClient) -> Effect<AppFeature.Action> {
    @Dependency(\.defaultDatabase) var database
    let mirror = state.contactMirrorEnabled && contacts.authorizationStatus() == .full
    return .run { send in
        try await database.write { try ContactLink.delete(peerHex: link.peerHex, $0) }
        if mirror { try? await contacts.clearAddress(link.contactIdentifier) }
        try await reloadContactLinks(database, send)
    }
}

/// Applies `mutate` to one row (stamping `updatedAt`), then reloads. A missing row is a no-op,
/// and so is a row that no longer names `expectingContact` when one is given.
private func updateContactLink(_ database: any DatabaseWriter, peerHex: String, now: Date,
                               expectingContact: String? = nil,
                               _ mutate: @escaping @Sendable (inout ContactLink) -> Void) -> Effect<AppFeature.Action> {
    .run { send in
        try await database.write { db in
            guard var row = try ContactLink.fetch(peerHex: peerHex, db),
                  expectingContact == nil || row.contactIdentifier == expectingContact
            else { return }
            mutate(&row)
            row.updatedAt = now
            try ContactLink.delete(peerHex: peerHex, db)
            try ContactLink.insert { row }.execute(db)
        }
        try await reloadContactLinks(database, send)
    }
}
