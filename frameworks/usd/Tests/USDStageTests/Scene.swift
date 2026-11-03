import Testing
import USDCore
@testable import USDStage

/// A small composition scene. The expected values in the tests below were
/// read from OpenUSD (usd-core 26.11) composing the same four layers.
enum Scene {
    static let root = """
    #usda 1.0
    (
        defaultPrim = "World"
        subLayers = [
            @./sub.usda@ (offset = 5)
        ]
    )

    def Xform "World"
    {
        def "Robot" (
            prepend references = @./robot.usda@
            variants = {
                string color = "blue"
            }
        )
        {
            over "Arm"
            {
                float length = 3
            }
        }

        def "Lamp" (
            prepend payload = @./lamp.usda@</Lamp>
        )
        {
        }

        def "Instance" (
            prepend inherits = </_Class>
        )
        {
        }

        def "Special" (
            prepend specializes = </_Spec>
        )
        {
            float s = 1
        }

        def "Internal" (
            prepend references = </World/Robot>
        )
        {
        }
    }

    class "_Class"
    {
        custom string note = "from class"

        def "ClassChild"
        {
        }
    }

    class "_Spec"
    {
        float s = 7
        float t = 8
    }
    """
    static let sub = """
    #usda 1.0

    over "World"
    {
        over "Robot"
        {
            float anim.timeSamples = {
                0: 0,
                10: 10,
            }
            float weight = 10
        }

        def "FromSub"
        {
        }
    }
    """
    static let robot = """
    #usda 1.0
    (
        defaultPrim = "Robot"
    )

    def Xform "Robot" (
        variants = {
            string color = "red"
        }
        prepend variantSets = "color"
    )
    {
        rel target = </Robot/Arm>
        float weight = 1

        def "Arm"
        {
            float length = 1
        }
        variantSet "color" = {
            "blue" {
                float hue = 240

                def "BlueOnly"
                {
                }

            }
            "red" {
                float hue = 0

            }
        }
    }
    """
    static let lamp = """
    #usda 1.0

    def "Lamp"
    {
        float intensity = 5
    }
    """

    static func stage() throws -> Stage {
        let layers = try [("root", root), ("sub", sub), ("robot", robot), ("lamp", lamp)].map {
            try USDAReader.read($0.1, identifier: "/mem/\($0.0).usda")
        }
        let resolver = MemoryLayerResolver(layers: layers)
        return Stage(rootLayer: layers[0], resolver: resolver)
    }
}
