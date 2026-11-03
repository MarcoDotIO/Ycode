/// The value types of metadata fields as USDA writes them (`kind = "x"` is a
/// token, `active = true` a bool). These are interop facts of the Sdf schema
/// and the UsdGeom/UsdPhysics/UsdShade plug-in metadata of OpenUSD.
enum MetadataType {
    case token, string, bool, double, int, dictionary, tokenArray, stringArray, asset, tokenListOp, stringListOp, tokenVector

    static let known: [String: MetadataType] = [
        "kind": .token, "defaultPrim": .token, "upAxis": .token, "interpolation": .token,
        "connectability": .token, "outputName": .token, "renderType": .token, "colorSpace": .token,
        "bindMaterialAs": .token, "colorManagementSystem": .token, "displayUnit": .token,
        "symmetryFunction": .token, "typeName": .token,
        "documentation": .string, "comment": .string, "displayName": .string, "displayGroup": .string,
        "owner": .string, "sessionOwner": .string,
        "active": .bool, "hidden": .bool, "instanceable": .bool, "noLoadHint": .bool, "custom": .bool,
        "hasOwnedSubLayers": .bool,
        "metersPerUnit": .double, "kilogramsPerUnit": .double, "startTimeCode": .double, "endTimeCode": .double,
        "timeCodesPerSecond": .double, "framesPerSecond": .double, "startFrame": .double, "endFrame": .double,
        "elementSize": .int, "framePrecision": .int,
        "customData": .dictionary, "assetInfo": .dictionary, "customLayerData": .dictionary,
        "sdrMetadata": .dictionary, "clips": .dictionary, "symmetryArguments": .dictionary,
        "expressionVariables": .dictionary, "prefixSubstitutions": .dictionary, "suffixSubstitutions": .dictionary,
        "allowedTokens": .tokenArray, "displayGroupOrder": .stringArray,
        "colorConfiguration": .asset,
        "apiSchemas": .tokenListOp, "variantSetNames": .stringListOp, "clipSets": .stringListOp,
        "primOrder": .tokenVector, "propertyOrder": .tokenVector,
    ]
}
