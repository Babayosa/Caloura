import Foundation

actor PermissionIdentityProvider {
    typealias Loader = @Sendable (Bundle) -> PermissionIdentity

    static let shared = PermissionIdentityProvider()

    private let bundle: Bundle
    private let loader: Loader
    private var cachedIdentity: PermissionIdentity?

    init(
        bundle: Bundle = .main,
        loader: @escaping Loader = { bundle in
            PermissionIdentity.current(bundle: bundle)
        }
    ) {
        self.bundle = bundle
        self.loader = loader
    }

    func currentIdentity() async -> PermissionIdentity {
        if let cachedIdentity {
            return cachedIdentity
        }

        let bundle = self.bundle
        let loader = self.loader
        let identity = await Task.detached(priority: .utility) {
            loader(bundle)
        }.value
        cachedIdentity = identity
        return identity
    }

    func invalidate() {
        cachedIdentity = nil
    }
}
