import Foundation
@testable import Caloura

func makeTestEntitlement(
    licenseID: String = "TEST-LICENSE",
    productID: String = "bmokl",
    validatedAt: Date = Date(),
    refreshAfter: Date? = nil,
    expiresAt: Date? = nil,
    source: LicenseEntitlementSource = .gumroadFallback
) -> LicenseEntitlement {
    let refreshDate = refreshAfter ?? validatedAt.addingTimeInterval(86_400)
    let expiryDate = expiresAt ?? validatedAt.addingTimeInterval(7 * 86_400)
    return LicenseEntitlement(
        claims: LicenseEntitlementClaims(
            productID: productID,
            licenseID: licenseID,
            issuedAt: validatedAt,
            refreshAfter: refreshDate,
            expiresAt: expiryDate,
            featureFlags: [:]
        ),
        source: source,
        token: nil,
        signature: nil,
        validatedAt: validatedAt
    )
}
