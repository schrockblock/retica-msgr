import Foundation
import ComposableArchitecture
#if canImport(Contacts)
import Contacts
#endif

/// What the Contacts framework lets us do (spec 2026-10-11 §2). `limited` is iOS 18's
/// "selected contacts only"; the picker still works, card writes do not.
public enum ContactsAuthorization: Equatable, Sendable {
    case notDetermined, full, limited, denied
}

public struct ContactSummary: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var hasPhoto: Bool

    public init(identifier: String, name: String, hasPhoto: Bool) {
        self.identifier = identifier
        self.name = name
        self.hasPhoto = hasPhoto
    }
}

/// A `reticulum:` URL found on a contact card (spec §3 "Import").
public struct ImportCandidate: Equatable, Hashable, Sendable, Identifiable {
    public var identifier: String
    public var name: String
    public var peerHex: String
    public var id: String { identifier }

    public init(identifier: String, name: String, peerHex: String) {
        self.identifier = identifier
        self.name = name
        self.peerHex = peerHex
    }
}

/// The Contacts framework behind closures, so reducers are tested against `FakeContacts`.
public struct ContactsClient: Sendable {
    public var authorizationStatus: @Sendable () -> ContactsAuthorization
    public var requestAccess: @Sendable () async -> ContactsAuthorization
    /// nil when the contact is missing or outside the limited selection.
    public var contact: @Sendable (_ identifier: String) async throws -> ContactSummary?
    public var thumbnail: @Sendable (_ identifier: String) async -> Data?
    /// Replace any `reticulum:` URL on the card with `reticulum:<peerHex>` (label `Reticulum`).
    public var writeAddress: @Sendable (_ identifier: String, _ peerHex: String) async throws -> Void
    /// Remove every `reticulum:` URL from the card.
    public var clearAddress: @Sendable (_ identifier: String) async throws -> Void
    /// Every available card that carries a `reticulum:` URL, unfiltered.
    public var addressedContacts: @Sendable () async throws -> [ImportCandidate]

    public static let urlLabel = "Reticulum"
    public static let urlScheme = "reticulum:"

    public init(authorizationStatus: @escaping @Sendable () -> ContactsAuthorization,
                requestAccess: @escaping @Sendable () async -> ContactsAuthorization,
                contact: @escaping @Sendable (String) async throws -> ContactSummary?,
                thumbnail: @escaping @Sendable (String) async -> Data?,
                writeAddress: @escaping @Sendable (String, String) async throws -> Void,
                clearAddress: @escaping @Sendable (String) async throws -> Void,
                addressedContacts: @escaping @Sendable () async throws -> [ImportCandidate]) {
        self.authorizationStatus = authorizationStatus
        self.requestAccess = requestAccess
        self.contact = contact
        self.thumbnail = thumbnail
        self.writeAddress = writeAddress
        self.clearAddress = clearAddress
        self.addressedContacts = addressedContacts
    }
}

/// An in-memory address book for tests: contacts by identifier, `reticulum:` addresses by
/// identifier, and a log of card writes and clears. The default `testValue`.
public final class FakeContacts: @unchecked Sendable {
    public struct Write: Equatable, Hashable, Sendable {
        public var identifier: String
        public var peerHex: String
        public init(identifier: String, peerHex: String) {
            self.identifier = identifier
            self.peerHex = peerHex
        }
    }

    private let lock = NSLock()
    private var _authorization: ContactsAuthorization
    private let grantOnRequest: ContactsAuthorization
    private var _contacts: [String: ContactSummary]
    private var _addresses: [String: String]
    private var _writes: [Write] = []
    private var _clears: [String] = []

    public init(authorization: ContactsAuthorization = .full, grantOnRequest: ContactsAuthorization = .full,
                contacts: [ContactSummary] = [], addresses: [String: String] = [:]) {
        _authorization = authorization
        self.grantOnRequest = grantOnRequest
        _contacts = Dictionary(uniqueKeysWithValues: contacts.map { ($0.identifier, $0) })
        _addresses = addresses
    }

    public var authorization: ContactsAuthorization {
        get { lock.withLock { _authorization } }
        set { lock.withLock { _authorization = newValue } }
    }
    public var writes: [Write] { lock.withLock { _writes } }
    public var clears: [String] { lock.withLock { _clears } }

    public var client: ContactsClient {
        ContactsClient(
            authorizationStatus: { [self] in authorization },
            requestAccess: { [self] in
                lock.withLock {
                    if _authorization == .notDetermined { _authorization = grantOnRequest }
                    return _authorization
                }
            },
            contact: { [self] id in lock.withLock { _contacts[id] } },
            thumbnail: { [self] id in lock.withLock { _contacts[id]?.hasPhoto == true ? Data([0xFF, 0xD8]) : nil } },
            writeAddress: { [self] id, hex in
                lock.withLock {
                    _writes.append(Write(identifier: id, peerHex: hex))
                    _addresses[id] = hex
                }
            },
            clearAddress: { [self] id in
                lock.withLock {
                    _clears.append(id)
                    _addresses[id] = nil
                }
            },
            addressedContacts: { [self] in
                lock.withLock {
                    _addresses.map { id, hex in ImportCandidate(identifier: id, name: _contacts[id]?.name ?? "", peerHex: hex) }
                }
            })
    }
}

extension ContactsAuthorization {
    #if canImport(Contacts)
    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        default:
            // `.limited` (iOS 18) is the only other case; named through `default` so the
            // package still compiles on SDKs without it.
            self = .limited
        }
    }
    #endif
}

extension ContactsClient: DependencyKey {
    public static var liveValue: ContactsClient {
        #if canImport(Contacts)
        // `CNContactStore` and `CNKeyDescriptor` are not `Sendable` (Apple's own types predate
        // the annotation), but Apple documents `CNContactStore` as thread-safe. Boxing it lets the
        // closures above capture it without a Swift 6 isolation error; `nameKeys()` sidesteps the
        // same problem for the descriptor array by recomputing it (cheap) instead of capturing it.
        final class StoreBox: @unchecked Sendable {
            let store = CNContactStore()
        }
        let box = StoreBox()
        @Sendable func nameKeys() -> [CNKeyDescriptor] {
            [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        }
        @Sendable func name(_ contact: CNContact) -> String {
            CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        }
        return ContactsClient(
            authorizationStatus: { ContactsAuthorization(CNContactStore.authorizationStatus(for: .contacts)) },
            requestAccess: {
                _ = try? await box.store.requestAccess(for: .contacts)
                return ContactsAuthorization(CNContactStore.authorizationStatus(for: .contacts))
            },
            contact: { id in
                let keys = nameKeys() + [CNContactImageDataAvailableKey as CNKeyDescriptor]
                guard let c = try? box.store.unifiedContact(withIdentifier: id, keysToFetch: keys) else { return nil }
                return ContactSummary(identifier: id, name: name(c), hasPhoto: c.imageDataAvailable)
            },
            thumbnail: { id in
                (try? box.store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactThumbnailImageDataKey as CNKeyDescriptor]))?
                    .thumbnailImageData
            },
            writeAddress: { id, hex in
                let c = try box.store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactUrlAddressesKey as CNKeyDescriptor])
                guard let m = c.mutableCopy() as? CNMutableContact else { return }
                m.urlAddresses = m.urlAddresses.filter { !($0.value as String).hasPrefix(ContactsClient.urlScheme) }
                    + [CNLabeledValue(label: ContactsClient.urlLabel, value: (ContactsClient.urlScheme + hex) as NSString)]
                let request = CNSaveRequest()
                request.update(m)
                try box.store.execute(request)
            },
            clearAddress: { id in
                let c = try box.store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactUrlAddressesKey as CNKeyDescriptor])
                guard let m = c.mutableCopy() as? CNMutableContact else { return }
                m.urlAddresses = m.urlAddresses.filter { !($0.value as String).hasPrefix(ContactsClient.urlScheme) }
                let request = CNSaveRequest()
                request.update(m)
                try box.store.execute(request)
            },
            addressedContacts: {
                let request = CNContactFetchRequest(keysToFetch: nameKeys() + [CNContactUrlAddressesKey as CNKeyDescriptor])
                var found: [ImportCandidate] = []
                try box.store.enumerateContacts(with: request) { c, _ in
                    for url in c.urlAddresses {
                        let value = url.value as String
                        guard value.hasPrefix(ContactsClient.urlScheme) else { continue }
                        found.append(ImportCandidate(identifier: c.identifier, name: name(c),
                                                     peerHex: String(value.dropFirst(ContactsClient.urlScheme.count))))
                    }
                }
                return found
            })
        #else
        return FakeContacts().client
        #endif
    }

    /// A fresh empty fake with full access; tests that need contacts build their own `FakeContacts`.
    public static var testValue: ContactsClient { FakeContacts().client }
}

extension DependencyValues {
    public var contactsClient: ContactsClient {
        get { self[ContactsClient.self] }
        set { self[ContactsClient.self] = newValue }
    }
}
