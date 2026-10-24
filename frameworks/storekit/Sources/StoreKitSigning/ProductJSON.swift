// The product's JSON representation (formats.md §1) synthesized from the catalog.
import Foundation
import StoreKitConfiguration
import StoreKitEngine

public enum ProductJSON {
    /// The catalog resource for `product` in a session locale and storefront.
    /// Keys are written sorted; code and win-back offers are not part of it.
    public static func value(_ product: CatalogProduct, catalog: Catalog, locale: String, storefront: Storefront) -> JSONValue {
        let priceLocale = storefront.priceLocaleIdentifier(locale: locale)
        func formatted(_ price: Decimal) -> String { PriceFormatter.displayPrice(price, priceLocale: priceLocale) }
        func plain(_ price: Decimal) -> String { PriceFormatter.plainPrice(price, currency: storefront.currency) }

        var offer: [String: JSONValue] = [
            "currencyCode": .string(storefront.currency),
            "priceFormatted": .string(formatted(product.price)),
            "priceString": .string(plain(product.price)),
        ]
        var attributes: [String: JSONValue] = [
            "kind": .string(product.type.rawValue),
            "offerName": .string(product.id),
            "name": .string(product.displayName(locale: locale)),
            "icuLocale": .string(priceLocale),
            "isFamilyShareable": .int(product.isFamilyShareable ? 1 : 0),
        ]
        if let d = product.description(locale: locale) { attributes["description"] = .object(["standard": .string(d)]) }
        if let sub = product.subscription {
            offer["type"] = .string("buy")
            offer["billingPeriod"] = .string(sub.period.iso8601)
            offer["recurringSubscriptionPeriod"] = .string(sub.period.iso8601)
            offer["billingPlanType"] = .string("BILLED_UPFRONT")
            var discounts: [JSONValue] = []
            for o in [sub.introductoryOffer].compactMap({ $0 }) + sub.promotionalOffers {
                var d: [String: JSONValue] = [
                    "type": .string(o.type == .introductory ? "IntroOffer" : "AdhocOffer"),
                    "modeType": .string(o.paymentMode.productJSONMode),
                    "numOfPeriods": .int(o.periodCount),
                    "recurringSubscriptionPeriod": .string(o.period.iso8601),
                    "priceFormatted": .string(formatted(o.price)),
                    "priceString": .string(plain(o.price)),
                    "billingPlanType": .string("BILLED_UPFRONT"),
                ]
                if o.type == .promotional, let id = o.identifier { d["offerId"] = .string(id) }
                discounts.append(.object(d))
            }
            offer["discounts"] = .array(discounts)
            attributes["subscriptionFamilyId"] = .string(sub.groupID)
            attributes["subscriptionFamilyName"] = .string(catalog.group(sub.groupID)?.displayName(locale: locale) ?? "")
            attributes["subscriptionFamilyRank"] = .int(sub.level)
        }
        attributes["offers"] = .array([.object(offer)])
        return .object(["id": .string(product.internalID), "type": .string("in-apps"), "attributes": .object(attributes)])
    }

    /// The compact JSON bytes (`Product.jsonRepresentation`).
    public static func data(_ product: CatalogProduct, catalog: Catalog, locale: String, storefront: Storefront) -> Data {
        Data(JSONWriter.compact(value(product, catalog: catalog, locale: locale, storefront: storefront)).utf8)
    }
}
