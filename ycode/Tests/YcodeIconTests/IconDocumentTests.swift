import Foundation
import Testing
@testable import YcodeIcon

/// ICON-READER (specs/formats/icon-format.md, README-icon.md): the model,
/// the reader's errors, the writer's layout, specializations and frames.
/// Every document here is our own, written in the test.
struct IconDocumentTests {
    /// A document in Icon Composer's layout that uses every key of §3, with
    /// specializations, every fill form, and keys Ycode does not know.
    static let everyKey = """
    {
      "color-space-for-untagged-svg-colors" : "display-p3",
      "fill" : {
        "automatic-gradient" : "extended-srgb:0.00000,0.53333,1.00000,1.00000"
      },
      "fill-specializations" : [
        {
          "value" : "automatic"
        },
        {
          "appearance" : "dark",
          "value" : {
            "solid" : "srgb:0.10000,0.10000,0.20000,1.00000"
          }
        },
        {
          "idiom" : "watchOS",
          "value" : {
            "linear-gradient" : [
              "display-p3:1.00000,0.00000,0.00000,1.00000",
              "gray:0.50000,1.00000"
            ],
            "orientation" : {
              "start" : {
                "x" : 0,
                "y" : 0
              },
              "stop" : {
                "x" : 1,
                "y" : 1
              }
            }
          }
        }
      ],
      "groups" : [
        {
          "blend-mode" : "multiply",
          "blend-mode-specializations" : [
            {
              "appearance" : "tinted",
              "value" : "screen"
            }
          ],
          "blur-material" : null,
          "blur-material-specializations" : [
            {
              "appearance" : "dark",
              "value" : 0.4
            }
          ],
          "hidden" : false,
          "hidden-specializations" : [
            {
              "idiom" : "macOS",
              "value" : true
            }
          ],
          "layers" : [
            {
              "blend-mode" : "plus-lighter",
              "fill" : {
                "solid" : "extended-gray:1.00000,1.00000"
              },
              "fill-specializations" : [
                {
                  "appearance" : "tinted",
                  "value" : "none"
                }
              ],
              "glass" : false,
              "glass-specializations" : [
                {
                  "appearance" : "dark",
                  "value" : true
                }
              ],
              "hidden" : false,
              "image-name" : "ring.svg",
              "image-name-specializations" : [
                {
                  "appearance" : "dark",
                  "value" : "ring-dark.svg"
                }
              ],
              "name" : "ring",
              "opacity" : 0.75,
              "opacity-specializations" : [
                {
                  "idiom" : "square",
                  "value" : 0.5
                }
              ],
              "position" : {
                "scale" : 1.25,
                "translation-in-points" : [
                  -10,
                  20.5
                ]
              },
              "position-specializations" : [
                {
                  "idiom" : "watchOS",
                  "value" : {
                    "relative-translation" : [
                      0.1,
                      0
                    ],
                    "scale" : 0.8,
                    "translation-in-points" : [
                      0,
                      0
                    ]
                  }
                }
              ],
              "x-layer-note" : "kept"
            },
            {
              "image-name" : "dot.png",
              "name" : "dot"
            }
          ],
          "lighting" : "combined",
          "lighting-specializations" : [
            {
              "appearance" : "light",
              "value" : "individual"
            }
          ],
          "name" : "Front",
          "opacity" : 0.9,
          "opacity-specializations" : [
            {
              "appearance" : "dark",
              "value" : 0.6
            }
          ],
          "position" : {
            "scale" : 2,
            "translation-in-points" : [
              50,
              -30
            ]
          },
          "position-specializations" : [
            {
              "value" : {
                "scale" : 1,
                "translation-in-points" : [
                  0,
                  0
                ]
              }
            }
          ],
          "refractivity" : {
            "depth" : 0.2,
            "enabled" : true,
            "strength" : 0.7
          },
          "refractivity-specializations" : [
            {
              "appearance" : "tinted",
              "value" : {
                "depth" : 0,
                "enabled" : false,
                "strength" : 0
              }
            }
          ],
          "shadow" : {
            "kind" : "layer-color",
            "opacity" : 0.25
          },
          "shadow-specializations" : [
            {
              "appearance" : "dark",
              "value" : {
                "kind" : "none",
                "opacity" : 0.5
              }
            }
          ],
          "specular" : false,
          "specular-highlight-placement" : "outside",
          "specular-highlight-placement-specializations" : [
            {
              "appearance" : "dark",
              "value" : "inside"
            }
          ],
          "specular-specializations" : [
            {
              "idiom" : "iOS",
              "value" : true
            }
          ],
          "translucency" : {
            "enabled" : false,
            "value" : 0.6
          },
          "translucency-specializations" : [
            {
              "appearance" : "tinted",
              "value" : {
                "enabled" : true,
                "value" : 0.1
              }
            }
          ],
          "x-group-note" : 7
        },
        {
          "layers" : [

          ]
        }
      ],
      "material-strength" : 0.5,
      "supported-platforms" : {
        "circles" : [
          "watchOS"
        ],
        "squares" : "shared"
      }
    }
    """

    func doc(_ s: String) throws -> IconDocument { try IconDocument(data: Data(s.utf8)) }

    @Test func everyKeyRoundTripsByteForByte() throws {
        let d = try doc(Self.everyKey)
        #expect(d.json.formatted() == Self.everyKey)
        // Reading what was written gives the same model.
        #expect(try IconDocument(data: d.data()) == d)
    }

    @Test func everyKeyIsInTheModel() throws {
        let d = try doc(Self.everyKey)
        #expect(d.colorSpaceForUntaggedSVGColors == "display-p3")
        #expect(d.fill.value == .automaticGradient(IconColor(space: .extendedSRGB, components: [0, 0.53333, 1, 1])))
        #expect(d.fill.specializations?.count == 3)
        #expect(d.supportedPlatforms == .multiplatform)
        #expect(d.extra["material-strength"] == .number(0.5))
        let g = d.groups[0]
        #expect(g.name == "Front")
        #expect(g.blendMode.value == .multiply)
        #expect(g.blurMaterial.value == IconBlurMaterial(nil))
        #expect(g.lighting.value == .combined)
        #expect(g.refractivity.value == IconRefractivity(enabled: true, strength: 0.7, depth: 0.2))
        #expect(g.shadow.value?.knownKind == .layerColor)
        #expect(g.specularHighlightPlacement.value == .outside)
        #expect(g.translucency.value?.effectiveValue == 0)
        #expect(g.extra["x-group-note"] == .number(7))
        let l = g.layers[0]
        #expect(l.imageName.value == "ring.svg")
        #expect(l.blendMode.value == .plusLighter)
        #expect(l.fill.value == .solid(.extendedGray(1)))
        #expect(l.glass.value == false)
        #expect(l.position.value == IconPosition(scale: 1.25, translation: IconPoint(x: -10, y: 20.5)))
        #expect(l.position.specializations?[0].value.extra["relative-translation"] == .array([.number(0.1), .number(0)]))
        #expect(l.extra["x-layer-note"] == .string("kept"))
        #expect(d.groups[1].layers.isEmpty)
    }

    @Test func writerUsesIconComposersLayout() throws {
        let d = IconDocument(fill: .solid(.srgb(1, 0.5, 0)), groups: [IconGroup(layers: [IconLayer(imageName: "a.svg")])])
        let expected = """
        {
          "fill" : {
            "solid" : "srgb:1.00000,0.50000,0.00000,1.00000"
          },
          "groups" : [
            {
              "layers" : [
                {
                  "image-name" : "a.svg"
                }
              ]
            }
          ]
        }
        """
        #expect(String(decoding: d.data(), as: UTF8.self) == expected)
        #expect(IconDocument(groups: []).json.formatted() == "{\n  \"groups\" : [\n\n  ]\n}")
    }

    @Test func handEditedLayoutsAndUnknownKeysAreRead() throws {
        let d = try doc(#"{"groups":[{"layers":[],"future":{"a":[1,2]}},{"layers":[{"name":"x"}]}], "fill": "system-dark", "new-key": true}"#)
        #expect(d.groups.count == 2)
        #expect(d.fill.value == .systemDark)
        let again = try IconDocument(data: d.data())
        #expect(again.groups[0].extra["future"] == .object(["a": .array([.number(1), .number(2)])]))
        #expect(again.extra["new-key"] == .bool(true))
    }

    @Test func numbersAreWrittenShortest() {
        #expect(IconJSON.format(1) == "1")
        #expect(IconJSON.format(-30) == "-30")
        #expect(IconJSON.format(0.3) == "0.3")
        #expect(IconJSON.format(20.5) == "20.5")
        #expect(IconJSON.format(0.00001) == "1e-05")
    }

    @Test func colorsParseAndKeepTheirText() throws {
        let c = try IconColor(parsing: "extended-srgb:0.00000,0.53333,1.00000,1.00000")
        #expect(c.space == .extendedSRGB && c.components == [0, 0.53333, 1, 1])
        #expect(c.description == "extended-srgb:0.00000,0.53333,1.00000,1.00000")
        // Hand-written text is kept as it was while the components are unchanged.
        #expect(try IconColor(parsing: "srgb:1,0,0,1").description == "srgb:1,0,0,1")
        var changed = try IconColor(parsing: "gray:0.5,1")
        changed.components[0] = 0.25
        #expect(changed.description == "gray:0.25000,1.00000")
    }

    // MARK: Errors (README-icon.md ICON-READER)

    @Test(arguments: [
        (#"{"fill":"x"}"#, "missing: groups"),
        (#"{"groups":[{"layers":[],"blend-mode":"dissolve"}]}"#, "Invalid blend mode"),
        (#"{"groups":[],"fill":"sunny"}"#, "A fill should be one of"),
        (#"{"groups":[],"fill":{"solid":"srgb:1,0,0,1","automatic-gradient":"srgb:1,0,0,1"}}"#, "A fill should be one of"),
        (#"{"groups":[],"fill":{"solid":"rgb:1,0,0,1"}}"#, "Invalid color space"),
        (#"{"groups":[],"fill":{"solid":"system-red"}}"#, "missing ':' delimiter"),
        (#"{"groups":[],"fill":{"solid":"srgb:1,0,0"}}"#, "takes 4 components"),
        (#"{"groups":[],"fill":{"linear-gradient":["gray:1,1","gray:0,1","gray:0.5,1"]}}"#, "exactly two colors"),
        (#"{"groups":[{"layers":[],"lighting":"global"}]}"#, "Invalid lighting"),
        (#"{"groups":[],"fill-specializations":[{"appearance":"clear","value":"automatic"}]}"#, "invalid appearance"),
        (#"{"groups":[],"fill-specializations":[{"idiom":"universal","value":"automatic"}]}"#, "invalid idiom"),
        (#"{"groups":[],"supported-platforms":{"squares":["tvOS"]}}"#, "unknown platform"),
        (#"{"groups":[{"layers":[],"refractivity":{"enabled":true,"strength":1}}]}"#, "needs enabled, strength and depth"),
        (#"{"groups":[],"color-space-for-untagged-svg-colors":"srgb"}"#, "Invalid color space"),
        (#"{"groups":[{"name":"no layers"}]}"#, "missing: layers"),
        (#"[1]"#, "isn't in the correct format"),
    ])
    func invalidDocumentsAreErrors(_ text: String, _ message: String) {
        do {
            _ = try doc(text)
            Issue.record("read \(text)")
        } catch {
            #expect("\(error)".contains(message), "\(error)")
        }
    }

    // MARK: Specializations (§5)

    @Test func renditionsUseTheirAppearancesEntries() throws {
        let d = try doc(#"""
        {"groups":[{"layers":[],"opacity":0.9,"opacity-specializations":[
          {"value":0.1},{"appearance":"light","value":0.2},{"appearance":"dark","value":0.3},{"appearance":"tinted","value":0.4}]}]}
        """#)
        let o = d.groups[0].opacity
        let table: [(IconRendition, Double)] = [(.default, 0.2), (.dark, 0.3), (.tintedLight, 0.4), (.tintedDark, 0.4), (.clearLight, 0.4), (.clearDark, 0.4)]
        for (r, v) in table { #expect(o.resolve(r.appearance, .iOS) == v, "\(r)") }
        // With specializations present, the plain key is not used.
        #expect(d.resolved(IconAppearance.dark, .iOS).groups[0].opacity == 0.3)
    }

    @Test func darkEntriesDoNotApplyToTintedDark() throws {
        let d = try doc(#"{"groups":[{"layers":[],"opacity-specializations":[{"value":1},{"appearance":"dark","value":0.3}]}]}"#)
        #expect(d.resolved(.tintedDark, .iOS).groups[0].opacity == 1)
        #expect(d.resolved(IconAppearance.dark, .iOS).groups[0].opacity == 0.3)
    }

    @Test func idiomsApplyToTheirPlatforms() throws {
        let d = try doc(#"""
        {"groups":[{"layers":[],"opacity-specializations":[{"value":1},{"idiom":"square","value":0.5},{"idiom":"macOS","value":0.25},{"idiom":"watchOS","value":0.75}]}]}
        """#)
        #expect(d.resolved(IconAppearance.light, .iOS).groups[0].opacity == 0.5)
        #expect(d.resolved(IconAppearance.light, .macOS).groups[0].opacity == 0.25)
        #expect(d.resolved(IconAppearance.light, .watchOS).groups[0].opacity == 0.75)
        #expect(IconIdiom.iOS.applies(to: .iOS) && !IconIdiom.iOS.applies(to: .macOS))
    }

    @Test func appearanceOutranksIdiomInYcodesPrecedence() throws {
        let d = try doc(#"{"groups":[{"layers":[],"opacity-specializations":[{"idiom":"square","value":0.5},{"appearance":"dark","value":0.3}]}]}"#)
        #expect(d.resolved(IconAppearance.dark, .iOS).groups[0].opacity == 0.3)
        #expect(d.resolved(IconAppearance.light, .iOS).groups[0].opacity == 0.5)
        #expect(d.resolved(IconAppearance.light, .watchOS).groups[0].opacity == 1)
    }

    // MARK: Defaults (§3)

    @Test func defaultsApplyWhenKeysAreAbsent() throws {
        let r = try doc(#"{"groups":[{"layers":[{"image-name":"a.svg"}]}]}"#).resolved(.light, .iOS)
        let g = r.groups[0], l = g.layers[0]
        #expect(!g.hidden && g.opacity == 1 && g.blendMode == .normal && g.position == .identity)
        #expect(g.shadow == IconShadow(kind: .neutral, opacity: 0.5))
        #expect(g.translucency == IconTranslucency(enabled: true, value: 0.3))
        #expect(g.specular && g.specularHighlightPlacement == .automatic && g.lighting == .individual)
        #expect(g.blurMaterial.effectiveValue == 0 && g.refractivity == .disabled)
        #expect(!l.hidden && l.opacity == 1 && l.blendMode == .normal && l.fill == .automatic && l.glass)
        #expect(r.background == .solid(.extendedGray(1)))
        #expect(r.canvasSize == 1024)
        #expect(IconPlatform.watchOS.canvasSize == 1088)
    }

    @Test func backgroundsPerAppearance() throws {
        let plain = try doc(#"{"groups":[]}"#)
        #expect(plain.background(.light, .iOS) == .solid(.extendedGray(1)))
        #expect(plain.background(.tinted, .iOS) == .solid(.extendedGray(1)))
        #expect(plain.background(.dark, .iOS) == .systemDark)
        let solid = try doc(#"{"groups":[],"fill":{"solid":"srgb:1,0,0,1"}}"#)
        #expect(solid.background(.light, .iOS) == .solid(.srgb(1, 0, 0)))
        // The compiled output gives a plain fill the system dark gradient in dark.
        #expect(solid.background(.dark, .iOS) == .systemDark)
        let dark = try doc(#"{"groups":[],"fill-specializations":[{"value":"automatic"},{"appearance":"dark","value":{"solid":"srgb:0,0,1,1"}}]}"#)
        #expect(dark.background(.dark, .iOS) == .solid(.srgb(0, 0, 1)))
        #expect(IconBackground(.automatic, appearance: .light) == .systemLight)
        #expect(IconBackground(.automatic, appearance: .dark) == .systemDark)
        #expect(IconBackground.systemLight.stops.map(\.color.components[0]) == [1, 0.925])
        #expect(IconBackground.systemDark.stops.map(\.color.components[0]) == [0.192, 0.078])
    }

    @Test func valueForKeyAppliesSpecializationsAndDefaults() throws {
        let d = try doc(Self.everyKey)
        #expect(d.value(for: "groups[0].opacity", appearance: .dark, platform: .iOS) == .number(0.6))
        #expect(d.value(for: "groups[0].opacity", appearance: .light, platform: .iOS) == .number(0.9))
        #expect(d.value(for: "groups[0].hidden", appearance: .light, platform: .macOS) == .bool(true))
        #expect(d.value(for: "groups[0].layers[0].image-name", appearance: .dark, platform: .iOS) == .string("ring-dark.svg"))
        #expect(d.value(for: "groups[0].layers[0].opacity", appearance: .light, platform: .iOS) == .number(0.5))
        #expect(d.value(for: "groups[0].layers[0].opacity", appearance: .light, platform: .watchOS) == .number(0.75))
        #expect(d.value(for: "groups[0].layers[1].glass", appearance: .light, platform: .iOS) == .bool(true))
        #expect(d.value(for: "groups[1].specular", appearance: .tinted, platform: .iOS) == .bool(true))
        #expect(d.value(for: "groups[0].specular", appearance: .light, platform: .iOS) == .bool(true))
        #expect(d.value(for: "groups[0].specular", appearance: .light, platform: .macOS) == .bool(false))
        #expect(d.value(for: "groups[0].blend-mode", appearance: .tinted, platform: .iOS) == .string("screen"))
        #expect(d.value(for: "groups[3].opacity", appearance: .light, platform: .iOS) == nil)
    }

    // MARK: Frames (§4.4)

    @Test func layerFramesFollowTheSpecExample() {
        let f = IconGeometry.layerFrame(natural: IconSize(width: 400, height: 400), layer: .identity,
                                        group: IconPosition(scale: 2, translation: IconPoint(x: 50, y: -30)), canvas: 1024)
        #expect(f == IconRect(x: 162, y: 82, width: 800, height: 800))
        // Positive y moves down; the layer's own position comes first.
        let g = IconGeometry.layerFrame(natural: IconSize(width: 100, height: 50), layer: IconPosition(scale: 2, translation: IconPoint(x: 0, y: 10)),
                                        group: .identity, canvas: 1024)
        #expect(g == IconRect(x: 412, y: 472, width: 200, height: 100))
        let w = IconGeometry.layerFrame(natural: IconSize(width: 1088, height: 1088), layer: .identity, group: .identity, canvas: 1088)
        #expect(w == IconRect(x: 0, y: 0, width: 1088, height: 1088))
    }

    @Test func naturalSizesOfSVGAndPNG() {
        #expect(IconImageInfo.svgSize(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="400px" height="300" viewBox="0 0 10 10">"#)
                == IconSize(width: 400, height: 300))
        #expect(IconImageInfo.svgSize(#"<svg viewBox="0 0 512 256" xmlns="http://www.w3.org/2000/svg"></svg>"#) == IconSize(width: 512, height: 256))
        #expect(IconImageInfo.svgSize(#"<svg stroke-width="3" viewBox="0,0,20,30">"#) == IconSize(width: 20, height: 30))
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
        png += [0, 0, 0x01, 0x00, 0, 0, 0, 0x80, 8, 6, 0, 0, 0, 0, 0, 0, 0]
        #expect(IconImageInfo.naturalSize(Data(png)) == IconSize(width: 256, height: 128))
    }
}

/// The package on disk: reading, writing, frames from real files, validation.
struct IconPackageTests {
    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func packageWritesAndReadsWithAssets() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assets = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><circle cx="200" cy="200" r="150"/></svg>"#.utf8)
            .write(to: assets.appendingPathComponent("ring.svg"))
        var group = IconGroup(name: "Front", layers: [IconLayer(name: "ring", imageName: "ring.svg"), IconLayer(name: "gone", imageName: "missing.png")])
        group.position = IconSpecialized(IconPosition(scale: 2, translation: IconPoint(x: 50, y: -30)))
        let pkg = IconPackage(url: dir.appendingPathComponent("AppIcon.icon"), document: IconDocument(fill: .automatic, groups: [group]))
        try pkg.write(copyingAssetsFrom: assets)
        let back = try IconPackage(contentsOf: pkg.url)
        #expect(back.name == "AppIcon")
        #expect(back.document == pkg.document)
        #expect(back.assetNames == ["ring.svg"])
        #expect(back.referencedImageNames == ["ring.svg", "missing.png"])
        let frames = back.layerFrames(.light, .iOS)
        #expect(frames.count == 1)
        #expect(frames[0].frame == IconRect(x: 162, y: 82, width: 800, height: 800))
        let issues = back.validate()
        #expect(issues.contains { $0.message.contains("Assets/missing.png is missing") })
        #expect(!issues.contains { $0.severity == .error })
    }

    @Test func tooManyVisibleGroupsIsAWarning() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var groups = (0..<5).map { IconGroup(name: "g\($0)", layers: [IconLayer(imageName: "a.svg")]) }
        let pkg = IconPackage(url: dir.appendingPathComponent("X.icon"), document: IconDocument(groups: groups))
        #expect(pkg.validate().contains { $0.message.hasPrefix("too-many-visible-groups") })
        groups[4].hidden = IconSpecialized(true)
        let ok = IconPackage(url: pkg.url, document: IconDocument(groups: groups))
        #expect(!ok.validate().contains { $0.message.hasPrefix("too-many-visible-groups") })
    }

    @Test func missingIconJSONIsAnError() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: IconError.self) { try IconPackage(contentsOf: dir) }
    }
}
