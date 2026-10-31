import Foundation

actor IdentifyInteractor {
    private let api: ChatwootAPI
    private let store: SessionStore
    private let resetLocalData: () async throws -> Void

    init(api: ChatwootAPI, store: SessionStore, resetLocalData: @escaping () async throws -> Void) {
        self.api = api
        self.store = store
        self.resetLocalData = resetLocalData
    }

    func identify(
        user: ChatwootUser,
        identity: Identity,
        customAttributes: [String: JSONValue]? = nil,
        force: Bool = false
    ) async -> Result<Session, ChatwootError> {
        if store.isCleanupRequired() {
            CWLog.i(.auth, "unfinished local data reset, finishing it first")
            guard await finishReset() else { return .failure(.unknown) }
        }
        if let existing = store.read() {
            if existing.identifier != identity.identifier {
                CWLog.i(.auth, "identifier changed, local data cleared")
                guard await finishReset() else { return .failure(.unknown) }
                store.clear()
            } else if force {
                CWLog.i(.auth, "reidentify requested, session dropped")
                store.clear()
            } else {
                return .success(existing)
            }
        }
        return await create(user: user, identity: identity, customAttributes: customAttributes)
    }

    private func create(
        user: ChatwootUser,
        identity: Identity,
        customAttributes: [String: JSONValue]?
    ) async -> Result<Session, ChatwootError> {
        let created: ContactInboxDTO
        do {
            created = try await api.createContact(
                ContactCreateBody(identifier: identity.identifier, identifierHash: identity.identifierHash, name: user.name, avatarURL: user.avatarURL)
            )
        } catch let error as ChatwootError {
            CWLog.w(.auth, "identify create failed: \(describe(error))")
            return .failure(error)
        } catch {
            CWLog.w(.auth, "identify create failed: \(type(of: error))")
            return .failure(.unknown)
        }
        guard let sourceID = created.sourceID, let pubsubToken = created.pubsubToken else {
            CWLog.w(.auth, "identify create: incomplete response")
            return .failure(.unknown)
        }
        let patched: ContactDTO
        do {
            patched = try await api.updateContact(
                sourceID: sourceID,
                body: ContactUpdateBody(
                    identifier: identity.identifier,
                    identifierHash: identity.identifierHash,
                    name: user.name,
                    avatarURL: user.avatarURL,
                    customAttributes: customAttributes
                )
            )
        } catch let error as ChatwootError {
            CWLog.w(.auth, "identify patch failed: \(describe(error))")
            return .failure(error)
        } catch {
            CWLog.w(.auth, "identify patch failed: \(type(of: error))")
            return .failure(.unknown)
        }
        guard patched.identifier == identity.identifier else {
            CWLog.w(.auth, "identity mismatch")
            let wiped = await finishReset()
            store.clear()
            return .failure(wiped ? .identityMismatch : .unknown)
        }
        guard let contactID = patched.id ?? created.id else {
            CWLog.w(.auth, "identify patch: no contact id")
            return .failure(.unknown)
        }
        let session = Session(
            identifier: identity.identifier,
            identifierHash: identity.identifierHash,
            sourceID: sourceID,
            pubsubToken: pubsubToken,
            contactID: contactID
        )
        do {
            try store.write(session)
        } catch {
            CWLog.w(.auth, "session not saved (\(type(of: error)))")
            return .failure(.unknown)
        }
        CWLog.i(.auth, "identified contactID=\(contactID)")
        return .success(session)
    }

    private func finishReset() async -> Bool {
        do {
            try await resetLocalData()
            return true
        } catch {
            CWLog.w(.auth, "local data reset failed (\(type(of: error)))")
            return false
        }
    }

    private func describe(_ error: ChatwootError) -> String {
        switch error {
        case .http(let code): return "http \(code)"
        default: return "\(error)"
        }
    }
}
